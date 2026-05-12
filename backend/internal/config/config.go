package config

import (
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/joho/godotenv"
)

// Config 应用配置 / Application configuration
type Config struct {
	// Blockchain 配置 / Blockchain configuration
	RPCURL                     string
	PrivateKey                 string
	OracleContractAddress      string
	LendingPoolContractAddress string
	PerpEngineContractAddress  string

	// Kafka 配置 / Kafka configuration
	KafkaBroker     string
	KafkaTopicPrice string
	// Oracle 消费者：消费组 ID、批量上链间隔 / Oracle consumer: group ID, batch interval
	KafkaConsumerGroupOracle    string
	OracleConsumerBatchInterval time.Duration
	// OHLCV 消费者：消费组 ID / OHLCV consumer: group ID
	KafkaConsumerGroupOHLCV string
	// 清算机器人：监听 Kafka 价格时使用的消费组 / Liquidation bot: consumer group when listening to Kafka prices
	KafkaConsumerGroupLiquidation string

	// TimescaleDB 配置 / TimescaleDB configuration
	DBHost     string
	DBPort     string
	DBUser     string
	DBPassword string
	DBName     string

	// Redis 配置 / Redis configuration
	RedisHost     string
	RedisPort     string
	RedisPassword string

	// Stock API 配置 / Stock API configuration
	StockAPIKey        string
	StockAPIURL        string
	StockSymbols       []string      // 监控的股票符号列表 / List of stock symbols to monitor
	StockFetchInterval time.Duration // 价格抓取间隔（默认 5m，适配 Alpha Vantage 免费 5 次/分钟）/ Price fetch interval (default 5m for Alpha Vantage free tier)

	// Prometheus：常驻进程独立 metrics HTTP；api-server 使用主端口 /metrics，可忽略此项。
	// Prometheus: standalone metrics HTTP for workers; api-server serves /metrics on main listener.
	MetricsAddr string
}

