// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {aToken} from "../src/tokens/aToken.sol";
import {USStockRWA} from "../src/tokens/USStockRWA.sol";

/**
 * @title aTokenTest
 * @notice 测试 aToken 存款凭证代币合约 / Test aToken deposit receipt token contract
 */
contract aTokenTest is Test {
    aToken public aRWA;
    USStockRWA public rwaToken;
    address public lendingPool;
    address public owner;
    address public user;

    function setUp() public {
        owner = address(0x1);
        lendingPool = address(0x2);
        user = address(0x3);
        
        // 部署 RWA 代币
        vm.prank(owner);
        rwaToken = new USStockRWA("NVIDIA RWA", "NVDA", owner);
        
        // 部署 aToken
        aRWA = new aToken("Anchor NVDA", "aNVDA", address(rwaToken), lendingPool);
    }

    /// @notice 测试构造函数 / Test constructor
    function test_Constructor() public {
        assertEq(aRWA.name(), "Anchor NVDA");
        assertEq(aRWA.symbol(), "aNVDA");
        assertEq(aRWA.underlyingAsset(), address(rwaToken));
        assertEq(aRWA.owner(), lendingPool);
        assertEq(aRWA.decimals(), 18);
    }

    /// @notice 测试铸造代币（仅所有者）/ Test mint tokens (owner only)
    function test_Mint() public {
        uint256 amount = 1000 * 1e18;
        
        vm.prank(lendingPool);
        aRWA.mint(user, amount);
        
        assertEq(aRWA.balanceOf(user), amount);
        assertEq(aRWA.totalSupply(), amount);
    }

    /// @notice 测试非所有者无法铸造 / Test non-owner cannot mint
    function test_Mint_OnlyOwner() public {
        uint256 amount = 1000 * 1e18;
        
        vm.prank(user);
        vm.expectRevert();
        aRWA.mint(user, amount);
    }

    /// @notice 测试销毁代币 / Test burn tokens
    function test_Burn() public {
        uint256 amount = 1000 * 1e18;
        
        vm.prank(lendingPool);
        aRWA.mint(user, amount);
        
        vm.prank(lendingPool);
        aRWA.burn(user, amount);
        
        assertEq(aRWA.balanceOf(user), 0);
        assertEq(aRWA.totalSupply(), 0);
    }

    /// @notice 测试非所有者无法销毁 / Test non-owner cannot burn
    function test_Burn_OnlyOwner() public {
        uint256 amount = 1000 * 1e18;
        
        vm.prank(lendingPool);
        aRWA.mint(user, amount);
        
        vm.prank(user);
        vm.expectRevert();
        aRWA.burn(user, amount);
    }
}
