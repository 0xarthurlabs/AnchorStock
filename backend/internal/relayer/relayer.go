package relayer

import (
	"context"
	"fmt"
	"log"
	"time"

	"anchorstock-backend/internal/config"
	"anchorstock-backend/internal/kafka"
	"anchorstock-backend/pkg/price"
)

// Relayer 价格中继器服务：仅负责抓价并写入 Kafka；K 线由 ohlcv-consumer 消费 Kafka 写 TimescaleDB，链上由 oracle-consumer 更新。
type Relayer struct {
	config          *config.Config
	fetcher         price.Fetcher
	fallbackFetcher price.Fetcher
	producer        *kafka.Producer
	ticker          *time.Ticker
	ctx             context.Context
	cancel          context.CancelFunc
}

// NewRelayer 创建价格中继器 / Create price relayer
func NewRelayer(cfg *config.Config) (*Relayer, error) {
	// 创建价格抓取器 / Create price fetcher
	var fetcher price.Fetcher
	var fallbackFetcher price.Fetcher
	if cfg.StockAPIKey != "" && cfg.StockAPIURL != "" {
		fetcher = price.NewAPIFetcher(cfg.StockAPIURL, cfg.StockAPIKey)
		fallbackFetcher = price.NewMockFetcher() // API 限频或空 quote 时用 mock 补全 / Fallback when API rate limit or empty quote
		log.Println("Using API fetcher for stock prices (with mock fallback for failed symbols)")
	} else {
		fetcher = price.NewMockFetcher()
		log.Println("Using mock fetcher for stock prices (development mode)")
	}

	// 创建 Kafka Producer / Create Kafka Producer
	producer, err := kafka.NewProducer(cfg.KafkaBroker, cfg.KafkaTopicPrice)
	if err != nil {
		return nil, fmt.Errorf("failed to create Kafka producer: %w", err)
	}

	ctx, cancel := context.WithCancel(context.Background())

	return &Relayer{
		config:          cfg,
		fetcher:         fetcher,
		fallbackFetcher: fallbackFetcher,
		producer:        producer,
		ticker:          time.NewTicker(cfg.StockFetchInterval),
		ctx:             ctx,
		cancel:          cancel,
	}, nil
}

// Start 启动中继器服务 / Start relayer service
func (r *Relayer) Start() error {
	log.Printf("Starting price relayer service (fetch interval: %s)...\n", r.config.StockFetchInterval)

	// 立即执行一次 / Execute immediately
	if err := r.fetchAndPublish(); err != nil {
		log.Printf("Error in initial fetch: %v\n", err)
	}

	// 定时执行 / Execute periodically
	go func() {
		for {
			select {
			case <-r.ctx.Done():
				return
			case <-r.ticker.C:
				if err := r.fetchAndPublish(); err != nil {
					log.Printf("Error fetching and publishing prices: %v\n", err)
				}
			}
		}
	}()

	log.Println("Price relayer service started")
	return nil
}

// fetchAndPublish 抓取价格并发布 / Fetch prices and publish
func (r *Relayer) fetchAndPublish() error {
	log.Println("Fetching stock prices...")

	// 抓取所有配置的股票价格 / Fetch all configured stock prices
	prices, err := r.fetcher.FetchPrices(r.config.StockSymbols)
	if err != nil {
		return fmt.Errorf("failed to fetch prices: %w", err)
	}

	// 当使用 API 时，对未返回的 symbol 用 mock 补全（确认是 API 限频/空数据导致）
	// When using API, fill missing symbols with mock (confirms API rate limit or empty quote)
	if r.fallbackFetcher != nil {
		for _, symbol := range r.config.StockSymbols {
			if prices[symbol] == nil {
				fallbackPrice, fallbackErr := r.fallbackFetcher.FetchPrice(symbol)
				if fallbackErr != nil {
					log.Printf("Fallback mock failed for %s: %v\n", symbol, fallbackErr)
					continue
				}
				prices[symbol] = fallbackPrice
				log.Printf("Symbol %s: API returned empty or error (likely rate limit 5/min or market closed), using mock data\n", symbol)
			}
		}
	}

	log.Printf("Fetched %d stock prices\n", len(prices))

	// 1. 发布到 Kafka（K 线由 ohlcv-consumer 消费写 DB，链上由 oracle-consumer 更新）
	if err := r.producer.PublishPrices(prices); err != nil {
		log.Printf("Error publishing to Kafka: %v\n", err)
	}
	return nil
}

// Stop 停止中继器服务 / Stop relayer service
func (r *Relayer) Stop() {
	log.Println("Stopping price relayer service...")
	r.cancel()
	r.ticker.Stop()
	r.producer.Close()
	log.Println("Price relayer service stopped")
}
