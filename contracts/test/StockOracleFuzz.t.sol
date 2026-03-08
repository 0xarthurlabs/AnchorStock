// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StockOracle} from "../src/StockOracle.sol";
import {MockPyth} from "../src/mocks/MockPyth.sol";
import {DeFiMath} from "../src/libraries/DeFiMath.sol";

/**
 * @title StockOracleFuzzTest
 * @notice Fuzz 测试 StockOracle 合约，发现边界情况和潜在漏洞 / Fuzz test StockOracle contract to discover edge cases and potential vulnerabilities
 */
contract StockOracleFuzzTest is Test {
    using DeFiMath for uint256;

    StockOracle public oracle;
    MockPyth public mockPyth;
    address public owner;

    /// @notice 设置测试环境 / Setup test environment
    function setUp() public {
        owner = address(0x1);
        
        // 部署 Mock Pyth
        mockPyth = new MockPyth();
        
        // 部署 StockOracle
        vm.prank(owner);
        oracle = new StockOracle(address(mockPyth), owner);
    }

    /// @notice Fuzz 测试：价格更新和获取 / Fuzz test: Price update and retrieval
    /// @param symbol 股票符号 / Stock symbol
    /// @param price 价格（8位精度，非零）/ Price (8 decimals, non-zero)
    function testFuzz_UpdateAndGetPrice(string memory symbol, uint256 price) public {
        // 确保价格非零，并限制范围避免溢出 / Ensure price is non-zero and limit range to avoid overflow
        price = bound(price, 1, type(uint256).max / 1e10);
        
        vm.prank(owner);
        oracle.updatePrice(symbol, price);
        
        (uint256 normalizedPrice, uint256 timestamp) = oracle.getPrice(symbol);
        
        // 验证价格已归一化 / Verify price is normalized
        uint256 expectedNormalized = DeFiMath.normalizeOraclePrice(price);
        assertEq(normalizedPrice, expectedNormalized, "Price normalization failed");
        
        // 验证时间戳 / Verify timestamp
        assertEq(timestamp, block.timestamp, "Timestamp should match");
        assertEq(oracle.lastUpdatedAt(symbol), block.timestamp, "Last updated timestamp should match");
    }

    /// @notice Fuzz 测试：价格过期检测 / Fuzz test: Price stale detection
    /// @param symbol 股票符号 / Stock symbol
    /// @param price 价格 / Price
    /// @param timeElapsed 经过的时间（秒）/ Time elapsed (seconds)
    function testFuzz_IsPriceStale(string memory symbol, uint256 price, uint256 timeElapsed) public {
        // 确保价格非零 / Ensure price is non-zero
        price = bound(price, 1, type(uint256).max);
        
        // 更新价格
        vm.prank(owner);
        oracle.updatePrice(symbol, price);
        
        // 时间前进
        timeElapsed = bound(timeElapsed, 0, 365 days); // 限制在一年内
        vm.warp(block.timestamp + timeElapsed);
        
        bool isStale = oracle.isPriceStale(symbol);
        uint256 threshold = oracle.stalePriceThreshold();
        
        // 验证过期逻辑 / Verify stale logic
        if (timeElapsed > threshold) {
            assertTrue(isStale, "Price should be stale after threshold");
        } else {
            assertFalse(isStale, "Price should not be stale before threshold");
        }
    }

    /// @notice Fuzz 测试：批量更新价格 / Fuzz test: Batch update prices
    /// @param count 价格数量 / Number of prices
    function testFuzz_UpdatePrices(uint8 count) public {
        // 限制数组大小，避免 gas 过高 / Limit array size to avoid high gas
        count = uint8(bound(uint256(count), 1, 10));
        
        string[] memory symbols = new string[](count);
        uint256[] memory prices = new uint256[](count);
        
        // 生成随机符号和价格 / Generate random symbols and prices
        for (uint8 i = 0; i < count; i++) {
            symbols[i] = string(abi.encodePacked("STOCK", vm.toString(i)));
            prices[i] = bound(uint256(keccak256(abi.encodePacked(i))), 1, type(uint256).max);
        }
        
        vm.prank(owner);
        oracle.updatePrices(symbols, prices);
        
        // 验证所有价格都已更新 / Verify all prices are updated
        for (uint8 i = 0; i < count; i++) {
            assertEq(oracle.stockPrices(symbols[i]), prices[i], "Price should be updated");
            assertEq(oracle.lastUpdatedAt(symbols[i]), block.timestamp, "Timestamp should be updated");
        }
    }

    /// @notice Fuzz 测试：价格过期阈值设置 / Fuzz test: Stale price threshold setting
    /// @param threshold 新的阈值（秒）/ New threshold (seconds)
    function testFuzz_SetStalePriceThreshold(uint256 threshold) public {
        // 限制阈值范围（1 秒到 1 年）/ Limit threshold range (1 second to 1 year)
        threshold = bound(threshold, 1 seconds, 365 days);
        
        uint256 oldThreshold = oracle.stalePriceThreshold();
        
        vm.prank(owner);
        oracle.setStalePriceThreshold(threshold);
        
        assertEq(oracle.stalePriceThreshold(), threshold, "Threshold should be updated");
        // 只有当新阈值与旧阈值不同时才检查 / Only check if new threshold differs from old
        if (threshold != oldThreshold) {
            assertNotEq(oracle.stalePriceThreshold(), oldThreshold, "Threshold should have changed");
        }
    }

    /// @notice Fuzz 测试：断路器模式 / Fuzz test: Circuit breaker mode
    /// @param symbol 股票符号 / Stock symbol
    /// @param price 价格 / Price
    /// @param enabled 是否启用断路器 / Whether to enable circuit breaker
    function testFuzz_CircuitBreaker(string memory symbol, uint256 price, bool enabled) public {
        // 确保价格非零，并限制范围避免溢出 / Ensure price is non-zero and limit range to avoid overflow
        price = bound(price, 1, type(uint256).max / 1e10);
        
        // 更新价格
        vm.prank(owner);
        oracle.updatePrice(symbol, price);
        
        // 设置断路器
        vm.prank(owner);
        oracle.setCircuitBreaker(enabled);
        
        // 时间前进超过阈值
        uint256 threshold = oracle.stalePriceThreshold();
        vm.warp(block.timestamp + threshold + 1);
        
        if (enabled) {
            // 启用断路器时应该失败
            vm.expectRevert(abi.encodeWithSelector(StockOracle.PriceStale.selector, symbol));
            oracle.getPriceWithStaleCheck(symbol);
        } else {
            // 禁用断路器时应该成功
            (uint256 normalizedPrice,, bool isStale) = oracle.getPriceWithStaleCheck(symbol);
            assertTrue(isStale, "Price should be stale");
            assertGt(normalizedPrice, 0, "Should return price even if stale");
        }
    }

    /// @notice Fuzz 测试：策略切换 / Fuzz test: Strategy switching
    /// @param usePyth 是否使用 Pyth / Whether to use Pyth
    function testFuzz_SwitchStrategy(bool usePyth) public {
        StockOracle.OracleStrategy strategy = usePyth 
            ? StockOracle.OracleStrategy.PYTH 
            : StockOracle.OracleStrategy.CUSTOM_RELAYER;
        
        vm.prank(owner);
        oracle.setOracleStrategy(strategy);
        
        assertEq(uint256(oracle.oracleStrategy()), uint256(strategy), "Strategy should be updated");
    }

    /// @notice Fuzz 测试：Pyth 价格获取 / Fuzz test: Pyth price retrieval
    /// @param symbol 股票符号 / Stock symbol
    /// @param price 价格（8位精度）/ Price (8 decimals)
    /// @param publishTime 发布时间戳 / Publish timestamp
    function testFuzz_GetPrice_Pyth(
        string memory symbol,
        uint256 price,
        uint256 publishTime
    ) public {
        // 确保价格非零且在 int64 范围内（Pyth 价格必须是正数）
        // Ensure price is non-zero and within int64 range (Pyth price must be positive)
        // int64 的最大值是 9223372036854775807，但我们需要确保转换为 int64 后仍为正数
        price = bound(price, 1, uint256(uint64(type(int64).max)));
        
        // 切换到 Pyth 策略
        vm.prank(owner);
        oracle.setOracleStrategy(StockOracle.OracleStrategy.PYTH);
        
        // 设置价格 ID
        bytes32 priceId = keccak256(bytes(symbol));
        vm.prank(owner);
        oracle.setStockPriceId(symbol, priceId);
        
        // 在 Mock Pyth 中设置价格（确保为正数）
        int64 pythPrice = int64(uint64(price));
        // 确保转换后仍为正数
        if (pythPrice <= 0) {
            pythPrice = 1;
            price = 1;
        }
        publishTime = bound(publishTime, 0, block.timestamp + 365 days);
        mockPyth.setPrice(priceId, pythPrice, publishTime);
        
        // 获取价格
        (uint256 normalizedPrice, uint256 timestamp) = oracle.getPrice(symbol);
        
        // 验证价格已归一化 / Verify price is normalized
        uint256 expectedNormalized = DeFiMath.normalizeOraclePrice(price);
        assertEq(normalizedPrice, expectedNormalized, "Pyth price normalization failed");
        assertEq(timestamp, publishTime, "Timestamp should match Pyth publish time");
    }

    /// @notice Fuzz 测试：价格信息获取 / Fuzz test: Get price info
    /// @param symbol 股票符号 / Stock symbol
    /// @param price 价格 / Price
    function testFuzz_GetPriceInfo(string memory symbol, uint256 price) public {
        // 确保价格非零，并限制范围避免溢出 / Ensure price is non-zero and limit range to avoid overflow
        price = bound(price, 1, type(uint256).max / 1e10);
        
        vm.prank(owner);
        oracle.updatePrice(symbol, price);
        
        (uint256 normalizedPrice, uint256 timestamp, bool isStale, StockOracle.OracleStrategy strategy) = 
            oracle.getPriceInfo(symbol);
        
        // 验证返回值 / Verify return values
        assertGt(normalizedPrice, 0, "Normalized price should be greater than 0");
        assertEq(timestamp, block.timestamp, "Timestamp should match");
        assertFalse(isStale, "Price should not be stale immediately after update");
        assertEq(uint256(strategy), uint256(StockOracle.OracleStrategy.CUSTOM_RELAYER), "Strategy should be CUSTOM_RELAYER");
    }

    /// @notice Fuzz 测试：多次价格更新 / Fuzz test: Multiple price updates
    /// @param symbol 股票符号 / Stock symbol
    /// @param updates 更新次数 / Number of updates
    function testFuzz_MultiplePriceUpdates(string memory symbol, uint8 updates) public {
        // 限制更新次数 / Limit number of updates
        updates = uint8(bound(uint256(updates), 1, 20));
        
        for (uint8 i = 0; i < updates; i++) {
            uint256 price = bound(uint256(keccak256(abi.encodePacked(i, symbol))), 1, type(uint256).max);
            
            vm.prank(owner);
            oracle.updatePrice(symbol, price);
            
            // 验证价格已更新 / Verify price is updated
            assertEq(oracle.stockPrices(symbol), price, "Price should be updated");
            
            // 时间前进 1 小时
            vm.warp(block.timestamp + 1 hours);
        }
        
        // 最后一次更新的价格应该是最新的
        uint256 finalPrice = oracle.stockPrices(symbol);
        assertGt(finalPrice, 0, "Final price should be set");
    }

    /// @notice Fuzz 测试：价格归一化一致性 / Fuzz test: Price normalization consistency
    /// @param price1 第一个价格 / First price
    /// @param price2 第二个价格 / Second price
    function testFuzz_PriceNormalizationConsistency(uint256 price1, uint256 price2) public {
        // 确保价格非零，并限制范围避免溢出 / Ensure prices are non-zero and limit range to avoid overflow
        price1 = bound(price1, 1, type(uint256).max / 1e10);
        price2 = bound(price2, 1, type(uint256).max / 1e10);
        
        // 更新两个不同的符号
        vm.prank(owner);
        oracle.updatePrice("SYMBOL1", price1);
        
        vm.prank(owner);
        oracle.updatePrice("SYMBOL2", price2);
        
        // 获取归一化后的价格
        (uint256 normalized1,) = oracle.getPrice("SYMBOL1");
        (uint256 normalized2,) = oracle.getPrice("SYMBOL2");
        
        // 验证归一化一致性 / Verify normalization consistency
        uint256 expected1 = DeFiMath.normalizeOraclePrice(price1);
        uint256 expected2 = DeFiMath.normalizeOraclePrice(price2);
        
        assertEq(normalized1, expected1, "First price normalization failed");
        assertEq(normalized2, expected2, "Second price normalization failed");
        
        // 如果原始价格相同，归一化后的价格也应该相同
        if (price1 == price2) {
            assertEq(normalized1, normalized2, "Same prices should normalize to same value");
        }
    }
}
