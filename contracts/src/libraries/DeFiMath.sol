// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DeFiMath
 * @author AnchorStock
 * @notice 精度归一化工具库 / Precision Normalization Utility Library
 * @dev 将所有不同精度的数值归一化到 1e18 基准 / Normalize all values with different decimals to 1e18 base
 * 
 * 支持的精度类型 / Supported Decimal Types:
 * - USDC: 6 decimals
 * - RWA: 18 decimals
 * - Oracle Price: 8 decimals
 * 
 * 归一化公式 / Normalization Formula:
 * normalized_value = raw_value * 10^(18 - decimals)
 */
library DeFiMath {
    /// @dev 精度基准常量 / Precision base constant (1e18)
    uint256 public constant PRECISION_BASE = 1e18;
    
    /// @dev USDC 精度 / USDC decimals
    uint8 public constant USDC_DECIMALS = 6;
    
    /// @dev Oracle 价格精度 / Oracle price decimals
    uint8 public constant ORACLE_DECIMALS = 8;
    
    /// @dev RWA 精度 / RWA decimals (already 18, no conversion needed)
    uint8 public constant RWA_DECIMALS = 18;

    /**
     * @notice 将任意精度的数值归一化到 18 位 / Normalize value with arbitrary decimals to 18 decimals
     * @param value 原始数值 / Raw value
     * @param decimals 原始精度位数 / Original decimal places
     * @return normalized 归一化后的数值（18位精度）/ Normalized value (18 decimals)
     */
    function normalize(uint256 value, uint8 decimals) internal pure returns (uint256 normalized) {
        if (decimals == 18) {
            return value; // Already normalized / 已经是 18 位精度
        }
        
        if (decimals > 18) {
            // 如果精度大于 18，需要向下缩放 / If decimals > 18, scale down
            revert("DeFiMath: decimals cannot exceed 18");
        }
        
        // 计算缩放因子 / Calculate scaling factor: 10^(18 - decimals)
        uint256 scaleFactor = 10 ** (18 - decimals);
        normalized = value * scaleFactor;
    }

    /**
     * @notice 将 USDC (6位) 归一化到 18 位 / Normalize USDC (6 decimals) to 18 decimals
     * @param usdcAmount USDC 数量 / USDC amount
     * @return normalized 归一化后的数值 / Normalized value
     */
    function normalizeUSDC(uint256 usdcAmount) internal pure returns (uint256 normalized) {
        return normalize(usdcAmount, USDC_DECIMALS);
    }

    /**
     * @notice 将 Oracle 价格 (8位) 归一化到 18 位 / Normalize Oracle price (8 decimals) to 18 decimals
     * @param price 价格数值 / Price value
     * @return normalized 归一化后的价格 / Normalized price
     */
    function normalizeOraclePrice(uint256 price) internal pure returns (uint256 normalized) {
        return normalize(price, ORACLE_DECIMALS);
    }

    /**
     * @notice 将 RWA (18位) 直接返回，无需转换 / Return RWA as-is (already 18 decimals)
     * @param rwaAmount RWA 数量 / RWA amount
     * @return normalized 归一化后的数值（即原值）/ Normalized value (same as input)
     */
    function normalizeRWA(uint256 rwaAmount) internal pure returns (uint256 normalized) {
        return rwaAmount; // Already 18 decimals / 已经是 18 位精度
    }

    /**
     * @notice 将归一化后的 18 位数值还原到指定精度 / Denormalize 18-decimal value back to specified decimals
     * @param normalized 归一化后的数值（18位）/ Normalized value (18 decimals)
     * @param targetDecimals 目标精度位数 / Target decimal places
     * @return denormalized 还原后的数值 / Denormalized value
     */
    function denormalize(uint256 normalized, uint8 targetDecimals) internal pure returns (uint256 denormalized) {
        if (targetDecimals == 18) {
            return normalized; // Already in target format / 已经是目标精度
        }
        
        if (targetDecimals > 18) {
            revert("DeFiMath: target decimals cannot exceed 18");
        }
        
        // 计算缩放因子 / Calculate scaling factor: 10^(18 - targetDecimals)
        uint256 scaleFactor = 10 ** (18 - targetDecimals);
        denormalized = normalized / scaleFactor;
    }

    /**
     * @notice 将归一化后的数值还原为 USDC (6位) / Denormalize to USDC (6 decimals)
     * @param normalized 归一化后的数值 / Normalized value
     * @return usdcAmount USDC 数量 / USDC amount
     */
    function denormalizeToUSDC(uint256 normalized) internal pure returns (uint256 usdcAmount) {
        return denormalize(normalized, USDC_DECIMALS);
    }

    /**
     * @notice 安全乘法：两个归一化后的 18 位数值相乘，结果仍为 18 位 / Safe multiplication of two normalized values
     * @param a 第一个归一化数值 / First normalized value
     * @param b 第二个归一化数值 / Second normalized value
     * @return result 乘积结果（18位精度）/ Product result (18 decimals)
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256 result) {
        // 由于两个数都是 18 位精度，相乘后需要除以 1e18 以保持 18 位精度
        // Since both values are 18 decimals, divide by 1e18 to maintain 18 decimals
        return (a * b) / PRECISION_BASE;
    }

    /**
     * @notice 安全除法：两个归一化后的 18 位数值相除，结果仍为 18 位 / Safe division of two normalized values
     * @param a 被除数（归一化） / Dividend (normalized)
     * @param b 除数（归一化） / Divisor (normalized)
     * @return result 商（18位精度）/ Quotient (18 decimals)
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256 result) {
        require(b > 0, "DeFiMath: division by zero");
        // 先乘以 1e18 再除以 b，以保持 18 位精度
        // Multiply by 1e18 first, then divide by b to maintain 18 decimals
        return (a * PRECISION_BASE) / b;
    }
}
