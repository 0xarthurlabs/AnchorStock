// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {USStockRWA} from "../src/tokens/USStockRWA.sol";

/**
 * @title USStockRWATest
 * @notice 测试 USStockRWA 代币合约 / Test USStockRWA token contract
 */
contract USStockRWATest is Test {
    USStockRWA public rwaToken;
    address public owner;
    address public user1;
    address public user2;

    function setUp() public {
        owner = address(0x1);
        user1 = address(0x2);
        user2 = address(0x3);
        
        vm.prank(owner);
        rwaToken = new USStockRWA("NVIDIA RWA", "NVDA", owner);
    }

    /// @notice 测试构造函数 / Test constructor
    function test_Constructor() public {
        assertEq(rwaToken.name(), "NVIDIA RWA");
        assertEq(rwaToken.symbol(), "NVDA");
        assertEq(rwaToken.stockSymbol(), "NVDA");
        assertEq(rwaToken.owner(), owner);
        assertEq(rwaToken.decimals(), 18);
        assertEq(rwaToken.totalSupply(), 0);
    }

    /// @notice 测试铸造代币 / Test mint tokens
    function test_Mint() public {
        uint256 amount = 1000 * 1e18;
        
        vm.prank(owner);
        rwaToken.mint(user1, amount);
        
        assertEq(rwaToken.balanceOf(user1), amount);
        assertEq(rwaToken.totalSupply(), amount);
    }

    /// @notice 测试非所有者无法铸造 / Test non-owner cannot mint
    function test_Mint_OnlyOwner() public {
        uint256 amount = 1000 * 1e18;
        
        vm.prank(user1);
        vm.expectRevert();
        rwaToken.mint(user2, amount);
    }

    /// @notice 测试批量铸造 / Test batch mint
    function test_BatchMint() public {
        address[] memory recipients = new address[](2);
        recipients[0] = user1;
        recipients[1] = user2;
        
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000 * 1e18;
        amounts[1] = 2000 * 1e18;
        
        vm.prank(owner);
        rwaToken.batchMint(recipients, amounts);
        
        assertEq(rwaToken.balanceOf(user1), amounts[0]);
        assertEq(rwaToken.balanceOf(user2), amounts[1]);
        assertEq(rwaToken.totalSupply(), amounts[0] + amounts[1]);
    }

    /// @notice 测试销毁代币 / Test burn tokens
    function test_Burn() public {
        uint256 amount = 1000 * 1e18;
        
        vm.prank(owner);
        rwaToken.mint(user1, amount);
        
        vm.prank(user1);
        rwaToken.burn(amount);
        
        assertEq(rwaToken.balanceOf(user1), 0);
        assertEq(rwaToken.totalSupply(), 0);
    }

    /// @notice 测试从指定地址销毁代币 / Test burn from specified address
    function test_BurnFrom() public {
        uint256 amount = 1000 * 1e18;
        
        vm.prank(owner);
        rwaToken.mint(user1, amount);
        
        vm.prank(owner);
        rwaToken.burnFrom(user1, amount);
        
        assertEq(rwaToken.balanceOf(user1), 0);
        assertEq(rwaToken.totalSupply(), 0);
    }

    /// @notice 测试转账功能 / Test transfer
    function test_Transfer() public {
        uint256 amount = 1000 * 1e18;
        
        vm.prank(owner);
        rwaToken.mint(user1, amount);
        
        vm.prank(user1);
        rwaToken.transfer(user2, amount);
        
        assertEq(rwaToken.balanceOf(user1), 0);
        assertEq(rwaToken.balanceOf(user2), amount);
    }
}
