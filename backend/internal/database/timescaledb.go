package database

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"anchorstock-backend/pkg/price"
)

// TimescaleDB TimescaleDB 数据库客户端 / TimescaleDB database client
type TimescaleDB struct {
	pool *pgxpool.Pool
}

// NewTimescaleDB 创建 TimescaleDB 连接 / Create TimescaleDB connection
// 带重试机制，等待数据库就绪 / With retry mechanism, wait for database to be ready
func NewTimescaleDB(host, port, user, password, dbname string) (*TimescaleDB, error) {
	dsn := fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=disable",
		host, port, user, password, dbname)

	// 重试连接，最多重试 10 次，每次等待 2 秒 / Retry connection, max 10 times, wait 2 seconds each
	maxRetries := 10
	retryDelay := 2 * time.Second
	
	var pool *pgxpool.Pool
	var err error
	
	for i := 0; i < maxRetries; i++ {
		pool, err = pgxpool.New(context.Background(), dsn)
		if err == nil {
			// 测试连接 / Test connection
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			err = pool.Ping(ctx)
			cancel()
			
			if err == nil {
				break // 连接成功 / Connection successful
			}
			pool.Close() // 关闭失败的连接 / Close failed connection
		}
		
		if i < maxRetries-1 {
			log.Printf("Database connection attempt %d/%d failed: %v, retrying in %v...", 
				i+1, maxRetries, err, retryDelay)
			time.Sleep(retryDelay)
		}
	}
	
	if err != nil {
		return nil, fmt.Errorf("failed to connect to database after %d attempts: %w", maxRetries, err)
	}
	
	log.Println("Successfully connected to TimescaleDB")

	db := &TimescaleDB{pool: pool}

	// 初始化表结构 / Initialize table structure
	if err := db.initSchema(); err != nil {
		return nil, fmt.Errorf("failed to initialize schema: %w", err)
	}

	return db, nil
}

// initSchema 初始化数据库表结构 / Initialize database schema
func (db *TimescaleDB) initSchema() error {
	ctx := context.Background()

	// 创建股票价格表（如果不存在）/ Create stock prices table (if not exists)
	createTableSQL := `
		CREATE TABLE IF NOT EXISTS stock_prices (
			time TIMESTAMPTZ NOT NULL,
			symbol VARCHAR(10) NOT NULL,
			price DOUBLE PRECISION NOT NULL,
			volume BIGINT NOT NULL,
			PRIMARY KEY (time, symbol)
		);
	`

	if _, err := db.pool.Exec(ctx, createTableSQL); err != nil {
		return fmt.Errorf("failed to create stock_prices table: %w", err)
	}

	// 将表转换为超表（TimescaleDB 特性）/ Convert table to hypertable (TimescaleDB feature)
	// 注意：如果已经是超表，这个命令会失败，但我们可以忽略错误 / Note: If already a hypertable, this will fail, but we can ignore the error
	createHypertableSQL := `
		SELECT create_hypertable('stock_prices', 'time', if_not_exists => TRUE);
	`

	_, err := db.pool.Exec(ctx, createHypertableSQL)
	if err != nil {
		// 如果表已经是超表，会返回错误，可以忽略 / If table is already a hypertable, error is returned, can ignore
		log.Printf("Note: Hypertable may already exist: %v\n", err)
	}

	// 创建索引以提高查询性能 / Create index for better query performance
	createIndexSQL := `
		CREATE INDEX IF NOT EXISTS idx_stock_prices_symbol_time 
		ON stock_prices (symbol, time DESC);
	`

	if _, err := db.pool.Exec(ctx, createIndexSQL); err != nil {
		return fmt.Errorf("failed to create index: %w", err)
	}

	log.Println("Database schema initialized successfully")
	return nil
}

// InsertPrice 插入价格数据 / Insert price data
func (db *TimescaleDB) InsertPrice(ctx context.Context, priceData *price.StockPrice) error {
	query := `
		INSERT INTO stock_prices (time, symbol, price, volume)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (time, symbol) DO UPDATE SET
			price = EXCLUDED.price,
			volume = EXCLUDED.volume;
	`

	_, err := db.pool.Exec(ctx, query,
		priceData.Timestamp,
		priceData.Symbol,
		priceData.Price,
		priceData.Volume,
	)

	if err != nil {
		return fmt.Errorf("failed to insert price: %w", err)
	}

	return nil
}

