package push

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

type FCM struct {
	serverKey string
	client    *http.Client
}

func NewFCM(serverKey string) *FCM {
	return &FCM{
		serverKey: strings.TrimSpace(serverKey),
		client:    &http.Client{Timeout: 5 * time.Second},
	}
}

func (f *FCM) Enabled() bool {
	return f.serverKey != ""
}

func (f *FCM) SendNewMessage(ctx context.Context, token, senderID string) error {
	if !f.Enabled() || strings.TrimSpace(token) == "" {
		return nil
	}
	title := senderID
	if len(title) > 12 {
		title = title[:12]
	}
	payload := map[string]any{
		"to": token,
		"notification": map[string]any{
			"title": title,
			"body":  "New message",
		},
		"data": map[string]any{
			"type":      "new_message",
			"sender_id": senderID,
		},
		"priority": "high",
	}
	b, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://fcm.googleapis.com/fcm/send", bytes.NewReader(b))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "key="+f.serverKey)
	resp, err := f.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("fcm status %d", resp.StatusCode)
	}
	return nil
}
