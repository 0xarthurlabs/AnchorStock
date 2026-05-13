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

    /// @dev 同一 JSON 对象的所有 serialize* 必须使用固定 objectKey；不能把上一行返回值当作 objectKey。
    function _serializeSummary(Vm vm_, string memory rootKey, DeploymentSummary memory s) private {
        vm_.serializeString(rootKey, "env", s.env);
        vm_.serializeUint(rootKey, "chainId", s.chainId);
        vm_.serializeString(rootKey, "gitCommit", s.gitCommit);
        vm_.serializeUint(rootKey, "deployedAt", s.deployedAt);

        string memory compilerKey = "summaryCompiler";
        vm_.serializeString(compilerKey, "solcVersion", s.compiler.solcVersion);
        vm_.serializeBool(compilerKey, "optimizerEnabled", s.compiler.optimizerEnabled);
        string memory compilerJson = vm_.serializeUint(compilerKey, "optimizerRuns", s.compiler.optimizerRuns);
        vm_.serializeString(rootKey, "compiler", compilerJson);
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

        string memory rootKey = "root";
        _serializeSummary(vm_, rootKey, s);

        // contracts: { name: { address, bytecodeHash, explorer? } }
        string memory contractsKey = "contractsAccum";
        string memory contractsJson;
        for (uint256 i = 0; i < contractNames.length; i++) {
            string memory itemKey = string.concat("c_", contractNames[i]);
            bytes32 codeHash = contractAddrs[i].codehash;

            vm_.serializeAddress(itemKey, "address", contractAddrs[i]);
            contractsJson = vm_.serializeBytes32(itemKey, "bytecodeHash", codeHash);
            if (bytes(explorerLinks[i]).length > 0) {
                contractsJson = vm_.serializeString(itemKey, "explorer", explorerLinks[i]);
            }

            contractsJson = vm_.serializeString(contractsKey, contractNames[i], contractsJson);
        }

        string memory out = vm_.serializeString(rootKey, "contracts", contractsJson);
        vm_.writeJson(out, outPath);
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

        string memory rootKey = "root";
        _serializeSummary(vm_, rootKey, s);

        string memory contractsKey = "contractsAccum";
        string memory contractsJson;
        for (uint256 i = 0; i < contractNames.length; i++) {
            string memory itemKey = string.concat("c_", contractNames[i]);
            bytes32 codeHash = contractAddrs[i].codehash;

            vm_.serializeAddress(itemKey, "address", contractAddrs[i]);
            contractsJson = vm_.serializeBytes32(itemKey, "bytecodeHash", codeHash);
            if (bytes(explorerLinks[i]).length > 0) {
                contractsJson = vm_.serializeString(itemKey, "explorer", explorerLinks[i]);
            }
            contractsJson = vm_.serializeString(contractsKey, contractNames[i], contractsJson);
        }
        vm_.serializeString(rootKey, "contracts", contractsJson);

        // params snapshot
        string memory paramsKey = "paramsRoot";
        string memory oracleKey = "paramsOracle";
        vm_.serializeUint(oracleKey, "stalePriceThreshold", p.oracleStalePriceThreshold);
        vm_.serializeBool(oracleKey, "circuitBreakerEnabled", p.oracleCircuitBreakerEnabled);
        string memory oracleJson = vm_.serializeUint(oracleKey, "oracleStrategy", p.oracleStrategy);
        vm_.serializeString(paramsKey, "oracle", oracleJson);

        string memory poolKey = "paramsPool";
        vm_.serializeUint(poolKey, "depositRate", p.poolDepositRate);
        vm_.serializeUint(poolKey, "borrowRate", p.poolBorrowRate);
        vm_.serializeUint(poolKey, "ltv", p.poolLtv);
        vm_.serializeUint(poolKey, "liquidationThreshold", p.poolLiquidationThreshold);
        string memory poolJson = vm_.serializeUint(poolKey, "liquidationBonusRate", p.poolLiquidationBonusRate);
        vm_.serializeString(paramsKey, "lendingPool", poolJson);

        string memory perpKey = "paramsPerp";
        vm_.serializeUint(perpKey, "initialMarginRate", p.perpInitialMarginRate);
        vm_.serializeUint(perpKey, "maintenanceMarginRate", p.perpMaintenanceMarginRate);
        vm_.serializeUint(perpKey, "fundingRate", p.perpFundingRate);
        vm_.serializeUint(perpKey, "fundingInterval", p.perpFundingInterval);
        string memory perpJson = vm_.serializeUint(perpKey, "liquidationBonusRate", p.perpLiquidationBonusRate);
        string memory paramsJson = vm_.serializeString(paramsKey, "perp", perpJson);

        string memory out = vm_.serializeString(rootKey, "params", paramsJson);
        vm_.writeJson(out, outPath);
    }
}

