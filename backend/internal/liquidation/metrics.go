package liquidation

import (
	"sync"
	"time"
)

// Metrics 指标收集器 / Metrics collector
type Metrics struct {
	mu                     sync.RWMutex
	totalChecks            int64
	totalLiquidations      int64
	successfulLiquidations int64
	failedLiquidations     int64
	lastCheckTime          time.Time
	lastLiquidationTime    time.Time
	averageCheckDuration   time.Duration
	totalCheckDuration     time.Duration
}

// NewMetrics 创建指标收集器 / Create metrics collector
func NewMetrics() *Metrics {
	return &Metrics{}
}

// RecordCheck 记录检查 / Record check
func (m *Metrics) RecordCheck(duration time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.totalChecks++
	m.lastCheckTime = time.Now()
	m.totalCheckDuration += duration
	m.averageCheckDuration = m.totalCheckDuration / time.Duration(m.totalChecks)
}

// RecordLiquidation 记录清算 / Record liquidation
func (m *Metrics) RecordLiquidation(success bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.totalLiquidations++
	m.lastLiquidationTime = time.Now()
	if success {
		m.successfulLiquidations++
	} else {
		m.failedLiquidations++
	}
}

// GetStats 获取统计信息 / Get statistics
func (m *Metrics) GetStats() Stats {
	m.mu.RLock()
	defer m.mu.RUnlock()

	successRate := float64(0)
	if m.totalLiquidations > 0 {
		successRate = float64(m.successfulLiquidations) / float64(m.totalLiquidations) * 100
	}

	return Stats{
		TotalChecks:            m.totalChecks,
		TotalLiquidations:      m.totalLiquidations,
		SuccessfulLiquidations: m.successfulLiquidations,
		FailedLiquidations:     m.failedLiquidations,
		SuccessRate:            successRate,
		LastCheckTime:          m.lastCheckTime,
		LastLiquidationTime:    m.lastLiquidationTime,
		AverageCheckDuration:   m.averageCheckDuration,
	}
}

// Stats 统计信息 / Statistics
type Stats struct {
	TotalChecks            int64         `json:"total_checks"`
	TotalLiquidations      int64         `json:"total_liquidations"`
	SuccessfulLiquidations int64         `json:"successful_liquidations"`
	FailedLiquidations     int64         `json:"failed_liquidations"`
	SuccessRate            float64       `json:"success_rate"`
	LastCheckTime          time.Time     `json:"last_check_time"`
	LastLiquidationTime    time.Time     `json:"last_liquidation_time"`
	AverageCheckDuration   time.Duration `json:"average_check_duration"`
}
