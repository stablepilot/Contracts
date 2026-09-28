// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {StablePilotRegistry} from "../StablePilotRegistry.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Handler for invariant testing
// ─────────────────────────────────────────────────────────────────────────────

contract RegistryHandler is Test {
    StablePilotRegistry internal registry;
    MockERC20 internal usdc;

    address internal owner;
    address internal moduleAddr;
    address internal payer;
    address internal treasury;

    uint256 public ghost_totalFeesCollected;

    constructor(
        StablePilotRegistry _registry,
        MockERC20 _usdc,
        address _owner,
        address _moduleAddr,
        address _payer,
        address _treasury
    ) {
        registry = _registry;
        usdc = _usdc;
        owner = _owner;
        moduleAddr = _moduleAddr;
        payer = _payer;
        treasury = _treasury;
    }

    /// Bound txAmount to keep multiplication from overflowing (max 500 bps, so txAmount * 500 / 10_000)
    function callCollectFee(uint256 txAmount) external {
        txAmount = bound(txAmount, 0, type(uint128).max);

        // Ensure payer has enough allowance + balance
        uint256 maxFee = (txAmount * 500) / 10_000;
        if (maxFee == 0) return;

        // Mint enough USDC to payer and approve registry
        usdc.mint(payer, maxFee);
        vm.prank(payer);
        usdc.approve(address(registry), maxFee);

        uint256 balBefore = usdc.balanceOf(treasury);
        vm.prank(moduleAddr);
        try registry.collectFee(0, txAmount, payer) returns (uint256 fee) {
            uint256 balAfter = usdc.balanceOf(treasury);
            ghost_totalFeesCollected += fee;
            // Sanity: treasury actually received the fee
            assertEq(balAfter - balBefore, fee);
        } catch {
            // collectFee may return 0 (feesEnabled=false path), ignore
        }
    }

    function callSetFeeRate(uint16 bps) external {
        bps = uint16(bound(bps, 0, 500));
        vm.prank(owner);
        registry.setFeeRate(0, bps);
    }

    function callToggleFees(bool enabled) external {
        vm.prank(owner);
        registry.setFeesEnabled(enabled);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main test contract
// ─────────────────────────────────────────────────────────────────────────────

contract StablePilotRegistryTest is Test {
    // ── actors ────────────────────────────────────────────────────────────────
    address internal owner    = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal moduleA  = makeAddr("moduleA");
    address internal moduleB  = makeAddr("moduleB");

    // ── contracts ─────────────────────────────────────────────────────────────
    MockERC20               internal usdc;
    StablePilotRegistry     internal registry;

    // ── constants ─────────────────────────────────────────────────────────────
    uint8  internal constant MOD_PAYROLL  = 0;
    uint8  internal constant MOD_SUPPLY   = 1;
    uint16 internal constant DEFAULT_BPS  = 100; // 1%
    uint256 internal constant USDC_SEED   = 1_000_000e6;

    // ─────────────────────────────────────────────────────────────────────────
    // setUp — runs before EVERY test
    // ─────────────────────────────────────────────────────────────────────────
    function setUp() public {
        // 1. Deploy mock USDC (6 decimals, like real USDC)
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        // 2. Deploy registry
        registry = new StablePilotRegistry(address(usdc), treasury, owner);

        // 3. Register moduleA as MODULE_PAYROLL (id=0)
        vm.prank(owner);
        registry.addModule(moduleA, MOD_PAYROLL);

        // 4. Give alice a generous USDC balance for fee-paying tests
        usdc.mint(alice, USDC_SEED);
    }

    // =========================================================================
    // ░░  DEPLOYMENT & INITIALIZATION
    // =========================================================================

    function test_Constructor_SetsImmutables() public view {
        assertEq(address(registry.usdc()),    address(usdc));
        assertEq(registry.treasury(),         treasury);
        assertEq(registry.owner(),            owner);
        assertFalse(registry.feesEnabled());
    }

    function test_Constructor_RevertsOnZeroUsdc() public {
        vm.expectRevert(abi.encodeWithSelector(StablePilotRegistry.ZeroAddress.selector, "usdc"));
        new StablePilotRegistry(address(0), treasury, owner);
    }

    function test_Constructor_RevertsOnZeroTreasury() public {
        vm.expectRevert(abi.encodeWithSelector(StablePilotRegistry.ZeroAddress.selector, "treasury"));
        new StablePilotRegistry(address(usdc), address(0), owner);
    }

    function test_Constructor_RevertsOnZeroOwner() public {
        // NOTE: The contract's own ZeroAddress("owner") guard is unreachable —
        // OZ Ownable(address(0)) fires OwnableInvalidOwner first.
        // This test documents the ACTUAL revert (OZ). See "Suspected contract bugs".
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0))
        );
        new StablePilotRegistry(address(usdc), treasury, address(0));
    }

    // =========================================================================
    // ░░  addModule
    // =========================================================================

    function test_AddModule_HappyPath() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(registry));
        emit StablePilotRegistry.ModuleAdded(moduleB, MOD_SUPPLY);
        registry.addModule(moduleB, MOD_SUPPLY);

        assertTrue(registry.isModule(moduleB));
        assertEq(registry.registeredModuleId(moduleB), MOD_SUPPLY);
    }

    function test_AddModule_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StablePilotRegistry.ZeroAddress.selector, "module"));
        registry.addModule(address(0), MOD_PAYROLL);
    }

    function test_AddModule_RevertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.addModule(moduleB, MOD_SUPPLY);
    }

    function test_AddModule_EmitsCorrectModuleId() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(registry));
        emit StablePilotRegistry.ModuleAdded(moduleB, 3); // MODULE_ZKCREDIT
        registry.addModule(moduleB, 3);
        assertEq(registry.registeredModuleId(moduleB), 3);
    }

    // =========================================================================
    // ░░  removeModule
    // =========================================================================

    function test_RemoveModule_HappyPath() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false, address(registry));
        emit StablePilotRegistry.ModuleRemoved(moduleA);
        registry.removeModule(moduleA);

        assertFalse(registry.isModule(moduleA));
        assertEq(registry.registeredModuleId(moduleA), 0);
    }

    function test_RemoveModule_ClearsModuleId() public {
        // Add module with non-zero id, then remove it — id resets to 0
        vm.prank(owner);
        registry.addModule(moduleB, MOD_SUPPLY);
        assertEq(registry.registeredModuleId(moduleB), MOD_SUPPLY);

        vm.prank(owner);
        registry.removeModule(moduleB);
        assertEq(registry.registeredModuleId(moduleB), 0);
        assertFalse(registry.isModule(moduleB));
    }

    function test_RemoveModule_RevertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.removeModule(moduleA);
    }

    // =========================================================================
    // ░░  setFeeRate
    // =========================================================================

    function test_SetFeeRate_HappyPath() public {
        uint16 oldBps = registry.feeRateBps(MOD_PAYROLL);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(registry));
        emit StablePilotRegistry.FeeRateSet(MOD_PAYROLL, oldBps, DEFAULT_BPS);
        registry.setFeeRate(MOD_PAYROLL, DEFAULT_BPS);

        assertEq(registry.feeRateBps(MOD_PAYROLL), DEFAULT_BPS);
    }

    function test_SetFeeRate_AcceptsZero() public {
        vm.prank(owner);
        registry.setFeeRate(MOD_PAYROLL, 0);
        assertEq(registry.feeRateBps(MOD_PAYROLL), 0);
    }

    function test_SetFeeRate_AcceptsMaxBps() public {
        vm.prank(owner);
        registry.setFeeRate(MOD_PAYROLL, 500);
        assertEq(registry.feeRateBps(MOD_PAYROLL), 500);
    }

    function test_SetFeeRate_RevertsAboveMax() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StablePilotRegistry.FeeBpsTooHigh.selector, uint16(501)));
        registry.setFeeRate(MOD_PAYROLL, 501);
    }

    function test_SetFeeRate_RevertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.setFeeRate(MOD_PAYROLL, DEFAULT_BPS);
    }

    function test_SetFeeRate_EmitsFeeRateSet() public {
        // Set once to 100, then change to 200 — check old value in event
        vm.prank(owner);
        registry.setFeeRate(MOD_PAYROLL, 100);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(registry));
        emit StablePilotRegistry.FeeRateSet(MOD_PAYROLL, 100, 200);
        registry.setFeeRate(MOD_PAYROLL, 200);
    }

    // =========================================================================
    // ░░  collectFee
    // =========================================================================

    /// Shared helper: enable fees + set rate + approve registry
    function _enableFees(uint16 bps, uint256 approveAmount) internal {
        vm.startPrank(owner);
        registry.setFeesEnabled(true);
        registry.setFeeRate(MOD_PAYROLL, bps);
        vm.stopPrank();

        vm.prank(alice);
        usdc.approve(address(registry), approveAmount);
    }

    function test_CollectFee_HappyPath() public {
        uint256 txAmount = 1_000e6; // 1,000 USDC
        uint16  bps      = 100;     // 1%
        uint256 expected = (txAmount * bps) / 10_000; // 10 USDC

        _enableFees(bps, expected);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(moduleA);
        vm.expectEmit(true, true, false, true, address(registry));
        emit StablePilotRegistry.FeeCollected(MOD_PAYROLL, alice, expected, txAmount);
        uint256 fee = registry.collectFee(MOD_PAYROLL, txAmount, alice);

        assertEq(fee, expected);
        assertEq(usdc.balanceOf(treasury), treasuryBefore + expected);
        assertEq(usdc.balanceOf(alice), USDC_SEED - expected);
    }

    function test_CollectFee_ReturnsZeroWhenFeesDisabled() public {
        // fees are disabled by default (feesEnabled = false)
        vm.prank(owner);
        registry.setFeeRate(MOD_PAYROLL, 100);

        vm.prank(moduleA);
        uint256 fee = registry.collectFee(MOD_PAYROLL, 1_000e6, alice);
        assertEq(fee, 0);
        // No USDC moved
        assertEq(usdc.balanceOf(alice), USDC_SEED);
    }

    function test_CollectFee_ReturnsZeroWhenFeeRateIsZero() public {
        vm.prank(owner);
        registry.setFeesEnabled(true);
        // feeRateBps[MOD_PAYROLL] defaults to 0

        vm.prank(moduleA);
        uint256 fee = registry.collectFee(MOD_PAYROLL, 1_000e6, alice);
        assertEq(fee, 0);
        assertEq(usdc.balanceOf(alice), USDC_SEED);
    }

    function test_CollectFee_RevertsNotModule() public {
        vm.prank(bob); // bob is not registered
        vm.expectRevert(StablePilotRegistry.NotModule.selector);
        registry.collectFee(MOD_PAYROLL, 1_000e6, alice);
    }

    function test_CollectFee_RevertsModuleIdMismatch() public {
        // moduleA is registered with MOD_PAYROLL (0); calling with MOD_SUPPLY (1) should revert
        vm.prank(moduleA);
        vm.expectRevert(StablePilotRegistry.ModuleIdMismatch.selector);
        registry.collectFee(MOD_SUPPLY, 1_000e6, alice);
    }

    function test_CollectFee_PartnerDiscount_50pct() public {
        uint256 txAmount = 1_000e6;
        uint16  bps      = 200;     // 2%
        uint256 baseFee  = (txAmount * bps) / 10_000; // 20 USDC
        uint8   mult     = 50;      // 50% of base fee
        uint256 expected = (baseFee * mult) / 100;    // 10 USDC

        _enableFees(bps, baseFee);

        vm.prank(owner);
        registry.setPartnerDiscount(alice, mult);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(moduleA);
        uint256 fee = registry.collectFee(MOD_PAYROLL, txAmount, alice);

        assertEq(fee, expected);
        assertEq(usdc.balanceOf(treasury), treasuryBefore + expected);
    }

    function test_CollectFee_PartnerDiscount_100pct_NoDiscount() public {
        // multiplier=100 means 100% of base fee — no discount
        uint256 txAmount = 1_000e6;
        uint16  bps      = 100;
        uint256 expected = (txAmount * bps) / 10_000;

        _enableFees(bps, expected);

        vm.prank(owner);
        registry.setPartnerDiscount(alice, 100);

        vm.prank(moduleA);
        uint256 fee = registry.collectFee(MOD_PAYROLL, txAmount, alice);
        assertEq(fee, expected); // same as base fee
    }

    function test_CollectFee_NoDiscountSetForPayer() public {
        // discountMultiplier[alice] == 0 (default) → no discount applied
        uint256 txAmount = 500e6;
        uint16  bps      = 100;
        uint256 expected = (txAmount * bps) / 10_000;

        _enableFees(bps, expected);

        vm.prank(moduleA);
        uint256 fee = registry.collectFee(MOD_PAYROLL, txAmount, alice);
        assertEq(fee, expected);
    }

    function test_CollectFee_ZeroTxAmount_ReturnsZero() public {
        _enableFees(DEFAULT_BPS, 0);

        vm.prank(moduleA);
        uint256 fee = registry.collectFee(MOD_PAYROLL, 0, alice);
        assertEq(fee, 0);
    }

    function test_CollectFee_AfterModuleRemoved_Reverts() public {
        _enableFees(DEFAULT_BPS, 1_000e6);

        vm.prank(owner);
        registry.removeModule(moduleA);

        vm.prank(moduleA);
        vm.expectRevert(StablePilotRegistry.NotModule.selector);
        registry.collectFee(MOD_PAYROLL, 1_000e6, alice);
    }

    // =========================================================================
    // ░░  computeFee
    // =========================================================================

    function test_ComputeFee_MatchesCollectFeeWithDiscount() public {
        uint256 txAmount = 2_000e6;
        uint16  bps      = 200;
        uint8   mult     = 75;

        vm.startPrank(owner);
        registry.setFeesEnabled(true);
        registry.setFeeRate(MOD_PAYROLL, bps);
        registry.setPartnerDiscount(alice, mult);
        vm.stopPrank();

        uint256 computed = registry.computeFee(MOD_PAYROLL, txAmount, alice);

        uint256 approveAmount = computed + 1;
        vm.prank(alice);
        usdc.approve(address(registry), approveAmount);

        vm.prank(moduleA);
        uint256 actual = registry.collectFee(MOD_PAYROLL, txAmount, alice);

        assertEq(computed, actual, "computeFee must match collectFee");
    }

    function test_ComputeFee_ZeroWhenFeesDisabled() public view {
        uint256 fee = registry.computeFee(MOD_PAYROLL, 1_000e6, alice);
        assertEq(fee, 0);
    }

    function test_ComputeFee_ZeroWhenFeeRateZero() public {
        vm.prank(owner);
        registry.setFeesEnabled(true);

        uint256 fee = registry.computeFee(MOD_PAYROLL, 1_000e6, alice);
        assertEq(fee, 0);
    }

    function test_ComputeFee_NoDiscount() public {
        vm.startPrank(owner);
        registry.setFeesEnabled(true);
        registry.setFeeRate(MOD_PAYROLL, 100);
        vm.stopPrank();

        uint256 fee = registry.computeFee(MOD_PAYROLL, 1_000e6, alice);
        assertEq(fee, (1_000e6 * 100) / 10_000); // 10 USDC
    }

    // =========================================================================
    // ░░  setFeesEnabled
    // =========================================================================

    function test_SetFeesEnabled_True() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(registry));
        emit StablePilotRegistry.FeesToggled(true);
        registry.setFeesEnabled(true);
        assertTrue(registry.feesEnabled());
    }

    function test_SetFeesEnabled_False() public {
        // First enable
        vm.prank(owner);
        registry.setFeesEnabled(true);

        // Then disable
        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(registry));
        emit StablePilotRegistry.FeesToggled(false);
        registry.setFeesEnabled(false);
        assertFalse(registry.feesEnabled());
    }

    function test_SetFeesEnabled_RevertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.setFeesEnabled(true);
    }

    // =========================================================================
    // ░░  setPartnerDiscount
    // =========================================================================

    function test_SetPartnerDiscount_Valid50() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(registry));
        emit StablePilotRegistry.PartnerDiscountSet(alice, 50);
        registry.setPartnerDiscount(alice, 50);
        assertEq(registry.discountMultiplier(alice), 50);
    }

    function test_SetPartnerDiscount_Valid75() public {
        vm.prank(owner);
        registry.setPartnerDiscount(alice, 75);
        assertEq(registry.discountMultiplier(alice), 75);
    }

    function test_SetPartnerDiscount_Valid100() public {
        vm.prank(owner);
        registry.setPartnerDiscount(alice, 100);
        assertEq(registry.discountMultiplier(alice), 100);
    }

    function test_SetPartnerDiscount_RevertsBelowMin() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StablePilotRegistry.InvalidDiscount.selector, uint8(49)));
        registry.setPartnerDiscount(alice, 49);
    }

    function test_SetPartnerDiscount_RevertsAboveMax() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StablePilotRegistry.InvalidDiscount.selector, uint8(101)));
        registry.setPartnerDiscount(alice, 101);
    }

    function test_SetPartnerDiscount_RevertsZeroMultiplier() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StablePilotRegistry.InvalidDiscount.selector, uint8(0)));
        registry.setPartnerDiscount(alice, 0);
    }

    function test_SetPartnerDiscount_RevertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StablePilotRegistry.ZeroAddress.selector, "partner"));
        registry.setPartnerDiscount(address(0), 75);
    }

    function test_SetPartnerDiscount_RevertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.setPartnerDiscount(bob, 75);
    }

    // =========================================================================
    // ░░  removePartnerDiscount
    // =========================================================================

    function test_RemovePartnerDiscount_ClearsMultiplier() public {
        vm.prank(owner);
        registry.setPartnerDiscount(alice, 75);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false, address(registry));
        emit StablePilotRegistry.PartnerDiscountRemoved(alice);
        registry.removePartnerDiscount(alice);

        assertEq(registry.discountMultiplier(alice), 0);
    }

    function test_RemovePartnerDiscount_RevertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.removePartnerDiscount(bob);
    }

    // =========================================================================
    // ░░  treasury two-step
    // =========================================================================

    function test_SetPendingTreasury_HappyPath() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false, address(registry));
        emit StablePilotRegistry.TreasuryUpdateProposed(bob);
        registry.setPendingTreasury(bob);

        assertEq(registry.pendingTreasury(), bob);
    }

    function test_SetPendingTreasury_RevertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StablePilotRegistry.ZeroAddress.selector, "pendingTreasury"));
        registry.setPendingTreasury(address(0));
    }

    function test_SetPendingTreasury_RevertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.setPendingTreasury(bob);
    }

    function test_AcceptTreasury_HappyPath() public {
        address oldTreasury = registry.treasury();

        vm.prank(owner);
        registry.setPendingTreasury(bob);

        vm.prank(bob);
        vm.expectEmit(true, true, false, false, address(registry));
        emit StablePilotRegistry.TreasuryUpdated(oldTreasury, bob);
        registry.acceptTreasury();

        assertEq(registry.treasury(), bob);
        assertEq(registry.pendingTreasury(), address(0));
    }

    function test_AcceptTreasury_RevertsIfNotPendingTreasury() public {
        vm.prank(owner);
        registry.setPendingTreasury(bob);

        // alice tries to accept — should revert
        vm.prank(alice);
        vm.expectRevert(StablePilotRegistry.NotPendingTreasury.selector);
        registry.acceptTreasury();
    }

    function test_AcceptTreasury_RevertsIfNoPendingSet() public {
        // pendingTreasury is address(0) by default; nobody matches
        vm.prank(alice);
        vm.expectRevert(StablePilotRegistry.NotPendingTreasury.selector);
        registry.acceptTreasury();
    }

    function test_AcceptTreasury_ClearsPendingTreasury() public {
        vm.prank(owner);
        registry.setPendingTreasury(bob);

        vm.prank(bob);
        registry.acceptTreasury();

        // pendingTreasury slot is now address(0); re-accepting should revert
        vm.prank(bob);
        vm.expectRevert(StablePilotRegistry.NotPendingTreasury.selector);
        registry.acceptTreasury();
    }

    // =========================================================================
    // ░░  renounceOwnership
    // =========================================================================

    function test_RenounceOwnership_AlwaysReverts() public {
        vm.prank(owner);
        vm.expectRevert(StablePilotRegistry.RenounceOwnershipDisabled.selector);
        registry.renounceOwnership();
    }

    function test_RenounceOwnership_RevertsEvenIfCalledByOwner() public {
        // Belt-and-suspenders: confirm ownership is still intact after the revert
        vm.prank(owner);
        vm.expectRevert(StablePilotRegistry.RenounceOwnershipDisabled.selector);
        registry.renounceOwnership();
        assertEq(registry.owner(), owner);
    }

    // =========================================================================
    // ░░  rescueTokens
    // =========================================================================

    function test_RescueTokens_HappyPath() public {
        // Mint some tokens directly into the registry to simulate accidental transfer
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(address(registry), 500e18);

        uint256 ownerBefore = other.balanceOf(owner);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true, address(registry));
        emit StablePilotRegistry.TokensRescued(address(other), owner, 500e18);
        registry.rescueTokens(address(other), owner, 500e18);

        assertEq(other.balanceOf(owner), ownerBefore + 500e18);
        assertEq(other.balanceOf(address(registry)), 0);
    }

    function test_RescueTokens_RevertsZeroRecipient() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StablePilotRegistry.ZeroAddress.selector, "to"));
        registry.rescueTokens(address(usdc), address(0), 1);
    }

    function test_RescueTokens_RevertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.rescueTokens(address(usdc), alice, 1);
    }

    function test_RescueTokens_CanRescueUSDC() public {
        // Accidentally-sent USDC
        usdc.mint(address(registry), 100e6);

        vm.prank(owner);
        registry.rescueTokens(address(usdc), owner, 100e6);

        assertEq(usdc.balanceOf(address(registry)), 0);
    }

    // =========================================================================
    // ░░  Ownable2Step — transferOwnership two-step
    // =========================================================================

    function test_TransferOwnership_TwoStep() public {
        vm.prank(owner);
        registry.transferOwnership(alice);

        // Owner not changed yet
        assertEq(registry.owner(), owner);
        assertEq(registry.pendingOwner(), alice);

        vm.prank(alice);
        registry.acceptOwnership();
        assertEq(registry.owner(), alice);
    }

    // =========================================================================
    // ░░  FUZZ — collectFee arithmetic
    // =========================================================================

    /// @dev Verifies feeAmount <= txAmount * 500 / 10_000 for all txAmount.
    function testFuzz_CollectFee_FeeNeverExceedsMaxBps(uint256 txAmount) public {
        // Use max-fee rate (500 bps) to test the worst case ceiling
        txAmount = bound(txAmount, 0, type(uint128).max); // prevent overflow in fee calc

        vm.startPrank(owner);
        registry.setFeesEnabled(true);
        registry.setFeeRate(MOD_PAYROLL, 500);
        vm.stopPrank();

        uint256 maxPossibleFee = (txAmount * 500) / 10_000;

        // Mint enough for payer and approve
        if (maxPossibleFee > 0) {
            usdc.mint(alice, maxPossibleFee);
        }
        vm.prank(alice);
        usdc.approve(address(registry), maxPossibleFee);

        vm.prank(moduleA);
        uint256 actualFee = registry.collectFee(MOD_PAYROLL, txAmount, alice);

        assertLe(actualFee, maxPossibleFee, "fee exceeded max bps ceiling");
    }

    /// @dev Verifies computeFee is always consistent with the formula.
    function testFuzz_ComputeFee_Formula(uint256 txAmount, uint16 bps) public {
        bps = uint16(bound(bps, 0, 500));
        txAmount = bound(txAmount, 0, type(uint128).max);

        vm.startPrank(owner);
        registry.setFeesEnabled(true);
        registry.setFeeRate(MOD_PAYROLL, bps);
        vm.stopPrank();

        uint256 expected = (txAmount * bps) / 10_000;
        uint256 computed = registry.computeFee(MOD_PAYROLL, txAmount, alice);
        // alice has no discount (discountMultiplier == 0 means no discount path taken)
        assertEq(computed, expected);
    }

    /// @dev Verifies partner discount is always within [50%, 100%] of base fee.
    function testFuzz_CollectFee_DiscountBounds(uint256 txAmount, uint8 discount) public {
        // Need txAmount large enough that integer division doesn't swamp the 50% floor check.
        // Minimum: baseFee = txAmount * 100 / 10_000 must be >= 100 so (baseFee * 50) / 100 >= 1.
        txAmount = bound(txAmount, 10_001, type(uint64).max);
        discount = uint8(bound(discount, 50, 100));

        vm.startPrank(owner);
        registry.setFeesEnabled(true);
        registry.setFeeRate(MOD_PAYROLL, 100); // 1%
        registry.setPartnerDiscount(alice, discount);
        vm.stopPrank();

        uint256 baseFee = (txAmount * 100) / 10_000;
        // Mirror the contract's formula exactly: a single division after both multiplications
        // (txAmount * bps * discount) / (10_000 * 100). Dividing twice (baseFee * discount / 100)
        // truncates twice and can under-estimate by 1 wei, e.g. txAmount = 67378892, discount = 53:
        // contract = 357108, double division = 357107.
        uint256 expectedFee = (txAmount * 100 * discount) / (10_000 * 100);

        if (expectedFee == 0) return; // nothing is transferred for dust amounts

        usdc.mint(alice, expectedFee);
        vm.prank(alice);
        usdc.approve(address(registry), expectedFee);

        // computeFee must agree with collectFee
        assertEq(registry.computeFee(MOD_PAYROLL, txAmount, alice), expectedFee, "computeFee mismatch");

        vm.prank(moduleA);
        uint256 fee = registry.collectFee(MOD_PAYROLL, txAmount, alice);

        assertEq(fee, expectedFee, "discounted fee does not match formula");
        assertEq(usdc.balanceOf(treasury), expectedFee, "treasury did not receive fee");

        // Bounds: the discount never inflates the fee, and single-division rounding is never
        // below the double-truncated value (so fee is within [baseFee * discount / 100, baseFee]).
        assertLe(fee, baseFee, "discounted fee exceeds base fee");
        assertGe(fee, (baseFee * discount) / 100, "discounted fee below double-truncated floor");
        // Since discount >= 50, the fee is at least ~half the base fee (floor rounding).
        assertGe(fee, (baseFee * 50) / 100, "discounted fee below 50% floor");
    }

    /// @dev Regression for the fuzz counterexample: the contract divides once, so the fee is
    /// 357108 (not the double-truncated 357107).
    function test_CollectFee_DiscountRounding_SingleDivision() public {
        uint256 txAmount = 67_378_892;
        uint8 discount = 53;

        vm.startPrank(owner);
        registry.setFeesEnabled(true);
        registry.setFeeRate(MOD_PAYROLL, 100); // 1%
        registry.setPartnerDiscount(alice, discount);
        vm.stopPrank();

        vm.prank(alice);
        usdc.approve(address(registry), 357_108);

        vm.prank(moduleA);
        uint256 fee = registry.collectFee(MOD_PAYROLL, txAmount, alice);

        assertEq(fee, 357_108, "contract uses a single division");
        assertEq(usdc.balanceOf(treasury), 357_108, "treasury received full fee");
        assertEq(usdc.allowance(alice, address(registry)), 0, "exact allowance consumed");
    }

    /// @dev setFeeRate with any bps in [0,500] must always succeed.
    function testFuzz_SetFeeRate_ValidRange(uint16 bps) public {
        bps = uint16(bound(bps, 0, 500));
        vm.prank(owner);
        registry.setFeeRate(MOD_PAYROLL, bps);
        assertEq(registry.feeRateBps(MOD_PAYROLL), bps);
    }

    /// @dev setFeeRate with any bps > 500 must always revert.
    function testFuzz_SetFeeRate_InvalidRange(uint16 bps) public {
        bps = uint16(bound(bps, 501, type(uint16).max));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StablePilotRegistry.FeeBpsTooHigh.selector, bps));
        registry.setFeeRate(MOD_PAYROLL, bps);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Invariant test contract — registry USDC balance is always 0
