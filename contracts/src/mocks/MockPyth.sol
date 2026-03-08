// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPyth} from "../interfaces/IPyth.sol";

/**
 * @title MockPyth
 * @author AnchorStock
 * @notice Mock Pyth Network 合约用于测试 / Mock Pyth Network contract for testing
 * @dev 实现 IPyth 接口，可设置价格与发布时间 / Implements IPyth, allows setting price and publish time
 */
contract MockPyth is IPyth {
    /// @notice 价格 ID 到价格的映射 / Mapping from price ID to price
    mapping(bytes32 => int64) public prices;
    
    /// @notice 价格 ID 到发布时间戳的映射 / Mapping from price ID to publish timestamp
    mapping(bytes32 => uint256) public publishTimes;

    /**
     * @notice 设置价格（用于测试）/ Set price (for testing)
     * @param priceId 价格 ID / Price ID
     * @param price 价格（8位精度）/ Price (8 decimals)
     * @param publishTime 发布时间戳 / Publish timestamp
     */
    function setPrice(bytes32 priceId, int64 price, uint256 publishTime) external {
        prices[priceId] = price;
        publishTimes[priceId] = publishTime;
    }

    /**
     * @notice 获取最新价格 / Get latest price
     * @param priceId 价格 ID / Price ID
     * @return price 价格（8位精度）/ Price (8 decimals)
     * @return publishTime 发布时间戳 / Publish timestamp
     */
    function getPrice(bytes32 priceId) external view override returns (int64 price, uint256 publishTime) {
        price = prices[priceId];
        publishTime = publishTimes[priceId];
    }
}
