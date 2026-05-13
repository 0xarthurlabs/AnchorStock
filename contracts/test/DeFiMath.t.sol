// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeFiMath} from "../src/libraries/DeFiMath.sol";
import {DeFiMathWrapper} from "./DeFiMathWrapper.sol";

/**
 * @title DeFiMathTest
 * @notice 测试 DeFiMath 库的精度归一化功能 / Test DeFiMath library precision normalization
 */
contract DeFiMathTest is Test {
    using DeFiMath for uint256;

    DeFiMathWrapper public wrapper;

    function setUp() public {
        wrapper = new DeFiMathWrapper();
    }

    /// @notice 测试 USDC 归一化 / Test USDC normalization
    function test_NormalizeUSDC() public pure {
        // 1 USDC (6 decimals) = 1 * 10^6
        uint256 usdcAmount = 1e6;
        uint256 normalized = DeFiMath.normalizeUSDC(usdcAmount);

        // 应该归一化为 1e18
        assertEq(normalized, 1e18, "1 USDC should normalize to 1e18");
    }

    /// @notice 测试 Oracle 价格归一化 / Test Oracle price normalization
    function test_NormalizeOraclePrice() public pure {
        // $150.50 (8 decimals) = 15050 * 10^6
        uint256 price = 15050 * 1e6; // 150.50 with 8 decimals
        uint256 normalized = DeFiMath.normalizeOraclePrice(price);

        // 应该归一化为 15050 * 10^16 (18 decimals)
        assertEq(normalized, 15050 * 1e16, "Oracle price normalization failed");
    }

    /// @notice 测试 RWA 归一化（应该保持不变）/ Test RWA normalization (should remain unchanged)
    function test_NormalizeRWA() public pure {
        uint256 rwaAmount = 1000 * 1e18;
        uint256 normalized = DeFiMath.normalizeRWA(rwaAmount);

        // RWA 已经是 18 位精度，应该保持不变
        assertEq(normalized, rwaAmount, "RWA should remain unchanged");
    }

    /// @notice 测试通用归一化函数 / Test generic normalize function
    function test_Normalize() public {
        // 测试 6 位精度
        uint256 value6 = 100 * 1e6;
        uint256 normalized6 = DeFiMath.normalize(value6, 6);
        assertEq(normalized6, 100 * 1e18, "6 decimals normalization failed");

        // 测试 8 位精度
        uint256 value8 = 200 * 1e8;
        uint256 normalized8 = DeFiMath.normalize(value8, 8);
        assertEq(normalized8, 200 * 1e18, "8 decimals normalization failed");

        // 测试 18 位精度（应该保持不变）
        uint256 value18 = 300 * 1e18;
        uint256 normalized18 = DeFiMath.normalize(value18, 18);
        assertEq(normalized18, value18, "18 decimals should remain unchanged");
    }

    /// @notice 测试归一化错误：精度超过 18 / Test normalization error: decimals exceed 18
    function test_Normalize_Exceeds18Decimals() public {
        uint256 value = 100;
        vm.expectRevert(bytes("DeFiMath: decimals cannot exceed 18"));
        wrapper.normalize(value, 19);
    }

    /// @notice 测试反归一化 / Test denormalization
    function test_Denormalize() public {
        uint256 normalized = 100 * 1e18;

        // 反归一化到 6 位精度
        uint256 denormalized6 = DeFiMath.denormalize(normalized, 6);
        assertEq(denormalized6, 100 * 1e6, "Denormalize to 6 decimals failed");

        // 反归一化到 8 位精度
        uint256 denormalized8 = DeFiMath.denormalize(normalized, 8);
        assertEq(denormalized8, 100 * 1e8, "Denormalize to 8 decimals failed");
    }

    /// @notice 测试反归一化到 USDC / Test denormalize to USDC
    function test_DenormalizeToUSDC() public {
        uint256 normalized = 500 * 1e18;
        uint256 usdcAmount = DeFiMath.denormalizeToUSDC(normalized);

        assertEq(usdcAmount, 500 * 1e6, "Denormalize to USDC failed");
    }

    /// @notice 测试安全乘法 / Test safe multiplication
    function test_Mul() public {
        uint256 a = 2 * 1e18; // 2.0 (normalized)
        uint256 b = 3 * 1e18; // 3.0 (normalized)
        uint256 result = DeFiMath.mul(a, b);

        // 2 * 3 = 6, 但需要保持 18 位精度
        assertEq(result, 6 * 1e18, "Safe multiplication failed");
    }

    /// @notice 测试安全除法 / Test safe division
    function test_Div() public {
        uint256 a = 6 * 1e18; // 6.0 (normalized)
        uint256 b = 2 * 1e18; // 2.0 (normalized)
        uint256 result = DeFiMath.div(a, b);

        // 6 / 2 = 3, 保持 18 位精度
        assertEq(result, 3 * 1e18, "Safe division failed");
    }

    /// @notice 测试除零错误 / Test division by zero
    function test_Div_ByZero() public {
        uint256 a = 100 * 1e18;
        uint256 b = 0;

        vm.expectRevert(bytes("DeFiMath: division by zero"));
        wrapper.div(a, b);
    }

    /// @notice 测试精度转换的往返 / Test round-trip precision conversion
    function test_RoundTrip() public {
        // 原始 USDC 数量
        uint256 originalUSDC = 1000 * 1e6;

        // 归一化
        uint256 normalized = DeFiMath.normalizeUSDC(originalUSDC);

        // 反归一化
        uint256 denormalized = DeFiMath.denormalizeToUSDC(normalized);

        // 应该得到原始值
        assertEq(denormalized, originalUSDC, "Round-trip conversion failed");
    }

    /// @notice 测试大数值的归一化 / Test normalization with large values
    function test_Normalize_LargeValues() public {
        // 1 million USDC
        uint256 largeUSDC = 1_000_000 * 1e6;
        uint256 normalized = DeFiMath.normalizeUSDC(largeUSDC);

        assertEq(normalized, 1_000_000 * 1e18, "Large value normalization failed");
    }

    /// @notice 测试小数精度 / Test decimal precision
    function test_Normalize_DecimalPrecision() public {
        // 0.5 USDC (6 decimals)
        uint256 halfUSDC = 500_000; // 0.5 * 1e6
        uint256 normalized = DeFiMath.normalizeUSDC(halfUSDC);

        // 应该归一化为 0.5 * 1e18
        assertEq(normalized, 5e17, "Decimal precision normalization failed");
    }
}
