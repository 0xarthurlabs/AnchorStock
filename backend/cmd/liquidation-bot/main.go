package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"anchorstock-backend/internal/config"
	"anchorstock-backend/internal/liquidation"

	"github.com/ethereum/go-ethereum/ethclient"
)

func main() {
	log.Println("Starting AnchorStock Liquidation Bot...")

	// 加载配置 / Load configuration
	cfg := config.Load()

	// 验证必要的配置 / Validate required configuration
	if cfg.LendingPoolContractAddress == "" && cfg.PerpEngineContractAddress == "" {
		log.Fatal("Neither LendingPool nor PerpEngine contract address is configured")
	}

	if cfg.PrivateKey == "" {
		log.Fatal("Private key not configured")
	}

	// 创建并启动清算机器人 / Create and start liquidation bot
	bot, err := liquidation.NewBot(cfg)
	if err != nil {
		log.Fatalf("Failed to create liquidation bot: %v", err)
	}

	// 注意：清算机器人会自动从链上事件中发现所有活跃仓位
	// Note: Liquidation bot will automatically discover all active positions from chain events
	// 无需手动配置监控用户列表 / No need to manually configure monitored users list

	if err := bot.Start(); err != nil {
		log.Fatalf("Failed to start liquidation bot: %v", err)
	}

	// 创建健康检查服务器 / Create health check server
	ethClient, err := ethclient.Dial(cfg.RPCURL)
	if err == nil {
		healthChecker := liquidation.NewHealthChecker(bot, ethClient, "8080")
		if err := healthChecker.Start(); err != nil {
			log.Printf("Warning: Failed to start health check server: %v\n", err)
		} else {
			log.Println("Health check server started on :8080")
			log.Println("  - GET /health - Health check")
			log.Println("  - GET /metrics - Metrics")
			log.Println("  - GET /status - Status")
		}
		defer func() {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			healthChecker.Stop(ctx)
			ethClient.Close()
		}()
	}

	// 等待中断信号 / Wait for interrupt signal
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)

	<-sigChan
	log.Println("Received interrupt signal, shutting down...")

	// 优雅关闭 / Graceful shutdown
	bot.Stop()

	log.Println("Liquidation Bot stopped")
}
