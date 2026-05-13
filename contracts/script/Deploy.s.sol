// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {StockOracle} from "../src/StockOracle.sol";
import {USStockRWA} from "../src/tokens/USStockRWA.sol";
import {MockUSD} from "../src/tokens/MockUSD.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {PerpEngine} from "../src/PerpEngine.sol";
import {MockPyth} from "../src/mocks/MockPyth.sol";

/**
 * @title DeployScript
 * @notice 部署所有合约的脚本 / Script to deploy all contracts
 * @dev 部署顺序：MockPyth -> StockOracle -> USStockRWA -> MockUSD -> LendingPool -> PerpEngine
 *      Deployment order: MockPyth -> StockOracle -> USStockRWA -> MockUSD -> LendingPool -> PerpEngine
 *
 * ============ 部署步骤 / Deployment Steps ============
 *
 * 1) 准备环境 / Prepare environment
 *    - 在 contracts 目录下创建 .env（或设置环境变量）/ Create .env under contracts/ or set env vars
 *    - 必须设置 PRIVATE_KEY（部署者钱包私钥，可带或不带 0x 前缀）
 *      Must set PRIVATE_KEY (deployer wallet private key, with or without 0x prefix)
 *    - 可选：ETH_RPC_URL 或 foundry.toml 中的 eth_rpc_url（若不通过 --rpc-url 传入）
 *      Optional: ETH_RPC_URL or eth_rpc_url in foundry.toml (if not passing --rpc-url)
 *
 * 2) 仅模拟、不发送交易（检查脚本是否正常）/ Dry run only (no broadcast)
 *    cd contracts
 *    forge script script/Deploy.s.sol:DeployScript --rpc-url <RPC_URL>
 *    例如 Sei 测试网 / e.g. Sei testnet:
 *    forge script script/Deploy.s.sol:DeployScript --rpc-url https://sei-testnet.g.alchemy.com/v2/YOUR_KEY
 *
 * 3) 正式部署并广播交易 / Deploy and broadcast
 *    forge script script/Deploy.s.sol:DeployScript --rpc-url <RPC_URL> --broadcast --chain-id <CHAIN_ID>
 *    Sei 测试网（建议加 --gas-estimate-multiplier 150 避免 RPC 估算不足）/ Sei testnet (add --gas-estimate-multiplier 150 if needed):
 *    forge script script/Deploy.s.sol:DeployScript --rpc-url https://sei-testnet.g.alchemy.com/v2/YOUR_KEY --broadcast --chain-id 1328 --gas-estimate-multiplier 150
 *
 * 注意 / Note: --gas-limit 仅对本地模拟有效；测试网/主网广播时：
 * - 部署（new）无法在脚本内指定 gas，请使用 --gas-estimate-multiplier 150 或 200 提高估算值；
 * - 部署后的调用（updatePrice、mint）在脚本内用 CALL_GAS 写死，广播会按此发送。
 * --gas-limit only affects local simulation; when broadcasting: deployment (new) cannot set gas in script, use --gas-estimate-multiplier 150 or 200; post-deploy calls use CALL_GAS.
 *
 * 4) 部署结果 / After deployment
 *    - 合约地址会写入 broadcast/Deploy.s.sol/<chainId>/run-latest.json
 *      Contract addresses are written to broadcast/Deploy.s.sol/<chainId>/run-latest.json
 *    - 若 WRITE_DEPLOYMENT_ARTIFACT 为 true（默认）：再写入 deployments/<DEPLOY_ENV>/<chainId>.json
 *      （ORACLE、LENDING_POOL、… 供协调发布 / 前端加载；DEPLOY_ENV、CHAIN_ID 由 CI 注入）
 *    - 将输出的 MockPyth、StockOracle、USStockRWA、MockUSD、LendingPool、aToken、PerpEngine 地址填入前端 .env
 *      Copy MockPyth, StockOracle, USStockRWA, MockUSD, LendingPool, aToken, PerpEngine addresses to frontend .env
 *    - 可选：运行 Verify.s.sol 生成区块浏览器验证命令 / Optional: run Verify.s.sol to get verification commands
 *    - 给用户铸造 RWA：使用 MintRWA.s.sol 或 scripts/mint-rwa.ps1
 *      To mint RWA for users: use MintRWA.s.sol or scripts/mint-rwa.ps1
 */
