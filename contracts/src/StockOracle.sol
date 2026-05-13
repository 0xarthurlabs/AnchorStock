// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeFiMath} from "./libraries/DeFiMath.sol";
import {IPyth} from "./interfaces/IPyth.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title StockOracle
 * @author AnchorStock
 * @notice 美股价格预言机，支持 Pyth Network 和 Custom Relayer 两种策略 / Stock price oracle supporting Pyth Network and Custom Relayer strategies
 * @dev 实现价格过期检测和断路器模式，防止休市期间的价格停滞风险 / Implements stale price detection and circuit breaker to prevent market hours trap
 */
contract StockOracle is Ownable {
    using DeFiMath for uint256;

    /// @notice Oracle 策略枚举 / Oracle strategy enum
    enum OracleStrategy {
        PYTH,
        CUSTOM_RELAYER
    }

    /// @notice 当前使用的 Oracle 策略 / Current oracle strategy
    OracleStrategy public oracleStrategy;

    /// @notice Pyth Network 合约地址 / Pyth Network contract address
    IPyth public pyth;

    /// @notice 股票符号到价格 ID 的映射（用于 Pyth）/ Mapping from stock symbol to price ID (for Pyth)
    mapping(string => bytes32) public stockPriceIds;

    /// @notice 股票符号到价格的映射（用于 Custom Relayer）/ Mapping from stock symbol to price (for Custom Relayer)
    mapping(string => uint256) public stockPrices;

    /// @notice 股票符号到最后更新时间戳的映射 / Mapping from stock symbol to last update timestamp
    mapping(string => uint256) public lastUpdatedAt;

    /// @notice 价格过期阈值（秒），默认 24 小时 / Stale price threshold (seconds), default 24 hours
    uint256 public stalePriceThreshold = 24 hours;

    /// @notice 断路器模式：价格过期时是否禁止新开仓位 / Circuit breaker: whether to disable new positions when price is stale
    bool public circuitBreakerEnabled = true;

    /// @notice 事件：价格更新 / Event: Price updated
    event PriceUpdated(string indexed symbol, uint256 price, uint256 timestamp, OracleStrategy strategy);

    /// @notice 事件：Oracle 策略切换 / Event: Oracle strategy switched
    event OracleStrategySwitched(OracleStrategy oldStrategy, OracleStrategy newStrategy);

    /// @notice 事件：价格过期阈值更新 / Event: Stale price threshold updated
    event StalePriceThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    /// @notice 错误：价格已过期 / Error: Price is stale
    error PriceStale(string symbol);

    /// @notice 错误：无效的股票符号 / Error: Invalid stock symbol
    error InvalidSymbol(string symbol);

    /// @notice 错误：无效的价格 / Error: Invalid price
    error InvalidPrice();

    event CheckFailedInvalidOwner(address value);
    event CheckFailedPriceNotSet(string symbol, uint256 value);
    event CheckFailedArraysLengthMismatch(uint256 lengthSymbols, uint256 lengthPrices);
    event CheckFailedPriceIdNotSet(string symbol);
    event CheckFailedInvalidPythPrice(bytes32 priceId, int64 price);
    event CheckFailedPriceStale(string symbol, uint256 timestamp, uint256 threshold);

    /**
     * @notice 构造函数 / Constructor
     * @param pythAddr Pyth Network 合约地址 / Pyth Network contract address
     * @param initialOwner 合约所有者地址 / Contract owner address
     */
    constructor(address pythAddr, address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) {
            emit CheckFailedInvalidOwner(initialOwner);
            require(false, "StockOracle: invalid owner");
        }
        pyth = IPyth(pythAddr);
        oracleStrategy = OracleStrategy.CUSTOM_RELAYER;
    }

    /**
     * @notice 设置股票符号的 Pyth 价格 ID / Set Pyth price ID for stock symbol
     */
    function setStockPriceId(string memory symbol, bytes32 priceId) external onlyOwner {
        stockPriceIds[symbol] = priceId;
    }

    /**
     * @notice 切换 Oracle 策略 / Switch oracle strategy
     */
    function setOracleStrategy(OracleStrategy newStrategy) external onlyOwner {
        OracleStrategy oldStrategy = oracleStrategy;
        oracleStrategy = newStrategy;
        emit OracleStrategySwitched(oldStrategy, newStrategy);
    }

    /**
     * @notice 设置价格过期阈值 / Set stale price threshold
     */
    function setStalePriceThreshold(uint256 newThreshold) external onlyOwner {
        uint256 oldThreshold = stalePriceThreshold;
        stalePriceThreshold = newThreshold;
        emit StalePriceThresholdUpdated(oldThreshold, newThreshold);
    }

    /**
     * @notice 设置断路器模式 / Set circuit breaker mode
     */
    function setCircuitBreaker(bool newEnabled) external onlyOwner {
        circuitBreakerEnabled = newEnabled;
    }

    /**
     * @notice 更新价格（Custom Relayer 策略使用）/ Update price (for Custom Relayer strategy)
     */
    function updatePrice(string memory symbol, uint256 price) external onlyOwner {
        if (price == 0) {
            emit CheckFailedPriceNotSet(symbol, price);
            revert InvalidPrice();
        }

        stockPrices[symbol] = price;
        lastUpdatedAt[symbol] = block.timestamp;

        emit PriceUpdated(symbol, price, block.timestamp, OracleStrategy.CUSTOM_RELAYER);
    }

    /**
     * @notice 批量更新价格 / Batch update prices
     */
    function updatePrices(string[] memory symbols, uint256[] memory prices) external onlyOwner {
        if (symbols.length != prices.length) {
            emit CheckFailedArraysLengthMismatch(symbols.length, prices.length);
            require(false, "StockOracle: arrays length mismatch");
        }

        for (uint256 i = 0; i < symbols.length; i++) {
            if (prices[i] == 0) {
                emit CheckFailedPriceNotSet(symbols[i], prices[i]);
                revert InvalidPrice();
            }
            stockPrices[symbols[i]] = prices[i];
            lastUpdatedAt[symbols[i]] = block.timestamp;
            emit PriceUpdated(symbols[i], prices[i], block.timestamp, OracleStrategy.CUSTOM_RELAYER);
        }
    }

    /**
     * @notice 获取股票价格（归一化到 18 位精度）/ Get stock price (normalized to 18 decimals)
     */
    function getPrice(string memory symbol) public view returns (uint256 normalizedPrice, uint256 timestamp) {
        uint256 rawPrice;

        if (oracleStrategy == OracleStrategy.PYTH) {
            bytes32 priceId = stockPriceIds[symbol];
            if (priceId == bytes32(0)) {
                require(false, "StockOracle: price ID not set");
            }

            (int64 pythPrice, uint256 publishTime) = pyth.getPrice(priceId);
            if (pythPrice <= 0) {
                require(false, "StockOracle: invalid Pyth price");
            }

            // forge-lint: disable-next-line(unsafe-typecast)
            rawPrice = uint256(uint64(pythPrice));
            timestamp = publishTime;
        } else {
            rawPrice = stockPrices[symbol];
            if (rawPrice == 0) {
                require(false, "StockOracle: price not set");
            }
            timestamp = lastUpdatedAt[symbol];
        }

        normalizedPrice = DeFiMath.normalizeOraclePrice(rawPrice);
    }

    /**
     * @notice 检查价格是否过期 / Check if price is stale
     */
    function isPriceStale(string memory symbol) public view returns (bool isStale) {
        uint256 lastUpdate = lastUpdatedAt[symbol];
        if (lastUpdate == 0) return true;

        if (oracleStrategy == OracleStrategy.PYTH) {
            bytes32 priceId = stockPriceIds[symbol];
            if (priceId == bytes32(0)) return true;

            // Only publishTime is needed; pythPrice return value is intentionally ignored here
            // slither-disable-next-line unused-return
            (, uint256 publishTime) = pyth.getPrice(priceId);
            lastUpdate = publishTime;
        }

        isStale = (block.timestamp - lastUpdate) > stalePriceThreshold;
    }

    /**
     * @notice 获取价格并检查是否过期（带断路器检查）/ Get price with stale check (with circuit breaker)
     */
    function getPriceWithStaleCheck(string memory symbol)
        external
        view
        returns (uint256 normalizedPrice, uint256 timestamp, bool isStale)
    {
        (normalizedPrice, timestamp) = getPrice(symbol);
        isStale = isPriceStale(symbol);

        if (circuitBreakerEnabled && isStale) {
            revert PriceStale(symbol);
        }
    }

    /**
     * @notice 获取价格信息（包含策略和状态）/ Get price info (including strategy and status)
     */
    function getPriceInfo(string memory symbol)
        external
        view
        returns (uint256 normalizedPrice, uint256 timestamp, bool isStale, OracleStrategy strategy)
    {
        (normalizedPrice, timestamp) = getPrice(symbol);
        isStale = isPriceStale(symbol);
        strategy = oracleStrategy;
    }
}
