// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

/**
 * @title VerifyScript
 * @author AnchorStock
 * @notice 合约验证脚本：在区块浏览器上验证已部署合约源码
 *         Contract verification script: verify deployed contract source on block explorer
 * @dev 使用 forge verify-contract 进行验证。需配置 ETHERSCAN_API_KEY 或对应链的 API Key。
 *      Use forge verify-contract for verification. Set ETHERSCAN_API_KEY or chain-specific API key.
 *
 * 用法 / Usage:
 *   forge script script/Verify.s.sol:VerifyScript --rpc-url $RPC_URL -vvvv
 *
 * 或逐条验证 / Or verify one by one:
 *   forge verify-contract <CONTRACT_ADDRESS> <CONTRACT_PATH>:<CONTRACT_NAME> --chain-id <CHAIN_ID> --watch
 *
 * Sei 测试网示例 / Sei testnet example:
 *   forge verify-contract 0x... src/StockOracle.sol:StockOracle --chain-id 1328 --watch
 */
contract VerifyScript is Script {
    function run() external view {
        // 从环境变量读取已部署地址（与 Deploy.s.sol 输出一致）
        // Read deployed addresses from env (same as Deploy.s.sol output)
        address mockPyth = vm.envOr("MOCK_PYTH_ADDRESS", address(0));
        address oracle = vm.envOr("ORACLE_ADDRESS", address(0));
        address rwaToken = vm.envOr("RWA_TOKEN_ADDRESS", address(0));
        address usdToken = vm.envOr("USD_TOKEN_ADDRESS", address(0));
        address lendingPool = vm.envOr("LENDING_POOL_ADDRESS", address(0));
        address aToken = vm.envOr("ATOKEN_ADDRESS", address(0));
        address perpEngine = vm.envOr("PERP_ENGINE_ADDRESS", address(0));

        console.log("=== Contract Verification Guide ===");
        console.log("Run the following commands (replace <CHAIN_ID> with your chain, e.g. 1328 for Sei testnet):");
        console.log("");
        if (mockPyth != address(0)) {
            console.log("forge verify-contract", mockPyth, "src/mocks/MockPyth.sol:MockPyth --chain-id <CHAIN_ID> --watch");
        }
        if (oracle != address(0)) {
            console.log("forge verify-contract", oracle, "src/StockOracle.sol:StockOracle --chain-id <CHAIN_ID> --watch");
        }
        if (rwaToken != address(0)) {
            console.log("forge verify-contract", rwaToken, "src/tokens/USStockRWA.sol:USStockRWA --chain-id <CHAIN_ID> --watch");
        }
        if (usdToken != address(0)) {
            console.log("forge verify-contract", usdToken, "src/tokens/MockUSD.sol:MockUSD --chain-id <CHAIN_ID> --watch");
        }
        if (lendingPool != address(0)) {
            console.log("forge verify-contract", lendingPool, "src/LendingPool.sol:LendingPool --chain-id <CHAIN_ID> --watch");
        }
        if (aToken != address(0)) {
            console.log("forge verify-contract", aToken, "src/tokens/aToken.sol:aToken --chain-id <CHAIN_ID> --watch");
        }
        if (perpEngine != address(0)) {
            console.log("forge verify-contract", perpEngine, "src/PerpEngine.sol:PerpEngine --chain-id <CHAIN_ID> --watch");
        }
        console.log("");
        console.log("Set ETHERSCAN_API_KEY or block explorer API key in .env before running.");
        console.log("Sei: use --verifier blockscout or chain-specific verifier if supported.");
    }
}
