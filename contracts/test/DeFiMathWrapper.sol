// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeFiMath} from "../src/libraries/DeFiMath.sol";

/**
 * @title DeFiMathWrapper
 * @notice 包装 DeFiMath 库函数以便测试 / Wrapper for DeFiMath library functions for testing
 */
contract DeFiMathWrapper {
    using DeFiMath for uint256;

    function normalize(uint256 value, uint8 decimals) external pure returns (uint256) {
        return DeFiMath.normalize(value, decimals);
    }

    function normalizeUSDC(uint256 usdcAmount) external pure returns (uint256) {
        return DeFiMath.normalizeUSDC(usdcAmount);
    }

    function normalizeOraclePrice(uint256 price) external pure returns (uint256) {
        return DeFiMath.normalizeOraclePrice(price);
    }

    function normalizeRWA(uint256 rwaAmount) external pure returns (uint256) {
        return DeFiMath.normalizeRWA(rwaAmount);
    }

    function denormalize(uint256 normalized, uint8 targetDecimals) external pure returns (uint256) {
        return DeFiMath.denormalize(normalized, targetDecimals);
    }

    function denormalizeToUSDC(uint256 normalized) external pure returns (uint256) {
        return DeFiMath.denormalizeToUSDC(normalized);
    }

    function mul(uint256 a, uint256 b) external pure returns (uint256) {
        return DeFiMath.mul(a, b);
    }

    function div(uint256 a, uint256 b) external pure returns (uint256) {
        return DeFiMath.div(a, b);
    }
}
