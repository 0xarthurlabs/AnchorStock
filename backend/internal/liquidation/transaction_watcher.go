package liquidation

import (
	"context"
	"fmt"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
)

// TransactionWatcher 交易监控器 / Transaction watcher
type TransactionWatcher struct {
	client     *ethclient.Client
	maxWaitTime time.Duration // 最大等待时间 / Maximum wait time
	confirmations int         // 需要的确认数 / Required confirmations
}

// NewTransactionWatcher 创建交易监控器 / Create transaction watcher
func NewTransactionWatcher(client *ethclient.Client) *TransactionWatcher {
	return &TransactionWatcher{
		client:       client,
		maxWaitTime:  5 * time.Minute, // 默认最大等待 5 分钟 / Default max wait 5 minutes
		confirmations: 1,              // 默认需要 1 个确认 / Default 1 confirmation
	}
}

// WaitForConfirmation 等待交易确认 / Wait for transaction confirmation
func (tw *TransactionWatcher) WaitForConfirmation(ctx context.Context, txHash common.Hash) (*types.Receipt, error) {
	deadline := time.Now().Add(tw.maxWaitTime)
	ticker := time.NewTicker(3 * time.Second) // 每 3 秒检查一次 / Check every 3 seconds
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-ticker.C:
			if time.Now().After(deadline) {
				return nil, fmt.Errorf("transaction confirmation timeout: %s", txHash.Hex())
			}

			// 检查交易收据 / Check transaction receipt
			receipt, err := tw.client.TransactionReceipt(ctx, txHash)
			if err != nil {
				// 交易可能还在 pending，继续等待 / Transaction may still be pending, continue waiting
				continue
			}

			// 检查确认数 / Check confirmations
			currentBlock, err := tw.client.BlockNumber(ctx)
			if err != nil {
				return receipt, nil // 返回收据，即使无法检查确认数 / Return receipt even if can't check confirmations
			}

			confirmations := currentBlock - receipt.BlockNumber.Uint64()
			if confirmations >= uint64(tw.confirmations) {
				return receipt, nil
			}
		}
	}
}

// WaitForConfirmationWithCallback 等待交易确认（带回调）/ Wait for transaction confirmation (with callback)
func (tw *TransactionWatcher) WaitForConfirmationWithCallback(
	ctx context.Context,
	txHash common.Hash,
	onPending func(),
	onConfirmed func(*types.Receipt),
	onFailed func(error),
) {
	go func() {
		receipt, err := tw.WaitForConfirmation(ctx, txHash)
		if err != nil {
			if onFailed != nil {
				onFailed(err)
			}
			return
		}

		if receipt.Status == 0 {
			// 交易失败 / Transaction failed
			if onFailed != nil {
				onFailed(fmt.Errorf("transaction failed: %s", txHash.Hex()))
			}
			return
		}

		// 交易成功 / Transaction successful
		if onConfirmed != nil {
			onConfirmed(receipt)
		}
	}()

	// 立即调用 pending 回调 / Immediately call pending callback
	if onPending != nil {
		onPending()
	}
}

// SetMaxWaitTime 设置最大等待时间 / Set maximum wait time
func (tw *TransactionWatcher) SetMaxWaitTime(duration time.Duration) {
	tw.maxWaitTime = duration
}

// SetConfirmations 设置需要的确认数 / Set required confirmations
func (tw *TransactionWatcher) SetConfirmations(confirmations int) {
	if confirmations < 1 {
		confirmations = 1
	}
	tw.confirmations = confirmations
}
