package liquidation

import (
	"context"
	"fmt"
	"log"
	"math/big"
	"sync"
	"time"

	"anchorstock-backend/internal/blockchain"
	"anchorstock-backend/internal/config"
	"anchorstock-backend/internal/kafka"
	"anchorstock-backend/pkg/price"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
)

// Bot 清算机器人 / Liquidation bot
type Bot struct {
	config             *config.Config
	lendingPool        *blockchain.ContractClient
	perpEngine         *blockchain.ContractClient
	positionDiscovery  *PositionDiscovery
	gasOptimizer       *GasOptimizer
	transactionWatcher *TransactionWatcher
	priorityQueue      *PriorityQueue
	ticker             *time.Ticker
	discoveryTicker    *time.Ticker // 定期发现仓位的定时器 / Ticker for periodic position discovery
	ctx                context.Context
	cancel             context.CancelFunc
	monitoredUsers     []common.Address  // 监控的用户列表 / List of monitored users
	lastBlock          *big.Int          // 上次扫描的区块号 / Last scanned block number
	metrics            *Metrics          // 指标收集器 / Metrics collector
	discoveryCounter   int               // 发现计数器（用于控制发现频率）/ Discovery counter (for controlling discovery frequency)
	mu                 sync.RWMutex      // 保护 monitoredUsers 的互斥锁 / Mutex to protect monitoredUsers
	ethClient          *ethclient.Client // 以太坊客户端（用于 Gas 优化和交易监控）/ Ethereum client (for gas optimization and transaction watching)
	// 可选：Kafka 价格消费者，收到价格时触发清算检查（防抖 5s）/ Optional: Kafka price consumer, trigger liquidation check on price (debounce 5s)
	kafkaConsumer *kafka.Consumer
}

