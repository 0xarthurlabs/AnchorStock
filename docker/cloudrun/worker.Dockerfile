# Go worker image (relayer | ohlcv-consumer | oracle-consumer | liquidation-bot).
# Build from repo root: docker build -f docker/cloudrun/worker.Dockerfile --build-arg GO_CMD=relayer .

FROM golang:1.24.3-alpine AS build
WORKDIR /src
RUN apk add --no-cache ca-certificates tzdata git
COPY backend/go.mod backend/go.sum ./backend/
WORKDIR /src/backend
RUN go mod download
COPY backend/ ./

ARG GO_CMD=relayer
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /out/worker ./cmd/${GO_CMD}

FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /app
COPY --from=build /out/worker /app/worker
USER nonroot:nonroot
ENTRYPOINT ["/app/worker"]
