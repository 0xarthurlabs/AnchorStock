// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {USStockRWA} from "../src/tokens/USStockRWA.sol";

/**
 * @title MintRWA
 * @notice Owner 给指定地址铸造 USStockRWA，用户才能 depositRWA。
 *
 * 环境变量（可全部放在 contracts/.env，forge script 会自动加载）：
 *   PRIVATE_KEY    - USStockRWA 的 owner 私钥（必填）
 *   RWA_TOKEN      - USStockRWA 合约地址（必填，也可用 scripts/mint-rwa.ps1 从 broadcast 自动带出）
 *   MINT_TO        - 接收 RWA 的地址（必填）
 *   MINT_AMOUNT    - 数量，默认 1000 表示 1000 * 1e18（可选）
 *
 * Linux/macOS:
 *   cd contracts && forge script script/MintRWA.s.sol:MintRWA --rpc-url $RPC_URL --broadcast
 *
 * Windows PowerShell（不用 .env 时）:
 *   cd contracts; $env:PRIVATE_KEY="..."; $env:RWA_TOKEN="0x..."; $env:MINT_TO="0x..."; forge script script/MintRWA.s.sol:MintRWA --rpc-url https://... --broadcast
 * 或：把 PRIVATE_KEY、RWA_TOKEN、MINT_TO 写在 contracts/.env 里，然后直接：
 *   forge script script/MintRWA.s.sol:MintRWA --rpc-url https://sei-testnet.g.alchemy.com/v2/... --broadcast
 *
 * 若出现 [out of gas]：--gas-limit 只影响本地模拟，广播时 Forge 仍用 RPC 估算值（约 106529），
 * 在 Sei 上不够。脚本里已对 mint 调用写死 gas: 500000，广播会按此发送；仍不够可改为 800000。
 * 脚本路径中的 :MintRWA 表示「使用该文件里的 MintRWA 合约」；forge 约定为 文件名:合约名。
 *
 * broadcast 目录：按「脚本名/链 ID」分子目录，例如 broadcast/Deploy.s.sol/1328/（1328 = Sei testnet），
 * 不是按网络名字分，和 Hardhat 的 networks.seitestnet 不同。run-latest.json 里可查到部署的合约地址。
 */
contract MintRWA is Script {
    function run() external {
        address rwaToken = vm.parseAddress(vm.envString("RWA_TOKEN"));
        address mintTo = vm.parseAddress(vm.envString("MINT_TO"));
        uint256 amount = vm.envOr("MINT_AMOUNT", uint256(1000)) * 1e18; // 默认 1000 RWA / default 1000 RWA

        string memory pkStr = vm.envString("PRIVATE_KEY");
        uint256 pk;
        bytes memory pkBytes = bytes(pkStr);
        if (pkBytes.length >= 2 && pkBytes[0] == "0" && pkBytes[1] == "x") {
            pk = vm.parseUint(pkStr);
        } else {
            pk = vm.parseUint(string.concat("0x", pkStr));
        }
        address owner = vm.addr(pk);

        USStockRWA rwa = USStockRWA(rwaToken);
        require(rwa.owner() == owner, "MintRWA: PRIVATE_KEY is not the owner of RWA_TOKEN");

        vm.startBroadcast(pk);
        // 显式指定 gas，否则 Forge 广播时用 RPC 估算（Sei 上约 106529）会 out of gas
        rwa.mint{gas: 500000}(mintTo, amount);
        vm.stopBroadcast();

        console.log("Minted", amount / 1e18, "RWA to", mintTo);
    }
}
