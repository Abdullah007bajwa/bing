// server/internal/model/packet.go
// Relay packet definition.
// This is the ONLY data structure the server ever processes.
// No sender IP, no reading timestamps, no user metadata.

package model

// Packet is the unit of relay. Server never inspects Ciphertext.
type Packet struct {
	// Routing fields (server reads these)
	ID      string `json:"id"`           // sender-generated random nonce (UUID) to prevent replay
	To      string `json:"to"`           // recipient user_id (hash of pubkey)
	MsgType string `json:"msg_type"`     // "prekey" | "signal" | "group" | "key_exchange"
	TTL     int    `json:"ttl_seconds"`  // 1–86400; default 3600

	// Payload (server never reads or logs this)
	Ciphertext string `json:"ciphertext"` // base64 Signal ciphertext
}

// Envelope wraps an incoming packet for local routing.
// SenderID is set so recipient can create contact on first message.
type Envelope struct {
	Packet   Packet
	SenderID string // user_id of sender (for Delivery.From)
}

// Delivery is sent back to the recipient.
// From is used only for routing/trial-decrypt so recipient can create contact on first message.
// Sender identity is still cryptographically sealed in the ciphertext.
type Delivery struct {
	From       string `json:"from"`        // sender user_id (routing only; not stored long-term by client)
	Ciphertext string `json:"ciphertext"`  // pass-through, untouched
	MsgType    string `json:"msg_type"`
	TTL        int    `json:"ttl_seconds"`
	ID         string `json:"id"`          // relay-assigned UUID for dedup
}
