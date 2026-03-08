// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title aToken
 * @author AnchorStock
 * @notice 存款凭证代币，代表用户在借贷池中的存款 / Deposit receipt token representing user deposits in lending pool
 * @dev 使用 ERC20 标准，18 位精度 / Uses ERC20 standard with 18 decimals
 * 
 * 当用户存入 RWA 到 LendingPool 时，会收到对应数量的 aToken 作为凭证
 * When users deposit RWA to LendingPool, they receive corresponding aToken as receipt
 * 
 * 示例：aNVDA 代表存入的 NVDA RWA 凭证 / Example: aNVDA represents deposited NVDA RWA receipt
 */
contract aToken is ERC20, Ownable {
    /// @notice 对应的底层资产地址 / Address of underlying asset
    address public underlyingAsset;

    /// @notice 事件：代币铸造 / Event: Token minted
    event Minted(address indexed to, uint256 amount);

    /// @notice 事件：代币销毁 / Event: Token burned
    event Burned(address indexed from, uint256 amount);

    /// @notice 检查失败：无效的底层资产地址 / Check failed: invalid underlying asset
    event CheckFailedInvalidUnderlyingAsset(address value);
    /// @notice 检查失败：铸造目标地址为 0 / Check failed: mint to zero address
    event CheckFailedMintToZeroAddress(address to);

    /**
     * @notice 构造函数 / Constructor
     * @param _name 代币名称（如 "Anchor NVDA"）/ Token name (e.g., "Anchor NVDA")
     * @param _symbol 代币符号（如 "aNVDA"）/ Token symbol (e.g., "aNVDA")
     * @param _underlyingAsset 底层资产地址 / Underlying asset address
     * @param _owner 合约所有者（通常是 LendingPool）/ Contract owner (usually LendingPool)
     */
    constructor(
        string memory _name,
        string memory _symbol,
        address _underlyingAsset,
        address _owner
    ) ERC20(_name, _symbol) Ownable(_owner) {
        require(_underlyingAsset != address(0), "aToken: invalid underlying asset");
        underlyingAsset = _underlyingAsset;
    }

    /**
     * @notice 铸造代币（仅所有者，通常由 LendingPool 调用）/ Mint tokens (owner only, usually called by LendingPool)
     * @param to 接收地址 / Recipient address
     * @param amount 铸造数量（18位精度）/ Amount to mint (18 decimals)
     */
    function mint(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) {
            emit CheckFailedMintToZeroAddress(to);
            require(false, "aToken: mint to zero address");
        }
        _mint(to, amount);
        emit Minted(to, amount);
    }

    /**
     * @notice 销毁代币（仅所有者，通常由 LendingPool 调用）/ Burn tokens (owner only, usually called by LendingPool)
     * @param from 销毁地址 / Address to burn from
     * @param amount 销毁数量（18位精度）/ Amount to burn (18 decimals)
     */
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
        emit Burned(from, amount);
    }
}
