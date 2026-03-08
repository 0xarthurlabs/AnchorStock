// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockUSD
 * @author AnchorStock
 * @notice 模拟 USD 稳定币（6位精度，类似 USDC）/ Mock USD stablecoin (6 decimals, similar to USDC)
 * @dev 用于测试和开发 / For testing and development
 */
contract MockUSD is ERC20, Ownable {
    /// @notice 事件：代币铸造 / Event: Token minted
    event Minted(address indexed to, uint256 amount);

    /// @notice 检查失败：铸造目标地址为 0 / Check failed: mint to zero address
    event CheckFailedMintToZeroAddress(address to);
    /// @notice 检查失败：数组长度不匹配 / Check failed: arrays length mismatch
    event CheckFailedArraysLengthMismatch(uint256 lengthRecipients, uint256 lengthAmounts);

    /**
     * @notice 构造函数 / Constructor
     * @param _owner 合约所有者 / Contract owner
     */
    constructor(address _owner) ERC20("Mock USD", "mUSD") Ownable(_owner) {}

    /**
     * @notice 铸造代币（仅所有者）/ Mint tokens (owner only)
     * @param to 接收地址 / Recipient address
     * @param amount 铸造数量（6位精度）/ Amount to mint (6 decimals)
     */
    function mint(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) {
            emit CheckFailedMintToZeroAddress(to);
            require(false, "MockUSD: mint to zero address");
        }
        _mint(to, amount);
        emit Minted(to, amount);
    }

    /**
     * @notice 批量铸造代币 / Batch mint tokens
     * @param recipients 接收地址数组 / Array of recipient addresses
     * @param amounts 数量数组（6位精度）/ Array of amounts (6 decimals)
     */
    function batchMint(address[] memory recipients, uint256[] memory amounts) external onlyOwner {
        if (recipients.length != amounts.length) {
            emit CheckFailedArraysLengthMismatch(recipients.length, amounts.length);
            require(false, "MockUSD: arrays length mismatch");
        }
        
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i] == address(0)) {
                emit CheckFailedMintToZeroAddress(recipients[i]);
                require(false, "MockUSD: mint to zero address");
            }
            _mint(recipients[i], amounts[i]);
            emit Minted(recipients[i], amounts[i]);
        }
    }
}
