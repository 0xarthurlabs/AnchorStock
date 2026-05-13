// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StockOracle} from "../src/StockOracle.sol";
import {MockPyth} from "../src/mocks/MockPyth.sol";
import {DeFiMath} from "../src/libraries/DeFiMath.sol";

/**
 * @title StockOracleTest
 * @notice 测试 StockOracle 合约的所有功能 / Test all StockOracle contract functions
 */
contract StockOracleTest is Test {
    using DeFiMath for uint256;

    StockOracle public oracle;
    MockPyth public mockPyth;
    address public owner;
    address public user;

    string constant SYMBOL_AAPL = "AAPL";
    string constant SYMBOL_NVDA = "NVDA";
    bytes32 constant PRICE_ID_AAPL = keccak256("AAPL");
    bytes32 constant PRICE_ID_NVDA = keccak256("NVDA");

    /// @notice 设置测试环境 / Setup test environment
    function setUp() public {
        owner = address(0x1);
        user = address(0x2);

        // 部署 Mock Pyth
        mockPyth = new MockPyth();

        // 部署 StockOracle
        vm.prank(owner);
        oracle = new StockOracle(address(mockPyth), owner);
    }

    /// @notice 测试构造函数 / Test constructor
    function test_Constructor() public {
        assertEq(address(oracle.pyth()), address(mockPyth), "Pyth address should be set");
        assertEq(oracle.owner(), owner, "Owner should be set");
        assertEq(
            uint256(oracle.oracleStrategy()),
            uint256(StockOracle.OracleStrategy.CUSTOM_RELAYER),
            "Default strategy should be CUSTOM_RELAYER"
        );
        assertEq(oracle.stalePriceThreshold(), 24 hours, "Default stale threshold should be 24 hours");
        assertTrue(oracle.circuitBreakerEnabled(), "Circuit breaker should be enabled by default");
    }

    /// @notice 测试更新价格（Custom Relayer）/ Test update price (Custom Relayer)
    function test_UpdatePrice() public {
        uint256 price = 15050 * 1e6; // $150.50 with 8 decimals

        vm.prank(owner);
        oracle.updatePrice(SYMBOL_AAPL, price);

        assertEq(oracle.stockPrices(SYMBOL_AAPL), price, "Price should be updated");
        assertEq(oracle.lastUpdatedAt(SYMBOL_AAPL), block.timestamp, "Timestamp should be updated");
    }

    /// @notice 测试非所有者无法更新价格 / Test non-owner cannot update price
    function test_UpdatePrice_OnlyOwner() public {
        uint256 price = 15050 * 1e6;

        vm.prank(user);
        vm.expectRevert();
        oracle.updatePrice(SYMBOL_AAPL, price);
    }

    /// @notice 测试更新价格为 0 应该失败 / Test updating price to 0 should fail
    function test_UpdatePrice_ZeroPrice() public {
        vm.prank(owner);
        vm.expectRevert(StockOracle.InvalidPrice.selector);
        oracle.updatePrice(SYMBOL_AAPL, 0);
    }

    /// @notice 测试批量更新价格 / Test batch update prices
    function test_UpdatePrices() public {
        string[] memory symbols = new string[](2);
        symbols[0] = SYMBOL_AAPL;
        symbols[1] = SYMBOL_NVDA;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 15050 * 1e6; // $150.50
        prices[1] = 50000 * 1e6; // $500.00

        vm.prank(owner);
        oracle.updatePrices(symbols, prices);

        assertEq(oracle.stockPrices(SYMBOL_AAPL), prices[0], "AAPL price should be updated");
        assertEq(oracle.stockPrices(SYMBOL_NVDA), prices[1], "NVDA price should be updated");
    }

    /// @notice 测试获取价格（Custom Relayer）/ Test get price (Custom Relayer)
    function test_GetPrice_CustomRelayer() public {
        uint256 rawPrice = 15050 * 1e6; // $150.50 with 8 decimals

        vm.prank(owner);
        oracle.updatePrice(SYMBOL_AAPL, rawPrice);

        (uint256 normalizedPrice, uint256 timestamp) = oracle.getPrice(SYMBOL_AAPL);

        // 应该归一化到 18 位精度
        uint256 expectedNormalized = DeFiMath.normalizeOraclePrice(rawPrice);
        assertEq(normalizedPrice, expectedNormalized, "Price should be normalized to 18 decimals");
        assertEq(timestamp, block.timestamp, "Timestamp should match");
    }

    /// @notice 测试获取未设置的价格应该失败 / Test getting unset price should fail
    function test_GetPrice_UnsetPrice() public {
        vm.expectRevert("StockOracle: price not set");
        oracle.getPrice(SYMBOL_AAPL);
    }

    /// @notice 测试切换到 Pyth 策略 / Test switch to Pyth strategy
    function test_SetOracleStrategy_Pyth() public {
        vm.prank(owner);
        oracle.setOracleStrategy(StockOracle.OracleStrategy.PYTH);

        assertEq(uint256(oracle.oracleStrategy()), uint256(StockOracle.OracleStrategy.PYTH), "Strategy should be PYTH");
    }

    /// @notice 测试使用 Pyth 获取价格 / Test get price using Pyth
    function test_GetPrice_Pyth() public {
        // 切换到 Pyth 策略
        vm.prank(owner);
        oracle.setOracleStrategy(StockOracle.OracleStrategy.PYTH);

        // 设置价格 ID
        vm.prank(owner);
        oracle.setStockPriceId(SYMBOL_AAPL, PRICE_ID_AAPL);

        // 在 Mock Pyth 中设置价格
        int64 pythPrice = 15050 * 1e6; // $150.50 with 8 decimals
        uint256 publishTime = block.timestamp;
        mockPyth.setPrice(PRICE_ID_AAPL, pythPrice, publishTime);

        // 获取价格
        (uint256 normalizedPrice, uint256 timestamp) = oracle.getPrice(SYMBOL_AAPL);

        uint256 expectedNormalized = DeFiMath.normalizeOraclePrice(uint256(uint64(pythPrice)));
        assertEq(normalizedPrice, expectedNormalized, "Pyth price should be normalized");
        assertEq(timestamp, publishTime, "Timestamp should match Pyth publish time");
    }

    /// @notice 测试价格过期检测 / Test price stale detection
    function test_IsPriceStale() public {
        uint256 price = 15050 * 1e6;

        // 更新价格
        vm.prank(owner);
        oracle.updatePrice(SYMBOL_AAPL, price);

        // 价格应该未过期
        assertFalse(oracle.isPriceStale(SYMBOL_AAPL), "Price should not be stale");

        // 时间前进 25 小时（超过 24 小时阈值）
        vm.warp(block.timestamp + 25 hours);

        // 价格应该过期
        assertTrue(oracle.isPriceStale(SYMBOL_AAPL), "Price should be stale after 25 hours");
    }

    /// @notice 测试未设置的价格应该被视为过期 / Test unset price should be considered stale
    function test_IsPriceStale_UnsetPrice() public {
        assertTrue(oracle.isPriceStale(SYMBOL_AAPL), "Unset price should be stale");
    }

    /// @notice 测试断路器模式 / Test circuit breaker mode
    function test_GetPriceWithStaleCheck_CircuitBreaker() public {
        uint256 price = 15050 * 1e6;

        // 更新价格
        vm.prank(owner);
        oracle.updatePrice(SYMBOL_AAPL, price);

        // 时间前进 25 小时
        vm.warp(block.timestamp + 25 hours);

        // 启用断路器时应该失败
        vm.expectRevert(abi.encodeWithSelector(StockOracle.PriceStale.selector, SYMBOL_AAPL));
        oracle.getPriceWithStaleCheck(SYMBOL_AAPL);
    }

    /// @notice 测试禁用断路器 / Test disable circuit breaker
    function test_GetPriceWithStaleCheck_DisabledBreaker() public {
        uint256 price = 15050 * 1e6;

        // 更新价格
        vm.prank(owner);
        oracle.updatePrice(SYMBOL_AAPL, price);

        // 禁用断路器
        vm.prank(owner);
        oracle.setCircuitBreaker(false);

        // 时间前进 25 小时
        vm.warp(block.timestamp + 25 hours);

        // 应该能够获取价格（即使过期）
        (uint256 normalizedPrice, uint256 timestamp, bool isStale) = oracle.getPriceWithStaleCheck(SYMBOL_AAPL);

        assertTrue(isStale, "Price should be stale");
        assertGt(normalizedPrice, 0, "Should return price even if stale");
    }

    /// @notice 测试设置价格过期阈值 / Test set stale price threshold
    function test_SetStalePriceThreshold() public {
        uint256 newThreshold = 48 hours;

        vm.prank(owner);
        oracle.setStalePriceThreshold(newThreshold);

        assertEq(oracle.stalePriceThreshold(), newThreshold, "Threshold should be updated");
    }

    /// @notice 测试获取价格信息 / Test get price info
    function test_GetPriceInfo() public {
        uint256 price = 15050 * 1e6;

        vm.prank(owner);
        oracle.updatePrice(SYMBOL_AAPL, price);

        (uint256 normalizedPrice, uint256 timestamp, bool isStale, StockOracle.OracleStrategy strategy) =
            oracle.getPriceInfo(SYMBOL_AAPL);

        assertGt(normalizedPrice, 0, "Normalized price should be greater than 0");
        assertEq(timestamp, block.timestamp, "Timestamp should match");
        assertFalse(isStale, "Price should not be stale");
        assertEq(
            uint256(strategy), uint256(StockOracle.OracleStrategy.CUSTOM_RELAYER), "Strategy should be CUSTOM_RELAYER"
        );
    }

    /// @notice 测试策略切换事件 / Test strategy switch event
    function test_SetOracleStrategy_Event() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit StockOracle.OracleStrategySwitched(
            StockOracle.OracleStrategy.CUSTOM_RELAYER, StockOracle.OracleStrategy.PYTH
        );
        oracle.setOracleStrategy(StockOracle.OracleStrategy.PYTH);
    }

    /// @notice 测试价格更新事件 / Test price update event
    function test_UpdatePrice_Event() public {
        uint256 price = 15050 * 1e6;

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit StockOracle.PriceUpdated(SYMBOL_AAPL, price, block.timestamp, StockOracle.OracleStrategy.CUSTOM_RELAYER);
        oracle.updatePrice(SYMBOL_AAPL, price);
    }

    /// @notice 测试 Pyth 价格未设置的情况 / Test Pyth price not set
    function test_GetPrice_Pyth_PriceNotSet() public {
        vm.prank(owner);
        oracle.setOracleStrategy(StockOracle.OracleStrategy.PYTH);

        vm.prank(owner);
        oracle.setStockPriceId(SYMBOL_AAPL, PRICE_ID_AAPL);

        // Pyth 中未设置价格
        vm.expectRevert("StockOracle: invalid Pyth price");
        oracle.getPrice(SYMBOL_AAPL);
    }

    /// @notice 测试 Pyth 价格 ID 未设置 / Test Pyth price ID not set
    function test_GetPrice_Pyth_PriceIdNotSet() public {
        vm.prank(owner);
        oracle.setOracleStrategy(StockOracle.OracleStrategy.PYTH);

        // 未设置价格 ID
        vm.expectRevert("StockOracle: price ID not set");
        oracle.getPrice(SYMBOL_AAPL);
    }
}
