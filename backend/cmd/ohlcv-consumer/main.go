// OHLCV Consumer：从 Kafka 消费 stock-prices，写入 TimescaleDB stock_prices 表，
// 供 API 的 GetOHLCV（time_bucket 聚合）查询 K 线。与 Relayer 解耦：Relayer 只写 Kafka。
package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"anchorstock-backend/internal/config"
	"anchorstock-backend/internal/database"
	"anchorstock-backend/internal/kafka"
	"anchorstock-backend/pkg/price"
)

func main() {
	log.Println("Starting AnchorStock OHLCV Consumer...")

	cfg := config.Load()

	consumer, err := kafka.NewConsumer(
		cfg.KafkaBroker,
		cfg.KafkaTopicPrice,
		cfg.KafkaConsumerGroupOHLCV,
	)
	if err != nil {
		log.Fatalf("Failed to create Kafka consumer: %v", err)
	}
	defer consumer.Close()

	db, err := database.NewTimescaleDB(
		cfg.DBHost,
		cfg.DBPort,
		cfg.DBUser,
		cfg.DBPassword,
		cfg.DBName,
	)
	if err != nil {
		log.Fatalf("Failed to connect to TimescaleDB: %v", err)
	}
	defer db.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	done := make(chan struct{})
	go func() {
		err := consumer.ConsumeWithContext(ctx, func(p *price.StockPrice) error {
			return db.InsertPrice(ctx, p)
		})
		if err != nil && ctx.Err() == nil {
			log.Printf("Consumer exited with error: %v", err)
		}
		close(done)
	}()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)
	<-sigChan

	log.Println("Shutting down OHLCV Consumer...")
	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		log.Println("Consumer shutdown timeout")
	}
	log.Println("OHLCV Consumer stopped")
}
