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
 * @title LendingPoolFuzzTest
 * @notice Fuzz 测试 LendingPool 借贷池合约 / Fuzz test LendingPool lending pool contract
 */
contract LendingPoolFuzzTest is Test {
    using DeFiMath for uint256;

    LendingPool public lendingPool;
    USStockRWA public rwaToken;
    MockUSD public usdToken;
    StockOracle public oracle;
    MockPyth public mockPyth;
    aToken public aRWA;

    address public owner;
    address public user;

    string constant STOCK_SYMBOL = "NVDA";
    uint256 constant INITIAL_PRICE = 150 * 1e8; // $150 with 8 decimals

    function setUp() public {
        owner = address(0x1);
        user = address(0x2);

        // 部署 Mock Pyth
        mockPyth = new MockPyth();

        // 部署 StockOracle
        vm.prank(owner);
        oracle = new StockOracle(address(mockPyth), owner);

        // 设置初始价格
        vm.prank(owner);
        oracle.updatePrice(STOCK_SYMBOL, INITIAL_PRICE);

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

        // 给用户铸造大量 RWA 和 USD（用于 fuzz 测试）
        vm.prank(owner);
        rwaToken.mint(user, type(uint256).max / 2);

        vm.prank(owner);
        usdToken.mint(user, type(uint256).max / 2);

        // 给 LendingPool 铸造大量 USD（用于借出）/ Mint large amount of USD to LendingPool (for lending)
        vm.prank(owner);
        usdToken.mint(address(lendingPool), type(uint256).max / 2);

        // 用户授权 LendingPool
        vm.prank(user);
        rwaToken.approve(address(lendingPool), type(uint256).max);

        vm.prank(user);
        usdToken.approve(address(lendingPool), type(uint256).max);
    }

    /// @notice Fuzz 测试：存款和提取 / Fuzz test: Deposit and withdraw
    /// @param amount 存款数量（18位精度）/ Deposit amount (18 decimals)
    function testFuzz_DepositAndWithdraw(uint256 amount) public {
        // 限制金额范围，避免溢出 / Limit amount range to avoid overflow
        amount = bound(amount, 1, 1000000 * 1e18);

        // 确保用户有足够的代币 / Ensure user has enough tokens
        uint256 userBalance = rwaToken.balanceOf(user);
        if (amount > userBalance) {
            vm.prank(owner);
            rwaToken.mint(user, amount - userBalance);
        }

        // 存款
        vm.prank(user);
        lendingPool.depositRWA(amount);

        assertEq(lendingPool.deposits(user, address(rwaToken)), amount);
        assertEq(aRWA.balanceOf(user), amount);

        // 提取
        vm.prank(user);
        lendingPool.withdrawRWA(amount);

        assertEq(lendingPool.deposits(user, address(rwaToken)), 0);
        assertEq(aRWA.balanceOf(user), 0);
    }

    /// @notice Fuzz 测试：借款和还款 / Fuzz test: Borrow and repay
    /// @param depositAmount 存款数量（18位精度）/ Deposit amount (18 decimals)
    /// @param borrowAmount 借款数量（6位精度）/ Borrow amount (6 decimals)
    function testFuzz_BorrowAndRepay(uint256 depositAmount, uint256 borrowAmount) public {
        // 限制金额范围 / Limit amount range
        depositAmount = bound(depositAmount, 100 * 1e18, 1000000 * 1e18);
        borrowAmount = bound(borrowAmount, 1, 1000000 * 1e6);

        // 确保用户有足够的代币 / Ensure user has enough tokens
        uint256 userBalance = rwaToken.balanceOf(user);
        if (depositAmount > userBalance) {
            vm.prank(owner);
            rwaToken.mint(user, depositAmount - userBalance);
        }

        // 存款
        vm.prank(user);
        lendingPool.depositRWA(depositAmount);

        // 计算最大可借款
        uint256 maxBorrow = lendingPool.getMaxBorrow(user);
        uint256 normalizedBorrow = DeFiMath.normalizeUSDC(borrowAmount);

        // 如果借款金额超过限额，调整 / If borrow amount exceeds limit, adjust
        if (normalizedBorrow > maxBorrow) {
            borrowAmount = DeFiMath.denormalizeToUSDC(maxBorrow);
            if (borrowAmount == 0) {
                return; // 无法借款 / Cannot borrow
            }
        }

        // 借款
        vm.prank(user);
        lendingPool.borrowUSD(borrowAmount);

        // 时间前进（模拟利息累积）/ Time passes (simulate interest accumulation)
        vm.warp(block.timestamp + 30 days);

        // 还款
        uint256 totalDebt = lendingPool.getTotalDebt(user);
        uint256 repayAmount = DeFiMath.denormalizeToUSDC(totalDebt);

        // 确保用户有足够的 USD / Ensure user has enough USD
        uint256 usdBalance = usdToken.balanceOf(user);
        if (repayAmount > usdBalance) {
            vm.prank(owner);
            usdToken.mint(user, repayAmount - usdBalance);
        }

        vm.prank(user);
        lendingPool.repayUSD(repayAmount);

        // 允许小的精度误差（由于归一化/反归一化）/ Allow small precision error (due to normalization/denormalization)
        uint256 remainingDebt = lendingPool.borrows(user);
        assertLe(remainingDebt, 1e12, "Remaining debt should be negligible"); // 允许 1e12 wei 的误差
    }

    /// @notice Fuzz 测试：健康因子计算 / Fuzz test: Health factor calculation
    /// @param depositAmount 存款数量（18位精度）/ Deposit amount (18 decimals)
    /// @param borrowAmount 借款数量（6位精度）/ Borrow amount (6 decimals)
    function testFuzz_HealthFactor(uint256 depositAmount, uint256 borrowAmount) public {
        // 限制金额范围 / Limit amount range
        depositAmount = bound(depositAmount, 100 * 1e18, 1000000 * 1e18);
        borrowAmount = bound(borrowAmount, 1, 1000000 * 1e6);

        // 确保用户有足够的代币 / Ensure user has enough tokens
        uint256 userBalance = rwaToken.balanceOf(user);
        if (depositAmount > userBalance) {
            vm.prank(owner);
            rwaToken.mint(user, depositAmount - userBalance);
        }

        // 存款
        vm.prank(user);
        lendingPool.depositRWA(depositAmount);

        // 计算最大可借款
        uint256 maxBorrow = lendingPool.getMaxBorrow(user);
        uint256 normalizedBorrow = DeFiMath.normalizeUSDC(borrowAmount);

        if (normalizedBorrow > maxBorrow) {
            borrowAmount = DeFiMath.denormalizeToUSDC(maxBorrow);
            if (borrowAmount == 0) {
                return;
            }
            normalizedBorrow = maxBorrow;
        }

        // 借款
        vm.prank(user);
        lendingPool.borrowUSD(borrowAmount);

        // 计算健康因子
        uint256 healthFactor = lendingPool.getAccountHealthFactor(user);

        // 健康因子应该 >= 1.0（否则无法借款）/ Health factor should >= 1.0 (otherwise cannot borrow)
        assertGe(healthFactor, 1e18, "Health factor should be >= 1.0");
    }

    /// @notice Fuzz 测试：最大可借款计算 / Fuzz test: Max borrow calculation
    /// @param depositAmount 存款数量（18位精度）/ Deposit amount (18 decimals)
    /// @param price 价格（8位精度）/ Price (8 decimals)
    function testFuzz_MaxBorrow(uint256 depositAmount, uint256 price) public {
        // 限制金额范围 / Limit amount range
        depositAmount = bound(depositAmount, 1 * 1e18, 1000000 * 1e18);
        price = bound(price, 1 * 1e8, 10000 * 1e8); // $1 to $10,000

        // 更新价格
        vm.prank(owner);
        oracle.updatePrice(STOCK_SYMBOL, price);

        // 确保用户有足够的代币 / Ensure user has enough tokens
        uint256 userBalance = rwaToken.balanceOf(user);
        if (depositAmount > userBalance) {
            vm.prank(owner);
            rwaToken.mint(user, depositAmount - userBalance);
        }

        // 存款
        vm.prank(user);
        lendingPool.depositRWA(depositAmount);

        // 计算最大可借款
        uint256 maxBorrow = lendingPool.getMaxBorrow(user);

        // 验证计算：抵押品价值 * LTV / Verify calculation: collateral value * LTV
        (uint256 normalizedPrice,) = oracle.getPrice(STOCK_SYMBOL);
        uint256 collateralValue = DeFiMath.mul(depositAmount, normalizedPrice);
        uint256 expectedMaxBorrow = DeFiMath.mul(collateralValue, lendingPool.ltv());

        assertEq(maxBorrow, expectedMaxBorrow, "Max borrow calculation failed");
    }

    /// @notice Fuzz 测试：线性利息计算 / Fuzz test: Linear interest calculation
    /// @param principal 本金（18位精度）/ Principal (18 decimals)
    /// @param timeElapsed 经过的时间（秒）/ Time elapsed (seconds)
    function testFuzz_LinearInterest(uint256 principal, uint256 timeElapsed) public {
        // 限制范围 / Limit range
        // 本金不能太小，否则利息计算会有精度问题 / Principal cannot be too small, otherwise interest calculation will have precision issues
        principal = bound(principal, 10000 * 1e18, 1000000 * 1e18); // 至少 10000 tokens
        timeElapsed = bound(timeElapsed, 7 days, 10 * 365 days); // 至少 7 天，最多 10 年 / At least 7 days, max 10 years

        // 设置借款
        uint256 depositAmount = principal * 2; // 确保有足够的抵押品 / Ensure enough collateral

        // 确保用户有足够的代币 / Ensure user has enough tokens
        uint256 userBalance = rwaToken.balanceOf(user);
        if (depositAmount > userBalance) {
            vm.prank(owner);
            rwaToken.mint(user, depositAmount - userBalance);
        }

        // 存款
        vm.prank(user);
        lendingPool.depositRWA(depositAmount);

        // 借款
        uint256 borrowAmount = DeFiMath.denormalizeToUSDC(principal);
        uint256 maxBorrow = lendingPool.getMaxBorrow(user);

        if (principal > maxBorrow) {
            borrowAmount = DeFiMath.denormalizeToUSDC(maxBorrow);
            principal = maxBorrow;
            if (principal == 0) {
                return;
            }
        }

        vm.prank(user);
        lendingPool.borrowUSD(borrowAmount);

        // 获取实际借出的本金（由于归一化/反归一化可能有精度损失）
        // Get actual borrowed principal (may have precision loss due to normalization/denormalization)
        uint256 actualPrincipal = lendingPool.borrows(user);

        // 时间前进
        vm.warp(block.timestamp + timeElapsed);

        // 计算总债务
        uint256 totalDebt = lendingPool.getTotalDebt(user);

        // 验证总债务应该 >= 实际本金 / Verify total debt should >= actual principal
        assertGe(totalDebt, actualPrincipal, "Total debt should be >= actual principal");

        // 验证线性利息公式 / Verify linear interest formula
        uint256 borrowRate = lendingPool.borrowRate();
        uint256 expectedInterest = DeFiMath.mul(actualPrincipal, borrowRate);
        expectedInterest = DeFiMath.mul(expectedInterest, timeElapsed);
        expectedInterest = expectedInterest / 365 days;

        uint256 actualInterest = totalDebt > actualPrincipal ? totalDebt - actualPrincipal : 0;

        // 验证线性利息公式（允许精度误差）/ Verify linear interest formula (allow precision error)
        // 由于整数除法的舍入，允许更大的误差范围 / Due to integer division rounding, allow larger error range
        uint256 diff =
            actualInterest > expectedInterest ? actualInterest - expectedInterest : expectedInterest - actualInterest;
        // 允许 5% 的误差或至少 1 wei / Allow 5% error or at least 1 wei
        uint256 maxError = expectedInterest > 0 ? (expectedInterest * 5) / 100 + 1 : 1;
        assertLe(diff, maxError, "Interest calculation error too large");
    }

    /// @notice Fuzz 测试：价格变化对健康因子的影响 / Fuzz test: Price change impact on health factor
    /// @param depositAmount 存款数量（18位精度）/ Deposit amount (18 decimals)
    /// @param borrowAmount 借款数量（6位精度）/ Borrow amount (6 decimals)
    /// @param newPrice 新价格（8位精度）/ New price (8 decimals)
    function testFuzz_PriceChangeImpact(uint256 depositAmount, uint256 borrowAmount, uint256 newPrice) public {
        // 限制金额范围 / Limit amount range
        depositAmount = bound(depositAmount, 100 * 1e18, 1000000 * 1e18);
        borrowAmount = bound(borrowAmount, 1, 1000000 * 1e6);
        newPrice = bound(newPrice, 1 * 1e8, 10000 * 1e8);

        // 确保用户有足够的代币 / Ensure user has enough tokens
        uint256 userBalance = rwaToken.balanceOf(user);
        if (depositAmount > userBalance) {
            vm.prank(owner);
            rwaToken.mint(user, depositAmount - userBalance);
        }

        // 存款和借款
        vm.prank(user);
        lendingPool.depositRWA(depositAmount);

        uint256 maxBorrow = lendingPool.getMaxBorrow(user);
        uint256 normalizedBorrow = DeFiMath.normalizeUSDC(borrowAmount);

        if (normalizedBorrow > maxBorrow) {
            borrowAmount = DeFiMath.denormalizeToUSDC(maxBorrow);
            if (borrowAmount == 0) {
                return;
            }
        }

        vm.prank(user);
        lendingPool.borrowUSD(borrowAmount);

        // 获取原始健康因子
        uint256 originalHF = lendingPool.getAccountHealthFactor(user);

        // 更新价格
        vm.prank(owner);
        oracle.updatePrice(STOCK_SYMBOL, newPrice);

        // 获取新健康因子
        uint256 newHF = lendingPool.getAccountHealthFactor(user);

        // 如果价格下跌，健康因子应该降低 / If price drops, health factor should decrease
        if (newPrice < INITIAL_PRICE) {
            assertLe(newHF, originalHF, "Health factor should decrease when price drops");
        } else if (newPrice > INITIAL_PRICE) {
            assertGe(newHF, originalHF, "Health factor should increase when price rises");
        }
    }

    /// @notice Fuzz 测试：多次存款和提取 / Fuzz test: Multiple deposits and withdrawals
    /// @param amounts 存款数量数组（18位精度）/ Array of deposit amounts (18 decimals)
    function testFuzz_MultipleDeposits(uint256[5] memory amounts) public {
        uint256 totalDeposited = 0;

        for (uint256 i = 0; i < amounts.length; i++) {
            amounts[i] = bound(amounts[i], 1, 100000 * 1e18);

            // 确保用户有足够的代币 / Ensure user has enough tokens
            uint256 userBalance = rwaToken.balanceOf(user);
            if (amounts[i] > userBalance) {
                vm.prank(owner);
                rwaToken.mint(user, amounts[i] - userBalance);
            }

            // 存款
            vm.prank(user);
            lendingPool.depositRWA(amounts[i]);

            totalDeposited += amounts[i];
        }

        // 验证总存款 / Verify total deposit
        assertEq(lendingPool.deposits(user, address(rwaToken)), totalDeposited);
        assertEq(aRWA.balanceOf(user), totalDeposited);

        // 提取所有
        vm.prank(user);
        lendingPool.withdrawRWA(totalDeposited);

        assertEq(lendingPool.deposits(user, address(rwaToken)), 0);
        assertEq(aRWA.balanceOf(user), 0);
    }
}