// GetLatestPrice 获取最新价格 / Get latest price
func (db *TimescaleDB) GetLatestPrice(ctx context.Context, symbol string) (*price.StockPrice, error) {
	query := `
		SELECT time, symbol, price, volume
		FROM stock_prices
		WHERE symbol = $1
		ORDER BY time DESC
		LIMIT 1;
	`

	var p price.StockPrice
	var t time.Time
	err := db.pool.QueryRow(ctx, query, symbol).Scan(
		&t, &p.Symbol, &p.Price, &p.Volume,
	)
	if err != nil {
		return nil, fmt.Errorf("failed to get latest price: %w", err)
	}

	p.Timestamp = t
	return &p, nil
}

// GetOHLCV 获取 OHLCV 数据（用于 K 线图）/ Get OHLCV data (for candlestick charts)
// 优先从 Continuous Aggregate 物化视图读取（1m/5m/15m/1h/4h/1d），否则回退到 time_bucket 实时聚合
func (db *TimescaleDB) GetOHLCV(ctx context.Context, symbol string, interval string, startTime, endTime time.Time) ([]OHLCV, error) {
	viewName := intervalToContinuousAggregateView(interval)
	if viewName != "" {
		return db.getOHLCVFromView(ctx, symbol, viewName, startTime, endTime)
	}
	return db.getOHLCVWithTimeBucket(ctx, symbol, interval, startTime, endTime)
}

// intervalToContinuousAggregateView 返回 TimescaleDB 物化视图名，不支持的 interval 返回空
func intervalToContinuousAggregateView(interval string) string {
	switch interval {
	case "1 minute":
		return "ohlcv_1m"
	case "5 minutes":
		return "ohlcv_5m"
	case "15 minutes":
		return "ohlcv_15m"
	case "1 hour":
		return "ohlcv_1h"
	case "4 hours":
		return "ohlcv_4h"
	case "1 day":
		return "ohlcv_1d"
	default:
		return ""
	}
}

// getOHLCVFromView 从 Continuous Aggregate 物化视图查询（简单 SELECT，无实时聚合）
func (db *TimescaleDB) getOHLCVFromView(ctx context.Context, symbol string, viewName string, startTime, endTime time.Time) ([]OHLCV, error) {
	query := fmt.Sprintf(`
		SELECT bucket AS time, symbol, open, high, low, close, volume
		FROM %s
		WHERE symbol = $1 AND bucket >= $2 AND bucket <= $3
		ORDER BY bucket`,
		viewName)
	rows, err := db.pool.Query(ctx, query, symbol, startTime, endTime)
	if err != nil {
		return nil, fmt.Errorf("failed to query %s: %w", viewName, err)
	}
	defer rows.Close()

	var ohlcvList []OHLCV
	for rows.Next() {
		var o OHLCV
		var t time.Time
		if err := rows.Scan(&t, &o.Symbol, &o.Open, &o.High, &o.Low, &o.Close, &o.Volume); err != nil {
			return nil, fmt.Errorf("failed to scan OHLCV: %w", err)
		}
		o.Time = t
		ohlcvList = append(ohlcvList, o)
	}
	return ohlcvList, nil
}

// getOHLCVWithTimeBucket 使用 time_bucket 在原始表上实时聚合（未配置对应物化视图时回退）
func (db *TimescaleDB) getOHLCVWithTimeBucket(ctx context.Context, symbol string, interval string, startTime, endTime time.Time) ([]OHLCV, error) {
	query := `
		SELECT 
			time_bucket($1::interval, time) AS bucket,
			symbol,
			FIRST(price, time) AS open,
			MAX(price) AS high,
			MIN(price) AS low,
			LAST(price, time) AS close,
			SUM(volume) AS volume
		FROM stock_prices
		WHERE symbol = $2 AND time >= $3 AND time <= $4
		GROUP BY bucket, symbol
		ORDER BY bucket;
	`

	rows, err := db.pool.Query(ctx, query, interval, symbol, startTime, endTime)
	if err != nil {
		return nil, fmt.Errorf("failed to query OHLCV: %w", err)
	}
	defer rows.Close()

	var ohlcvList []OHLCV
	for rows.Next() {
		var o OHLCV
		var t time.Time
		if err := rows.Scan(&t, &o.Symbol, &o.Open, &o.High, &o.Low, &o.Close, &o.Volume); err != nil {
			return nil, fmt.Errorf("failed to scan OHLCV: %w", err)
		}
		o.Time = t
		ohlcvList = append(ohlcvList, o)
	}

	return ohlcvList, nil
}

// OHLCV OHLCV 数据结构 / OHLCV data structure
type OHLCV struct {
	Time   time.Time `json:"time"`
	Symbol string    `json:"symbol"`
	Open   float64   `json:"open"`
	High   float64   `json:"high"`
	Low    float64   `json:"low"`
	Close  float64   `json:"close"`
	Volume int64     `json:"volume"`
}

// Close 关闭数据库连接 / Close database connection
func (db *TimescaleDB) Close() {
	db.pool.Close()
}
