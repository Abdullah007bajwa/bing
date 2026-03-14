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

			// Deliver any pending offline messages (recover so one panic doesn't kill the goroutine)
			go func(client *Client) {
				defer func() {
					if r := recover(); r != nil {
						log.Error().Interface("panic", r).Msg("deliverPending panic recovered")
					}
				}()
				h.deliverPending(client)
			}(c)

		case c := <-h.unregister:
			h.mu.Lock()
			if _, ok := h.clients[c.ID]; ok {
				delete(h.clients, c.ID)
				close(c.Send)
			}
			h.mu.Unlock()
			log.Info().Str("user", c.ID[:8]+"…").Msg("client disconnected")

		case env := <-h.relay:
			func() {
				defer func() {
					if r := recover(); r != nil {
						log.Error().Interface("panic", r).Msg("hub route panic recovered")
					}
				}()
				h.route(env)
			}()
		}
	}
}

// route either delivers to an online client or stores in Redis for TTL.
func (h *Hub) route(env model.Envelope) {
	delivery := model.Delivery{
		From: env.SenderID,
		ID:   env.Packet.ID, // Preserve sender-chosen id so clients can ack/read + dedup.
	}
	if env.Packet.Type == "receipt" {
		delivery.Type = "receipt"
		delivery.Receipt = env.Packet.Receipt
		delivery.MsgID = env.Packet.MsgID
	} else {
		delivery.Ciphertext = env.Packet.Ciphertext
		delivery.MsgType = env.Packet.MsgType
		delivery.TTL = env.Packet.TTL
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

	log.Info().Str("to", env.Packet.To).Bool("recipient_online", online).Msg("[Hub] routing")

	if online {
		// Direct relay — no Redis touch
		select {
		case recipient.Send <- data:
			log.Info().Str("from", env.SenderID).Str("to", env.Packet.To).Str("pkt_id", env.Packet.ID).Msg("delivered to online client")
		default:
			// Recipient's send buffer full — store in Redis
			_ = h.store.Store(context.Background(), env.Packet.To, delivery.ID, data, ttl)
			log.Info().Str("from", env.SenderID).Str("to", env.Packet.To).Str("pkt_id", env.Packet.ID).Msg("recipient buffer full, stored pending")
		}
	} else {
		// Offline — store encrypted packet in Redis with TTL
		_ = h.store.Store(context.Background(), env.Packet.To, delivery.ID, data, ttl)
		log.Info().Str("from", env.SenderID).Str("to", env.Packet.To).Str("pkt_id", env.Packet.ID).Msg("recipient offline, stored pending")
	}
}

// deliverPending fetches and delivers all Redis-stored messages for a newly connected client.
func (h *Hub) deliverPending(c *Client) {
	ctx := context.Background()
	packets, err := h.store.FetchAll(ctx, c.ID)
	if err != nil {
		log.Info().Str("user", c.ID).Err(err).Msg("deliverPending fetch failed")
		return
	}
	n := len(packets)
	log.Info().Str("user", c.ID).Int("count", n).Msg("deliverPending")
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

	// Read pump: 64KB max packet, 5min idle timeout (close connections that don't ping)
	const idleTimeout = 5 * time.Minute
	c.Conn.SetReadLimit(64 * 1024)
	c.Conn.SetReadDeadline(time.Now().Add(idleTimeout))
	c.Conn.SetPongHandler(func(_ string) error {
		c.Conn.SetReadDeadline(time.Now().Add(idleTimeout))
		return nil
	})

	for {
		_, raw, err := c.Conn.ReadMessage()
		if err != nil {
			return
		}
		c.Conn.SetReadDeadline(time.Now().Add(idleTimeout))

		// Log that we received a frame (size only — never content)
		log.Debug().Str("user", c.ID[:min(8, len(c.ID))]+"…").Int("size", len(raw)).Msg("ws message received")

		var pkt model.Packet
		if err := json.Unmarshal(raw, &pkt); err != nil {
			log.Warn().Str("user", c.ID[:min(8, len(c.ID))]+"…").Err(err).Msg("packet dropped: malformed json")
			continue
		}

		// Skip control/auth frames (client sends uid+timestamp+signature first; no to/id)
		if pkt.To == "" && pkt.ID == "" {
			log.Debug().Str("user", c.ID[:min(8, len(c.ID))]+"…").Msg("control/auth frame, skipping")
			continue
		}

		// Basic validation — relay packets must have to and id
		if pkt.To == "" || pkt.ID == "" {
			log.Warn().Str("user", c.ID[:min(8, len(c.ID))]+"…").Str("to", pkt.To).Str("id", pkt.ID).Msg("packet dropped: empty to or id")
			continue
		}
		if pkt.Type == "receipt" {
			if pkt.Receipt == "" || pkt.MsgID == "" {
				log.Warn().Str("user", c.ID[:min(8, len(c.ID))]+"…").Msg("packet dropped: receipt missing receipt/msg_id")
				continue
			}
		} else {
			// Standard encrypted message packet
			if pkt.Ciphertext == "" {
				log.Warn().Str("user", c.ID[:min(8, len(c.ID))]+"…").Str("to", pkt.To).Str("pkt_id", pkt.ID).Msg("packet dropped: empty ciphertext")
				continue
			}
		}
		// Never relay to self
		if pkt.To == c.ID {
			log.Warn().Str("user", c.ID[:min(8, len(c.ID))]+"…").Msg("packet dropped: self-send")
			continue
		}

		// ── Relay Hardening (Phase 4) ───────────────────────────────────────

		ctx := context.Background()

		// 1. Rate Limiting (100 packets capacity, regenerates 100 per minute)
		allowed, err := h.store.AllowRateLimit(ctx, c.ID, 100, 100)
		if err != nil || !allowed {
			log.Warn().Str("user", c.ID[:8]).Msg("rate limit exceeded, dropping packet")
			continue
		}

		// 2. Replay Protection (track nonce for up to 24h)
		ttl := time.Duration(pkt.TTL) * time.Second
		if ttl <= 0 || ttl > 24*time.Hour {
			ttl = 24 * time.Hour
		}
		
		isNew, err := h.store.CheckReplay(ctx, pkt.ID, ttl)
		if err != nil || !isNew {
			log.Warn().Str("user", c.ID[:8]).Str("pkt", pkt.ID).Msg("replay detected, dropping packet")
			continue
		}

		// ────────────────────────────────────────────────────────────────────

		log.Info().Str("from", c.ID).Str("to", pkt.To).Str("pkt_id", pkt.ID).Str("type", pkt.Type).Msg("packet accepted, relaying")
		h.relay <- model.Envelope{Packet: pkt, SenderID: c.ID}
	}
}
