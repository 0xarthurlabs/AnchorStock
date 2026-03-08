package liquidation

import (
	"context"
	"fmt"
	"log"
	"math/big"

	"strings"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/ethclient"
)

// PositionDiscovery 仓位发现服务 / Position discovery service
// 用于从链上事件中获取所有活跃仓位 / Used to get all active positions from chain events
type PositionDiscovery struct {
	client           *ethclient.Client
	lendingPoolAddr  common.Address
	perpEngineAddr  common.Address
	lendingPoolABI   abi.ABI
	perpEngineABI    abi.ABI
}

// NewPositionDiscovery 创建仓位发现服务 / Create position discovery service
func NewPositionDiscovery(rpcURL string, lendingPoolAddr, perpEngineAddr common.Address) (*PositionDiscovery, error) {
	client, err := ethclient.Dial(rpcURL)
	if err != nil {
		return nil, fmt.Errorf("failed to dial RPC: %w", err)
	}

	// 解析 ABI（简化版，实际应该从编译后的合约获取）/ Parse ABI (simplified, should get from compiled contract)
	lendingPoolABI, err := abi.JSON(strings.NewReader(LendingPoolEventsABI))
	if err != nil {
		return nil, fmt.Errorf("failed to parse LendingPool ABI: %w", err)
	}

	perpEngineABI, err := abi.JSON(strings.NewReader(PerpEngineEventsABI))
	if err != nil {
		return nil, fmt.Errorf("failed to parse PerpEngine ABI: %w", err)
	}

	return &PositionDiscovery{
		client:          client,
		lendingPoolAddr: lendingPoolAddr,
		perpEngineAddr:  perpEngineAddr,
		lendingPoolABI:  lendingPoolABI,
		perpEngineABI:   perpEngineABI,
	}, nil
}

// GetActiveUsersFromLendingPool 从 LendingPool 事件中获取所有活跃用户 / Get all active users from LendingPool events
// 活跃用户 = 有存款或借款的用户 / Active users = users with deposits or borrows
func (pd *PositionDiscovery) GetActiveUsersFromLendingPool(ctx context.Context, fromBlock, toBlock *big.Int) ([]common.Address, error) {
	users := make(map[common.Address]bool)

	// 查询 Deposited 事件 / Query Deposited events
	depositedEvent := pd.lendingPoolABI.Events["Deposited"]
	query := ethereum.FilterQuery{
		FromBlock: fromBlock,
		ToBlock:   toBlock,
		Addresses: []common.Address{pd.lendingPoolAddr},
		Topics: [][]common.Hash{
			{depositedEvent.ID},
		},
	}

	logs, err := pd.client.FilterLogs(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("failed to filter Deposited events: %w", err)
	}

	for _, vLog := range logs {
		event, err := pd.lendingPoolABI.Unpack("Deposited", vLog.Data)
		if err != nil {
			continue
		}
		if len(event) > 0 {
			// event[0] 是 user 地址 / event[0] is user address
			if user, ok := event[0].(common.Address); ok {
				users[user] = true
			}
		}
		// 也可以从 indexed 参数获取 / Can also get from indexed parameters
		if len(vLog.Topics) > 1 {
			user := common.BytesToAddress(vLog.Topics[1].Bytes())
			users[user] = true
		}
	}

	// 查询 Borrowed 事件 / Query Borrowed events
	borrowedEvent := pd.lendingPoolABI.Events["Borrowed"]
	query = ethereum.FilterQuery{
		FromBlock: fromBlock,
		ToBlock:   toBlock,
		Addresses: []common.Address{pd.lendingPoolAddr},
		Topics: [][]common.Hash{
			{borrowedEvent.ID},
		},
	}

	logs, err = pd.client.FilterLogs(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("failed to filter Borrowed events: %w", err)
	}

	for _, vLog := range logs {
		if len(vLog.Topics) > 1 {
			user := common.BytesToAddress(vLog.Topics[1].Bytes())
			users[user] = true
		}
	}

	// 转换为切片 / Convert to slice
	result := make([]common.Address, 0, len(users))
	for user := range users {
		result = append(result, user)
	}

	log.Printf("Found %d active users in LendingPool\n", len(result))
	return result, nil
}

