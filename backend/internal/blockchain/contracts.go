package blockchain

import (
	"context"
	"crypto/ecdsa"
	"fmt"
	"math/big"
	"strings"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum"
)

// ContractClient 通用合约客户端 / Generic contract client
type ContractClient struct {
	client     *ethclient.Client
	contract   common.Address
	privateKey *ecdsa.PrivateKey
	chainID    *big.Int
	abi        abi.ABI
}

// NewContractClient 创建合约客户端 / Create contract client
func NewContractClient(rpcURL, contractAddr, privateKeyHex, contractABI string) (*ContractClient, error) {
	client, err := ethclient.Dial(rpcURL)
	if err != nil {
		return nil, fmt.Errorf("failed to dial RPC: %w", err)
	}

	contract := common.HexToAddress(contractAddr)

	privateKey, err := crypto.HexToECDSA(strings.TrimPrefix(privateKeyHex, "0x"))
	if err != nil {
		return nil, fmt.Errorf("failed to parse private key: %w", err)
	}

	chainID, err := client.NetworkID(context.Background())
	if err != nil {
		return nil, fmt.Errorf("failed to get chain ID: %w", err)
	}

	contractABIParsed, err := abi.JSON(strings.NewReader(contractABI))
	if err != nil {
		return nil, fmt.Errorf("failed to parse ABI: %w", err)
	}

	return &ContractClient{
		client:     client,
		contract:   contract,
		privateKey: privateKey,
		chainID:    chainID,
		abi:        contractABIParsed,
	}, nil
}

// CallView 调用视图函数 / Call view function
func (c *ContractClient) CallView(ctx context.Context, method string, args ...interface{}) ([]interface{}, error) {
	data, err := c.abi.Pack(method, args...)
	if err != nil {
		return nil, fmt.Errorf("failed to pack data: %w", err)
	}

	result, err := c.client.CallContract(ctx, ethereum.CallMsg{
		To:   &c.contract,
		Data: data,
	}, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to call contract: %w", err)
	}

	unpacked, err := c.abi.Unpack(method, result)
	if err != nil {
		return nil, fmt.Errorf("failed to unpack result: %w", err)
	}

	return unpacked, nil
}

// SendTransaction 发送交易 / Send transaction
func (c *ContractClient) SendTransaction(ctx context.Context, method string, args ...interface{}) (*types.Transaction, error) {
	return c.SendTransactionWithGasPrice(ctx, nil, method, args...)
}

// SendTransactionWithGasPrice 使用指定 Gas 价格发送交易 / Send transaction with specified gas price
func (c *ContractClient) SendTransactionWithGasPrice(ctx context.Context, gasPrice *big.Int, method string, args ...interface{}) (*types.Transaction, error) {
	data, err := c.abi.Pack(method, args...)
	if err != nil {
		return nil, fmt.Errorf("failed to pack data: %w", err)
	}

	auth, err := bind.NewKeyedTransactorWithChainID(c.privateKey, c.chainID)
	if err != nil {
		return nil, fmt.Errorf("failed to create transactor: %w", err)
	}

	if gasPrice == nil {
		gasPrice, err = c.client.SuggestGasPrice(ctx)
		if err != nil {
			return nil, fmt.Errorf("failed to suggest gas price: %w", err)
		}
	}

	gasLimit, err := c.client.EstimateGas(ctx, ethereum.CallMsg{
		To:   &c.contract,
		Data: data,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to estimate gas: %w", err)
	}

	tx := types.NewTransaction(
		auth.Nonce.Uint64(),
		c.contract,
		big.NewInt(0),
		gasLimit,
		gasPrice,
		data,
	)

	signedTx, err := types.SignTx(tx, types.NewEIP155Signer(c.chainID), c.privateKey)
	if err != nil {
		return nil, fmt.Errorf("failed to sign transaction: %w", err)
	}

	if err := c.client.SendTransaction(ctx, signedTx); err != nil {
		return nil, fmt.Errorf("failed to send transaction: %w", err)
	}

	return signedTx, nil
}

// Close 关闭客户端 / Close client
func (c *ContractClient) Close() {
	c.client.Close()
}

// LendingPoolABI LendingPool 合约的 ABI（简化版）/ LendingPool contract ABI (simplified)
const LendingPoolABI = `[
	{
		"inputs": [{"internalType": "address", "name": "user", "type": "address"}],
		"name": "getAccountHealthFactor",
		"outputs": [{"internalType": "uint256", "name": "healthFactor", "type": "uint256"}],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [{"internalType": "address", "name": "user", "type": "address"}],
		"name": "liquidate",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	}
]`

// PerpEngineABI PerpEngine 合约的 ABI（简化版）/ PerpEngine contract ABI (simplified)
const PerpEngineABI = `[
	{
		"inputs": [{"internalType": "address", "name": "user", "type": "address"}],
		"name": "getPositionHealthFactor",
		"outputs": [{"internalType": "uint256", "name": "healthFactor", "type": "uint256"}],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [{"internalType": "address", "name": "user", "type": "address"}],
		"name": "liquidatePosition",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	}
]`
