package liquidation

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/ethereum/go-ethereum/ethclient"
)

// HealthChecker 健康检查器 / Health checker
type HealthChecker struct {
	bot    *Bot
	client *ethclient.Client
	server *http.Server
}

// NewHealthChecker 创建健康检查器 / Create health checker
func NewHealthChecker(bot *Bot, client *ethclient.Client, port string) *HealthChecker {
	hc := &HealthChecker{
		bot:    bot,
		client: client,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", hc.healthHandler)
	mux.HandleFunc("/metrics", hc.metricsHandler)
	mux.HandleFunc("/status", hc.statusHandler)

	hc.server = &http.Server{
		Addr:    ":" + port,
		Handler: mux,
	}

	return hc
}

// Start 启动健康检查服务器 / Start health check server
func (hc *HealthChecker) Start() error {
	go func() {
		if err := hc.server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			fmt.Printf("Health check server error: %v\n", err)
		}
	}()
	return nil
}

// Stop 停止健康检查服务器 / Stop health check server
func (hc *HealthChecker) Stop(ctx context.Context) error {
	return hc.server.Shutdown(ctx)
}

// healthHandler 健康检查处理器 / Health check handler
func (hc *HealthChecker) healthHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// 检查 RPC 连接 / Check RPC connection
	_, err := hc.client.BlockNumber(ctx)
	if err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		json.NewEncoder(w).Encode(map[string]interface{}{
			"status":  "unhealthy",
			"error":   err.Error(),
			"service": "liquidation-bot",
		})
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":  "healthy",
		"service": "liquidation-bot",
		"time":    time.Now().Unix(),
	})
}

// metricsHandler 指标处理器 / Metrics handler
func (hc *HealthChecker) metricsHandler(w http.ResponseWriter, r *http.Request) {
	stats := hc.bot.GetMetrics()
	
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"total_checks":            stats.TotalChecks,
		"total_liquidations":      stats.TotalLiquidations,
		"successful_liquidations": stats.SuccessfulLiquidations,
		"failed_liquidations":     stats.FailedLiquidations,
		"success_rate":            stats.SuccessRate,
		"last_check_time":         stats.LastCheckTime.Unix(),
		"last_liquidation_time":   stats.LastLiquidationTime.Unix(),
		"average_check_duration":  stats.AverageCheckDuration.Milliseconds(),
	})
}

// statusHandler 状态处理器 / Status handler
func (hc *HealthChecker) statusHandler(w http.ResponseWriter, r *http.Request) {
	stats := hc.bot.GetMetrics()
	
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	blockNumber, _ := hc.client.BlockNumber(ctx)
	
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"service":      "liquidation-bot",
		"status":        "running",
		"block_number":  blockNumber,
		"metrics":       stats,
		"uptime":        time.Since(stats.LastCheckTime).String(),
	})
}