// GetActiveUsersFromPerpEngine 从 PerpEngine 事件中获取所有活跃用户 / Get all active users from PerpEngine events
// 活跃用户 = 有开仓的用户 / Active users = users with open positions
func (pd *PositionDiscovery) GetActiveUsersFromPerpEngine(ctx context.Context, fromBlock, toBlock *big.Int) ([]common.Address, error) {
	users := make(map[common.Address]bool)

	// 查询 PositionOpened 事件 / Query PositionOpened events
	openedEvent := pd.perpEngineABI.Events["PositionOpened"]
	query := ethereum.FilterQuery{
		FromBlock: fromBlock,
		ToBlock:   toBlock,
		Addresses: []common.Address{pd.perpEngineAddr},
		Topics: [][]common.Hash{
			{openedEvent.ID},
		},
	}

	logs, err := pd.client.FilterLogs(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("failed to filter PositionOpened events: %w", err)
	}

	for _, vLog := range logs {
		if len(vLog.Topics) > 1 {
			user := common.BytesToAddress(vLog.Topics[1].Bytes())
			users[user] = true
		}
	}

	// 查询 PositionClosed 和 PositionLiquidated 事件，移除已关闭/清算的用户 / Query PositionClosed and PositionLiquidated events, remove closed/liquidated users
	closedEvent := pd.perpEngineABI.Events["PositionClosed"]
	liquidatedEvent := pd.perpEngineABI.Events["PositionLiquidated"]

	// 分别查询关闭和清算事件 / Query closed and liquidated events separately
	query = ethereum.FilterQuery{
		FromBlock: fromBlock,
		ToBlock:   toBlock,
		Addresses: []common.Address{pd.perpEngineAddr},
		Topics: [][]common.Hash{
			{closedEvent.ID},
		},
	}

	logs, err = pd.client.FilterLogs(ctx, query)
	if err == nil {
		for _, vLog := range logs {
			if len(vLog.Topics) > 1 {
				user := common.BytesToAddress(vLog.Topics[1].Bytes())
				delete(users, user)
			}
		}
	}

	query = ethereum.FilterQuery{
		FromBlock: fromBlock,
		ToBlock:   toBlock,
		Addresses: []common.Address{pd.perpEngineAddr},
		Topics: [][]common.Hash{
			{liquidatedEvent.ID},
		},
	}

	logs, err = pd.client.FilterLogs(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("failed to filter PositionClosed/Liquidated events: %w", err)
	}

	for _, vLog := range logs {
		if len(vLog.Topics) > 1 {
			user := common.BytesToAddress(vLog.Topics[1].Bytes())
			// 移除已关闭/清算的用户 / Remove closed/liquidated users
			delete(users, user)
		}
	}

	// 转换为切片 / Convert to slice
	result := make([]common.Address, 0, len(users))
	for user := range users {
		result = append(result, user)
	}

	log.Printf("Found %d active users in PerpEngine\n", len(result))
	return result, nil
}

// Close 关闭客户端 / Close client
func (pd *PositionDiscovery) Close() {
	pd.client.Close()
}

// LendingPoolEventsABI LendingPool 事件 ABI（简化版）/ LendingPool events ABI (simplified)
const LendingPoolEventsABI = `[
	{
		"anonymous": false,
		"inputs": [
			{"indexed": true, "internalType": "address", "name": "user", "type": "address"},
			{"indexed": true, "internalType": "address", "name": "asset", "type": "address"},
			{"indexed": false, "internalType": "uint256", "name": "amount", "type": "uint256"},
			{"indexed": false, "internalType": "uint256", "name": "aTokenAmount", "type": "uint256"}
		],
		"name": "Deposited",
		"type": "event"
	},
	{
		"anonymous": false,
		"inputs": [
			{"indexed": true, "internalType": "address", "name": "user", "type": "address"},
			{"indexed": false, "internalType": "uint256", "name": "amount", "type": "uint256"},
			{"indexed": false, "internalType": "uint256", "name": "timestamp", "type": "uint256"}
		],
		"name": "Borrowed",
		"type": "event"
	}
]`

// PerpEngineEventsABI PerpEngine 事件 ABI（简化版）/ PerpEngine events ABI (simplified)
const PerpEngineEventsABI = `[
	{
		"anonymous": false,
		"inputs": [
			{"indexed": true, "internalType": "address", "name": "user", "type": "address"},
			{"indexed": false, "internalType": "uint8", "name": "side", "type": "uint8"},
			{"indexed": false, "internalType": "uint256", "name": "size", "type": "uint256"},
			{"indexed": false, "internalType": "uint256", "name": "entryPrice", "type": "uint256"},
			{"indexed": false, "internalType": "uint256", "name": "collateral", "type": "uint256"}
		],
		"name": "PositionOpened",
		"type": "event"
	},
	{
		"anonymous": false,
		"inputs": [
			{"indexed": true, "internalType": "address", "name": "user", "type": "address"},
			{"indexed": false, "internalType": "uint8", "name": "side", "type": "uint8"},
			{"indexed": false, "internalType": "uint256", "name": "size", "type": "uint256"},
			{"indexed": false, "internalType": "uint256", "name": "exitPrice", "type": "uint256"},
			{"indexed": false, "internalType": "uint256", "name": "pnl", "type": "uint256"},
			{"indexed": false, "internalType": "uint256", "name": "fundingFee", "type": "uint256"}
		],
		"name": "PositionClosed",
		"type": "event"
	},
	{
		"anonymous": false,
		"inputs": [
			{"indexed": true, "internalType": "address", "name": "user", "type": "address"},
			{"indexed": true, "internalType": "address", "name": "liquidator", "type": "address"},
			{"indexed": false, "internalType": "uint8", "name": "side", "type": "uint8"},
			{"indexed": false, "internalType": "uint256", "name": "size", "type": "uint256"},
			{"indexed": false, "internalType": "uint256", "name": "collateralSeized", "type": "uint256"},
			{"indexed": false, "internalType": "uint256", "name": "liquidationBonus", "type": "uint256"}
		],
		"name": "PositionLiquidated",
		"type": "event"
	}
]`
