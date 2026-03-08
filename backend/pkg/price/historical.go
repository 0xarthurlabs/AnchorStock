package price

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"time"
)

// HistoricalFetcher 历史 K 线数据抓取接口 / Historical OHLCV fetcher interface
type HistoricalFetcher interface {
	// FetchHistorical 获取历史 K 线（按条返回，每条对应一个时间桶的收盘价与成交量）/ Fetch historical bars (one StockPrice per bucket: close price + volume)
	FetchHistorical(symbol string, interval string, startTime, endTime time.Time) ([]*StockPrice, error)
}

// AlphaVantageHistorical 使用 Alpha Vantage TIME_SERIES_INTRADAY / TIME_SERIES_DAILY 回填
type AlphaVantageHistorical struct {
	apiURL string
	apiKey string
	client *http.Client
}

// NewAlphaVantageHistorical 创建 Alpha Vantage 历史数据抓取器
func NewAlphaVantageHistorical(apiURL, apiKey string) *AlphaVantageHistorical {
	if apiURL == "" {
		apiURL = "https://www.alphavantage.co/query"
	}
	return &AlphaVantageHistorical{
		apiURL: apiURL,
		apiKey: apiKey,
		client: &http.Client{Timeout: 30 * time.Second},
	}
}

// FetchHistorical 拉取历史数据并转为 []*StockPrice（每条为 time_bucket 的 close + volume，便于写入 stock_prices 表）
func (a *AlphaVantageHistorical) FetchHistorical(symbol string, interval string, startTime, endTime time.Time) ([]*StockPrice, error) {
	// 支持 1min, 5min, 15min, 30min, 60min, daily
	intervalParam := interval
	if interval == "1d" || interval == "day" || interval == "daily" {
		intervalParam = "daily"
	}
	var url string
	if intervalParam == "daily" {
		url = fmt.Sprintf("%s?function=TIME_SERIES_DAILY&symbol=%s&apikey=%s&outputsize=full", a.apiURL, symbol, a.apiKey)
	} else {
		// 1min, 5min, 15min, 30min, 60min
		url = fmt.Sprintf("%s?function=TIME_SERIES_INTRADAY&symbol=%s&interval=%s&apikey=%s&outputsize=full", a.apiURL, symbol, intervalParam, a.apiKey)
	}

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("API status %d: %s", resp.StatusCode, string(body))
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	var full map[string]interface{}
	if err := json.Unmarshal(body, &full); err != nil {
		return nil, err
	}
	if errMsg, _ := full["Error Message"].(string); errMsg != "" {
		return nil, fmt.Errorf("Alpha Vantage error: %s", errMsg)
	}
	if note, _ := full["Note"].(string); note != "" {
		return nil, fmt.Errorf("Alpha Vantage rate limit: %s", note)
	}
	var series map[string]interface{}
	for k, v := range full {
		if k == "Meta Data" {
			continue
		}
		if m, ok := v.(map[string]interface{}); ok {
			series = m
			break
		}
	}
	if series == nil {
		return nil, fmt.Errorf("no time series in response")
	}

	var out []*StockPrice
	layout := "2006-01-02 15:04:05"
	if intervalParam == "daily" {
		layout = "2006-01-02"
	}
	for tsStr, v := range series {
		bar, ok := v.(map[string]interface{})
		if !ok {
			continue
		}
		t, err := time.Parse(layout, tsStr)
		if err != nil {
			continue
		}
		if t.Before(startTime) || t.After(endTime) {
			continue
		}
		closeStr, _ := bar["4. close"].(string)
		if closeStr == "" {
			closeStr, _ = bar["5. close"].(string)
		}
		volStr, _ := bar["5. volume"].(string)
		if volStr == "" {
			volStr, _ = bar["6. volume"].(string)
		}
		price, _ := strconv.ParseFloat(closeStr, 64)
		vol, _ := strconv.ParseInt(volStr, 10, 64)
		out = append(out, &StockPrice{
			Symbol:    symbol,
			Price:     price,
			Timestamp: t,
			Volume:    vol,
		})
	}
	return out, nil
}
