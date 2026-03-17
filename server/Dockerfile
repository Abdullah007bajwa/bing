# Ghost Relay — Multi-stage Docker build
# Final image: distroless/static — no shell, no package manager, minimal attack surface

FROM golang:1.24-alpine AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-w -s" -o relay ./cmd/relay

# ── Minimal production image ────────────────────────────────────────────────
FROM gcr.io/distroless/static:nonroot

COPY --from=builder /app/relay /relay

EXPOSE 8080
ENTRYPOINT ["/relay"]
