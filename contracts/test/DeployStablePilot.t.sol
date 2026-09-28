// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {StablePilotRegistry} from "../StablePilotRegistry.sol";
import {PrivatePayroll} from "../PrivatePayroll.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {DeployStablePilot} from "../script/DeployStablePilot.s.sol";

/// @notice Exercises the fresh-deployment script locally (no RPC, nothing broadcast to any network).
contract DeployStablePilotTest is Test {
    address internal constant USER_WALLET = 0x65831439CFCa8559148D2DA4B03c4d745d00E1A0;

    DeployStablePilot internal script;
    MockERC20 internal usdc;

    function setUp() public {
        script = new DeployStablePilot();
        usdc = new MockERC20("USD Coin", "USDC", 6);
    }

    function _cfg() internal view returns (DeployStablePilot.Config memory cfg) {
        cfg = DeployStablePilot.Config({
            usdc: address(usdc),
            treasury: USER_WALLET,
            payrollOwner: USER_WALLET,
            finalOwner: USER_WALLET,
            feeBps: 10,
            feesEnabled: true,
            expectedChainId: block.chainid
        });
    }

    function _setGoodEnv() internal {
        vm.setEnv("SP_USDC_ADDRESS", vm.toString(address(usdc)));
        vm.setEnv("SP_EXPECTED_CHAIN_ID", vm.toString(block.chainid));
        vm.setEnv("SP_FINAL_OWNER", vm.toString(makeAddr("finalOwner")));
        vm.setEnv("SP_TREASURY", vm.toString(makeAddr("treasury")));
        vm.setEnv("SP_PAYROLL_OWNER", vm.toString(makeAddr("payrollOwner")));
        vm.setEnv("SP_FEE_BPS", "25");
        vm.setEnv("SP_FEES_ENABLED", "true");
    }

    /// Single env test on purpose: env vars are process-global and tests run in parallel.
    function test_Run_DefaultsAndEnvOverrides() public {
        // Defaults (no SP_* vars set yet): Arc Testnet, user wallet owns everything, 10 bps, fees on.
        DeployStablePilot.Config memory d = script.configFromEnv();
        assertEq(d.usdc, 0x3600000000000000000000000000000000000000);
        assertEq(d.expectedChainId, 5042002);
        assertEq(d.finalOwner, USER_WALLET);
        assertEq(d.treasury, USER_WALLET);
        assertEq(d.payrollOwner, USER_WALLET);
        assertEq(d.feeBps, 10);
        assertTrue(d.feesEnabled);

        // Defaults refuse to run off Arc Testnet.
        vm.expectRevert("DeployStablePilot: unexpected chain id");
        script.run();

        _setGoodEnv();
        (StablePilotRegistry registry, PrivatePayroll payroll) = script.run();
        assertEq(address(registry.usdc()), address(usdc));
        assertEq(registry.treasury(), makeAddr("treasury"));
        assertEq(registry.owner(), DEFAULT_SENDER);
        assertEq(registry.pendingOwner(), makeAddr("finalOwner"));
        assertEq(registry.feeRateBps(0), 25);
        assertTrue(registry.feesEnabled());
        assertTrue(registry.isModule(address(payroll)));
        assertEq(payroll.owner(), makeAddr("payrollOwner"));
        assertEq(address(payroll.registry()), address(registry));

        vm.setEnv("SP_FEE_BPS", "501");
        vm.expectRevert("DeployStablePilot: SP_FEE_BPS > 500");
        script.run();

        _setGoodEnv();
        vm.setEnv("SP_EXPECTED_CHAIN_ID", "5042002");
        vm.expectRevert("DeployStablePilot: unexpected chain id");
        script.run();

        _setGoodEnv();
        vm.setEnv("SP_USDC_ADDRESS", vm.toString(makeAddr("noCode")));
        vm.expectRevert("DeployStablePilot: usdc has no code");
        script.run();

        _setGoodEnv();
        MockERC20 wrongDecimals = new MockERC20("Wrapped Ether", "WETH", 18);
        vm.setEnv("SP_USDC_ADDRESS", vm.toString(address(wrongDecimals)));
        vm.expectRevert("DeployStablePilot: usdc decimals != 6");
        script.run();

        _setGoodEnv();
        vm.setEnv("SP_FEES_ENABLED", "false");
        (registry,) = script.run();
        assertFalse(registry.feesEnabled());
    }

    function test_Deploy_WiresEverythingAndHandsOffOwnership() public {
        (StablePilotRegistry registry, PrivatePayroll payroll) = script.deploy(_cfg());

        // Registry: new, user is treasury, deployer is owner until the user accepts (Ownable2Step).
        assertEq(address(registry.usdc()), address(usdc));
        assertEq(registry.treasury(), USER_WALLET);
        assertEq(registry.owner(), DEFAULT_SENDER);
        assertEq(registry.pendingOwner(), USER_WALLET);
        assertTrue(registry.isModule(address(payroll)));
        assertEq(registry.registeredModuleId(address(payroll)), registry.MODULE_PAYROLL());
        assertEq(registry.feeRateBps(0), 10);
        assertTrue(registry.feesEnabled());

        // Payroll: owned by the user from construction, no pending transfer.
        assertEq(payroll.owner(), USER_WALLET);
        assertEq(payroll.pendingOwner(), address(0));
        assertEq(address(payroll.registry()), address(registry));
        assertEq(address(payroll.usdc()), address(usdc));

        // Only the pending owner can accept; afterwards the deployer has no rights left.
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("stranger")));
        registry.acceptOwnership();

        vm.prank(USER_WALLET);
        registry.acceptOwnership();
        assertEq(registry.owner(), USER_WALLET);
        assertEq(registry.pendingOwner(), address(0));

        vm.prank(DEFAULT_SENDER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, DEFAULT_SENDER));
        registry.setFeeRate(0, 500);

        // End to end: funding a period charges 10 bps to the user's treasury.
        address employer = makeAddr("employer");
        usdc.mint(employer, 20_000e6);
        vm.startPrank(employer);
        usdc.approve(address(payroll), type(uint256).max);
        usdc.approve(address(registry), type(uint256).max);
        uint256 pid = payroll.createPayroll();
        payroll.deposit(pid, 10_000e6);
        (, uint256 fee) =
            payroll.fundPeriod(pid, keccak256("root"), 10_000e6, uint64(block.timestamp + payroll.MIN_CLAIM_WINDOW()));
        vm.stopPrank();
        assertEq(fee, 10e6);
        assertEq(usdc.balanceOf(USER_WALLET), 10e6);
    }

    function test_Deploy_FinalOwnerIsDeployer_SkipsHandoff() public {
        DeployStablePilot.Config memory cfg = _cfg();
        cfg.finalOwner = DEFAULT_SENDER;
        (StablePilotRegistry registry,) = script.deploy(cfg);
        assertEq(registry.owner(), DEFAULT_SENDER);
        assertEq(registry.pendingOwner(), address(0));
    }

    function test_Deploy_RevertsOnZeroAddresses() public {
        DeployStablePilot.Config memory cfg = _cfg();
        cfg.finalOwner = address(0);
        vm.expectRevert("DeployStablePilot: final owner is zero");
        script.deploy(cfg);

        cfg = _cfg();
        cfg.treasury = address(0);
        vm.expectRevert("DeployStablePilot: treasury is zero");
        script.deploy(cfg);

        cfg = _cfg();
        cfg.payrollOwner = address(0);
        vm.expectRevert("DeployStablePilot: payroll owner is zero");
        script.deploy(cfg);
    }
}
