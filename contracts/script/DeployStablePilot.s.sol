// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {StablePilotRegistry} from "../StablePilotRegistry.sol";
import {PrivatePayroll} from "../PrivatePayroll.sol";

/// @notice Fresh StablePilot deployment in ONE broadcast: a new StablePilotRegistry + PrivatePayroll,
/// wired together, with ownership handed to SP_FINAL_OWNER. NOT run by CI (only its test is).
///
/// Broadcast sequence (6 txs, all from the broadcaster = temporary registry owner):
///   1. registry = new StablePilotRegistry(usdc, treasury, broadcaster)
///   2. payroll  = new PrivatePayroll(registry, payrollOwner)        // Ownable: owner set directly, no accept needed
///   3. registry.addModule(payroll, MODULE_PAYROLL /* 0 */)
///   4. registry.setFeeRate(MODULE_PAYROLL, feeBps)
///   5. registry.setFeesEnabled(feesEnabled)
///   6. registry.transferOwnership(finalOwner)                      // Ownable2Step: sets pendingOwner only
///      (step 6 is skipped when finalOwner == broadcaster)
///
/// AFTER BROADCAST, finalOwner MUST call `acceptOwnership()` on the REGISTRY to become its owner.
/// Until then the broadcaster remains registry owner.
///
/// Env vars (all optional). Names are prefixed with SP_ so they cannot collide with
/// DeployPrivatePayroll's env vars when both script tests run in parallel (env is process-global):
///   SP_FINAL_OWNER      final owner of registry (2-step) and payroll (default: 0x65831439CFCa8559148D2DA4B03c4d745d00E1A0)
///   SP_TREASURY         registry fee treasury        (default: SP_FINAL_OWNER)
///   SP_PAYROLL_OWNER    PrivatePayroll owner         (default: SP_FINAL_OWNER)
///   SP_USDC_ADDRESS     USDC ERC-20                  (default: Arc Testnet 0x3600000000000000000000000000000000000000, 6 decimals)
///   SP_FEE_BPS          payroll (module 0) fee, bps  (default: 10 = 0.10%; max 500)
///   SP_FEES_ENABLED     global fee switch            (default: true)
///   SP_EXPECTED_CHAIN_ID safety check                (default: 5042002 = Arc Testnet)
///
/// Dry run (simulation only, nothing is sent):
///   forge script contracts/script/DeployStablePilot.s.sol --rpc-url arc_testnet --sender <deployer>
/// Broadcast (deploys!): add `--broadcast` plus a signer (`--account <keystore>` / `--ledger` / `--private-key`).
contract DeployStablePilot is Script {
    address internal constant ARC_TESTNET_USDC = 0x3600000000000000000000000000000000000000;
    uint256 internal constant ARC_TESTNET_CHAIN_ID = 5042002;
    address internal constant DEFAULT_FINAL_OWNER = 0x65831439CFCa8559148D2DA4B03c4d745d00E1A0;
    uint256 internal constant DEFAULT_FEE_BPS = 10;
    uint8 internal constant USDC_DECIMALS = 6;

    struct Config {
        address usdc;
        address treasury;
        address payrollOwner;
        address finalOwner;
        uint16 feeBps;
        bool feesEnabled;
        uint256 expectedChainId;
    }

    function run() external returns (StablePilotRegistry registry, PrivatePayroll payroll) {
        return deploy(configFromEnv());
    }

    function configFromEnv() public view returns (Config memory cfg) {
        cfg.finalOwner = vm.envOr("SP_FINAL_OWNER", DEFAULT_FINAL_OWNER);
        cfg.treasury = vm.envOr("SP_TREASURY", cfg.finalOwner);
        cfg.payrollOwner = vm.envOr("SP_PAYROLL_OWNER", cfg.finalOwner);
        cfg.usdc = vm.envOr("SP_USDC_ADDRESS", ARC_TESTNET_USDC);
        uint256 bps = vm.envOr("SP_FEE_BPS", DEFAULT_FEE_BPS);
        require(bps <= 500, "DeployStablePilot: SP_FEE_BPS > 500");
        // forge-lint: disable-next-line(unsafe-typecast) -- bps <= 500 checked above
        cfg.feeBps = uint16(bps);
        cfg.feesEnabled = vm.envOr("SP_FEES_ENABLED", true);
        cfg.expectedChainId = vm.envOr("SP_EXPECTED_CHAIN_ID", ARC_TESTNET_CHAIN_ID);
    }

    function deploy(Config memory cfg) public returns (StablePilotRegistry registry, PrivatePayroll payroll) {
        require(block.chainid == cfg.expectedChainId, "DeployStablePilot: unexpected chain id");
        require(cfg.finalOwner != address(0), "DeployStablePilot: final owner is zero");
        require(cfg.treasury != address(0), "DeployStablePilot: treasury is zero");
        require(cfg.payrollOwner != address(0), "DeployStablePilot: payroll owner is zero");
        require(cfg.usdc.code.length > 0, "DeployStablePilot: usdc has no code");
        require(_decimals(cfg.usdc) == USDC_DECIMALS, "DeployStablePilot: usdc decimals != 6");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        registry = new StablePilotRegistry(cfg.usdc, cfg.treasury, deployer);
        payroll = new PrivatePayroll(address(registry), cfg.payrollOwner);
        uint8 moduleId = registry.MODULE_PAYROLL();
        registry.addModule(address(payroll), moduleId);
        registry.setFeeRate(moduleId, cfg.feeBps);
        registry.setFeesEnabled(cfg.feesEnabled);
        bool handoff = cfg.finalOwner != deployer;
        if (handoff) registry.transferOwnership(cfg.finalOwner);
        vm.stopBroadcast();

        // Post-conditions (checked in the simulation before anything is broadcast).
        require(address(registry.usdc()) == cfg.usdc, "DeployStablePilot: registry.usdc mismatch");
        require(address(payroll.usdc()) == cfg.usdc, "DeployStablePilot: payroll.usdc mismatch");
        require(address(payroll.registry()) == address(registry), "DeployStablePilot: payroll.registry mismatch");
        require(registry.isModule(address(payroll)), "DeployStablePilot: module not registered");
        require(registry.registeredModuleId(address(payroll)) == moduleId, "DeployStablePilot: module id mismatch");
        require(registry.feeRateBps(moduleId) == cfg.feeBps, "DeployStablePilot: fee rate mismatch");
        require(registry.feesEnabled() == cfg.feesEnabled, "DeployStablePilot: fee switch mismatch");
        require(registry.treasury() == cfg.treasury, "DeployStablePilot: treasury mismatch");
        require(registry.owner() == deployer, "DeployStablePilot: registry owner mismatch");
        require(
            registry.pendingOwner() == (handoff ? cfg.finalOwner : address(0)),
            "DeployStablePilot: registry pendingOwner mismatch"
        );
        require(payroll.owner() == cfg.payrollOwner, "DeployStablePilot: payroll owner mismatch");

        console2.log("chain id:               ", block.chainid);
        console2.log("usdc:                   ", cfg.usdc);
        console2.log("deployer (temp owner):  ", deployer);
        console2.log("StablePilotRegistry:    ", address(registry));
        console2.log("  treasury:             ", cfg.treasury);
        console2.log("  owner (now):          ", registry.owner());
        console2.log("  pendingOwner:         ", registry.pendingOwner());
        console2.log("  feeRateBps[0]:        ", cfg.feeBps);
        console2.log("  feesEnabled:          ", cfg.feesEnabled);
        console2.log("PrivatePayroll:         ", address(payroll));
        console2.log("  owner:                ", cfg.payrollOwner);
        if (handoff) {
            console2.log("NEXT: pendingOwner must call acceptOwnership() on StablePilotRegistry", address(registry));
        }
    }

    function _decimals(address token) internal view returns (uint8) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        require(ok && data.length >= 32, "DeployStablePilot: usdc decimals() failed");
        return abi.decode(data, (uint8));
    }
}