// NewBot 创建清算机器人 / Create liquidation bot
func NewBot(cfg *config.Config) (*Bot, error) {
	// 创建 LendingPool 客户端 / Create LendingPool client
	var lendingPool *blockchain.ContractClient
	var err error
	if cfg.LendingPoolContractAddress != "" && cfg.PrivateKey != "" {
		lendingPool, err = blockchain.NewContractClient(
			cfg.RPCURL,
			cfg.LendingPoolContractAddress,
			cfg.PrivateKey,
			blockchain.LendingPoolABI,
		)
		if err != nil {
			log.Printf("Warning: Failed to create LendingPool client: %v\n", err)
		} else {
			log.Println("LendingPool client created successfully")
		}
	}

	// 创建 PerpEngine 客户端 / Create PerpEngine client
	var perpEngine *blockchain.ContractClient
	if cfg.PerpEngineContractAddress != "" && cfg.PrivateKey != "" {
		perpEngine, err = blockchain.NewContractClient(
			cfg.RPCURL,
			cfg.PerpEngineContractAddress,
			cfg.PrivateKey,
			blockchain.PerpEngineABI,
		)
		if err != nil {
			log.Printf("Warning: Failed to create PerpEngine client: %v\n", err)
		} else {
			log.Println("PerpEngine client created successfully")
		}
	}

	if lendingPool == nil && perpEngine == nil {
		return nil, fmt.Errorf("both LendingPool and PerpEngine clients are nil")
	}

	// 创建以太坊客户端（用于 Gas 优化和交易监控）/ Create Ethereum client (for gas optimization and transaction watching)
	ethClient, err := ethclient.Dial(cfg.RPCURL)
	if err != nil {
		log.Printf("Warning: Failed to create Ethereum client: %v\n", err)
	} else {
		log.Println("Ethereum client created successfully")
	}

	// 创建 Gas 优化器 / Create gas optimizer
	var gasOptimizer *GasOptimizer
	if ethClient != nil {
		gasOptimizer = NewGasOptimizer(ethClient)
		log.Println("Gas optimizer created successfully")
	}

	// 创建交易监控器 / Create transaction watcher
	var transactionWatcher *TransactionWatcher
	if ethClient != nil {
		transactionWatcher = NewTransactionWatcher(ethClient)
		log.Println("Transaction watcher created successfully")
	}

	// 创建优先级队列 / Create priority queue
	priorityQueue := NewPriorityQueue()
	log.Println("Priority queue created successfully")

	// 创建仓位发现服务 / Create position discovery service
	var positionDiscovery *PositionDiscovery
	if cfg.LendingPoolContractAddress != "" || cfg.PerpEngineContractAddress != "" {
		var lendingPoolAddr, perpEngineAddr common.Address
		if cfg.LendingPoolContractAddress != "" {
			lendingPoolAddr = common.HexToAddress(cfg.LendingPoolContractAddress)
		}
		if cfg.PerpEngineContractAddress != "" {
			perpEngineAddr = common.HexToAddress(cfg.PerpEngineContractAddress)
		}

		var err error
		positionDiscovery, err = NewPositionDiscovery(cfg.RPCURL, lendingPoolAddr, perpEngineAddr)
		if err != nil {
			log.Printf("Warning: Failed to create position discovery service: %v\n", err)
		} else {
			log.Println("Position discovery service created successfully")
		}
	}

	ctx, cancel := context.WithCancel(context.Background())

	return &Bot{
		config:             cfg,
		lendingPool:        lendingPool,
		perpEngine:         perpEngine,
		positionDiscovery:  positionDiscovery,
		gasOptimizer:       gasOptimizer,
		transactionWatcher: transactionWatcher,
		priorityQueue:      priorityQueue,
		ticker:             time.NewTicker(10 * time.Second), // 每 10 秒检查一次 / Check every 10 seconds
		discoveryTicker:    time.NewTicker(5 * time.Minute),  // 每 5 分钟发现一次仓位 / Discover positions every 5 minutes
		ctx:                ctx,
		cancel:             cancel,
		monitoredUsers:     []common.Address{}, // 初始为空，需要从链上获取或配置 / Initially empty, need to get from chain or config
		lastBlock:          nil,                // 首次扫描时获取当前区块 / Get current block on first scan
		metrics:            NewMetrics(),       // 初始化指标收集器 / Initialize metrics collector
		discoveryCounter:   0,
		ethClient:          ethClient,
	}, nil
}

// Start 启动清算机器人 / Start liquidation bot
func (b *Bot) Start() error {
	log.Println("Starting liquidation bot...")

	// 立即执行一次仓位发现 / Execute position discovery immediately
	if b.positionDiscovery != nil {
		if err := b.discoverActivePositions(); err != nil {
			log.Printf("Error in initial position discovery: %v\n", err)
		}
	}

	// 立即执行一次检查 / Execute check immediately
	if err := b.checkAndLiquidate(); err != nil {
		log.Printf("Error in initial check: %v\n", err)
	}

	// 定时执行检查 / Execute check periodically
	go func() {
		for {
			select {
			case <-b.ctx.Done():
				return
			case <-b.ticker.C:
				start := time.Now()
				if err := b.checkAndLiquidate(); err != nil {
					log.Printf("Error checking and liquidating: %v\n", err)
				}
				b.metrics.RecordCheck(time.Since(start))
			case <-b.discoveryTicker.C:
				// 定期发现仓位 / Periodically discover positions
				if b.positionDiscovery != nil {
					if err := b.discoverActivePositions(); err != nil {
						log.Printf("Error in periodic position discovery: %v\n", err)
					}
				}
			}
		}
	}()

	// 可选：监听 Kafka 价格，收到价格时防抖触发清算检查（最多每 5s 一次）
	if b.config.KafkaBroker != "" && b.config.KafkaTopicPrice != "" {
		kc, err := kafka.NewConsumer(b.config.KafkaBroker, b.config.KafkaTopicPrice, b.config.KafkaConsumerGroupLiquidation)
		if err != nil {
			log.Printf("Warning: Kafka consumer for liquidation bot not started: %v\n", err)
		} else {
			b.kafkaConsumer = kc
			triggerChan := make(chan struct{}, 1)
			go func() {
				for {
					select {
					case <-b.ctx.Done():
						return
					case <-triggerChan:
						if err := b.checkAndLiquidate(); err != nil {
							log.Printf("Error in price-triggered liquidation check: %v\n", err)
						}
						time.Sleep(5 * time.Second) // 防抖：5s 内不再重复 / Debounce
					}
				}
			}()
			go func() {
				_ = kc.ConsumeWithContext(b.ctx, func(_ *price.StockPrice) error {
					select {
					case triggerChan <- struct{}{}:
					default:
					}
					return nil
				})
			}()
			log.Println("Liquidation bot: Kafka price consumer started (debounced check every 5s on price)")
		}
	}

	log.Println("Liquidation bot started")
	return nil
}

