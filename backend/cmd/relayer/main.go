package main

import (
	"log"
	"os"
	"os/signal"
	"syscall"

	"anchorstock-backend/internal/config"
	"anchorstock-backend/internal/relayer"
)

func main() {
	log.Println("Starting AnchorStock Price Relayer...")

	// 加载配置 / Load configuration
	cfg := config.Load()

	// 验证必要的配置 / Validate required configuration
	if len(cfg.StockSymbols) == 0 {
		log.Fatal("No stock symbols configured")
	}

	// 创建并启动 Relayer / Create and start Relayer
	relayerService, err := relayer.NewRelayer(cfg)
	if err != nil {
		log.Fatalf("Failed to create relayer: %v", err)
	}

	if err := relayerService.Start(); err != nil {
		log.Fatalf("Failed to start relayer: %v", err)
	}

	// 等待中断信号 / Wait for interrupt signal
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)

	<-sigChan
	log.Println("Received interrupt signal, shutting down...")

	// 优雅关闭 / Graceful shutdown
	relayerService.Stop()

	log.Println("Price Relayer stopped")
}
