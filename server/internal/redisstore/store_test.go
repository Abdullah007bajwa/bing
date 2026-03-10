package redisstore

import (
	"context"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

func TestStore_StoreAndFetch(t *testing.T) {
	// Setup miniredis (in-memory redis for testing)
	mr, err := miniredis.Run()
	if err != nil {
		t.Fatalf("failed to start miniredis: %v", err)
	}
	defer mr.Close()

	rdb := redis.NewClient(&redis.Options{
		Addr: mr.Addr(),
	})
	store := &Store{rdb: rdb}
	ctx := context.Background()

	userID := "user123"
	msgID := "msg456"
	data := []byte(`{"ciphertext":"base64encoded="}`)

	// Store message
	err = store.Store(ctx, userID, msgID, data, 1*time.Hour)
	if err != nil {
		t.Fatalf("failed to store message: %v", err)
	}

	// Fetch messages
	packets, err := store.FetchAll(ctx, userID)
	if err != nil {
		t.Fatalf("failed to fetch messages: %v", err)
	}

	if len(packets) != 1 {
		t.Fatalf("expected 1 packet, got %d", len(packets))
	}

	if string(packets[0]) != string(data) {
		t.Errorf("expected packet data %s, got %s", data, packets[0])
	}
}

func TestStore_DeleteAll(t *testing.T) {
	mr, _ := miniredis.Run()
	defer mr.Close()

	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	store := &Store{rdb: rdb}
	ctx := context.Background()

	userID := "abc"
	_ = store.Store(ctx, userID, "1", []byte("data1"), time.Hour)
	_ = store.Store(ctx, userID, "2", []byte("data2"), time.Hour)

	// Delete
	err := store.DeleteAll(ctx, userID)
	if err != nil {
		t.Fatalf("Failed to delete: %v", err)
	}

	// Fetch should return empty
	packets, err := store.FetchAll(ctx, userID)
	if err != nil {
		t.Fatalf("Fetch error: %v", err)
	}
	if len(packets) != 0 {
		t.Errorf("Expected 0 packets after deletion, got %d", len(packets))
	}
}

func TestStore_TTL(t *testing.T) {
	mr, _ := miniredis.Run()
	defer mr.Close()

	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	store := &Store{rdb: rdb}
	ctx := context.Background()

	// Store with 1 second TTL
	err := store.Store(ctx, "user", "msg", []byte("data"), 1*time.Second)
	if err != nil {
		t.Fatalf("Failed to store: %v", err)
	}

	// Fast forward time in miniredis
	mr.FastForward(2 * time.Second)

	packets, err := store.FetchAll(ctx, "user")
	if err != nil {
		t.Fatalf("Fetch error: %v", err)
	}
	if len(packets) != 0 {
		t.Errorf("Expected message to be deleted by TTL, but got %d packets", len(packets))
	}
}
