// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {USStockRWA} from "../src/tokens/USStockRWA.sol";
import {MockUSD} from "../src/tokens/MockUSD.sol";
import {aToken} from "../src/tokens/aToken.sol";
import {StockOracle} from "../src/StockOracle.sol";
import {MockPyth} from "../src/mocks/MockPyth.sol";
import {DeFiMath} from "../src/libraries/DeFiMath.sol";

/**
 * @title LendingPoolTest
 * @notice 测试 LendingPool 借贷池合约 / Test LendingPool lending pool contract
 */
contract LendingPoolTest is Test {
    using DeFiMath for uint256;

    LendingPool public lendingPool;
    USStockRWA public rwaToken;
    MockUSD public usdToken;
    StockOracle public oracle;
    MockPyth public mockPyth;
    aToken public aRWA;

    address public owner;
    address public user1;
    address public user2;

    string constant STOCK_SYMBOL = "NVDA";
    uint256 constant RWA_PRICE = 150 * 1e8; // $150 with 8 decimals

    function setUp() public {
        owner = address(0x1);
        user1 = address(0x2);
        user2 = address(0x3);

        // 部署 Mock Pyth
        mockPyth = new MockPyth();

        // 部署 StockOracle
        vm.prank(owner);
        oracle = new StockOracle(address(mockPyth), owner);

        // 设置价格
        vm.prank(owner);
        oracle.updatePrice(STOCK_SYMBOL, RWA_PRICE);

        // 部署 RWA 代币
        vm.prank(owner);
        rwaToken = new USStockRWA("NVIDIA RWA", "NVDA", owner);

        // 部署 USD 代币
        vm.prank(owner);
        usdToken = new MockUSD(owner);

        // 部署 LendingPool
        vm.prank(owner);
        lendingPool = new LendingPool(address(rwaToken), address(usdToken), address(oracle), STOCK_SYMBOL, owner);

        // 获取 aToken 地址
        address aTokenAddress = lendingPool.aTokens(address(rwaToken));
        aRWA = aToken(aTokenAddress);

        // 给用户铸造一些 RWA 和 USD
        uint256 rwaAmount = 10000 * 1e18;
        uint256 usdAmount = 1000000 * 1e6;

        vm.prank(owner);
        rwaToken.mint(user1, rwaAmount);

        vm.prank(owner);
        usdToken.mint(user1, usdAmount);

        // 给 LendingPool 铸造 USD（用于借出）/ Mint USD to LendingPool (for lending)
        vm.prank(owner);
        usdToken.mint(address(lendingPool), 10000000 * 1e6); // 10M USD

        // 用户授权 LendingPool
        vm.prank(user1);
        rwaToken.approve(address(lendingPool), type(uint256).max);

        vm.prank(user1);
        usdToken.approve(address(lendingPool), type(uint256).max);
    }

    /// @notice 测试构造函数 / Test constructor
    function test_Constructor() public {
        assertEq(address(lendingPool.rwaToken()), address(rwaToken));
        assertEq(address(lendingPool.usdToken()), address(usdToken));
        assertEq(address(lendingPool.oracle()), address(oracle));
        assertEq(lendingPool.stockSymbol(), STOCK_SYMBOL);
        assertEq(lendingPool.owner(), owner);
        assertEq(lendingPool.ltv(), 0.7 * 1e18);
        assertEq(lendingPool.liquidationThreshold(), 1.0 * 1e18);
    }

    /// @notice 测试存款 RWA / Test deposit RWA
    function test_DepositRWA() public {
        uint256 amount = 1000 * 1e18;

        vm.prank(user1);
        lendingPool.depositRWA(amount);

        assertEq(lendingPool.deposits(user1, address(rwaToken)), amount);
        assertEq(aRWA.balanceOf(user1), amount);
        assertEq(rwaToken.balanceOf(address(lendingPool)), amount);
    }

    /// @notice 测试提取 RWA / Test withdraw RWA
    function test_WithdrawRWA() public {
        uint256 depositAmount = 1000 * 1e18;

        // 先存款
        vm.prank(user1);
        lendingPool.depositRWA(depositAmount);

        // 提取
        vm.prank(user1);
        lendingPool.withdrawRWA(depositAmount);

        assertEq(lendingPool.deposits(user1, address(rwaToken)), 0);
        assertEq(aRWA.balanceOf(user1), 0);
        assertEq(rwaToken.balanceOf(user1), 10000 * 1e18); // 恢复原始余额
    }

    /// @notice 测试借款 USD / Test borrow USD
    function test_BorrowUSD() public {
        uint256 depositAmount = 1000 * 1e18;
        uint256 borrowAmount = 50000 * 1e6; // $50,000 USD (6 decimals)

        // 先存款
        vm.prank(user1);
        lendingPool.depositRWA(depositAmount);

        // 计算最大可借款
        uint256 maxBorrow = lendingPool.getMaxBorrow(user1);
        uint256 normalizedBorrow = DeFiMath.normalizeUSDC(borrowAmount);

        require(normalizedBorrow <= maxBorrow, "Borrow amount exceeds limit");

        // 借款
        vm.prank(user1);
        lendingPool.borrowUSD(borrowAmount);

        assertEq(lendingPool.borrows(user1), normalizedBorrow);
        assertEq(usdToken.balanceOf(user1), 1000000 * 1e6 + borrowAmount);
    }

    /// @notice 测试还款 USD / Test repay USD
    function test_RepayUSD() public {
        uint256 depositAmount = 1000 * 1e18;
        uint256 borrowAmount = 50000 * 1e6;

        // 存款和借款
        vm.prank(user1);
        lendingPool.depositRWA(depositAmount);

        vm.prank(user1);
        lendingPool.borrowUSD(borrowAmount);

        // 时间前进 1 年
        vm.warp(block.timestamp + 365 days);

        // 还款
        uint256 totalDebt = lendingPool.getTotalDebt(user1);
        uint256 repayAmount = DeFiMath.denormalizeToUSDC(totalDebt);

        // 确保用户有足够的 USD / Ensure user has enough USD
        uint256 userBalance = usdToken.balanceOf(user1);
        if (repayAmount > userBalance) {
            vm.prank(owner);
            usdToken.mint(user1, repayAmount - userBalance);
        }

        vm.prank(user1);
        lendingPool.repayUSD(repayAmount);

        // 允许小的精度误差（由于归一化/反归一化）/ Allow small precision error (due to normalization/denormalization)
        uint256 remainingDebt = lendingPool.borrows(user1);
        assertLe(remainingDebt, 1e12, "Remaining debt should be negligible"); // 允许 1e12 wei 的误差
    }

    /// @notice 测试健康因子计算 / Test health factor calculation
    function test_GetAccountHealthFactor() public {
        uint256 depositAmount = 1000 * 1e18;
        uint256 borrowAmount = 50000 * 1e6;

        // 存款
        vm.prank(user1);
        lendingPool.depositRWA(depositAmount);

        // 借款前健康因子应该为最大值
        uint256 hf1 = lendingPool.getAccountHealthFactor(user1);
        assertEq(hf1, type(uint256).max);

        // 借款
        vm.prank(user1);
        lendingPool.borrowUSD(borrowAmount);

        // 借款后健康因子应该大于 1.0
        uint256 hf2 = lendingPool.getAccountHealthFactor(user1);
        assertGt(hf2, 1e18);
    }

    /// @notice 测试健康因子过低无法提取 / Test cannot withdraw when health factor too low
    function test_Withdraw_HealthFactorTooLow() public {
        uint256 depositAmount = 1000 * 1e18;
        uint256 borrowAmount = 100000 * 1e6; // 大额借款

        // 存款和借款
        vm.prank(user1);
        lendingPool.depositRWA(depositAmount);

        vm.prank(user1);
        lendingPool.borrowUSD(borrowAmount);

        // 尝试提取（应该失败，因为健康因子会过低）
        vm.prank(user1);
        vm.expectRevert("LendingPool: health factor too low");
        lendingPool.withdrawRWA(depositAmount);
    }

    /// @notice 测试清算 / Test liquidation
    function test_Liquidate() public {
        uint256 depositAmount = 1000 * 1e18;
        uint256 borrowAmount = 100000 * 1e6;

        // 存款和借款
        vm.prank(user1);
        lendingPool.depositRWA(depositAmount);

        vm.prank(user1);
        lendingPool.borrowUSD(borrowAmount);

        // 价格下跌，导致健康因子降低
        vm.prank(owner);
        oracle.updatePrice(STOCK_SYMBOL, 50 * 1e8); // 价格从 $150 跌到 $50

        // 清算
        vm.prank(user2);
        lendingPool.liquidate(user1);

        assertEq(lendingPool.deposits(user1, address(rwaToken)), 0);
        assertEq(lendingPool.borrows(user1), 0);
        assertGt(rwaToken.balanceOf(user2), 0); // 清算人获得抵押品
    }

    /// @notice 测试最大可借款计算 / Test max borrow calculation
    function test_GetMaxBorrow() public {
        uint256 depositAmount = 1000 * 1e18;

        // 存款
        vm.prank(user1);
        lendingPool.depositRWA(depositAmount);

        // 计算最大可借款
        uint256 maxBorrow = lendingPool.getMaxBorrow(user1);

        // 抵押品价值 = 1000 * 150 = 150,000 (归一化)
        // 最大借款 = 150,000 * 0.7 = 105,000 (归一化)
        uint256 expectedMaxBorrow =
            DeFiMath.mul(DeFiMath.mul(depositAmount, DeFiMath.normalizeOraclePrice(RWA_PRICE)), 0.7 * 1e18);

        assertEq(maxBorrow, expectedMaxBorrow);
    }

    /// @notice 测试设置利率 / Test set interest rates
    function test_SetRates() public {
        uint256 newDepositRate = 0.06 * 1e18; // 6%
        uint256 newBorrowRate = 0.09 * 1e18; // 9%

        vm.prank(owner);
        lendingPool.setDepositRate(newDepositRate);

        vm.prank(owner);
        lendingPool.setBorrowRate(newBorrowRate);

        assertEq(lendingPool.depositRate(), newDepositRate);
        assertEq(lendingPool.borrowRate(), newBorrowRate);
    }

    /// @notice 测试设置 LTV / Test set LTV
    function test_SetLTV() public {
        uint256 newLTV = 0.75 * 1e18; // 75%

        vm.prank(owner);
        lendingPool.setLTV(newLTV);

        assertEq(lendingPool.ltv(), newLTV);
    }
}
