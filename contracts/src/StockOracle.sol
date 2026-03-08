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
        PYTH,        // 使用 Pyth Network (Pull 模型) / Use Pyth Network (Pull model)
        CUSTOM_RELAYER // 使用自定义中继器 (Push 模型) / Use custom relayer (Push model)
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

    /// @notice 检查失败事件：无效的 owner / Check failed: invalid owner
    event CheckFailedInvalidOwner(address value);
    /// @notice 检查失败事件：价格未设置或为 0 / Check failed: price not set or zero
    event CheckFailedPriceNotSet(string symbol, uint256 value);
    /// @notice 检查失败事件：数组长度不匹配 / Check failed: arrays length mismatch
    event CheckFailedArraysLengthMismatch(uint256 lengthSymbols, uint256 lengthPrices);
    /// @notice 检查失败事件：价格 ID 未设置 / Check failed: price ID not set
    event CheckFailedPriceIdNotSet(string symbol);
    /// @notice 检查失败事件：Pyth 价格无效 / Check failed: invalid Pyth price
    event CheckFailedInvalidPythPrice(bytes32 priceId, int64 price);
    /// @notice 检查失败事件：价格过期（断路器）/ Check failed: price stale (circuit breaker)
    event CheckFailedPriceStale(string symbol, uint256 timestamp, uint256 threshold);

    /**
     * @notice 构造函数 / Constructor
     * @param _pyth Pyth Network 合约地址 / Pyth Network contract address
     * @param _owner 合约所有者地址（使用 OpenZeppelin Ownable）/ Contract owner address (using OpenZeppelin Ownable)
     */
    constructor(address _pyth, address _owner) Ownable(_owner) {
        if (_owner == address(0)) {
            emit CheckFailedInvalidOwner(_owner);
            require(false, "StockOracle: invalid owner");
        }
        pyth = IPyth(_pyth);
        oracleStrategy = OracleStrategy.CUSTOM_RELAYER; // 默认使用 Custom Relayer / Default to Custom Relayer
    }

    /**
     * @notice 设置股票符号的 Pyth 价格 ID / Set Pyth price ID for stock symbol
     * @param symbol 股票符号（如 "AAPL"）/ Stock symbol (e.g., "AAPL")
     * @param priceId Pyth 价格 ID / Pyth price ID
     */
    function setStockPriceId(string memory symbol, bytes32 priceId) external onlyOwner {
        stockPriceIds[symbol] = priceId;
    }

    /**
     * @notice 切换 Oracle 策略 / Switch oracle strategy
     * @param _strategy 新的策略 / New strategy
     */
    function setOracleStrategy(OracleStrategy _strategy) external onlyOwner {
        OracleStrategy oldStrategy = oracleStrategy;
        oracleStrategy = _strategy;
        emit OracleStrategySwitched(oldStrategy, _strategy);
    }

    /**
     * @notice 设置价格过期阈值 / Set stale price threshold
     * @param _threshold 新的阈值（秒）/ New threshold (seconds)
     */
    function setStalePriceThreshold(uint256 _threshold) external onlyOwner {
        uint256 oldThreshold = stalePriceThreshold;
        stalePriceThreshold = _threshold;
        emit StalePriceThresholdUpdated(oldThreshold, _threshold);
    }

    /**
     * @notice 设置断路器模式 / Set circuit breaker mode
     * @param _enabled 是否启用 / Whether to enable
     */
    function setCircuitBreaker(bool _enabled) external onlyOwner {
        circuitBreakerEnabled = _enabled;
    }

    /**
     * @notice 更新价格（Custom Relayer 策略使用）/ Update price (for Custom Relayer strategy)
     * @param symbol 股票符号 / Stock symbol
     * @param price 价格（8位精度）/ Price (8 decimals)
     */
    function updatePrice(string memory symbol, uint256 price) external onlyOwner {
        if (price == 0) {
            emit CheckFailedPriceNotSet(symbol, price);
            revert InvalidPrice();
        }
        
        // 保存原始价格（8位精度）/ Save raw price (8 decimals)
        stockPrices[symbol] = price;
        lastUpdatedAt[symbol] = block.timestamp;

        emit PriceUpdated(symbol, price, block.timestamp, OracleStrategy.CUSTOM_RELAYER);
    }

    /**
     * @notice 批量更新价格 / Batch update prices
     * @param symbols 股票符号数组 / Array of stock symbols
     * @param prices 价格数组（8位精度）/ Array of prices (8 decimals)
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
     * @param symbol 股票符号 / Stock symbol
     * @return normalizedPrice 归一化后的价格（18位精度）/ Normalized price (18 decimals)
     * @return timestamp 最后更新时间戳 / Last update timestamp
     */
    function getPrice(string memory symbol) public view returns (uint256 normalizedPrice, uint256 timestamp) {
        uint256 rawPrice;
        
        if (oracleStrategy == OracleStrategy.PYTH) {
            // 从 Pyth Network 拉取价格 / Pull price from Pyth Network
            bytes32 priceId = stockPriceIds[symbol];
            if (priceId == bytes32(0)) {
                require(false, "StockOracle: price ID not set");
            }
            
            (int64 pythPrice, uint256 publishTime) = pyth.getPrice(priceId);
            if (pythPrice <= 0) {
                require(false, "StockOracle: invalid Pyth price");
            }
            
            // Safe cast: Pyth prices are always positive for stocks / 安全转换：股票价格在 Pyth 中始终为正
            // forge-lint: disable-next-line(unsafe-typecast)
            rawPrice = uint256(uint64(pythPrice));
            timestamp = publishTime;
        } else {
            // 从 Custom Relayer 获取价格 / Get price from Custom Relayer
            rawPrice = stockPrices[symbol];
            if (rawPrice == 0) {
                require(false, "StockOracle: price not set");
            }
            timestamp = lastUpdatedAt[symbol];
        }

        // 归一化价格：从 8 位精度转换为 18 位精度 / Normalize price: convert from 8 decimals to 18 decimals
        normalizedPrice = DeFiMath.normalizeOraclePrice(rawPrice);
    }

    /**
     * @notice 检查价格是否过期 / Check if price is stale
     * @param symbol 股票符号 / Stock symbol
     * @return isStale 是否过期 / Whether price is stale
     */
    function isPriceStale(string memory symbol) public view returns (bool isStale) {
        uint256 lastUpdate = lastUpdatedAt[symbol];
        if (lastUpdate == 0) return true; // 从未更新过 / Never updated
        
        // 如果使用 Pyth，需要从 Pyth 获取时间戳 / If using Pyth, get timestamp from Pyth
        if (oracleStrategy == OracleStrategy.PYTH) {
            bytes32 priceId = stockPriceIds[symbol];
            if (priceId == bytes32(0)) return true;
            
            (, uint256 publishTime) = pyth.getPrice(priceId);
            lastUpdate = publishTime;
        }
        
        // 检查是否超过阈值 / Check if exceeds threshold
        isStale = (block.timestamp - lastUpdate) > stalePriceThreshold;
    }

    /**
     * @notice 获取价格并检查是否过期（带断路器检查）/ Get price with stale check (with circuit breaker)
     * @param symbol 股票符号 / Stock symbol
     * @return normalizedPrice 归一化后的价格（18位精度）/ Normalized price (18 decimals)
     * @return timestamp 最后更新时间戳 / Last update timestamp
     * @return isStale 是否过期 / Whether price is stale
     */
    function getPriceWithStaleCheck(string memory symbol) 
        external 
        view 
        returns (uint256 normalizedPrice, uint256 timestamp, bool isStale) 
    {
        (normalizedPrice, timestamp) = getPrice(symbol);
        isStale = isPriceStale(symbol);
        
        // 如果启用断路器且价格过期，抛出错误 / If circuit breaker enabled and price stale, revert
        if (circuitBreakerEnabled && isStale) {
            revert PriceStale(symbol);
        }
    }

    /**
     * @notice 获取价格信息（包含策略和状态）/ Get price info (including strategy and status)
     * @param symbol 股票符号 / Stock symbol
     * @return normalizedPrice 归一化后的价格（18位精度）/ Normalized price (18 decimals)
     * @return timestamp 最后更新时间戳 / Last update timestamp
     * @return isStale 是否过期 / Whether price is stale
     * @return strategy 当前使用的策略 / Current strategy
     */
    function getPriceInfo(string memory symbol)
        external
        view
        returns (
            uint256 normalizedPrice,
            uint256 timestamp,
            bool isStale,
            OracleStrategy strategy
        )
    {
        (normalizedPrice, timestamp) = getPrice(symbol);
        isStale = isPriceStale(symbol);
        strategy = oracleStrategy;
    }
}
