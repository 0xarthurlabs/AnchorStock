package blockchain

import (
	"context"
	"crypto/ecdsa"
	"encoding/hex"
	"fmt"
	"log"
	"math/big"
	"regexp"
	"strings"

	"anchorstock-backend/pkg/price"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

// OracleClient 链上 Oracle 客户端 / On-chain Oracle client
type OracleClient struct {
	client     *ethclient.Client
	contract   common.Address
	privateKey *ecdsa.PrivateKey
	chainID    *big.Int
	abi        abi.ABI
}

// NewOracleClient 创建 Oracle 客户端 / Create Oracle client
func NewOracleClient(rpcURL, contractAddr, privateKeyHex string) (*OracleClient, error) {
	// 连接以太坊节点 / Connect to Ethereum node
	client, err := ethclient.Dial(rpcURL)
	if err != nil {
		return nil, fmt.Errorf("failed to dial RPC: %w", err)
	}

	// 解析合约地址 / Parse contract address
	contract := common.HexToAddress(contractAddr)

	// 解析私钥 / Parse private key
	privateKey, err := crypto.HexToECDSA(strings.TrimPrefix(privateKeyHex, "0x"))
	if err != nil {
		return nil, fmt.Errorf("failed to parse private key: %w", err)
	}

	// 获取链 ID / Get chain ID
	chainID, err := client.NetworkID(context.Background())
	if err != nil {
		return nil, fmt.Errorf("failed to get chain ID: %w", err)
	}

	// 解析 ABI（简化版，实际应该从编译后的合约获取）/ Parse ABI (simplified, should get from compiled contract)
	// 这里使用 StockOracle 的核心函数 ABI / Using core functions ABI of StockOracle
	contractABI, err := abi.JSON(strings.NewReader(StockOracleABI))
	if err != nil {
		return nil, fmt.Errorf("failed to parse ABI: %w", err)
	}

	return &OracleClient{
		client:     client,
		contract:   contract,
		privateKey: privateKey,
		chainID:    chainID,
		abi:        contractABI,
	}, nil
}

// UpdatePrice 更新链上 Oracle 价格 / Update on-chain Oracle price
func (o *OracleClient) UpdatePrice(ctx context.Context, priceData *price.StockPrice) (*types.Transaction, error) {
	oracleInflightTx.Set(1)
	defer oracleInflightTx.Set(0)

	// 将价格转换为 uint256（8 位小数）/ Convert price to uint256 (8 decimals)
	priceUint256, err := priceData.PriceToUint256()
	if err != nil {
		return nil, fmt.Errorf("failed to convert price: %w", err)
	}

	// 准备交易数据 / Prepare transaction data
	// updatePrice(string memory symbol, uint256 price)
	data, err := o.abi.Pack("updatePrice", priceData.Symbol, priceUint256)
	if err != nil {
		return nil, fmt.Errorf("failed to pack data: %w", err)
	}

	from := crypto.PubkeyToAddress(o.privateKey.PublicKey)

	// 获取 gas 价格 / Get gas price
	gasPrice, err := o.client.SuggestGasPrice(ctx)
	if err != nil {
		recordOracleRPCError("suggest_gas")
		return nil, fmt.Errorf("failed to suggest gas price: %w", err)
	}

	// 估算 gas / Estimate gas
	gasLimit, err := o.client.EstimateGas(ctx, ethereum.CallMsg{
		To:   &o.contract,
		Data: data,
	})
	if err != nil {
		recordOracleRPCError("estimate_gas")
		return nil, fmt.Errorf("failed to estimate gas: %w", err)
	}

	nonce, err := o.client.PendingNonceAt(ctx, from)
	if err != nil {
		recordOracleRPCError("pending_nonce")
		return nil, fmt.Errorf("failed to get nonce: %w", err)
	}
	oraclePendingNonce.Set(float64(nonce))

	// 构建交易 / Build transaction
	tx := types.NewTransaction(
		nonce,
		o.contract,
		big.NewInt(0), // value
		gasLimit,
		gasPrice,
		data,
	)

	// 签名交易 / Sign transaction
	signedTx, err := types.SignTx(tx, types.NewEIP155Signer(o.chainID), o.privateKey)
	if err != nil {
		recordOracleRPCError("sign_tx")
		return nil, fmt.Errorf("failed to sign transaction: %w", err)
	}

	// 发送交易 / Send transaction
	if err := o.client.SendTransaction(ctx, signedTx); err != nil {
		recordOracleRPCError("send_tx")
		return nil, fmt.Errorf("failed to send transaction: %w", err)
	}

	if head, err := o.client.BlockNumber(ctx); err == nil {
		oracleChainHead.Set(float64(head))
	} else {
		recordOracleRPCError("block_number")
	}

	log.Printf("Sent transaction to update price for %s: %s\n", priceData.Symbol, signedTx.Hash().Hex())

	return signedTx, nil
}

// UpdatePrices 批量更新价格 / Batch update prices
func (o *OracleClient) UpdatePrices(ctx context.Context, prices map[string]*price.StockPrice) error {
	oracleInflightTx.Set(1)
	defer oracleInflightTx.Set(0)

	symbols := make([]string, 0, len(prices))
	priceValues := make([]*big.Int, 0, len(prices))

	for symbol, priceData := range prices {
		priceUint256, err := priceData.PriceToUint256()
		if err != nil {
			log.Printf("Error converting price for %s: %v\n", symbol, err)
			continue
		}
		// Contract reverts with InvalidPrice() if price is 0
		if priceUint256.Sign() == 0 {
			log.Printf("Skip %s: price converts to 0 (contract would revert with InvalidPrice)\n", symbol)
			continue
		}
		symbols = append(symbols, symbol)
		priceValues = append(priceValues, priceUint256)
	}

	if len(symbols) == 0 {
		return fmt.Errorf("no valid prices to update")
	}

	// updatePrices(string[] memory symbols, uint256[] memory prices)
	data, err := o.abi.Pack("updatePrices", symbols, priceValues)
	if err != nil {
		return fmt.Errorf("failed to pack data: %w", err)
	}

	auth, err := bind.NewKeyedTransactorWithChainID(o.privateKey, o.chainID)
	if err != nil {
		return fmt.Errorf("failed to create transactor: %w", err)
	}

	gasPrice, err := o.client.SuggestGasPrice(ctx)
	if err != nil {
		recordOracleRPCError("suggest_gas")
		return fmt.Errorf("failed to suggest gas price: %w", err)
	}

	// Simulate call first to get revert reason on failure (eth_call with From set)
	from := crypto.PubkeyToAddress(o.privateKey.PublicKey)
	msg := ethereum.CallMsg{
		From: from,
		To:   &o.contract,
		Data: data,
	}
	log.Printf("[Oracle] Simulating update with eth_call (from=%s, symbols=%v)...\n", from.Hex(), symbols)
	_, err = o.client.CallContract(ctx, msg, nil)
	if err != nil {
		recordOracleRPCError("eth_call")
		reason := extractRevertReason(err)
		log.Printf("[Oracle] eth_call failed. Revert reason: %s\n", reason)
		log.Printf("[Oracle] Raw RPC error: %v\n", err)
		return fmt.Errorf("oracle update would revert: %s (original: %w)", reason, err)
	}
	log.Printf("[Oracle] eth_call simulation OK, sending transaction...\n")

	gasLimit, err := o.client.EstimateGas(ctx, ethereum.CallMsg{
		From: from,
		To:   &o.contract,
		Data: data,
	})
	if err != nil {
		recordOracleRPCError("estimate_gas")
		reason := extractRevertReason(err)
		return fmt.Errorf("failed to estimate gas: %s (original: %w)", reason, err)
	}

	// 获取当前 nonce（NewKeyedTransactorWithChainID 不会自动拉取）/ Get current nonce
	nonce, err := o.client.PendingNonceAt(ctx, from)
	if err != nil {
		recordOracleRPCError("pending_nonce")
		return fmt.Errorf("failed to get nonce: %w", err)
	}
	oraclePendingNonce.Set(float64(nonce))
	auth.Nonce = big.NewInt(int64(nonce))

	// 构建交易 / Build transaction
	tx := types.NewTransaction(
		auth.Nonce.Uint64(),
		o.contract,
		big.NewInt(0),
		gasLimit,
		gasPrice,
		data,
	)

	// 签名并发送交易 / Sign and send transaction
	signedTx, err := types.SignTx(tx, types.NewEIP155Signer(o.chainID), o.privateKey)
	if err != nil {
		recordOracleRPCError("sign_tx")
		return fmt.Errorf("failed to sign transaction: %w", err)
	}

	if err := o.client.SendTransaction(ctx, signedTx); err != nil {
		recordOracleRPCError("send_tx")
		return fmt.Errorf("failed to send transaction: %w", err)
	}

	if head, err := o.client.BlockNumber(ctx); err == nil {
		oracleChainHead.Set(float64(head))
	} else {
		recordOracleRPCError("block_number")
	}

	log.Printf("Sent batch update transaction: %s\n", signedTx.Hash().Hex())
	return nil
}

// Close 关闭客户端连接 / Close client connection
func (o *OracleClient) Close() {
	o.client.Close()
}

// extractRevertReason 从 RPC 错误中解析 revert 原因（Error(string) 或十六进制 data）/ Extract revert reason from RPC error
func extractRevertReason(err error) string {
	if err == nil {
		return ""
	}
	msg := err.Error()
	// 常见格式: "execution reverted: 0x..." 或 "VM execution error. 0x..." 或直接包含 0x 的 data
	re := regexp.MustCompile(`0x[0-9a-fA-F]+`)
	hexStr := re.FindString(msg)
	if hexStr == "" {
		return msg
	}
	data, errDec := hex.DecodeString(strings.TrimPrefix(hexStr, "0x"))
	if errDec != nil || len(data) < 4 {
		return msg
	}
	// Error(string) selector = 0x08c379a0
	if len(data) >= 4 && data[0] == 0x08 && data[1] == 0xc3 && data[2] == 0x79 && data[3] == 0xa0 {
		if s, errUnpack := abi.UnpackRevert(data); errUnpack == nil {
			return s
		}
	}
	// Custom error: return selector (first 4 bytes) as hex so user can look up (e.g. InvalidPrice, OwnableUnauthorizedAccount)
	return "custom error selector 0x" + hex.EncodeToString(data[:4]) + " (see contract for meaning)"
}

// StockOracleABI StockOracle 合约的 ABI（简化版）/ StockOracle contract ABI (simplified)
// 实际使用时应该从编译后的合约 JSON 文件读取 / Should read from compiled contract JSON file in production
const StockOracleABI = `[
	{
		"inputs": [
			{"internalType": "string", "name": "symbol", "type": "string"},
			{"internalType": "uint256", "name": "price", "type": "uint256"}
		],
		"name": "updatePrice",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [
			{"internalType": "string[]", "name": "symbols", "type": "string[]"},
			{"internalType": "uint256[]", "name": "prices", "type": "uint256[]"}
		],
		"name": "updatePrices",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	}
]`
