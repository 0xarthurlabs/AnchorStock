package price

import (
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"strconv"
	"time"
)

// Fetcher 价格抓取器接口 / Price fetcher interface
type Fetcher interface {
	FetchPrice(symbol string) (*StockPrice, error)
	FetchPrices(symbols []string) (map[string]*StockPrice, error)
}

// MockFetcher 模拟价格抓取器（用于开发和测试）/ Mock price fetcher (for development and testing)
type MockFetcher struct {
	basePrices map[string]float64 // 基础价格 / Base prices
}

// NewMockFetcher 创建模拟价格抓取器 / Create mock price fetcher
func NewMockFetcher() *MockFetcher {
	return &MockFetcher{
		basePrices: map[string]float64{
			"NVDA": 177.0, // 约当前市价 / approx current market (fallback when API limit)
			"AAPL": 230.0,
			"TSLA": 260.0,
			"MSFT": 420.0,
		},
	}
}

// FetchPrice 获取单个股票价格（模拟）/ Fetch single stock price (mock)
func (m *MockFetcher) FetchPrice(symbol string) (*StockPrice, error) {
	basePrice, exists := m.basePrices[symbol]
	if !exists {
		// 若符号不在预设列表，使用合理区间随机价格 / If symbol not in list, use random in reasonable range
		basePrice = 50.0 + rand.Float64()*200.0
	}

	// 模拟价格波动（±2%）/ Simulate price volatility (±2%)
	volatility := 0.02
	change := (rand.Float64() - 0.5) * 2 * volatility
	price := basePrice * (1 + change)

	return &StockPrice{
		Symbol:    symbol,
		Price:     price,
		Timestamp: time.Now(),
		Volume:    rand.Int63n(10000000) + 1000000,
	}, nil
}

// FetchPrices 批量获取股票价格（模拟）/ Fetch multiple stock prices (mock)
func (m *MockFetcher) FetchPrices(symbols []string) (map[string]*StockPrice, error) {
	prices := make(map[string]*StockPrice)
	for _, symbol := range symbols {
		price, err := m.FetchPrice(symbol)
		if err != nil {
			return nil, err
		}
		prices[symbol] = price
	}
	return prices, nil
}

// APIFetcher 真实 API 价格抓取器 / Real API price fetcher
type APIFetcher struct {
	apiURL string
	apiKey string
	client *http.Client
}

// NewAPIFetcher 创建 API 价格抓取器 / Create API price fetcher
func NewAPIFetcher(apiURL, apiKey string) *APIFetcher {
	return &APIFetcher{
		apiURL: apiURL,
		apiKey: apiKey,
		client: &http.Client{
			Timeout: 10 * time.Second,
		},
	}
}