contract DeployScript is Script {
    // 部署的合约地址 / Deployed contract addresses
    address public mockPyth;
    address public oracle;
    address public rwaToken;
    address public usdToken;
    address public lendingPool;
    address public aToken;
    address public perpEngine;

    // 配置参数 / Configuration parameters
    string constant STOCK_SYMBOL = "NVDA";
    address constant OWNER = address(0x1); // 部署者地址，实际部署时会使用 msg.sender / Deployer address, will use msg.sender in actual deployment

    /// 部署后调用的 gas 上限（如 updatePrice、mint）；广播时生效
    /// Gas limit for post-deploy calls (updatePrice, mint); used when broadcasting
    uint256 constant CALL_GAS = 500_000;

    address constant ANVIL_DEFAULT = address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);
    uint256 constant LOCAL_CHAIN_ID = 31337;

    function run() external {
        // 读取私钥，支持带或不带 0x 前缀 / Read private key, support with or without 0x prefix
        string memory privateKeyStr = vm.envString("PRIVATE_KEY");
        uint256 deployerPrivateKey;

        // 检查是否有 0x 前缀 / Check if has 0x prefix
        bytes memory privateKeyBytes = bytes(privateKeyStr);
        if (privateKeyBytes.length >= 2 && privateKeyBytes[0] == bytes1("0") && privateKeyBytes[1] == bytes1("x")) {
            deployerPrivateKey = vm.parseUint(privateKeyStr);
        } else {
            // 如果没有 0x 前缀，添加它 / If no 0x prefix, add it
            string memory prefixedKey = string.concat("0x", privateKeyStr);
            deployerPrivateKey = vm.parseUint(prefixedKey);
        }

        address deployer = vm.addr(deployerPrivateKey);

        // 非本地链时禁止使用 Anvil 默认私钥，避免误用（本地 anvil 链 id 31337 允许默认账户方便测试）
        // On non-local chains, reject Anvil default key to avoid misuse; on local chain (31337) allow it for testing
        require(
            deployer != ANVIL_DEFAULT || block.chainid == LOCAL_CHAIN_ID,
            "DeployScript: PRIVATE_KEY not set or wrong. Put PRIVATE_KEY in contracts/.env (not repo root). 0xf39Fd... is Anvil default."
        );

        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying contracts...", deployer);

        // 1. 部署 MockPyth（用于测试，生产环境应使用真实的 Pyth 合约）/ Deploy MockPyth (for testing, use real Pyth contract in production)
        console.log("\n1. Deploying MockPyth...");
        MockPyth mockPythContract = new MockPyth();
        mockPyth = address(mockPythContract);
        console.log("MockPyth deployed at:", mockPyth);

        // 2. 部署 StockOracle / Deploy StockOracle
        console.log("\n2. Deploying StockOracle...");
        StockOracle oracleContract = new StockOracle(mockPyth, deployer);
        oracle = address(oracleContract);
        console.log("StockOracle deployed at:", oracle);

        // 设置初始价格（可选）/ Set initial price (optional)
        oracleContract.updatePrice{gas: CALL_GAS}(STOCK_SYMBOL, 150 * 1e8); // $150 with 8 decimals
        console.log("Initial price set:", STOCK_SYMBOL, "= $150");

        // 3. 部署 USStockRWA / Deploy USStockRWA
        console.log("\n3. Deploying USStockRWA...");
        USStockRWA rwaTokenContract = new USStockRWA("NVIDIA RWA", "NVDA", deployer);
        rwaToken = address(rwaTokenContract);
        console.log("USStockRWA deployed at:", rwaToken);

        // 4. 部署 MockUSD / Deploy MockUSD
        console.log("\n4. Deploying MockUSD...");
        MockUSD usdTokenContract = new MockUSD(deployer);
        usdToken = address(usdTokenContract);
        console.log("MockUSD deployed at:", usdToken);

        // 5. 部署 LendingPool / Deploy LendingPool
        console.log("\n5. Deploying LendingPool...");
        LendingPool lendingPoolContract = new LendingPool(rwaToken, usdToken, oracle, STOCK_SYMBOL, deployer);
        lendingPool = address(lendingPoolContract);
        console.log("LendingPool deployed at:", lendingPool);

        // 获取 aToken 地址 / Get aToken address
        aToken = lendingPoolContract.aTokens(rwaToken);
        console.log("aToken deployed at:", aToken);

        // 6. 部署 PerpEngine / Deploy PerpEngine
        console.log("\n6. Deploying PerpEngine...");
        PerpEngine perpEngineContract = new PerpEngine(oracle, STOCK_SYMBOL, aToken, deployer);
        perpEngine = address(perpEngineContract);
        console.log("PerpEngine deployed at:", perpEngine);

        // 7. 给 LendingPool 铸造一些 USD（用于借出）/ Mint some USD to LendingPool (for lending)
        console.log("\n7. Minting USD to LendingPool...");
        usdTokenContract.mint{gas: CALL_GAS}(lendingPool, 10_000_000 * 1e6); // 10M USD
        console.log("Minted 10M USD to LendingPool");

        vm.stopBroadcast();

        // 链下消费的 deployments JSON（与 contracts-testnet-deploy / coordinated 工作流一致）
        bool writeArtifact = vm.envOr("WRITE_DEPLOYMENT_ARTIFACT", true);
        if (writeArtifact) {
            string memory deployEnv = vm.envOr("DEPLOY_ENV", string("dev"));
            string memory dir = string.concat("deployments/", deployEnv);
            vm.createDir(dir, true);
            string memory out = string.concat(dir, "/", vm.toString(block.chainid), ".json");
            string memory root = "artifact";
            root = vm.serializeString(root, "env", deployEnv);
            root = vm.serializeUint(root, "chainId", block.chainid);
            root = vm.serializeAddress(root, "ORACLE", oracle);
            root = vm.serializeAddress(root, "LENDING_POOL", lendingPool);
            root = vm.serializeAddress(root, "PERP_ENGINE", perpEngine);
            root = vm.serializeAddress(root, "RWA_TOKEN", rwaToken);
            root = vm.serializeAddress(root, "USD_TOKEN", usdToken);
            root = vm.serializeAddress(root, "A_TOKEN", aToken);
            vm.writeJson(root, out);
            console.log("Deployment artifact:", out);
        }

        // 输出部署结果 / Output deployment results
        console.log("\n=== Deployment Summary ===");
        console.log("MockPyth:", mockPyth);
        console.log("StockOracle:", oracle);
        console.log("USStockRWA:", rwaToken);
        console.log("MockUSD:", usdToken);
        console.log("LendingPool:", lendingPool);
        console.log("aToken:", aToken);
        console.log("PerpEngine:", perpEngine);
        console.log("\nSave these addresses to your .env file!");
    }
}