// Load 加载配置 / Load configuration
func Load() *Config {
	// 加载 .env 文件 / Load .env file
	// 尝试多个可能的路径 / Try multiple possible paths
	// 首先使用当前工作目录（对于 go run 更可靠）/ First use current working directory (more reliable for go run)
	cwd, _ := os.Getwd()

	// 尝试获取可执行文件所在目录 / Try to get executable directory
	execPath, err := os.Executable()
	var execDir string
	if err == nil {
		execDir = filepath.Dir(execPath)
	}

	// 构建 .env 文件路径列表 / Build .env file path list
	envPaths := []string{
		".env",                     // 当前目录 / Current directory
		filepath.Join(cwd, ".env"), // 当前工作目录 / Current working directory
	}

	// 如果当前目录不是 backend，尝试 backend 目录 / If current directory is not backend, try backend directory
	if !strings.HasSuffix(cwd, "backend") && !strings.HasSuffix(cwd, "backend"+string(filepath.Separator)) {
		envPaths = append(envPaths,
			filepath.Join(cwd, "backend", ".env"),
			filepath.Join(cwd, "..", "backend", ".env"),
		)
	}

	// 如果可执行文件目录不同，也尝试 / If executable directory is different, also try
	if execDir != "" && execDir != cwd {
		envPaths = append(envPaths,
			filepath.Join(execDir, ".env"),
			filepath.Join(execDir, "..", ".env"),
			filepath.Join(execDir, "backend", ".env"),
		)
	}

	// 添加更多可能的路径（相对路径）/ Add more possible paths (relative paths)
	envPaths = append(envPaths,
		"backend/.env",
		"../backend/.env",
	)

	// 尝试从项目根目录查找 / Try to find from project root
	// 如果当前在 backend 目录，尝试上级目录 / If currently in backend directory, try parent directory
	if strings.HasSuffix(cwd, "backend") || strings.HasSuffix(cwd, "backend"+string(filepath.Separator)) {
		parentDir := filepath.Dir(cwd)
		envPaths = append(envPaths, filepath.Join(parentDir, "backend", ".env"))
	}

	var envLoaded bool
	for _, path := range envPaths {
		// 尝试加载 .env 文件 / Try to load .env file
		// 使用绝对路径确保能找到文件 / Use absolute path to ensure file can be found
		absPath, err := filepath.Abs(path)
		if err == nil {
			path = absPath
		}

		if err := godotenv.Load(path); err == nil {
			log.Printf("Loaded .env file from: %s", path)
			envLoaded = true
			break
		} else {
			// 调试：记录失败的路径 / Debug: log failed path
			log.Printf("Failed to load .env from: %s (error: %v)", path, err)
		}
	}

	if !envLoaded {
		log.Println("Warning: .env file not found in any of the expected paths, using environment variables")
		log.Printf("Searched in: %v", envPaths)
		log.Printf("Current working directory: %s", cwd)
		if execDir != "" {
			log.Printf("Executable directory: %s", execDir)
		}
	}

	// 默认股票符号 / Default stock symbols
	defaultSymbols := []string{"NVDA", "AAPL", "TSLA", "MSFT"}
	if symbols := os.Getenv("STOCK_SYMBOLS"); symbols != "" {
		// 解析逗号分隔的股票符号 / Parse comma-separated stock symbols
		symbolList := strings.Split(symbols, ",")
		for i := range symbolList {
			symbolList[i] = strings.TrimSpace(symbolList[i])
		}
		if len(symbolList) > 0 && symbolList[0] != "" {
			defaultSymbols = symbolList
		}
	}

	// 价格抓取间隔，默认 5 分钟（Alpha Vantage 免费 5 次/分钟，多 symbol 一次请求即多次调用）
	fetchIntervalStr := getEnv("RELAYER_FETCH_INTERVAL", "5m")
	fetchInterval, err := time.ParseDuration(fetchIntervalStr)
	if err != nil || fetchInterval <= 0 {
		fetchInterval = 5 * time.Minute
		log.Printf("Invalid RELAYER_FETCH_INTERVAL %q, using 5m", fetchIntervalStr)
	}

	return &Config{
		// Blockchain
		RPCURL:                     getEnv("RPC_URL", "http://localhost:8545"),
		PrivateKey:                 getEnv("PRIVATE_KEY", ""),
		OracleContractAddress:      getEnv("ORACLE_CONTRACT_ADDRESS", ""),
		LendingPoolContractAddress: getEnv("LENDING_POOL_CONTRACT_ADDRESS", ""),
		PerpEngineContractAddress:  getEnv("PERP_ENGINE_CONTRACT_ADDRESS", ""),

		// Kafka
		KafkaBroker:     getEnv("KAFKA_BROKER", "localhost:9092"),
		KafkaTopicPrice: getEnv("KAFKA_TOPIC_PRICE", "stock-prices"),
		KafkaConsumerGroupOracle:    getEnv("KAFKA_CONSUMER_GROUP_ORACLE", "oracle-updater"),
		OracleConsumerBatchInterval: parseDuration(getEnv("ORACLE_CONSUMER_BATCH_INTERVAL", "30s"), 30*time.Second),
		KafkaConsumerGroupOHLCV:     getEnv("KAFKA_CONSUMER_GROUP_OHLCV", "ohlcv-writer"),
		KafkaConsumerGroupLiquidation: getEnv("KAFKA_CONSUMER_GROUP_LIQUIDATION", "liquidation-bot"),

		// TimescaleDB
		DBHost:     getEnv("DB_HOST", "localhost"),
		DBPort:     getEnv("DB_PORT", "5432"),
		DBUser:     getEnv("DB_USER", "anchorstock"),
		DBPassword: getEnv("DB_PASSWORD", "anchorstock"),
		DBName:     getEnv("DB_NAME", "anchorstock"),

		// Redis
		RedisHost:     getEnv("REDIS_HOST", "localhost"),
		RedisPort:     getEnv("REDIS_PORT", "6379"),
		RedisPassword: getEnv("REDIS_PASSWORD", ""),

		// Stock API
		StockAPIKey:        getEnv("STOCK_API_KEY", ""),
		StockAPIURL:        getEnv("STOCK_API_URL", "https://api.example.com"),
		StockSymbols:       defaultSymbols,
		StockFetchInterval: fetchInterval,

		MetricsAddr: getEnv("METRICS_ADDR", ""),
	}
}

// getEnv 获取环境变量，如果不存在则返回默认值 / Get environment variable, return default if not exists
func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

// parseDuration 解析时长，失败则返回默认值 / Parse duration, return default on failure
func parseDuration(s string, defaultVal time.Duration) time.Duration {
	d, err := time.ParseDuration(s)
	if err != nil || d <= 0 {
		return defaultVal
	}
	return d
}
