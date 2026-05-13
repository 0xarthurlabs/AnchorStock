// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StockOracle} from "../src/StockOracle.sol";
import {USStockRWA} from "../src/tokens/USStockRWA.sol";
import {MockUSD} from "../src/tokens/MockUSD.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {PerpEngine} from "../src/PerpEngine.sol";
import {MockPyth} from "../src/mocks/MockPyth.sol";
import {aToken} from "../src/tokens/aToken.sol";

/**
 * @title DeployScriptTest
 * @notice 部署流程测试：复现 Deploy.s.sol 的完整部署并校验 / Deployment flow test: replicate full Deploy.s.sol and assert
 * @dev 不依赖外部 RPC，在 forge test 中运行 / No external RPC, runs in forge test
 */
contract DeployScriptTest is Test {
    string constant STOCK_SYMBOL = "NVDA";
    uint256 constant MINT_USD_TO_POOL = 10_000_000 * 1e6; // 10M USD

    MockPyth public mockPyth;
    StockOracle public oracle;
    USStockRWA public rwaToken;
    MockUSD public usdToken;
    LendingPool public lendingPool;
    aToken public aRWA;
    PerpEngine public perpEngine;

    address public deployer;

    /// @notice 执行与 Deploy.s.sol 一致的部署步骤 / Perform same deployment steps as Deploy.s.sol
    function _deployAll() internal {
        deployer = address(0x1);
        vm.startPrank(deployer);

        // 1. MockPyth
        mockPyth = new MockPyth();
        // 2. StockOracle
        oracle = new StockOracle(address(mockPyth), deployer);
        oracle.updatePrice(STOCK_SYMBOL, 150 * 1e8);
        // 3. USStockRWA
        rwaToken = new USStockRWA("NVIDIA RWA", "NVDA", deployer);
        // 4. MockUSD
        usdToken = new MockUSD(deployer);
        // 5. LendingPool
        lendingPool = new LendingPool(address(rwaToken), address(usdToken), address(oracle), STOCK_SYMBOL, deployer);
        address aTokenAddress = lendingPool.aTokens(address(rwaToken));
        aRWA = aToken(aTokenAddress);
        // 6. PerpEngine
        perpEngine = new PerpEngine(address(oracle), STOCK_SYMBOL, address(aRWA), deployer);
        // 7. Mint USD to LendingPool
        usdToken.mint(address(lendingPool), MINT_USD_TO_POOL);

        vm.stopPrank();
    }

    /// @notice 测试完整部署流程与状态 / Test full deployment flow and state
    function test_FullDeploymentFlow() public {
        _deployAll();

        assertTrue(address(mockPyth) != address(0), "MockPyth");
        assertTrue(address(oracle) != address(0), "Oracle");
        assertTrue(address(rwaToken) != address(0), "RWA");
        assertTrue(address(usdToken) != address(0), "USD");
        assertTrue(address(lendingPool) != address(0), "LendingPool");
        assertTrue(address(aRWA) != address(0), "aToken");
        assertTrue(address(perpEngine) != address(0), "PerpEngine");

        assertEq(address(lendingPool.rwaToken()), address(rwaToken));
        assertEq(address(lendingPool.usdToken()), address(usdToken));
        assertEq(address(lendingPool.oracle()), address(oracle));
        assertEq(lendingPool.stockSymbol(), STOCK_SYMBOL);
        assertEq(lendingPool.owner(), deployer);

        assertEq(usdToken.balanceOf(address(lendingPool)), MINT_USD_TO_POOL, "LendingPool USD balance");
        (uint256 price,) = oracle.getPrice(STOCK_SYMBOL);
        assertTrue(price > 0, "Oracle price set");
        assertEq(oracle.owner(), deployer);
        assertEq(rwaToken.owner(), deployer);
        assertEq(usdToken.owner(), deployer);
        assertEq(perpEngine.owner(), deployer);
        assertEq(address(perpEngine.collateralToken()), address(aRWA));
    }

    /// @notice 部署后完整用户流程：铸造 RWA -> 存款 -> 借款 -> 还款 -> 提取 / Post-deploy user flow: mint RWA -> deposit -> borrow -> repay -> withdraw
    function test_PostDeployUserFlow() public {
        _deployAll();
        address user = address(0x2);
        uint256 rwaAmount = 1000 * 1e18;
        uint256 borrowAmountUsd = 50_000 * 1e6; // 50k USD (6 decimals)

        vm.startPrank(deployer);
        rwaToken.mint(user, rwaAmount);
        vm.stopPrank();

        vm.startPrank(user);
        rwaToken.approve(address(lendingPool), type(uint256).max);
        usdToken.approve(address(lendingPool), type(uint256).max);

        // Deposit
        lendingPool.depositRWA(rwaAmount);
        assertEq(lendingPool.deposits(user, address(rwaToken)), rwaAmount);
        assertEq(aRWA.balanceOf(user), rwaAmount);

        // Borrow (within LTV)
        lendingPool.borrowUSD(borrowAmountUsd);
        assertTrue(lendingPool.borrows(user) > 0);
        assertEq(usdToken.balanceOf(user), borrowAmountUsd);

        // Repay
        lendingPool.repayUSD(borrowAmountUsd);
        assertEq(lendingPool.borrows(user), 0);

        // Withdraw
        lendingPool.withdrawRWA(rwaAmount);
        assertEq(lendingPool.deposits(user, address(rwaToken)), 0);
        assertEq(rwaToken.balanceOf(user), rwaAmount);
        vm.stopPrank();
    }

    /// @notice 部署后 Perp 流程：开仓 -> 平仓 / Post-deploy perp flow: open -> close
    function test_PostDeployPerpFlow() public {
        _deployAll();
        address user = address(0x2);
        uint256 collateralAmount = 200 * 1e18;
        uint256 size = 1000 * 1e18;

        vm.startPrank(deployer);
        rwaToken.mint(user, 10_000 * 1e18);
        vm.stopPrank();

        vm.startPrank(user);
        rwaToken.approve(address(lendingPool), type(uint256).max);
        lendingPool.depositRWA(500 * 1e18);
        aRWA.approve(address(perpEngine), type(uint256).max);

        perpEngine.openPosition(PerpEngine.PositionSide.LONG, size, collateralAmount);
        (, uint256 openSize,,,,) = perpEngine.positions(user);
        assertTrue(openSize > 0);

        perpEngine.closePosition(0); // close all
        (, uint256 closeSize,,,,) = perpEngine.positions(user);
        assertEq(closeSize, 0);
        vm.stopPrank();
    }
}