// checkAndLiquidate 检查并执行清算 / Check and execute liquidation
func (b *Bot) checkAndLiquidate() error {
	log.Println("Checking for liquidatable positions...")

	// 获取监控用户列表（线程安全）/ Get monitored users list (thread-safe)
	b.mu.RLock()
	users := make([]common.Address, len(b.monitoredUsers))
	copy(users, b.monitoredUsers)
	b.mu.RUnlock()

	if len(users) == 0 {
		log.Println("No users to monitor")
		return nil
	}

	// 并发检查 LendingPool 和 PerpEngine / Check LendingPool and PerpEngine concurrently
	var wg sync.WaitGroup
	errChan := make(chan error, 2)

	if b.lendingPool != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := b.checkLendingPoolConcurrent(users); err != nil {
				errChan <- fmt.Errorf("LendingPool: %w", err)
			}
		}()
	}

	if b.perpEngine != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := b.checkPerpEngineConcurrent(users); err != nil {
				errChan <- fmt.Errorf("PerpEngine: %w", err)
			}
		}()
	}

	wg.Wait()
	close(errChan)

	// 收集错误 / Collect errors
	var errors []error
	for err := range errChan {
		errors = append(errors, err)
	}

	if len(errors) > 0 {
		return fmt.Errorf("errors during check: %v", errors)
	}

	return nil
}

