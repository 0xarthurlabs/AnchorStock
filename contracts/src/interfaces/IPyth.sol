// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPyth
 * @author AnchorStock
 * @notice Pyth Network Oracle 接口 / Pyth Network Oracle Interface
 * @dev 简化版 Pyth 接口，用于价格查询 / Simplified Pyth interface for price queries
 */
interface IPyth {
    /**
     * @notice 获取最新价格 / Get latest price
     * @param priceId 价格 ID / Price ID
     * @return price 价格（8位精度）/ Price (8 decimals)
     * @return publishTime 发布时间戳 / Publish timestamp
     */
    function getPrice(bytes32 priceId) external view returns (int64 price, uint256 publishTime);
}
