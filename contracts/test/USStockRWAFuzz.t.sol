// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {USStockRWA} from "../src/tokens/USStockRWA.sol";

/**
 * @title USStockRWAFuzzTest
 * @notice Fuzz 测试 USStockRWA 代币合约 / Fuzz test USStockRWA token contract
 */
contract USStockRWAFuzzTest is Test {
    USStockRWA public rwaToken;
    address public owner;
    address public user;

    function setUp() public {
        owner = address(0x1);
        user = address(0x2);

        vm.prank(owner);
        rwaToken = new USStockRWA("NVIDIA RWA", "NVDA", owner);
    }

    /// @notice Fuzz 测试：铸造和转账 / Fuzz test: Mint and transfer
    /// @param amount 铸造数量（18位精度）/ Mint amount (18 decimals)
    function testFuzz_MintAndTransfer(uint256 amount) public {
        // 限制金额范围，避免溢出 / Limit amount range to avoid overflow
        amount = bound(amount, 1, type(uint256).max / 2);

        vm.prank(owner);
        rwaToken.mint(user, amount);

        assertEq(rwaToken.balanceOf(user), amount);
        assertEq(rwaToken.totalSupply(), amount);

        // 转账
        address recipient = address(0x3);
        vm.prank(user);
        rwaToken.transfer(recipient, amount);

        assertEq(rwaToken.balanceOf(user), 0);
        assertEq(rwaToken.balanceOf(recipient), amount);
    }

    /// @notice Fuzz 测试：批量铸造 / Fuzz test: Batch mint
    /// @param count 数量 / Count
    function testFuzz_BatchMint(uint8 count) public {
        // 限制数组大小 / Limit array size
        count = uint8(bound(uint256(count), 1, 10));

        address[] memory recipients = new address[](count);
        uint256[] memory amounts = new uint256[](count);
        uint256 totalAmount = 0;

        for (uint8 i = 0; i < count; i++) {
            recipients[i] = address(uint160(i + 100));
            amounts[i] = bound(uint256(keccak256(abi.encodePacked(i))), 1, 1000000 * 1e18);
            totalAmount += amounts[i];
        }

        vm.prank(owner);
        rwaToken.batchMint(recipients, amounts);

        assertEq(rwaToken.totalSupply(), totalAmount);

        for (uint8 i = 0; i < count; i++) {
            assertEq(rwaToken.balanceOf(recipients[i]), amounts[i]);
        }
    }

    /// @notice Fuzz 测试：铸造和销毁 / Fuzz test: Mint and burn
    /// @param amount 数量（18位精度）/ Amount (18 decimals)
    function testFuzz_MintAndBurn(uint256 amount) public {
        amount = bound(amount, 1, type(uint256).max / 2);

        vm.prank(owner);
        rwaToken.mint(user, amount);

        vm.prank(user);
        rwaToken.burn(amount);

        assertEq(rwaToken.balanceOf(user), 0);
        assertEq(rwaToken.totalSupply(), 0);
    }
}