// discoverActivePositions 发现所有活跃仓位 / Discover all active positions
func (b *Bot) discoverActivePositions() error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// 获取当前区块号 / Get current block number
	// 注意：PositionDiscovery 需要暴露 client 或添加方法 / Note: PositionDiscovery needs to expose client or add method
	// 这里简化处理，使用配置的 RPC URL 创建临时客户端 / Simplified: create temporary client using configured RPC URL
	client, err := ethclient.Dial(b.config.RPCURL)
	if err != nil {
		return fmt.Errorf("failed to dial RPC: %w", err)
	}
	defer client.Close()

	currentBlock, err := client.BlockNumber(ctx)
	if err != nil {
		return fmt.Errorf("failed to get current block number: %w", err)
	}

	// 确定扫描范围 / Determine scan range
	var fromBlock *big.Int
	if b.lastBlock == nil {
		// 首次扫描，从最近 1000 个区块开始 / First scan, start from last 1000 blocks
		fromBlock = big.NewInt(int64(currentBlock) - 1000)
		if fromBlock.Sign() < 0 {
			fromBlock = big.NewInt(0)
		}
	} else {
		fromBlock = new(big.Int).Set(b.lastBlock)
	}

	toBlock := big.NewInt(int64(currentBlock))

	// RPC 免费 tier（如 Alchemy）限制 eth_getLogs 单次最多 10 个区块，按块范围分片请求并合并结果
	const maxBlockRangePerRequest = 10
	allLendingUsers := make(map[common.Address]bool)
	allPerpUsers := make(map[common.Address]bool)

	for start := new(big.Int).Set(fromBlock); start.Cmp(toBlock) <= 0; {
		chunkEnd := new(big.Int).Add(start, big.NewInt(maxBlockRangePerRequest-1))
		if chunkEnd.Cmp(toBlock) > 0 {
			chunkEnd = new(big.Int).Set(toBlock)
		}

		// 从 LendingPool 获取本块范围内的活跃用户 / Get active users from LendingPool for this chunk
		if b.lendingPool != nil {
			lendingUsers, err := b.positionDiscovery.GetActiveUsersFromLendingPool(ctx, start, chunkEnd)
			if err != nil {
				log.Printf("Error getting active users from LendingPool (blocks %s-%s): %v\n", start.String(), chunkEnd.String(), err)
			} else {
				for _, u := range lendingUsers {
					allLendingUsers[u] = true
				}
			}
		}

		// 从 PerpEngine 获取本块范围内的活跃用户 / Get active users from PerpEngine for this chunk
		if b.perpEngine != nil {
			perpUsers, err := b.positionDiscovery.GetActiveUsersFromPerpEngine(ctx, start, chunkEnd)
			if err != nil {
				log.Printf("Error getting active users from PerpEngine (blocks %s-%s): %v\n", start.String(), chunkEnd.String(), err)
			} else {
				for _, u := range perpUsers {
					allPerpUsers[u] = true
				}
			}
		}

		// 下一段：从 chunkEnd+1 开始 / Next chunk starts at chunkEnd+1
		startNext := new(big.Int).Add(chunkEnd, big.NewInt(1))
		if startNext.Cmp(toBlock) > 0 {
			break
		}
		start = startNext
	}

	// 合并 Lending + Perp 用户到监控列表 / Merge Lending + Perp users into monitoring list
	{
		b.mu.Lock()
		userMap := make(map[common.Address]bool)
		for _, user := range b.monitoredUsers {
			userMap[user] = true
		}
		for u := range allLendingUsers {
			userMap[u] = true
		}
		for u := range allPerpUsers {
			userMap[u] = true
		}
		b.monitoredUsers = make([]common.Address, 0, len(userMap))
		for user := range userMap {
			b.monitoredUsers = append(b.monitoredUsers, user)
		}
		b.mu.Unlock()
	}

	// 更新最后扫描的区块号 / Update last scanned block number
	b.lastBlock = toBlock

	log.Printf("Discovered %d active positions to monitor\n", len(b.monitoredUsers))
	return nil
}

