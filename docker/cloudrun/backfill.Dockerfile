FROM golang:1.24.3-alpine AS build
WORKDIR /src
RUN apk add --no-cache ca-certificates tzdata git
COPY backend/go.mod backend/go.sum ./backend/
WORKDIR /src/backend
RUN go mod download
COPY backend/ ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /out/backfill ./cmd/backfill

FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /app
COPY --from=build /out/backfill /app/backfill
USER nonroot:nonroot
ENTRYPOINT ["/app/backfill"]
