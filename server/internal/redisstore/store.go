// server/internal/redisstore/store.go
// Redis ephemeral message store.
// Key pattern: ghost:pending:<user_id>:<msg_id>
// Every key has TTL — messages self-destruct on expiry.
// No plaintext is ever stored. Only base64 ciphertext blobs.

package redisstore

import (
	"context"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

const keyPrefix = "ghost:pending:"

type Store struct {
	rdb *redis.Client
}

func NewStore(redisURL string) (*Store, error) {
	opt, err := redis.ParseURL(redisURL)
	if err != nil {
		return nil, fmt.Errorf("redis URL parse: %w", err)
	}
	opt.MaxRetries    = 5
	opt.DialTimeout  = 5 * time.Second
	opt.ReadTimeout  = 3 * time.Second
	opt.WriteTimeout = 3 * time.Second

	rdb := redis.NewClient(opt)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := rdb.Ping(ctx).Err(); err != nil {
		return nil, fmt.Errorf("redis ping: %w", err)
	}
	return &Store{rdb: rdb}, nil
}

// Store saves an encrypted packet blob under the recipient's key with TTL.
func (s *Store) Store(ctx context.Context, toUserID, msgID string, data []byte, ttl time.Duration) error {
	key := fmt.Sprintf("%s%s:%s", keyPrefix, toUserID, msgID)
	return s.rdb.Set(ctx, key, data, ttl).Err()
}

// FetchAll returns all pending encrypted packets for a user.
func (s *Store) FetchAll(ctx context.Context, userID string) ([][]byte, error) {
	pattern := fmt.Sprintf("%s%s:*", keyPrefix, userID)
	keys, err := s.rdb.Keys(ctx, pattern).Result()
	if err != nil {
		return nil, err
	}
	if len(keys) == 0 {
		return nil, nil
	}

	values, err := s.rdb.MGet(ctx, keys...).Result()
	if err != nil {
		return nil, err
	}

	out := make([][]byte, 0, len(values))
	for _, v := range values {
		if v == nil {
			continue
		}
		out = append(out, []byte(v.(string)))
	}
	return out, nil
}

// DeleteAll removes all pending packets for a user after delivery.
func (s *Store) DeleteAll(ctx context.Context, userID string) error {
	pattern := fmt.Sprintf("%s%s:*", keyPrefix, userID)
	keys, err := s.rdb.Keys(ctx, pattern).Result()
	if err != nil || len(keys) == 0 {
		return err
	}
	return s.rdb.Del(ctx, keys...).Err()
}

// ── Relay Hardening (Phase 4) ───────────────────────────────────────────────

// CheckReplay uses SETNX to ensure a packet ID hasn't been seen recently.
// Returns true if the packet is NEW (allowed), false if it's a replay.
func (s *Store) CheckReplay(ctx context.Context, packetID string, ttl time.Duration) (bool, error) {
	if packetID == "" {
		return false, nil // reject packets without nonce
	}
	key := fmt.Sprintf("ghost:nonce:%s", packetID)
	
	// SETNX returns true if key was set (new packet), false if it existed (replay)
	return s.rdb.SetNX(ctx, key, "1", ttl).Result()
}

// AllowRateLimit implements a token bucket algorithm via Redis Lua script.
// Limits a user to 'capacity' packets, regenerating at 'ratePerMin'.
func (s *Store) AllowRateLimit(ctx context.Context, userID string, capacity int, ratePerMin int) (bool, error) {
	// Simple rate limiter script (token bucket)
	script := `
		var key = KEYS[1]
		var capacity = tonumber(ARGV[1])
		var rate = tonumber(ARGV[2])
		var now = tonumber(ARGV[3])
		
		var info = redis.call("HMGET", key, "tokens", "last_update")
		var tokens = tonumber(info[1])
		var last_update = tonumber(info[2])
		
		if not tokens then
			tokens = capacity
			last_update = now
		end
		
		-- replenish tokens based on time passed
		local delta_min = (now - last_update) / 60.0
		tokens = math.min(capacity, tokens + (delta_min * rate))
		
		if tokens >= 1 then
			redis.call("HMSET", key, "tokens", tokens - 1, "last_update", now)
			redis.call("EXPIRE", key, 3600) -- expire bucket after 1h inactivity
			return 1
		else
			return 0
		end
	`
	
	now := time.Now().Unix()
	key := fmt.Sprintf("ghost:ratelimit:%s", userID)
	
	val, err := s.rdb.Eval(ctx, script, []string{key}, capacity, ratePerMin, now).Result()
	if err != nil {
		return false, err
	}
	
	return val.(int64) == 1, nil
}

// Close shuts down the Redis connection gracefully.
func (s *Store) Close() error {
	return s.rdb.Close()
}

// HealthCheck pings Redis.
func (s *Store) HealthCheck(ctx context.Context) error {
	return s.rdb.Ping(ctx).Err()
}
