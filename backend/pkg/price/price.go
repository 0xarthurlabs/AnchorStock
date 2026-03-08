package price

import (
	"encoding/json"
	"fmt"
	"math/big"
	"time"
)

// StockPrice 股票价格数据结构 / Stock price data structure
type StockPrice struct {
	Symbol    string    `json:"symbol"`     // 股票符号 / Stock symbol (e.g., "NVDA")
	Price     float64   `json:"price"`      // 价格（美元）/ Price in USD
	Timestamp time.Time `json:"timestamp"` // 时间戳 / Timestamp
	Volume    int64     `json:"volume"`     // 成交量 / Trading volume
}

// PriceToUint256 将价格转换为 uint256（8 位小数，用于 Oracle）/ Convert price to uint256 (8 decimals for Oracle)
// Oracle 使用 8 位小数，所以需要乘以 1e8 / Oracle uses 8 decimals, so multiply by 1e8
func (p *StockPrice) PriceToUint256() (*big.Int, error) {
	// 将价格乘以 1e8 转换为整数 / Multiply price by 1e8 to convert to integer
	priceBig := new(big.Float).SetFloat64(p.Price)
	multiplier := new(big.Float).SetInt64(1e8)
	priceBig.Mul(priceBig, multiplier)
	
	// 转换为 big.Int / Convert to big.Int
	priceInt, _ := priceBig.Int(nil)
	if priceInt == nil {
		return nil, fmt.Errorf("failed to convert price to uint256")
	}
	
	return priceInt, nil
}

// ToJSON 转换为 JSON 字符串 / Convert to JSON string
func (p *StockPrice) ToJSON() ([]byte, error) {
	return json.Marshal(p)
}

// FromJSON 从 JSON 字符串解析 / Parse from JSON string
func FromJSON(data []byte) (*StockPrice, error) {
	var price StockPrice
	if err := json.Unmarshal(data, &price); err != nil {
		return nil, err
	}
	return &price, nil
}
