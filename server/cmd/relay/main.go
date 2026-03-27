// server/cmd/relay/main.go
// Ghost relay server entry point.
// WebSocket relay + Redis TTL store + health API.
// Intended to run on Render (see render.yaml).

package main

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/ghostmsg/relay/internal/push"
	"github.com/ghostmsg/relay/internal/redisstore"
	"github.com/ghostmsg/relay/internal/ws"
	"github.com/gorilla/websocket"
	"github.com/joho/godotenv"
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

	// GOMAXPROCS: match Render instance CPU (set GOMAXPROCS in env if needed)
	if v := os.Getenv("GOMAXPROCS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			runtime.GOMAXPROCS(n)
		}
	}

	// Load .env file (ignores error if running in production where file doesn't exist)
	_ = godotenv.Load()

	port := getEnv("PORT", "8080")
	redisURL := getEnv("REDIS_URL", "redis://localhost:6379")
	fcmServerKey := strings.TrimSpace(os.Getenv("FCM_SERVER_KEY"))

	// ── Redis ─────────────────────────────────────────────────────────────────
	store, err := redisstore.NewStore(redisURL)
	if err != nil {
		log.Fatal().Err(err).Msg("redis connection failed")
	}
	defer store.Close()
	log.Info().Msg("redis connected")

	// ── WebSocket Hub ─────────────────────────────────────────────────────────
	fcmPush := push.NewFCM(fcmServerKey)
	hub := ws.NewHub(store, fcmPush)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go hub.Run(ctx)

	// ── HTTP Routes ───────────────────────────────────────────────────────────
	mux := http.NewServeMux()

	// WebSocket upgrade
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		// Extract user_id from query param — no auth token needed (anonymous relay)
		uid := strings.TrimSpace(r.URL.Query().Get("uid"))
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

	mux.HandleFunc("/register_device", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var req struct {
			UserID   string `json:"user_id"`
			FCMToken string `json:"fcm_token"`
			Platform string `json:"platform"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "bad json", http.StatusBadRequest)
			return
		}
		req.UserID = strings.TrimSpace(req.UserID)
		req.FCMToken = strings.TrimSpace(req.FCMToken)
		if req.UserID == "" || req.FCMToken == "" {
			http.Error(w, "missing user_id or fcm_token", http.StatusBadRequest)
			return
		}
		if err := store.RegisterDeviceToken(r.Context(), req.UserID, req.FCMToken, 30*24*time.Hour); err != nil {
			http.Error(w, "redis error", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
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
