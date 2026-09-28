// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {PrivatePayroll} from "../PrivatePayroll.sol";
import {IStablePilotRegistry} from "../interfaces/IStablePilotRegistry.sol";

/// @notice Deploys PrivatePayroll against an existing StablePilotRegistry. NOT run by CI.
///
/// Env vars (all optional):
///   REGISTRY_ADDRESS   StablePilotRegistry          (default: Arc Testnet 0x1070dc6494402aacaa5e701139d27f20de6527ff)
///   USDC_ADDRESS       expected USDC ERC-20         (default: Arc Testnet 0x3600000000000000000000000000000000000000,
///                      the ERC-20 interface of native USDC, 6 decimals — docs.arc.io/arc/references/contract-addresses)
///   PAYROLL_OWNER      protocol owner of the module (default: the broadcaster; use a multisig for production)
///   EXPECTED_CHAIN_ID  safety check                 (default: 5042002 = Arc Testnet)
///
/// Dry run (simulation only, nothing is sent):
///   forge script contracts/script/DeployPrivatePayroll.s.sol --rpc-url arc_testnet
/// Broadcast (deploys!): add `--broadcast` plus a signer (`--account <keystore>` / `--ledger`).
///
/// After deployment the REGISTRY OWNER must, on-chain:
///   registry.addModule(<payroll>, 0)          // MODULE_PAYROLL; otherwise fundPeriod reverts NotModule()
///   registry.setFeeRate(0, <bps>)             // optional, 0..500
///   registry.setFeesEnabled(true)             // optional; while false, collectFee charges 0
contract DeployPrivatePayroll is Script {
    address internal constant ARC_TESTNET_REGISTRY = 0x1070dc6494402aacAa5E701139d27f20de6527Ff;
    address internal constant ARC_TESTNET_USDC = 0x3600000000000000000000000000000000000000;
    uint256 internal constant ARC_TESTNET_CHAIN_ID = 5042002;

    function run() external returns (PrivatePayroll payroll) {
        address registry = vm.envOr("REGISTRY_ADDRESS", ARC_TESTNET_REGISTRY);
        address expectedUsdc = vm.envOr("USDC_ADDRESS", ARC_TESTNET_USDC);
        uint256 expectedChainId = vm.envOr("EXPECTED_CHAIN_ID", ARC_TESTNET_CHAIN_ID);

        require(block.chainid == expectedChainId, "DeployPrivatePayroll: unexpected chain id");
        require(registry.code.length > 0, "DeployPrivatePayroll: registry has no code");
        require(
            IStablePilotRegistry(registry).usdc() == expectedUsdc,
            "DeployPrivatePayroll: registry.usdc() != USDC_ADDRESS"
        );

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        address owner = vm.envOr("PAYROLL_OWNER", broadcaster);
        payroll = new PrivatePayroll(registry, owner);
        vm.stopBroadcast();

        console2.log("PrivatePayroll:", address(payroll));
        console2.log("owner:", owner);
        console2.log("registry:", registry);
        console2.log("usdc:", address(payroll.usdc()));
        console2.log("NEXT (registry owner): registry.addModule(payroll, 0); setFeeRate(0, bps); setFeesEnabled(true)");
    }
}
