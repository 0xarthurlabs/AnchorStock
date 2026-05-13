// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployScript} from "../script/Deploy.s.sol";

contract DeploymentArtifactTest is Test {
    function test_DeployScriptCanRunWithArtifactWriteDisabled() public {
        // In forge test sandbox, write access can be restricted; ensure script can still run.
        vm.setEnv("PRIVATE_KEY", "0x59c6995e998f97a5a0044966f094538b2920f8e2d2f1b0dff78eaefddc6f8d39"); // anvil #1
        vm.setEnv("WRITE_DEPLOYMENT_ARTIFACT", "false");

        DeployScript s = new DeployScript();
        s.run();

        assertTrue(s.oracle() != address(0));
        assertTrue(s.lendingPool() != address(0));
        assertTrue(s.perpEngine() != address(0));
    }
}