// FetchPrice 从 API 获取单个股票价格 / Fetch single stock price from API
// 支持 Alpha Vantage API 格式 / Supports Alpha Vantage API format
func (a *APIFetcher) FetchPrice(symbol string) (*StockPrice, error) {
	// 检测是否为 Alpha Vantage API / Detect if it's Alpha Vantage API
	isAlphaVantage := a.isAlphaVantageAPI()

	var url string
	if isAlphaVantage {
		// Alpha Vantage API 格式 / Alpha Vantage API format
		// https://www.alphavantage.co/query?function=GLOBAL_QUOTE&symbol=NVDA&apikey=YOUR_KEY
		url = fmt.Sprintf("%s?function=GLOBAL_QUOTE&symbol=%s&apikey=%s", a.apiURL, symbol, a.apiKey)
	} else {
		// 通用 API 格式（向后兼容）/ Generic API format (backward compatible)
		url = fmt.Sprintf("%s/quote/%s?apikey=%s", a.apiURL, symbol, a.apiKey)
	}

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	resp, err := a.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch price: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("API returned status %d: %s", resp.StatusCode, string(body))
	}

	// 根据 API 类型解析响应 / Parse response based on API type
	if isAlphaVantage {
		return a.parseAlphaVantageResponse(resp.Body, symbol)
	}

	// 通用 API 响应格式 / Generic API response format
	var apiResponse struct {
		Symbol    string  `json:"symbol"`
		Price     float64 `json:"price"`
		Timestamp int64   `json:"timestamp"`
		Volume    int64   `json:"volume"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&apiResponse); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return &StockPrice{
		Symbol:    apiResponse.Symbol,
		Price:     apiResponse.Price,
		Timestamp: time.Unix(apiResponse.Timestamp, 0),
		Volume:    apiResponse.Volume,
	}, nil
}

// isAlphaVantageAPI 检测是否为 Alpha Vantage API / Detect if it's Alpha Vantage API
func (a *APIFetcher) isAlphaVantageAPI() bool {
	return a.apiURL == "https://www.alphavantage.co/query" ||
		a.apiURL == "http://www.alphavantage.co/query"
}

// parseAlphaVantageResponse 解析 Alpha Vantage API 响应 / Parse Alpha Vantage API response
func (a *APIFetcher) parseAlphaVantageResponse(body io.Reader, symbol string) (*StockPrice, error) {
	// Alpha Vantage 响应格式 / Alpha Vantage response format
	var apiResponse struct {
		GlobalQuote struct {
			Symbol           string `json:"01. symbol"`
			Open             string `json:"02. open"`
			High             string `json:"03. high"`
			Low              string `json:"04. low"`
			Price            string `json:"05. price"`
			Volume           string `json:"06. volume"`
			LatestTradingDay string `json:"07. latest trading day"`
			PreviousClose    string `json:"08. previous close"`
			Change           string `json:"09. change"`
			ChangePercent    string `json:"10. change percent"`
		} `json:"Global Quote"`
		Note  string `json:"Note"`          // API 调用频率限制提示 / API call frequency limit notice
		Error string `json:"Error Message"` // 错误信息 / Error message
	}

	if err := json.NewDecoder(body).Decode(&apiResponse); err != nil {
		return nil, fmt.Errorf("failed to decode Alpha Vantage response: %w", err)
	}

	// 检查错误 / Check for errors
	if apiResponse.Error != "" {
		return nil, fmt.Errorf("Alpha Vantage API error: %s", apiResponse.Error)
	}

	if apiResponse.Note != "" {
		return nil, fmt.Errorf("Alpha Vantage API rate limit (Note): %s", apiResponse.Note)
	}

	// 检查是否为空响应（常见原因：免费 tier 限频 5 次/分钟、或非交易时段无数据）
	// Empty quote often means: free tier rate limit (5 calls/min) or market closed
	if apiResponse.GlobalQuote.Symbol == "" {
		return nil, fmt.Errorf(
			"Alpha Vantage returned empty quote for %s (possible causes: rate limit 5 calls/min on free tier, or market closed)",
			symbol,
		)
	}

	// 解析价格（字符串转浮点数）/ Parse price (string to float)
	var price float64
	var volume int64
	var err error

	if price, err = parseFloat(apiResponse.GlobalQuote.Price); err != nil {
		return nil, fmt.Errorf("failed to parse price: %w", err)
	}

	if volume, err = parseInt64(apiResponse.GlobalQuote.Volume); err != nil {
		// 如果成交量解析失败，使用 0 / If volume parsing fails, use 0
		volume = 0
	}

	// 解析日期时间：写入时序库/Kafka 时必须用「当前时间」以便每条推送产生新的一行；用 LatestTradingDay 会导致同一天内反复覆盖同一行
	// Use current time for DB/Kafka so each relayer run creates a new row; using LatestTradingDay would overwrite the same row every fetch within the same day
	var timestamp time.Time
	timestamp = time.Now()

	return &StockPrice{
		Symbol:    apiResponse.GlobalQuote.Symbol,
		Price:     price,
		Timestamp: timestamp,
		Volume:    volume,
	}, nil
}

// parseFloat 解析字符串为浮点数 / Parse string to float
func parseFloat(s string) (float64, error) {
	if s == "" {
		return 0, fmt.Errorf("empty string")
	}
	return strconv.ParseFloat(s, 64)
}

// parseInt64 解析字符串为 int64 / Parse string to int64
func parseInt64(s string) (int64, error) {
	if s == "" {
		return 0, fmt.Errorf("empty string")
	}
	return strconv.ParseInt(s, 10, 64)
}

// FetchPrices 批量获取股票价格 / Fetch multiple stock prices
func (a *APIFetcher) FetchPrices(symbols []string) (map[string]*StockPrice, error) {
	prices := make(map[string]*StockPrice)
	for _, symbol := range symbols {
		price, err := a.FetchPrice(symbol)
		if err != nil {
			// 记录错误但继续处理其他符号 / Log error but continue processing other symbols
			fmt.Printf("Error fetching price for %s: %v\n", symbol, err)
			continue
		}
		prices[symbol] = price
	}
	return prices, nil
}
