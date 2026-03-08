package liquidation

import (
	"context"
	"fmt"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum/ethclient"
)

// GasOptimizer Gas 价格优化器 / Gas price optimizer
type GasOptimizer struct {
	client      *ethclient.Client
	baseGasPrice *big.Int
	multiplier   float64 // Gas 价格倍数（用于加速交易）/ Gas price multiplier (for transaction acceleration)
}

// NewGasOptimizer 创建 Gas 价格优化器 / Create gas price optimizer
func NewGasOptimizer(client *ethclient.Client) *GasOptimizer {
	return &GasOptimizer{
		client:      client,
		baseGasPrice: nil,
		multiplier:   1.1, // 默认增加 10% 以确保交易快速确认 / Default 10% increase to ensure fast confirmation
	}
}

// GetOptimalGasPrice 获取最优 Gas 价格 / Get optimal gas price
// 根据网络拥堵情况动态调整 / Dynamically adjust based on network congestion
func (g *GasOptimizer) GetOptimalGasPrice(ctx context.Context) (*big.Int, error) {
	// 获取建议的 Gas 价格 / Get suggested gas price
	suggestedPrice, err := g.client.SuggestGasPrice(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get suggested gas price: %w", err)
	}

	// 如果有基础价格，使用两者中的较大值 / If base price exists, use the larger of the two
	if g.baseGasPrice != nil && g.baseGasPrice.Cmp(suggestedPrice) > 0 {
		suggestedPrice = g.baseGasPrice
	}

	// 应用倍数（增加 Gas 价格以加速确认）/ Apply multiplier (increase gas price to accelerate confirmation)
	multiplier := big.NewFloat(g.multiplier)
	priceFloat := new(big.Float).SetInt(suggestedPrice)
	priceFloat.Mul(priceFloat, multiplier)
	
	optimalPrice, _ := priceFloat.Int(nil)
	if optimalPrice == nil {
		optimalPrice = suggestedPrice
	}

	return optimalPrice, nil
}

// SetMultiplier 设置 Gas 价格倍数 / Set gas price multiplier
func (g *GasOptimizer) SetMultiplier(multiplier float64) {
	if multiplier < 1.0 {
		multiplier = 1.0
	}
	if multiplier > 2.0 {
		multiplier = 2.0 // 最大 2 倍，避免过度支付 / Max 2x to avoid overpaying
	}
	g.multiplier = multiplier
}

// SetBaseGasPrice 设置基础 Gas 价格 / Set base gas price
func (g *GasOptimizer) SetBaseGasPrice(price *big.Int) {
	g.baseGasPrice = price
}

// GetGasPriceHistory 获取 Gas 价格历史（用于分析）/ Get gas price history (for analysis)
func (g *GasOptimizer) GetGasPriceHistory(ctx context.Context, duration time.Duration) ([]*big.Int, error) {
	// 简化实现：获取当前和最近几次的 Gas 价格 / Simplified: get current and recent gas prices
	prices := make([]*big.Int, 0)
	
	for i := 0; i < 5; i++ {
		price, err := g.client.SuggestGasPrice(ctx)
		if err != nil {
			return prices, err
		}
		prices = append(prices, price)
		time.Sleep(100 * time.Millisecond)
	}
	
	return prices, nil
}
