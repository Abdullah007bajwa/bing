// server/cmd/relay/main.go
// Ghost relay server entry point.
// WebSocket relay + Redis TTL store + health API.
// Intended to run on Render (see render.yaml).

package main

import (
	"context"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/ghostmsg/relay/internal/redisstore"
	"github.com/ghostmsg/relay/internal/ws"
	"github.com/gorilla/websocket"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
)

var upgrader = websocket.Upgrader{
	HandshakeTimeout: 10 * time.Second,
	ReadBufferSize:   1024,
	WriteBufferSize:  1024,
	// Only accept from known origins in production — or use AllowAll for dev
	CheckOrigin: func(r *http.Request) bool { return true },
}

func main() {
	// ── Structured JSON logging (no message content ever logged) ─────────────
	zerolog.TimeFieldFormat = zerolog.TimeFormatUnix
	zerolog.SetGlobalLevel(zerolog.InfoLevel)
	log.Logger = log.With().Str("svc", "ghost-relay").Logger()

	port     := getEnv("PORT",      "8080")
	redisURL := getEnv("REDIS_URL", "redis://localhost:6379")

	// ── Redis ─────────────────────────────────────────────────────────────────
	store, err := redisstore.NewStore(redisURL)
	if err != nil {
		log.Fatal().Err(err).Msg("redis connection failed")
	}
	defer store.Close()
	log.Info().Msg("redis connected")

	// ── WebSocket Hub ─────────────────────────────────────────────────────────
	hub := ws.NewHub(store)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go hub.Run(ctx)

	// ── HTTP Routes ───────────────────────────────────────────────────────────
	mux := http.NewServeMux()

	// WebSocket upgrade
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		// Extract user_id from query param — no auth token needed (anonymous relay)
		uid := r.URL.Query().Get("uid")
		if uid == "" || len(uid) < 8 {
			http.Error(w, "missing uid", http.StatusBadRequest)
			return
		}

		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			log.Warn().Err(err).Msg("ws upgrade failed")
			return
		}

		client := &ws.Client{
			ID:   uid,
			Conn: conn,
			Send: make(chan []byte, 256),
			Hub:  hub,
		}
		go hub.HandleClient(client)
	})

	// Health check (for Render load balancer)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		if err := store.HealthCheck(r.Context()); err != nil {
			http.Error(w, "redis unhealthy", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok","service":"ghost-relay"}`))
	})

	// ── Server ────────────────────────────────────────────────────────────────
	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	go func() {
		log.Info().Str("port", port).Msg("ghost relay listening")
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal().Err(err).Msg("server error")
		}
	}()

	// ── Graceful shutdown ─────────────────────────────────────────────────────
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Info().Msg("shutting down")
	cancel()

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()
	_ = srv.Shutdown(shutdownCtx)
	log.Info().Msg("relay stopped")
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
