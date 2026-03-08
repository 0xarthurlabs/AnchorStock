// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeFiMath} from "../src/libraries/DeFiMath.sol";
import {DeFiMathWrapper} from "./DeFiMathWrapper.sol";

/**
 * @title DeFiMathFuzzTest
 * @notice Fuzz 测试 DeFiMath 库，发现边界情况和潜在漏洞 / Fuzz test DeFiMath library to discover edge cases and potential vulnerabilities
 */
contract DeFiMathFuzzTest is Test {
    using DeFiMath for uint256;

    DeFiMathWrapper public wrapper;

    function setUp() public {
        wrapper = new DeFiMathWrapper();
    }

    /// @notice Fuzz 测试：USDC 归一化往返转换 / Fuzz test: USDC normalization round-trip
    /// @param usdcAmount USDC 数量（6位精度）/ USDC amount (6 decimals)
    function testFuzz_NormalizeUSDC_RoundTrip(uint256 usdcAmount) public {
        // 限制输入范围，避免溢出 / Limit input range to avoid overflow
        usdcAmount = bound(usdcAmount, 0, type(uint256).max / 1e12);
        
        uint256 normalized = wrapper.normalizeUSDC(usdcAmount);
        uint256 denormalized = wrapper.denormalizeToUSDC(normalized);
        
        // 往返转换后应该得到原始值（可能有精度损失，但应该在合理范围内）
        // Round-trip should return original value (may have precision loss, but within reasonable range)
        assertEq(denormalized, usdcAmount, "USDC round-trip conversion failed");
    }

    /// @notice Fuzz 测试：Oracle 价格归一化 / Fuzz test: Oracle price normalization
    /// @param price 价格（8位精度）/ Price (8 decimals)
    function testFuzz_NormalizeOraclePrice(uint256 price) public {
        // 限制输入范围，避免溢出 / Limit input range to avoid overflow
        price = bound(price, 1, type(uint256).max / 1e10);
        
        uint256 normalized = wrapper.normalizeOraclePrice(price);
        
        // 归一化后的值应该是 price * 10^10
        assertEq(normalized, price * 1e10, "Oracle price normalization failed");
    }

    /// @notice Fuzz 测试：通用归一化函数 / Fuzz test: Generic normalize function
    /// @param value 原始数值 / Raw value
    /// @param decimals 精度位数（0-18）/ Decimal places (0-18)
    function testFuzz_Normalize(uint256 value, uint8 decimals) public {
        // 限制精度范围 / Limit decimals range
        decimals = uint8(bound(uint256(decimals), 0, 18));
        
        // 限制输入值，避免溢出 / Limit input value to avoid overflow
        if (decimals < 18) {
            uint256 maxValue = type(uint256).max / (10 ** (18 - decimals));
            value = bound(value, 0, maxValue);
        }
        
        uint256 normalized = wrapper.normalize(value, decimals);
        
        if (decimals == 18) {
            // 如果已经是 18 位精度，应该保持不变
            assertEq(normalized, value, "18 decimals should remain unchanged");
        } else {
            // 归一化后的值应该是 value * 10^(18 - decimals)
            uint256 expected = value * (10 ** (18 - decimals));
            assertEq(normalized, expected, "Normalization calculation failed");
        }
    }

    /// @notice Fuzz 测试：安全乘法 / Fuzz test: Safe multiplication
    /// @param a 第一个数值（18位精度）/ First value (18 decimals)
    /// @param b 第二个数值（18位精度）/ Second value (18 decimals)
    function testFuzz_Mul(uint256 a, uint256 b) public {
        // 限制输入范围，避免溢出 / Limit input range to avoid overflow
        // 使用更保守的边界，确保 a * b 不会溢出
        uint256 maxValue = type(uint256).max / 1e18;
        a = bound(a, 0, maxValue);
        b = bound(b, 0, maxValue);
        
        // 进一步限制，确保 a * b 不会溢出
        if (a > 0 && b > type(uint256).max / a) {
            b = type(uint256).max / a;
        }
        
        uint256 result = wrapper.mul(a, b);
        
        // 结果应该是 (a * b) / 1e18
        uint256 expected = (a * b) / 1e18;
        assertEq(result, expected, "Safe multiplication failed");
    }

    /// @notice Fuzz 测试：安全除法 / Fuzz test: Safe division
    /// @param a 被除数（18位精度）/ Dividend (18 decimals)
    /// @param b 除数（18位精度，非零）/ Divisor (18 decimals, non-zero)
    function testFuzz_Div(uint256 a, uint256 b) public {
        // 确保除数不为零 / Ensure divisor is non-zero
        b = bound(b, 1, type(uint256).max);
        
        // 限制被除数，避免溢出 / Limit dividend to avoid overflow
        a = bound(a, 0, type(uint256).max / 1e18);
        
        uint256 result = wrapper.div(a, b);
        
        // 结果应该是 (a * 1e18) / b
        uint256 expected = (a * 1e18) / b;
        assertEq(result, expected, "Safe division failed");
    }

    /// @notice Fuzz 测试：除法不变量 / Fuzz test: Division invariant
    /// @param a 被除数 / Dividend
    /// @param b 除数（非零）/ Divisor (non-zero)
    function testFuzz_Div_Invariant(uint256 a, uint256 b) public {
        // 确保除数不为零 / Ensure divisor is non-zero
        b = bound(b, 1, type(uint256).max / 1e18);
        
        // 限制范围，避免溢出 / Limit range to avoid overflow
        a = bound(a, 0, type(uint256).max / 1e18);
        
        uint256 result = wrapper.div(a, b);
        
        // 不变量：result * b / 1e18 应该约等于 a（可能有精度损失）
        // Invariant: result * b / 1e18 should approximately equal a (may have precision loss)
        // 由于除法向下取整，reconstructed 可能小于 a，这是正常的
        uint256 reconstructed = wrapper.mul(result, b);
        
        // 由于除法向下取整，reconstructed 应该 <= a
        // 误差范围：由于 div 的实现是 (a * 1e18) / b，然后 mul 是 (result * b) / 1e18
        // 所以 reconstructed = ((a * 1e18) / b) * b / 1e18
        // 由于整数除法的向下取整，reconstructed <= a
        assertLe(reconstructed, a, "Division invariant failed: reconstructed should be <= a");
        
        // 计算理论上的最大误差（由于向下取整）
        // 最大误差是 b / 1e18（当 a * 1e18 不能被 b 整除时）
        uint256 maxError = b > 1e18 ? (b / 1e18) + 1 : 1;
        assertGe(reconstructed + maxError, a, "Division invariant failed: error too large");
    }

    /// @notice Fuzz 测试：归一化精度边界 / Fuzz test: Normalization precision boundaries
    /// @param value 原始数值 / Raw value
    function testFuzz_Normalize_PrecisionBoundaries(uint256 value) public {
        // 测试 6 位精度（USDC）
        value = bound(value, 0, type(uint256).max / 1e12);
        uint256 normalized6 = wrapper.normalize(value, 6);
        assertEq(normalized6, value * 1e12, "6 decimals normalization failed");
        
        // 测试 8 位精度（Oracle）
        value = bound(value, 0, type(uint256).max / 1e10);
        uint256 normalized8 = wrapper.normalize(value, 8);
        assertEq(normalized8, value * 1e10, "8 decimals normalization failed");
        
        // 测试 18 位精度（RWA）
        uint256 normalized18 = wrapper.normalize(value, 18);
        assertEq(normalized18, value, "18 decimals should remain unchanged");
    }

    /// @notice Fuzz 测试：反归一化精度边界 / Fuzz test: Denormalization precision boundaries
    /// @param normalized 归一化后的数值（18位精度）/ Normalized value (18 decimals)
    function testFuzz_Denormalize_PrecisionBoundaries(uint256 normalized) public {
        // 测试反归一化到 6 位精度
        uint256 denormalized6 = wrapper.denormalize(normalized, 6);
        assertEq(denormalized6, normalized / 1e12, "6 decimals denormalization failed");
        
        // 测试反归一化到 8 位精度
        uint256 denormalized8 = wrapper.denormalize(normalized, 8);
        assertEq(denormalized8, normalized / 1e10, "8 decimals denormalization failed");
        
        // 测试反归一化到 18 位精度（应该保持不变）
        uint256 denormalized18 = wrapper.denormalize(normalized, 18);
        assertEq(denormalized18, normalized, "18 decimals should remain unchanged");
    }

    /// @notice Fuzz 测试：乘除法结合 / Fuzz test: Multiplication and division combination
    /// @param a 第一个数值 / First value
    /// @param b 第二个数值 / Second value
    /// @param c 第三个数值（非零）/ Third value (non-zero)
    function testFuzz_MulDiv_Combination(uint256 a, uint256 b, uint256 c) public {
        // 限制范围，避免溢出 / Limit range to avoid overflow
        // 使用更保守的边界
        uint256 maxValue = type(uint256).max / 1e36; // 更保守的边界
        a = bound(a, 0, maxValue);
        b = bound(b, 0, maxValue);
        c = bound(c, 1, maxValue);
        
        // 确保 a * b 不会溢出
        if (a > 0 && b > type(uint256).max / a) {
            b = type(uint256).max / a;
        }
        
        // 计算 (a * b) / c
        uint256 mulResult = wrapper.mul(a, b);
        uint256 finalResult = wrapper.div(mulResult, c);
        
        // 应该等于 (a * b * 1e18) / (c * 1e18) = (a * b) / c
        // 但由于精度问题，我们验证结果在合理范围内
        uint256 expected = (a * b) / c;
        
        // 允许精度误差（由于中间计算）
        if (expected > 0) {
            uint256 diff = finalResult > expected ? finalResult - expected : expected - finalResult;
            // 允许更大的误差（由于两次精度转换）
            uint256 maxError = (c > 0) ? (1e18 / c) + 1 : 1;
            assertLe(diff, maxError, "MulDiv combination precision error too large");
        } else {
            assertEq(finalResult, 0, "Result should be 0 when expected is 0");
        }
    }
}
