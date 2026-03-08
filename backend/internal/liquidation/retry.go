package liquidation

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// RetryConfig 重试配置 / Retry configuration
type RetryConfig struct {
	MaxRetries      int           // 最大重试次数 / Maximum retries
	InitialDelay    time.Duration // 初始延迟 / Initial delay
	MaxDelay        time.Duration // 最大延迟 / Maximum delay
	BackoffFactor   float64       // 退避因子 / Backoff factor
	RetryableErrors []error       // 可重试的错误类型 / Retryable error types
}

// DefaultRetryConfig 默认重试配置 / Default retry configuration
func DefaultRetryConfig() *RetryConfig {
	return &RetryConfig{
		MaxRetries:    3,
		InitialDelay:  1 * time.Second,
		MaxDelay:      30 * time.Second,
		BackoffFactor: 2.0,
	}
}

// Retry 重试函数 / Retry function
func Retry(ctx context.Context, config *RetryConfig, fn func() error) error {
	var lastErr error
	delay := config.InitialDelay

	for attempt := 0; attempt <= config.MaxRetries; attempt++ {
		if attempt > 0 {
			// 等待退避时间 / Wait for backoff time
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(delay):
			}

			// 计算下次延迟（指数退避）/ Calculate next delay (exponential backoff)
			delay = time.Duration(float64(delay) * config.BackoffFactor)
			if delay > config.MaxDelay {
				delay = config.MaxDelay
			}
		}

		// 执行函数 / Execute function
		err := fn()
		if err == nil {
			return nil
		}

		lastErr = err

		// 检查是否可重试 / Check if retryable
		if !isRetryableError(err, config) {
			return err
		}
	}

	return fmt.Errorf("max retries exceeded: %w", lastErr)
}

// isRetryableError 检查错误是否可重试 / Check if error is retryable
func isRetryableError(err error, config *RetryConfig) bool {
	// 网络错误、超时错误等通常可重试 / Network errors, timeout errors are usually retryable
	errStr := err.Error()
	retryablePatterns := []string{
		"timeout",
		"connection",
		"network",
		"temporary",
		"rate limit",
		"too many requests",
	}

	for _, pattern := range retryablePatterns {
		if contains(errStr, pattern) {
			return true
		}
	}

	return false
}

// contains 检查字符串是否包含子串（不区分大小写）/ Check if string contains substring (case-insensitive)
func contains(s, substr string) bool {
	return strings.Contains(strings.ToLower(s), strings.ToLower(substr))
}
