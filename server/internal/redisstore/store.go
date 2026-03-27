// server/internal/redisstore/store.go
// Redis ephemeral message store.
// Key pattern: ghost:pending:<user_id>
// Value: Redis list of JSON blobs (ciphertext-only payloads / receipts).
// Key has TTL — pending queue self-destructs on expiry.
// No plaintext is ever stored. Only encrypted payloads and metadata.

package redisstore

import (
	"context"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

const keyPrefix = "ghost:pending:"
const deviceTokenPrefix = "ghost:device:"

func pendingKey(userID string) string {
	return fmt.Sprintf("%s%s", keyPrefix, userID)
}

func deviceKey(userID string) string {
	return fmt.Sprintf("%s%s", deviceTokenPrefix, userID)
}

type Store struct {
	rdb *redis.Client
}

func NewStore(redisURL string) (*Store, error) {
	opt, err := redis.ParseURL(redisURL)
	if err != nil {
		return nil, fmt.Errorf("redis URL parse: %w", err)
	}
	opt.MaxRetries = 5
	opt.DialTimeout = 5 * time.Second
	opt.ReadTimeout = 3 * time.Second
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
	key := pendingKey(toUserID)
	if err := s.rdb.RPush(ctx, key, data).Err(); err != nil {
		return err
	}

	// Maintain TTL on the pending queue. Use the maximum TTL seen so we don't shorten expiry.
	if ttl <= 0 {
		return nil
	}
	current, err := s.rdb.TTL(ctx, key).Result()
	if err != nil {
		return err
	}
	if current < 0 || ttl > current {
		return s.rdb.Expire(ctx, key, ttl).Err()
	}
	return nil
}

// FetchAll returns all pending encrypted packets for a user.
func (s *Store) FetchAll(ctx context.Context, userID string) ([][]byte, error) {
	key := pendingKey(userID)
	values, err := s.rdb.LRange(ctx, key, 0, -1).Result()
	if err != nil {
		return nil, err
	}
	if len(values) == 0 {
		return nil, nil
	}
	out := make([][]byte, 0, len(values))
	for _, v := range values {
		out = append(out, []byte(v))
	}
	return out, nil
}

// DeleteAll removes all pending packets for a user after delivery.
func (s *Store) DeleteAll(ctx context.Context, userID string) error {
	key := pendingKey(userID)
	return s.rdb.Del(ctx, key).Err()
}

func (s *Store) RegisterDeviceToken(ctx context.Context, userID, token string, ttl time.Duration) error {
	if userID == "" || token == "" {
		return nil
	}
	if ttl <= 0 {
		ttl = 30 * 24 * time.Hour
	}
	return s.rdb.Set(ctx, deviceKey(userID), token, ttl).Err()
}

func (s *Store) GetDeviceToken(ctx context.Context, userID string) (string, error) {
	v, err := s.rdb.Get(ctx, deviceKey(userID)).Result()
	if err == redis.Nil {
		return "", nil
	}
	return v, err
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
		local key = KEYS[1]
		local capacity = tonumber(ARGV[1])
		local rate = tonumber(ARGV[2])
		local now = tonumber(ARGV[3])

		local info = redis.call("HMGET", key, "tokens", "last_update")
		local tokens = tonumber(info[1])
		local last_update = tonumber(info[2])

		if tokens == nil or last_update == nil then
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
		end
		return 0
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