// checkLendingPoolConcurrent 并发检查 LendingPool 中的可清算账户 / Concurrently check liquidatable accounts in LendingPool
func (b *Bot) checkLendingPoolConcurrent(users []common.Address) error {
	const maxConcurrency = 10 // 最大并发数 / Maximum concurrency
	sem := make(chan struct{}, maxConcurrency)
	var wg sync.WaitGroup
	var mu sync.Mutex
	var errors []error

	for _, user := range users {
		wg.Add(1)
		sem <- struct{}{} // 获取信号量 / Acquire semaphore

		go func(u common.Address) {
			defer wg.Done()
			defer func() { <-sem }() // 释放信号量 / Release semaphore

			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()

			// 获取健康因子 / Get health factor
			result, err := b.lendingPool.CallView(ctx, "getAccountHealthFactor", u)
			if err != nil {
				// 如果用户没有仓位，这是正常的，不记录错误 / If user has no position, this is normal, don't log error
				return
			}

			if len(result) == 0 {
				return
			}

			healthFactor, ok := result[0].(*big.Int)
			if !ok {
				mu.Lock()
				errors = append(errors, fmt.Errorf("invalid health factor type for %s", u.Hex()))
				mu.Unlock()
				return
			}

			// 健康因子 < 1e18 (1.0) 表示可以清算 / Health factor < 1e18 (1.0) means can be liquidated
			oneE18 := big.NewInt(1e18)
			if healthFactor.Cmp(oneE18) < 0 {
				log.Printf("Liquidatable account found in LendingPool: %s (health factor: %s)\n",
					u.Hex(), healthFactor.String())

				// 使用重试机制执行清算 / Execute liquidation with retry mechanism
				config := DefaultRetryConfig()
				err = Retry(ctx, config, func() error {
					// 获取最优 Gas 价格 / Get optimal gas price
					var gasPrice *big.Int
					if b.gasOptimizer != nil {
						gasPrice, _ = b.gasOptimizer.GetOptimalGasPrice(ctx)
					}

					// 发送交易 / Send transaction
					var tx *types.Transaction
					if gasPrice != nil {
						tx, err = b.lendingPool.SendTransactionWithGasPrice(ctx, gasPrice, "liquidate", u)
					} else {
						tx, err = b.lendingPool.SendTransaction(ctx, "liquidate", u)
					}
					if err != nil {
						return err
					}

					log.Printf("Liquidation transaction sent for %s: %s\n", u.Hex(), tx.Hash().Hex())

					// 等待交易确认（异步）/ Wait for transaction confirmation (async)
					if b.transactionWatcher != nil {
						b.transactionWatcher.WaitForConfirmationWithCallback(
							ctx,
							tx.Hash(),
							func() {
								log.Printf("Transaction %s pending...\n", tx.Hash().Hex())
							},
							func(receipt *types.Receipt) {
								log.Printf("Transaction %s confirmed in block %d\n", tx.Hash().Hex(), receipt.BlockNumber.Uint64())
								b.metrics.RecordLiquidation(true)
							},
							func(err error) {
								log.Printf("Transaction %s failed: %v\n", tx.Hash().Hex(), err)
								b.metrics.RecordLiquidation(false)
							},
						)
					} else {
						// 如果没有交易监控器，立即记录成功 / If no transaction watcher, record success immediately
						b.metrics.RecordLiquidation(true)
					}

					return nil
				})

				if err != nil {
					log.Printf("Error liquidating %s after retries: %v\n", u.Hex(), err)
					b.metrics.RecordLiquidation(false)
					mu.Lock()
					errors = append(errors, fmt.Errorf("failed to liquidate %s: %w", u.Hex(), err))
					mu.Unlock()
				}
			}
		}(user)
	}

	wg.Wait()

	if len(errors) > 0 {
		return fmt.Errorf("errors in LendingPool check: %v", errors)
	}

	return nil
}

