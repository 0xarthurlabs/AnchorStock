// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";

library DeploymentArtifact {
    struct CompilerSummary {
        string solcVersion;
        bool optimizerEnabled;
        uint256 optimizerRuns;
    }

    struct DeploymentSummary {
        string env;
        uint256 chainId;
        string gitCommit;
        uint256 deployedAt;
        CompilerSummary compiler;
    }

    struct ParamsSnapshot {
        // StockOracle
        uint256 oracleStalePriceThreshold;
        bool oracleCircuitBreakerEnabled;
        uint256 oracleStrategy; // uint8 casted to uint256 for JSON

        // LendingPool
        uint256 poolDepositRate;
        uint256 poolBorrowRate;
        uint256 poolLtv;
        uint256 poolLiquidationThreshold;
        uint256 poolLiquidationBonusRate;

        // PerpEngine
        uint256 perpInitialMarginRate;
        uint256 perpMaintenanceMarginRate;
        uint256 perpFundingRate;
        uint256 perpFundingInterval;
        uint256 perpLiquidationBonusRate;
    }

    function _envOrEmpty(Vm vm_, string memory key) private view returns (string memory) {
        return vm_.envOr(key, string(""));
    }

    function _envOrBool(Vm vm_, string memory key, bool def) private view returns (bool) {
        return vm_.envOr(key, def);
    }

    function _envOrUint(Vm vm_, string memory key, uint256 def) private view returns (uint256) {
        return vm_.envOr(key, def);
    }

    function summary(Vm vm_, string memory deployEnv) internal view returns (DeploymentSummary memory s) {
        s.env = deployEnv;
        s.chainId = block.chainid;
        s.gitCommit = _envOrEmpty(vm_, "GIT_COMMIT");
        s.deployedAt = block.timestamp;
        s.compiler = CompilerSummary({
            solcVersion: _envOrEmpty(vm_, "SOLC_VERSION"),
            optimizerEnabled: _envOrBool(vm_, "OPTIMIZER_ENABLED", true),
            optimizerRuns: _envOrUint(vm_, "OPTIMIZER_RUNS", 200)
        });
    }

    function _serializeSummary(Vm vm_, string memory root, DeploymentSummary memory s) private returns (string memory) {
        string memory o = root;
        o = vm_.serializeString(o, "env", s.env);
        o = vm_.serializeUint(o, "chainId", s.chainId);
        o = vm_.serializeString(o, "gitCommit", s.gitCommit);
        o = vm_.serializeUint(o, "deployedAt", s.deployedAt);

        string memory c = "compiler";
        c = vm_.serializeString(c, "solcVersion", s.compiler.solcVersion);
        c = vm_.serializeBool(c, "optimizerEnabled", s.compiler.optimizerEnabled);
        c = vm_.serializeUint(c, "optimizerRuns", s.compiler.optimizerRuns);

        return vm_.serializeString(o, "compiler", c);
    }

    function write(
        Vm vm_,
        string memory deployEnv,
        string[] memory contractNames,
        address[] memory contractAddrs,
        string[] memory explorerLinks,
        string memory outPath
    ) internal {
        require(contractNames.length == contractAddrs.length, "DeploymentArtifact: length mismatch");
        require(explorerLinks.length == contractAddrs.length, "DeploymentArtifact: explorer length mismatch");

        DeploymentSummary memory s = summary(vm_, deployEnv);

        string memory root = "root";
        root = _serializeSummary(vm_, root, s);

        // contracts: { name: { address, bytecodeHash, explorer? } }
        string memory contractsObj = "contracts";
        for (uint256 i = 0; i < contractNames.length; i++) {
            string memory item = string.concat("c_", contractNames[i]);
            bytes32 codeHash = contractAddrs[i].codehash;

            item = vm_.serializeAddress(item, "address", contractAddrs[i]);
            item = vm_.serializeBytes32(item, "bytecodeHash", codeHash);
            if (bytes(explorerLinks[i]).length > 0) {
                item = vm_.serializeString(item, "explorer", explorerLinks[i]);
            }

            contractsObj = vm_.serializeString(contractsObj, contractNames[i], item);
        }

        root = vm_.serializeString(root, "contracts", contractsObj);

        vm_.writeJson(root, outPath);
    }

    function writeWithParams(
        Vm vm_,
        string memory deployEnv,
        string[] memory contractNames,
        address[] memory contractAddrs,
        string[] memory explorerLinks,
        ParamsSnapshot memory p,
        string memory outPath
    ) internal {
        require(contractNames.length == contractAddrs.length, "DeploymentArtifact: length mismatch");
        require(explorerLinks.length == contractAddrs.length, "DeploymentArtifact: explorer length mismatch");

        DeploymentSummary memory s = summary(vm_, deployEnv);

        string memory root = "root";
        root = _serializeSummary(vm_, root, s);

        string memory contractsObj = "contracts";
        for (uint256 i = 0; i < contractNames.length; i++) {
            string memory item = string.concat("c_", contractNames[i]);
            bytes32 codeHash = contractAddrs[i].codehash;

            item = vm_.serializeAddress(item, "address", contractAddrs[i]);
            item = vm_.serializeBytes32(item, "bytecodeHash", codeHash);
            if (bytes(explorerLinks[i]).length > 0) {
                item = vm_.serializeString(item, "explorer", explorerLinks[i]);
            }
            contractsObj = vm_.serializeString(contractsObj, contractNames[i], item);
        }
        root = vm_.serializeString(root, "contracts", contractsObj);

        // params snapshot
        string memory params = "params";
        string memory oracle = "oracle";
        oracle = vm_.serializeUint(oracle, "stalePriceThreshold", p.oracleStalePriceThreshold);
        oracle = vm_.serializeBool(oracle, "circuitBreakerEnabled", p.oracleCircuitBreakerEnabled);
        oracle = vm_.serializeUint(oracle, "oracleStrategy", p.oracleStrategy);
        params = vm_.serializeString(params, "oracle", oracle);

        string memory pool = "lendingPool";
        pool = vm_.serializeUint(pool, "depositRate", p.poolDepositRate);
        pool = vm_.serializeUint(pool, "borrowRate", p.poolBorrowRate);
        pool = vm_.serializeUint(pool, "ltv", p.poolLtv);
        pool = vm_.serializeUint(pool, "liquidationThreshold", p.poolLiquidationThreshold);
        pool = vm_.serializeUint(pool, "liquidationBonusRate", p.poolLiquidationBonusRate);
        params = vm_.serializeString(params, "lendingPool", pool);

        string memory perp = "perp";
        perp = vm_.serializeUint(perp, "initialMarginRate", p.perpInitialMarginRate);
        perp = vm_.serializeUint(perp, "maintenanceMarginRate", p.perpMaintenanceMarginRate);
        perp = vm_.serializeUint(perp, "fundingRate", p.perpFundingRate);
        perp = vm_.serializeUint(perp, "fundingInterval", p.perpFundingInterval);
        perp = vm_.serializeUint(perp, "liquidationBonusRate", p.perpLiquidationBonusRate);
        params = vm_.serializeString(params, "perp", perp);

        root = vm_.serializeString(root, "params", params);

        vm_.writeJson(root, outPath);
    }
}