// ─────────────────────────────────────────────────────────────────────────────

contract StablePilotRegistryInvariant is Test {
    StablePilotRegistry internal registry;
    MockERC20           internal usdc;
    RegistryHandler     internal handler;

    address internal owner    = makeAddr("invOwner");
    address internal treasury = makeAddr("invTreasury");
    address internal moduleA  = makeAddr("invModuleA");
    address internal payer    = makeAddr("invPayer");

    function setUp() public {
        usdc     = new MockERC20("Mock USDC", "mUSDC", 6);
        registry = new StablePilotRegistry(address(usdc), treasury, owner);

        vm.startPrank(owner);
        registry.addModule(moduleA, 0);
        registry.setFeesEnabled(true);
        registry.setFeeRate(0, 100); // 1%
        vm.stopPrank();

        handler = new RegistryHandler(registry, usdc, owner, moduleA, payer, treasury);

        // Seed the handler with a bit of USDC for the payer
        usdc.mint(payer, 1_000_000e6);
        vm.prank(payer);
        usdc.approve(address(registry), type(uint256).max);

        // Target handler for invariant fuzzer
        targetContract(address(handler));
    }

    /// @dev The registry must NEVER hold USDC — it immediately routes fees to treasury.
    function invariant_RegistryHoldsNoUsdc() public view {
        assertEq(
            usdc.balanceOf(address(registry)),
            0,
            "registry should never hold USDC"
        );
    }

    /// @dev Ghost accounting: treasury balance >= total fees collected.
    function invariant_TreasuryBalanceGrowsMonotonically() public view {
        assertGe(
            usdc.balanceOf(treasury),
            handler.ghost_totalFeesCollected(),
            "treasury must hold at least accumulated fees"
        );
    }
}
