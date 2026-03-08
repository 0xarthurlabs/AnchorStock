// Oracle Consumer：从 Kafka 消费 stock-prices，按间隔批量更新链上 Oracle。
// 与 Relayer 解耦：Relayer 只负责抓价 + 写 Kafka，本进程负责 Kafka → 链上。
package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"anchorstock-backend/internal/blockchain"
	"anchorstock-backend/internal/config"
	"anchorstock-backend/internal/kafka"
	"anchorstock-backend/pkg/price"
)

func main() {
	log.Println("Starting AnchorStock Oracle Consumer...")

	cfg := config.Load()

	if cfg.OracleContractAddress == "" || cfg.PrivateKey == "" {
		log.Fatal("ORACLE_CONTRACT_ADDRESS and PRIVATE_KEY are required for oracle-consumer")
	}

	consumer, err := kafka.NewConsumer(
		cfg.KafkaBroker,
		cfg.KafkaTopicPrice,
		cfg.KafkaConsumerGroupOracle,
	)
	if err != nil {
		log.Fatalf("Failed to create Kafka consumer: %v", err)
	}
	defer consumer.Close()

	oracle, err := blockchain.NewOracleClient(
		cfg.RPCURL,
		cfg.OracleContractAddress,
		cfg.PrivateKey,
	)
	if err != nil {
		log.Fatalf("Failed to create Oracle client: %v", err)
	}
	defer oracle.Close()

	// 内存批量：symbol -> 最新价格，按间隔 flush 到链上
	batch := &priceBatch{ prices: make(map[string]*price.StockPrice) }

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// 消费循环（在 goroutine 中运行）
	go func() {
		err := consumer.ConsumeWithContext(ctx, func(p *price.StockPrice) error {
			batch.add(p)
			return nil
		})
		if err != nil && ctx.Err() == nil {
			log.Printf("Consumer exited with error: %v", err)
		}
	}()

	// 定时批量上链
	ticker := time.NewTicker(cfg.OracleConsumerBatchInterval)
	defer ticker.Stop()
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				batch.flushToOracle(oracle)
			}
		}
	}()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)
	<-sigChan

	log.Println("Shutting down Oracle Consumer...")
	cancel()
	time.Sleep(500 * time.Millisecond) // 让 Consume 有机会退出
	batch.flushToOracle(oracle)
	log.Println("Oracle Consumer stopped")
}

type priceBatch struct {
	mu     sync.Mutex
	prices map[string]*price.StockPrice
}

func (b *priceBatch) add(p *price.StockPrice) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.prices[p.Symbol] = p
}

func (b *priceBatch) flushToOracle(oracle *blockchain.OracleClient) {
	b.mu.Lock()
	if len(b.prices) == 0 {
		b.mu.Unlock()
		return
	}
	// 复制并清空，避免长时间持锁
	copy := make(map[string]*price.StockPrice, len(b.prices))
	for k, v := range b.prices {
		copy[k] = v
	}
	b.prices = make(map[string]*price.StockPrice)
	b.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := oracle.UpdatePrices(ctx, copy); err != nil {
		log.Printf("Oracle batch update failed: %v", err)
		// 可选：把 copy 重新放回 batch 重试，这里简化处理
		return
	}
	log.Printf("Updated Oracle on-chain with %d symbols", len(copy))
}
