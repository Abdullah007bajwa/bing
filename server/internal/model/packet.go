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
// NO SENDER IDENTITY IS TRACKED (Sealed Sender Model).
type Envelope struct {
	Packet Packet
}

// Delivery is sent back to the recipient.
// Note: No 'From' field exists. The sender identity is sealed within the ciphertext.
type Delivery struct {
	Ciphertext string `json:"ciphertext"`  // pass-through, untouched
	MsgType    string `json:"msg_type"`
	TTL        int    `json:"ttl_seconds"`
	ID         string `json:"id"`          // relay-assigned UUID for dedup
}
