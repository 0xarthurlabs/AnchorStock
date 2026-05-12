package metrics

import (
	"log"
	"net/http"
	"sync"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var once sync.Once

// StartBackgroundServer starts a minimal Prometheus metrics HTTP server.
// If addr is empty, it does nothing.
func StartBackgroundServer(addr string) {
	if addr == "" {
		return
	}

	once.Do(func() {
		mux := http.NewServeMux()
		mux.Handle("/metrics", promhttp.Handler())

		srv := &http.Server{
			Addr:    addr,
			Handler: mux,
		}

		go func() {
			log.Printf("Metrics server listening on %s", addr)
			if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
				log.Printf("Metrics server failed: %v", err)
			}
		}()
	})
}

