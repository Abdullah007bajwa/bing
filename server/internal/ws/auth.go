package ws

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"time"

	"filippo.io/edwards25519/field"
)

// AuthHandshake is the signed client handshake:
// {"uid":"<user_id>","timestamp":"<unix_ms>","signature":"<b64>"}
type AuthHandshake struct {
	UID       string `json:"uid"`
	Timestamp string `json:"timestamp"`
	Signature string `json:"signature"`
}

// VerifyAuthHandshake verifies:
// - timestamp freshness (±5 minutes)
// - signature validity using the user's Supabase-registered public key
//
// Returns (ok, reason). reason is safe to log.
func VerifyAuthHandshake(ctx context.Context, uid string, timestamp string, signatureB64 string) (bool, string) {
	const toleranceSeconds = 300
	// Allow client clocks slightly ahead of the server (otherwise ageSec < 0 fails immediately).
	const maxFutureSkewSeconds = 120

	tsMs, err := strconv.ParseInt(timestamp, 10, 64)
	if err != nil {
		return false, "bad_timestamp"
	}
	nowMs := time.Now().UnixMilli()
	ageSec := (nowMs - tsMs) / 1000
	if ageSec < -maxFutureSkewSeconds || ageSec > toleranceSeconds {
		return false, "timestamp_out_of_tolerance"
	}

	pubKeyB64, err := fetchSupabasePublicKey(ctx, uid)
	if err != nil {
		return false, "supabase_public_key_unavailable"
	}

	pubKeyRaw, err := base64.StdEncoding.DecodeString(pubKeyB64)
	if err != nil {
		return false, "bad_public_key_b64"
	}
	pubKey32, err := normalizeSignalCurve25519PublicKey(pubKeyRaw)
	if err != nil {
		return false, "bad_public_key_format"
	}

	sig, err := base64.StdEncoding.DecodeString(signatureB64)
	if err != nil || len(sig) != 64 {
		return false, "bad_signature"
	}

	msg := []byte(fmt.Sprintf("%s:%s", uid, timestamp))
	if !verifySignalCurve25519Signature(pubKey32, msg, sig) {
		return false, "invalid_signature"
	}

	return true, "ok"
}

func fetchSupabasePublicKey(ctx context.Context, uid string) (string, error) {
	baseURL := os.Getenv("SUPABASE_URL")
	anonKey := os.Getenv("SUPABASE_ANON_KEY")
	if baseURL == "" || anonKey == "" {
		return "", errors.New("missing supabase env")
	}

	// GET /rest/v1/users?select=public_key&user_id=eq.<uid>&limit=1
	url := fmt.Sprintf("%s/rest/v1/users?select=public_key&user_id=eq.%s&limit=1", stringsTrimRightSlash(baseURL), uid)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("apikey", anonKey)
	req.Header.Set("Authorization", "Bearer "+anonKey)
	req.Header.Set("Accept", "application/json")

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("supabase status %d", resp.StatusCode)
	}

	var rows []struct {
		PublicKey string `json:"public_key"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&rows); err != nil {
		return "", err
	}
	if len(rows) == 0 || rows[0].PublicKey == "" {
		return "", errors.New("no public key")
	}
	return rows[0].PublicKey, nil
}

func stringsTrimRightSlash(s string) string {
	for len(s) > 0 && s[len(s)-1] == '/' {
		s = s[:len(s)-1]
	}
	return s
}

func normalizeSignalCurve25519PublicKey(raw []byte) ([32]byte, error) {
	// libsignal's ECPublicKey.serialize() is typically 33 bytes with a leading type byte (0x05).
	// Some callers may store 32 bytes; accept either.
	if len(raw) == 33 {
		raw = raw[1:]
	}
	if len(raw) != 32 {
		return [32]byte{}, errors.New("unexpected public key length")
	}
	var out [32]byte
	copy(out[:], raw)
	return out, nil
}

// verifySignalCurve25519Signature verifies the signature produced by libsignal's Curve.calculateSignature()
// and verified by Curve.verifySignature() using a Curve25519 public key.
//
// This follows the same approach used by common Go libsignal implementations:
// - Convert Curve25519 (Montgomery) public key to an Edwards key representation
// - Move sign bit from signature into public key encoding
// - Verify with standard Ed25519
func verifySignalCurve25519Signature(publicKey [32]byte, message []byte, signature []byte) bool {
	if len(signature) != 64 {
		return false
	}

	// Work on copies; we must not mutate caller slices/arrays.
	var pk [32]byte
	copy(pk[:], publicKey[:])
	sig := make([]byte, 64)
	copy(sig, signature)

	// Clear sign bit on Curve25519 public key before conversion.
	pk[31] &= 0x7f

	edPk, ok := montgomeryToEdwardsPublicKey(pk)
	if !ok {
		return false
	}

	// In the Signal-style signature scheme, the sign bit is carried in signature[63].
	edPk[31] |= sig[63] & 0x80
	sig[63] &= 0x7f

	return ed25519.Verify(ed25519.PublicKey(edPk[:]), message, sig)
}

func montgomeryToEdwardsPublicKey(mont [32]byte) ([32]byte, bool) {
	// y = (u - 1) / (u + 1)
	// where u is Montgomery x-coordinate, y is Edwards y-coordinate.
	var u field.Element
	if _, err := u.SetBytes(mont[:]); err != nil {
		return [32]byte{}, false
	}
	var one field.Element
	one.One()

	var uMinus1 field.Element
	uMinus1.Subtract(&u, &one)
	var uPlus1 field.Element
	uPlus1.Add(&u, &one)

	var inv field.Element
	inv.Invert(&uPlus1)

	var y field.Element
	y.Multiply(&uMinus1, &inv)

	yBytes := y.Bytes()
	var out [32]byte
	copy(out[:], yBytes)
	return out, true
}
