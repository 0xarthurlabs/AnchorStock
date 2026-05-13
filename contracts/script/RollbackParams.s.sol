// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {PerpEngine} from "../src/PerpEngine.sol";
import {StockOracle} from "../src/StockOracle.sol";

/**
 * @notice dev/staging 回滚演练：读取旧 deployment artifact，生成“恢复旧参数”的 calldata（不广播）。
 *
 * 约定（全部在 contracts/.env 或 CI env）：
 * - DEPLOY_ENV: dev|staging|...（默认 dev）
 * - CHAIN_ID:   可选；默认使用当前 block.chainid
 *
 * 用法示例（不广播，仅输出 calldata）：
 *   cd contracts
 *   forge script script/RollbackParams.s.sol:RollbackParams --sig "run(address)" <GOVERNANCE_OWNER>
 *
 * 注意：本项目当前合约不是代理升级模型；“回滚”在测试网/预发布网以“恢复旧参数”为主。
 * 主网回滚必须走 Safe/时间锁/硬件钱包链外流程，CI 不负责执行写交易。
 */
contract RollbackParams is Script {
    function _emitOracleCalldata(StockOracle oracle, string memory json) internal view {
        uint256 stale = vm.parseJsonUint(json, "$.params.oracle.stalePriceThreshold");
        bool cb = vm.parseJsonBool(json, "$.params.oracle.circuitBreakerEnabled");
        uint256 strategy = vm.parseJsonUint(json, "$.params.oracle.oracleStrategy");

        console2.log("\n[StockOracle] setStalePriceThreshold(uint256)");
        console2.logBytes(abi.encodeCall(oracle.setStalePriceThreshold, (stale)));

        console2.log("[StockOracle] setCircuitBreaker(bool)");
        console2.logBytes(abi.encodeCall(oracle.setCircuitBreaker, (cb)));

        console2.log("[StockOracle] setOracleStrategy(uint8)");
        console2.logBytes(abi.encodeCall(oracle.setOracleStrategy, (StockOracle.OracleStrategy(strategy))));
    }

    function _emitPoolCalldata(LendingPool pool, string memory json) internal view {
        console2.log("\n[LendingPool] setDepositRate(uint256)");
        console2.logBytes(
            abi.encodeCall(pool.setDepositRate, (vm.parseJsonUint(json, "$.params.lendingPool.depositRate")))
        );

        console2.log("[LendingPool] setBorrowRate(uint256)");
        console2.logBytes(
            abi.encodeCall(pool.setBorrowRate, (vm.parseJsonUint(json, "$.params.lendingPool.borrowRate")))
        );

        console2.log("[LendingPool] setLTV(uint256)");
        console2.logBytes(abi.encodeCall(pool.setLTV, (vm.parseJsonUint(json, "$.params.lendingPool.ltv"))));

        console2.log("[LendingPool] setLiquidationThreshold(uint256)");
        console2.logBytes(
            abi.encodeCall(
                pool.setLiquidationThreshold, (vm.parseJsonUint(json, "$.params.lendingPool.liquidationThreshold"))
            )
        );

        console2.log("[LendingPool] setLiquidationBonusRate(uint256)");
        console2.logBytes(
            abi.encodeCall(
                pool.setLiquidationBonusRate, (vm.parseJsonUint(json, "$.params.lendingPool.liquidationBonusRate"))
            )
        );
    }

    function _emitPerpCalldata(PerpEngine perp, string memory json) internal view {
        console2.log("\n[PerpEngine] setInitialMarginRate(uint256)");
        console2.logBytes(
            abi.encodeCall(perp.setInitialMarginRate, (vm.parseJsonUint(json, "$.params.perp.initialMarginRate")))
        );

        console2.log("[PerpEngine] setMaintenanceMarginRate(uint256)");
        console2.logBytes(
            abi.encodeCall(
                perp.setMaintenanceMarginRate, (vm.parseJsonUint(json, "$.params.perp.maintenanceMarginRate"))
            )
        );

        console2.log("[PerpEngine] setFundingRate(uint256)");
        console2.logBytes(abi.encodeCall(perp.setFundingRate, (vm.parseJsonUint(json, "$.params.perp.fundingRate"))));

        console2.log("[PerpEngine] setFundingInterval(uint256)");
        console2.logBytes(
            abi.encodeCall(perp.setFundingInterval, (vm.parseJsonUint(json, "$.params.perp.fundingInterval")))
        );

        console2.log("[PerpEngine] setLiquidationBonusRate(uint256)");
        console2.logBytes(
            abi.encodeCall(perp.setLiquidationBonusRate, (vm.parseJsonUint(json, "$.params.perp.liquidationBonusRate")))
        );
    }

    function run(address governanceOwner) external view {
        string memory deployEnv = vm.envOr("DEPLOY_ENV", string("dev"));
        uint256 chainId = vm.envOr("CHAIN_ID", block.chainid);
        string memory artifactPath = string.concat("deployments/", deployEnv, "/", vm.toString(chainId), ".json");

        string memory json = vm.readFile(artifactPath);

        address oracleAddr = vm.parseJsonAddress(json, "$.contracts.StockOracle.address");
        address poolAddr = vm.parseJsonAddress(json, "$.contracts.LendingPool.address");
        address perpAddr = vm.parseJsonAddress(json, "$.contracts.PerpEngine.address");

        // Read current onchain params for comparison (optional log)
        StockOracle oracle = StockOracle(oracleAddr);
        LendingPool pool = LendingPool(poolAddr);
        PerpEngine perp = PerpEngine(perpAddr);

        console2.log("=== Rollback (restore params) calldata ===");
        console2.log("artifact:", artifactPath);
        console2.log("governanceOwner:", governanceOwner);
        console2.log("oracle:", oracleAddr);
        console2.log("pool:", poolAddr);
        console2.log("perp:", perpAddr);

        _emitOracleCalldata(oracle, json);
        _emitPoolCalldata(pool, json);
        _emitPerpCalldata(perp, json);

        console2.log("\nNOTE: execute via Safe/timelock/hardware wallet on-chain. CI must not broadcast mainnet tx.");
        console2.log("Current onchain snapshot (for reference only):");
        console2.log("oracle.stalePriceThreshold", oracle.stalePriceThreshold());
        console2.log("oracle.circuitBreakerEnabled", oracle.circuitBreakerEnabled());
        console2.log("oracle.oracleStrategy", uint256(oracle.oracleStrategy()));
        console2.log("pool.depositRate", pool.depositRate());
        console2.log("pool.borrowRate", pool.borrowRate());
        console2.log("pool.ltv", pool.ltv());
        console2.log("pool.liquidationThreshold", pool.liquidationThreshold());
        console2.log("pool.liquidationBonusRate", pool.liquidationBonusRate());
        console2.log("perp.initialMarginRate", perp.initialMarginRate());
        console2.log("perp.maintenanceMarginRate", perp.maintenanceMarginRate());
        console2.log("perp.fundingRate", perp.fundingRate());
        console2.log("perp.fundingInterval", perp.fundingInterval());
        console2.log("perp.liquidationBonusRate", perp.liquidationBonusRate());
    }
}