// checkPerpEngineConcurrent 并发检查 PerpEngine 中的可清算仓位 / Concurrently check liquidatable positions in PerpEngine
func (b *Bot) checkPerpEngineConcurrent(users []common.Address) error {
	const maxConcurrency = 10 // 最大并发数 / Maximum concurrency
	sem := make(chan struct{}, maxConcurrency)
	var wg sync.WaitGroup
	var mu sync.Mutex
	var errors []error

	for _, user := range users {
		wg.Add(1)
		sem <- struct{}{} // 获取信号量 / Acquire semaphore

		go func(u common.Address) {
			defer wg.Done()
			defer func() { <-sem }() // 释放信号量 / Release semaphore

			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()

			// 获取健康因子 / Get health factor
			result, err := b.perpEngine.CallView(ctx, "getPositionHealthFactor", u)
			if err != nil {
				// 如果用户没有仓位，会返回错误，这是正常的 / If user has no position, error is returned, which is normal
				return
			}

			if len(result) == 0 {
				return
			}

			healthFactor, ok := result[0].(*big.Int)
			if !ok {
				mu.Lock()
				errors = append(errors, fmt.Errorf("invalid health factor type for %s", u.Hex()))
				mu.Unlock()
				return
			}

			// 健康因子 < 1e18 (1.0) 表示可以清算 / Health factor < 1e18 (1.0) means can be liquidated
			oneE18 := big.NewInt(1e18)
			if healthFactor.Cmp(oneE18) < 0 {
				log.Printf("Liquidatable position found in PerpEngine: %s (health factor: %s)\n",
					u.Hex(), healthFactor.String())

				// 使用重试机制执行清算 / Execute liquidation with retry mechanism
				config := DefaultRetryConfig()
				err = Retry(ctx, config, func() error {
					// 获取最优 Gas 价格 / Get optimal gas price
					var gasPrice *big.Int
					if b.gasOptimizer != nil {
						gasPrice, _ = b.gasOptimizer.GetOptimalGasPrice(ctx)
					}

					// 发送交易 / Send transaction
					var tx *types.Transaction
					if gasPrice != nil {
						tx, err = b.perpEngine.SendTransactionWithGasPrice(ctx, gasPrice, "liquidatePosition", u)
					} else {
						tx, err = b.perpEngine.SendTransaction(ctx, "liquidatePosition", u)
					}
					if err != nil {
						return err
					}

					log.Printf("Liquidation transaction sent for %s: %s\n", u.Hex(), tx.Hash().Hex())

					// 等待交易确认（异步）/ Wait for transaction confirmation (async)
					if b.transactionWatcher != nil {
						b.transactionWatcher.WaitForConfirmationWithCallback(
							ctx,
							tx.Hash(),
							func() {
								log.Printf("Transaction %s pending...\n", tx.Hash().Hex())
							},
							func(receipt *types.Receipt) {
								log.Printf("Transaction %s confirmed in block %d\n", tx.Hash().Hex(), receipt.BlockNumber.Uint64())
								b.metrics.RecordLiquidation(true)
							},
							func(err error) {
								log.Printf("Transaction %s failed: %v\n", tx.Hash().Hex(), err)
								b.metrics.RecordLiquidation(false)
							},
						)
					} else {
						// 如果没有交易监控器，立即记录成功 / If no transaction watcher, record success immediately
						b.metrics.RecordLiquidation(true)
					}

					return nil
				})

				if err != nil {
					log.Printf("Error liquidating position for %s after retries: %v\n", u.Hex(), err)
					b.metrics.RecordLiquidation(false)
					mu.Lock()
					errors = append(errors, fmt.Errorf("failed to liquidate position for %s: %w", u.Hex(), err))
					mu.Unlock()
				}
			}
		}(user)
	}

	wg.Wait()

	if len(errors) > 0 {
		return fmt.Errorf("errors in PerpEngine check: %v", errors)
	}

	return nil
}

// AddMonitoredUser 添加监控用户 / Add monitored user
func (b *Bot) AddMonitoredUser(user common.Address) {
	b.monitoredUsers = append(b.monitoredUsers, user)
	log.Printf("Added user to monitoring list: %s\n", user.Hex())
}

// SetMonitoredUsers 设置监控用户列表 / Set monitored users list
func (b *Bot) SetMonitoredUsers(users []common.Address) {
	b.monitoredUsers = users
	log.Printf("Set %d users to monitoring list\n", len(users))
}

// GetMetrics 获取指标 / Get metrics
func (b *Bot) GetMetrics() Stats {
	return b.metrics.GetStats()
}

// Stop 停止清算机器人 / Stop liquidation bot
func (b *Bot) Stop() {
	log.Println("Stopping liquidation bot...")
	b.cancel()
	b.ticker.Stop()
	b.discoveryTicker.Stop()
	if b.kafkaConsumer != nil {
		_ = b.kafkaConsumer.Close()
		b.kafkaConsumer = nil
	}
	if b.lendingPool != nil {
		b.lendingPool.Close()
	}
	if b.perpEngine != nil {
		b.perpEngine.Close()
	}
	if b.positionDiscovery != nil {
		b.positionDiscovery.Close()
	}
	if b.ethClient != nil {
		b.ethClient.Close()
	}

	// 打印最终统计信息 / Print final statistics
	stats := b.metrics.GetStats()
	log.Printf("Final statistics: %+v\n", stats)
	log.Println("Liquidation bot stopped")
}
