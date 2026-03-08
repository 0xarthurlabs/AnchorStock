// Backfill 历史 K 线回填：从 Alpha Vantage 拉取历史数据并写入 TimescaleDB stock_prices，
// 供 GetOHLCV 查询。用法：BACKFILL_SYMBOL=NVDA BACKFILL_INTERVAL=5min go run cmd/backfill/main.go
// 或传参：go run cmd/backfill/main.go --symbol=NVDA --interval=5min [--start=2024-01-01] [--end=2024-12-31]
package main

import (
	"context"
	"flag"
	"log"
	"os"
	"strings"
	"time"

	"anchorstock-backend/internal/config"
	"anchorstock-backend/internal/database"
	"anchorstock-backend/pkg/price"
)

func main() {
	symbol := flag.String("symbol", getEnv("BACKFILL_SYMBOL", "NVDA"), "Stock symbol to backfill")
	interval := flag.String("interval", getEnv("BACKFILL_INTERVAL", "5min"), "Bar interval: 1min, 5min, 15min, 30min, 60min, daily")
	startStr := flag.String("start", getEnv("BACKFILL_START", ""), "Start date (YYYY-MM-DD), default 1 year ago")
	endStr := flag.String("end", getEnv("BACKFILL_END", ""), "End date (YYYY-MM-DD), default today")
	flag.Parse()

	cfg := config.Load()
	if cfg.StockAPIKey == "" || cfg.StockAPIURL == "" {
		log.Fatal("STOCK_API_KEY and STOCK_API_URL are required for backfill (use Alpha Vantage)")
	}

	endTime := time.Now()
	if *endStr != "" {
		t, err := time.Parse("2006-01-02", *endStr)
		if err != nil {
			log.Fatalf("Invalid --end: %v", err)
		}
		endTime = t
	}
	startTime := endTime.AddDate(-1, 0, 0)
	if *startStr != "" {
		t, err := time.Parse("2006-01-02", *startStr)
		if err != nil {
			log.Fatalf("Invalid --start: %v", err)
		}
		startTime = t
	}
	if startTime.After(endTime) {
		log.Fatal("start must be before end")
	}

	db, err := database.NewTimescaleDB(cfg.DBHost, cfg.DBPort, cfg.DBUser, cfg.DBPassword, cfg.DBName)
	if err != nil {
		log.Fatalf("Failed to connect to TimescaleDB: %v", err)
	}
	defer db.Close()

	fetcher := price.NewAlphaVantageHistorical(cfg.StockAPIURL, cfg.StockAPIKey)
	intervalNorm := *interval
	if intervalNorm == "1d" || intervalNorm == "day" {
		intervalNorm = "daily"
	}

	log.Printf("Backfilling %s interval=%s from %s to %s", *symbol, intervalNorm, startTime.Format("2006-01-02"), endTime.Format("2006-01-02"))
	bars, err := fetcher.FetchHistorical(*symbol, intervalNorm, startTime, endTime)
	if err != nil {
		log.Fatalf("Fetch historical: %v", err)
	}
	log.Printf("Fetched %d bars", len(bars))
	if len(bars) == 0 {
		log.Println("No data in range (check API rate limit or date range)")
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	inserted := 0
	for _, p := range bars {
		if err := db.InsertPrice(ctx, p); err != nil {
			log.Printf("Insert %s %s: %v", p.Symbol, p.Timestamp.Format(time.RFC3339), err)
			continue
		}
		inserted++
	}
	log.Printf("Backfill done: inserted %d rows for %s", inserted, *symbol)
}

func getEnv(key, defaultVal string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return defaultVal
}
