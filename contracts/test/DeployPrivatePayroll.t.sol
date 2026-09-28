// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StablePilotRegistry} from "../StablePilotRegistry.sol";
import {PrivatePayroll} from "../PrivatePayroll.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {DeployPrivatePayroll} from "../script/DeployPrivatePayroll.s.sol";

/// @notice Exercises the deploy script locally (no RPC, nothing broadcast to any network).
contract DeployPrivatePayrollTest is Test {
    DeployPrivatePayroll internal script;
    StablePilotRegistry internal registry;
    MockERC20 internal usdc;

    function setUp() public {
        script = new DeployPrivatePayroll();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        registry = new StablePilotRegistry(address(usdc), makeAddr("treasury"), makeAddr("regOwner"));
    }

    function _setGoodEnv() internal {
        vm.setEnv("REGISTRY_ADDRESS", vm.toString(address(registry)));
        vm.setEnv("USDC_ADDRESS", vm.toString(address(usdc)));
        vm.setEnv("EXPECTED_CHAIN_ID", vm.toString(block.chainid));
        vm.setEnv("PAYROLL_OWNER", vm.toString(makeAddr("multisig")));
    }

    /// Single test on purpose: env vars are process-global and tests run in parallel.
    function test_Run_DeploysAndValidatesEnv() public {
        _setGoodEnv();
        PrivatePayroll payroll = script.run();
        assertEq(address(payroll.registry()), address(registry));
        assertEq(address(payroll.usdc()), address(usdc));
        assertEq(payroll.owner(), makeAddr("multisig"));

        vm.setEnv("EXPECTED_CHAIN_ID", "5042002");
        vm.expectRevert("DeployPrivatePayroll: unexpected chain id");
        script.run();

        _setGoodEnv();
        vm.setEnv("USDC_ADDRESS", vm.toString(address(0x3600000000000000000000000000000000000000)));
        vm.expectRevert("DeployPrivatePayroll: registry.usdc() != USDC_ADDRESS");
        script.run();

        _setGoodEnv();
        vm.setEnv("REGISTRY_ADDRESS", vm.toString(makeAddr("empty")));
        vm.expectRevert("DeployPrivatePayroll: registry has no code");
        script.run();
    }
}
