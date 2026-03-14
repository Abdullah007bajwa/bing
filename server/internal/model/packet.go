// server/internal/model/packet.go
// Relay packet definition.
// This is the ONLY data structure the server ever processes.
// No sender IP, no reading timestamps, no user metadata.

package model

// Packet is the unit of relay. Server never inspects Ciphertext.
type Packet struct {
	// Type allows non-message control packets (e.g. read receipts).
	// Empty or "message" means standard encrypted message relay.
	Type string `json:"type,omitempty"` // "message" | "receipt"

	// Routing fields (server reads these)
	ID      string `json:"id"`           // sender-generated random nonce (UUID) to prevent replay
	To      string `json:"to"`           // recipient user_id (hash of pubkey)
	MsgType string `json:"msg_type"`     // "prekey" | "signal" | "group" | "key_exchange"
	TTL     int    `json:"ttl_seconds"`  // 1–86400; default 3600

	// Payload (server never reads or logs this)
	Ciphertext string `json:"ciphertext"` // base64 Signal ciphertext

	// Receipt fields (for Type="receipt")
	Receipt string `json:"receipt,omitempty"` // "read"
	MsgID   string `json:"msg_id,omitempty"`  // original message id being acknowledged
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
	Ciphertext string `json:"ciphertext,omitempty"`  // pass-through, untouched (messages)
	MsgType    string `json:"msg_type,omitempty"`
	TTL        int    `json:"ttl_seconds,omitempty"`
	ID         string `json:"id"`                    // message id (sender-chosen) or control packet id

	// Control packets (e.g. read receipts)
	Type    string `json:"type,omitempty"`    // "receipt"
	Receipt string `json:"receipt,omitempty"` // "read"
	MsgID   string `json:"msg_id,omitempty"`  // message id being acknowledged
}
