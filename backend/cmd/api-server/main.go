package main

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"bytes"

	"anchorstock-backend/internal/cache"
	"anchorstock-backend/internal/config"
	"anchorstock-backend/internal/database"
	"anchorstock-backend/internal/metrics"
	"anchorstock-backend/pkg/price"

	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/fiber/v2/middleware/cors"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/common/expfmt"
)

func main() {
	log.Println("Starting AnchorStock API Server...")

	// 加载配置 / Load configuration
	cfg := config.Load()

	// Prometheus: optional dedicated metrics listener for scrape jobs (e.g. :9090)
	metrics.StartBackgroundServer(cfg.MetricsAddr)

	// 创建 TimescaleDB 连接 / Create TimescaleDB connection
	db, err := database.NewTimescaleDB(
		cfg.DBHost,
		cfg.DBPort,
		cfg.DBUser,
		cfg.DBPassword,
		cfg.DBName,
	)
	if err != nil {
		log.Fatalf("Failed to create database connection: %v", err)
	}
	defer db.Close()

	// Redis 缓存（可选：未配置或连接失败则不用缓存）
	redisCache, _ := cache.New(cfg.RedisHost, cfg.RedisPort, cfg.RedisPassword)
	if redisCache != nil {
		defer redisCache.Close()
	}

	// 创建 Fiber 应用 / Create Fiber app
	app := fiber.New(fiber.Config{
		AppName: "AnchorStock API",
	})

	// 添加 CORS 中间件 / Add CORS middleware
	app.Use(cors.New(cors.Config{
		AllowOrigins: "*",
		AllowMethods: "GET,POST,HEAD,PUT,DELETE,PATCH,OPTIONS",
		AllowHeaders: "Origin, Content-Type, Accept, Authorization",
	}))

	// 健康检查端点 / Health check endpoint
	app.Get("/health", func(c *fiber.Ctx) error {
		return c.JSON(fiber.Map{
			"status": "ok",
			"time":   time.Now().Unix(),
		})
	})

	// Prometheus metrics — native Fiber handler (avoids adaptor/v2 compat issues with Fiber v2.52+)
	app.Get("/metrics", func(c *fiber.Ctx) error {
		mfs, err := prometheus.DefaultGatherer.Gather()
		if err != nil {
			return c.Status(500).SendString(err.Error())
		}
		var buf bytes.Buffer
		enc := expfmt.NewEncoder(&buf, expfmt.NewFormat(expfmt.TypeTextPlain))
		for _, mf := range mfs {
			if err := enc.Encode(mf); err != nil {
				return c.Status(500).SendString(err.Error())
			}
		}
		c.Set("Content-Type", string(expfmt.NewFormat(expfmt.TypeTextPlain)))
		return c.Send(buf.Bytes())
	})

	// OHLCV K 线数据端点 / OHLCV candlestick data endpoint
	app.Get("/api/ohlcv", func(c *fiber.Ctx) error {
		symbol := c.Query("symbol", "NVDA")
		intervalStr := c.Query("interval", "1h")
		limitStr := c.Query("limit", "100")

		// 解析 limit / Parse limit
		limit, err := strconv.Atoi(limitStr)
		if err != nil || limit <= 0 {
			limit = 100
		}
		if limit > 1000 {
			limit = 1000 // 最大限制 / Max limit
		}

		// Redis 缓存 key / Redis cache key
		cacheKey := "ohlcv:" + symbol + ":" + intervalStr + ":" + limitStr
		if redisCache != nil {
			cacheCtx := context.Background()
			if data, err := redisCache.Get(cacheCtx, cacheKey); err == nil {
				var result []map[string]interface{}
				if json.Unmarshal(data, &result) == nil {
					return c.JSON(result)
				}
			}
		}

		// 转换 interval 为 TimescaleDB 格式 / Convert interval to TimescaleDB format
		interval := convertInterval(intervalStr)

		// 计算时间范围 / Calculate time range
		now := time.Now()
		var startTime time.Time
		switch intervalStr {
		case "1m", "5m", "15m":
			startTime = now.Add(-time.Duration(limit) * time.Minute)
		case "1h", "4h":
			startTime = now.Add(-time.Duration(limit) * time.Hour)
		case "1d":
			startTime = now.AddDate(0, 0, -limit)
		default:
			startTime = now.Add(-time.Duration(limit) * time.Hour)
		}

		// 查询数据库 / Query database
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()

		ohlcvData, err := db.GetOHLCV(ctx, symbol, interval, startTime, now)
		if err != nil {
			log.Printf("Error querying OHLCV: %v", err)
			return c.Status(500).JSON(fiber.Map{
				"error": "Failed to query OHLCV data",
			})
		}

		// 转换为前端需要的格式 / Convert to frontend format
		result := make([]map[string]interface{}, len(ohlcvData))
		for i, o := range ohlcvData {
			result[i] = map[string]interface{}{
				"time":   o.Time.Unix(),
				"open":   o.Open,
				"high":   o.High,
				"low":    o.Low,
				"close":  o.Close,
				"volume": o.Volume,
			}
		}

		// 写入 Redis 缓存（1 分钟）/ Write to Redis cache (1 minute)
		if redisCache != nil {
			if data, err := json.Marshal(result); err == nil {
				cacheCtx := context.Background()
				_ = redisCache.Set(cacheCtx, cacheKey, data, time.Minute)
			}
		}

		return c.JSON(result)
	})

	// 获取最新价格 / Get latest price
	app.Get("/api/price/:symbol", func(c *fiber.Ctx) error {
		symbol := c.Params("symbol")
		cacheKey := "price:" + symbol

		// 先查 Redis 缓存（30 秒）/ Try Redis cache first (30s TTL)
		if redisCache != nil {
			cacheCtx := context.Background()
			if data, err := redisCache.Get(cacheCtx, cacheKey); err == nil {
				var out map[string]interface{}
				if json.Unmarshal(data, &out) == nil {
					return c.JSON(out)
				}
			}
		}

		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		price, err := db.GetLatestPrice(ctx, symbol)
		if err != nil {
			return c.Status(404).JSON(fiber.Map{
				"error": "Price not found",
			})
		}

		resp := fiber.Map{
			"symbol":    price.Symbol,
			"price":     price.Price,
			"volume":    price.Volume,
			"timestamp": price.Timestamp.Unix(),
		}

		// 写入缓存 / Write to cache
		if redisCache != nil {
			if data, err := json.Marshal(resp); err == nil {
				cacheCtx := context.Background()
				_ = redisCache.Set(cacheCtx, cacheKey, data, 30*time.Second)
			}
		}

		return c.JSON(resp)
	})

	// 诊断：当前 Alpha Vantage 是否可用（是否限频或返回空）/ Diagnostic: is Alpha Vantage currently available (rate limit or empty?)
	app.Get("/api/price-source/:symbol", func(c *fiber.Ctx) error {
		sym := c.Params("symbol")
		if sym == "" {
			return c.Status(400).JSON(fiber.Map{"error": "symbol required"})
		}
		if cfg.StockAPIKey == "" || cfg.StockAPIURL == "" {
			return c.JSON(fiber.Map{
				"source":  "none",
				"message": "Stock API not configured (STOCK_API_KEY / STOCK_API_URL)",
			})
		}
		fetcher := price.NewAPIFetcher(cfg.StockAPIURL, cfg.StockAPIKey)
		p, err := fetcher.FetchPrice(sym)
		if err != nil {
			return c.JSON(fiber.Map{
				"source": "error",
				"error":  err.Error(),
				"hint":   "Alpha Vantage free tier is about 5 calls/min rate limit, or returns empty when market is closed. Relayer will use mock price in that case.",
			})
		}
		return c.JSON(fiber.Map{
			"source":    "api",
			"symbol":    p.Symbol,
			"price":     p.Price,
			"timestamp": p.Timestamp.Unix(),
			"message":   "Alpha Vantage returned successfully",
		})
	})

	// 启动服务器 / Start server
	// Cloud Run uses PORT; local/dev may use API_PORT.
	port := os.Getenv("PORT")
	if port == "" {
		port = os.Getenv("API_PORT")
	}
	if port == "" {
		port = "3001"
	}

	// 在 goroutine 中启动服务器 / Start server in goroutine
	go func() {
		if err := app.Listen(":" + port); err != nil {
			log.Fatalf("Failed to start API server: %v", err)
		}
	}()

	log.Printf("API Server started on :%s", port)
	log.Println("Endpoints:")
	log.Println("  - GET /health - Health check")
	log.Println("  - GET /metrics - Prometheus metrics")
	log.Println("  - GET /api/ohlcv?symbol=NVDA&interval=1h&limit=100 - OHLCV data")
	log.Println("  - GET /api/price/:symbol - Latest price")
	log.Println("  - GET /api/price-source/:symbol - Diagnostic: Alpha Vantage rate limit / empty response")

	// 等待中断信号 / Wait for interrupt signal
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)

	<-sigChan
	log.Println("Received interrupt signal, shutting down...")

	// 优雅关闭 / Graceful shutdown
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := app.ShutdownWithContext(ctx); err != nil {
		log.Printf("Error shutting down server: %v", err)
	}

	log.Println("API Server stopped")
}

// convertInterval 转换前端 interval 为 TimescaleDB 格式 / Convert frontend interval to TimescaleDB format
func convertInterval(interval string) string {
	switch interval {
	case "1m":
		return "1 minute"
	case "5m":
		return "5 minutes"
	case "15m":
		return "15 minutes"
	case "1h":
		return "1 hour"
	case "4h":
		return "4 hours"
	case "1d":
		return "1 day"
	default:
		return "1 hour"
	}
}
