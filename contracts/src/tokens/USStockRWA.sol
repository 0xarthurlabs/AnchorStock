// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title USStockRWA
 * @author AnchorStock
 * @notice 美股 RWA（Real World Asset）代币，代表美股资产 / US Stock RWA token representing stock assets
 * @dev 使用 ERC20 标准，18 位精度 / Uses ERC20 standard with 18 decimals
 *
 * 示例：$NVDA, $AAPL 等美股代币化资产 / Examples: $NVDA, $AAPL tokenized stock assets
 */
contract USStockRWA is ERC20, Ownable {
    /// @notice 股票符号（如 "NVDA", "AAPL"）/ Stock symbol (e.g., "NVDA", "AAPL")
    string public stockSymbol;

    /// @notice 事件：代币铸造 / Event: Token minted
    event Minted(address indexed to, uint256 amount);

    /// @notice 事件：代币销毁 / Event: Token burned
    event Burned(address indexed from, uint256 amount);

    /// @notice 检查失败：铸造/销毁目标地址为 0 / Check failed: mint/burn to zero address
    event CheckFailedZeroAddress(string context, address value);
    /// @notice 检查失败：数组长度不匹配 / Check failed: arrays length mismatch
    event CheckFailedArraysLengthMismatch(uint256 lengthRecipients, uint256 lengthAmounts);

    /**
     * @notice 构造函数 / Constructor
     * @param _name 代币名称（如 "NVIDIA RWA"）/ Token name (e.g., "NVIDIA RWA")
     * @param _symbol 代币符号（如 "NVDA"）/ Token symbol (e.g., "NVDA")
     * @param _owner 合约所有者 / Contract owner
     */
    constructor(string memory _name, string memory _symbol, address _owner) ERC20(_name, _symbol) Ownable(_owner) {
        stockSymbol = _symbol;
    }

    /**
     * @notice 铸造代币（仅所有者）/ Mint tokens (owner only)
     * @param to 接收地址 / Recipient address
     * @param amount 铸造数量（18位精度）/ Amount to mint (18 decimals)
     */
    function mint(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) {
            emit CheckFailedZeroAddress("mint", to);
            require(false, "USStockRWA: mint to zero address");
        }
        _mint(to, amount);
        emit Minted(to, amount);
    }

    /**
     * @notice 批量铸造代币 / Batch mint tokens
     * @param recipients 接收地址数组 / Array of recipient addresses
     * @param amounts 数量数组（18位精度）/ Array of amounts (18 decimals)
     */
    function batchMint(address[] memory recipients, uint256[] memory amounts) external onlyOwner {
        if (recipients.length != amounts.length) {
            emit CheckFailedArraysLengthMismatch(recipients.length, amounts.length);
            require(false, "USStockRWA: arrays length mismatch");
        }

        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i] == address(0)) {
                emit CheckFailedZeroAddress("batchMint", recipients[i]);
                require(false, "USStockRWA: mint to zero address");
            }
            _mint(recipients[i], amounts[i]);
            emit Minted(recipients[i], amounts[i]);
        }
    }

    /**
     * @notice 销毁代币 / Burn tokens
     * @param amount 销毁数量（18位精度）/ Amount to burn (18 decimals)
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
        emit Burned(msg.sender, amount);
    }

    /**
     * @notice 从指定地址销毁代币（仅所有者）/ Burn tokens from specified address (owner only)
     * @param from 销毁地址 / Address to burn from
     * @param amount 销毁数量（18位精度）/ Amount to burn (18 decimals)
     */
    function burnFrom(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
        emit Burned(from, amount);
    }
}
