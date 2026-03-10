// server/internal/ws/hub.go
// WebSocket hub: the core relay engine.
// Registers clients, relays encrypted packets, stores offline messages in Redis.
// NEVER logs message content. NEVER reads ciphertext.

package ws

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/ghostmsg/relay/internal/model"
	"github.com/ghostmsg/relay/internal/redisstore"
	"github.com/google/uuid"
	"github.com/gorilla/websocket"
	"github.com/rs/zerolog/log"
)

// Client represents a connected Ghost user.
type Client struct {
	ID   string          // user_id (base58 SHA-256 of pubkey) — set from URL param
	Conn *websocket.Conn
	Send chan []byte
	Hub  *Hub
}

// Hub manages all client connections and message routing.
type Hub struct {
	mu         sync.RWMutex
	clients    map[string]*Client // user_id → *Client
	register   chan *Client
	unregister chan *Client
	relay      chan model.Envelope
	store      *redisstore.Store
}

func NewHub(store *redisstore.Store) *Hub {
	return &Hub{
		clients:    make(map[string]*Client),
		register:   make(chan *Client, 64),
		unregister: make(chan *Client, 64),
		relay:      make(chan model.Envelope, 512),
		store:      store,
	}
}

func (h *Hub) Run(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return

		case c := <-h.register:
			h.mu.Lock()
			h.clients[c.ID] = c
			h.mu.Unlock()
			log.Info().Str("user", c.ID[:8]+"…").Msg("client connected")

			// Deliver any pending offline messages
			go h.deliverPending(c)

		case c := <-h.unregister:
			h.mu.Lock()
			if _, ok := h.clients[c.ID]; ok {
				delete(h.clients, c.ID)
				close(c.Send)
			}
			h.mu.Unlock()
			log.Info().Str("user", c.ID[:8]+"…").Msg("client disconnected")

		case env := <-h.relay:
			h.route(env)
		}
	}
}

// route either delivers to an online client or stores in Redis for TTL.
func (h *Hub) route(env model.Envelope) {
	delivery := model.Delivery{
		From:       env.From,
		Ciphertext: env.Packet.Ciphertext,
		MsgType:    env.Packet.MsgType,
		TTL:        env.Packet.TTL,
		ID:         uuid.NewString(),
	}
	data, err := json.Marshal(delivery)
	if err != nil {
		return
	}

	ttl := time.Duration(env.Packet.TTL) * time.Second
	if ttl <= 0 || ttl > 24*time.Hour {
		ttl = time.Hour // sanitize
	}

	h.mu.RLock()
	recipient, online := h.clients[env.Packet.To]
	h.mu.RUnlock()

	if online {
		// Direct relay — no Redis touch
		select {
		case recipient.Send <- data:
		default:
			// Recipient's send buffer full — store in Redis
			_ = h.store.Store(context.Background(), env.Packet.To, delivery.ID, data, ttl)
		}
	} else {
		// Offline — store encrypted packet in Redis with TTL
		_ = h.store.Store(context.Background(), env.Packet.To, delivery.ID, data, ttl)
	}
}

// deliverPending fetches and delivers all Redis-stored messages for a newly connected client.
func (h *Hub) deliverPending(c *Client) {
	ctx := context.Background()
	packets, err := h.store.FetchAll(ctx, c.ID)
	if err != nil {
		return
	}
	for _, p := range packets {
		select {
		case c.Send <- p:
		default:
		}
	}
	// Delete after delivery
	_ = h.store.DeleteAll(ctx, c.ID)
}

// HandleClient runs read/write pumps for a client connection.
func (h *Hub) HandleClient(c *Client) {
	h.register <- c
	defer func() { h.unregister <- c }()

	// Write pump
	go func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case msg, ok := <-c.Send:
				c.Conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
				if !ok {
					_ = c.Conn.WriteMessage(websocket.CloseMessage, []byte{})
					return
				}
				if err := c.Conn.WriteMessage(websocket.TextMessage, msg); err != nil {
					return
				}
			case <-ticker.C:
				c.Conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
				if err := c.Conn.WriteMessage(websocket.PingMessage, nil); err != nil {
					return
				}
			}
		}
	}()

	// Read pump
	c.Conn.SetReadLimit(64 * 1024) // 64KB max packet
	c.Conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	c.Conn.SetPongHandler(func(_ string) error {
		c.Conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		return nil
	})

	for {
		_, raw, err := c.Conn.ReadMessage()
		if err != nil {
			return
		}
		c.Conn.SetReadDeadline(time.Now().Add(60 * time.Second))

		var pkt model.Packet
		if err := json.Unmarshal(raw, &pkt); err != nil {
			continue // malformed — discard
		}

		// Basic validation: must have a recipient and ciphertext
		if pkt.To == "" || pkt.Ciphertext == "" {
			continue
		}
		// Never relay to self
		if pkt.To == c.ID {
			continue
		}

		h.relay <- model.Envelope{From: c.ID, Packet: pkt}
	}
}
