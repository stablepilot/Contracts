// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {StablePilotRegistry} from "../StablePilotRegistry.sol";
import {PrivatePayroll} from "../PrivatePayroll.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {MerkleBuilder} from "../test-helpers/MerkleBuilder.sol";
import {MockERC1271Wallet, MockRegistryStub, MockFeeOnTransferToken} from "../test-helpers/PayrollMocks.sol";

abstract contract PrivatePayrollBase is Test {
    uint256 internal constant USDC = 1e6; // 6 decimals
    uint16 internal constant FEE_BPS = 50; // 0.5%

    MockERC20 internal usdc;
    StablePilotRegistry internal registry;
    PrivatePayroll internal payroll;

    address internal registryOwner = makeAddr("registryOwner");
    address internal treasury = makeAddr("treasury");
    address internal protocolOwner = makeAddr("protocolOwner");
    address internal employer = makeAddr("employer");
    address internal relayer = makeAddr("relayer");
    address internal stranger = makeAddr("stranger");

    uint256 internal payrollId;

    function setUp() public virtual {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        registry = new StablePilotRegistry(address(usdc), treasury, registryOwner);
        payroll = new PrivatePayroll(address(registry), protocolOwner);

        // Registry configuration the protocol owner must perform on-chain (see design doc §Registry).
        vm.startPrank(registryOwner);
        registry.addModule(address(payroll), registry.MODULE_PAYROLL());
        registry.setFeeRate(registry.MODULE_PAYROLL(), FEE_BPS);
        registry.setFeesEnabled(true);
        vm.stopPrank();

        usdc.mint(employer, 10_000_000 * USDC);
        vm.startPrank(employer);
        usdc.approve(address(payroll), type(uint256).max);
        usdc.approve(address(registry), type(uint256).max);
        payrollId = payroll.createPayroll();
        payroll.deposit(payrollId, 1_000_000 * USDC);
        vm.stopPrank();
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _req(uint256 pid, uint256 periodId, uint256 index, address employee, uint256 amount, bytes32 salt)
        internal
        pure
        returns (PrivatePayroll.ClaimRequest memory)
    {
        return PrivatePayroll.ClaimRequest(pid, periodId, index, employee, amount, salt);
    }

    function _salt(uint256 periodId, uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("salt", periodId, i));
    }

    /// Builds a tree for `employees/amounts` in the next period of `pid`; returns requests & leaves.
    function _buildPeriod(uint256 pid, address[] memory employees, uint256[] memory amounts)
        internal
        view
        returns (PrivatePayroll.ClaimRequest[] memory reqs, bytes32[] memory leaves, bytes32 root, uint256 total)
    {
        uint256 periodId = payroll.getPayroll(pid).periodCount + 1;
        reqs = new PrivatePayroll.ClaimRequest[](employees.length);
        leaves = new bytes32[](employees.length);
        for (uint256 i; i < employees.length; ++i) {
            reqs[i] = _req(pid, periodId, i, employees[i], amounts[i], _salt(periodId, i));
            leaves[i] = payroll.leafHash(reqs[i]);
            total += amounts[i];
        }
        root = MerkleBuilder.root(leaves);
    }

    function _deadline() internal view returns (uint64) {
        return uint64(block.timestamp + 30 days);
    }

    function _fund(bytes32 root, uint256 total) internal returns (uint256 periodId, uint256 fee) {
        vm.prank(employer);
        (periodId, fee) = payroll.fundPeriod(payrollId, root, total, _deadline());
    }

    function _twoEmployees()
        internal
        returns (PrivatePayroll.ClaimRequest[] memory reqs, bytes32[] memory leaves, uint256 periodId)
    {
        address[] memory e = new address[](2);
        e[0] = makeAddr("emp0");
        e[1] = makeAddr("emp1");
        uint256[] memory a = new uint256[](2);
        a[0] = 2_500 * USDC;
        a[1] = 3_000 * USDC + 1;
        bytes32 root;
        uint256 total;
        (reqs, leaves, root, total) = _buildPeriod(payrollId, e, a);
        (periodId,) = _fund(root, total);
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}

contract PrivatePayrollTest is PrivatePayrollBase {
    // Test vector produced by tools/merkle (fixtures/example.csv -> example.expected.json).
    bytes32 internal constant FIXTURE_ROOT = 0x697e19a1415787e47e118f3333f7273e08a1a92ba21f24c89170d832de14727f;
    uint256 internal constant FIXTURE_TOTAL = 11_800_749_999;

    // ── constructor ─────────────────────────────────────────────────────────

    function test_Constructor_SetsState() public view {
        assertEq(address(payroll.usdc()), address(usdc));
        assertEq(address(payroll.registry()), address(registry));
        assertEq(payroll.owner(), protocolOwner);
        assertEq(payroll.MODULE_PAYROLL(), registry.MODULE_PAYROLL());
    }

    function test_Constructor_RevertsZeroRegistry() public {
        vm.expectRevert(PrivatePayroll.ZeroAddress.selector);
        new PrivatePayroll(address(0), protocolOwner);
    }

    function test_Constructor_RevertsRegistryWithoutToken() public {
        MockRegistryStub stub = new MockRegistryStub(address(0), 0);
        vm.expectRevert(PrivatePayroll.ZeroAddress.selector);
        new PrivatePayroll(address(stub), protocolOwner);
    }

    function test_Constructor_RevertsModuleIdMismatch() public {
        MockRegistryStub stub = new MockRegistryStub(address(usdc), 1);
        vm.expectRevert(PrivatePayroll.ModuleIdMismatch.selector);
        new PrivatePayroll(address(stub), protocolOwner);
    }

    function test_Constructor_RevertsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new PrivatePayroll(address(registry), address(0));
    }

    // ── fixture / off-chain tool compatibility ──────────────────────────────

    function _fixtureReqs() internal pure returns (PrivatePayroll.ClaimRequest[4] memory r, bytes32[2][4] memory p) {
        r[0] = PrivatePayroll.ClaimRequest(
            1,
            1,
            0,
            0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7,
            2_500_000_000,
            0x004b2069db7ceb2455a66ba21001bd2808e1ac82eb25c58570c16b00de9a7ed4
        );
        r[1] = PrivatePayroll.ClaimRequest(
            1,
            1,
            1,
            0x0376AAc07Ad725E01357B1725B5ceC61aE10473c,
            3_100_500_000,
            0xce8c21d881d8e333b3a02d733b47684333c6b920dcab78ef3f43df04dceaec8d
        );
        r[2] = PrivatePayroll.ClaimRequest(
            1,
            1,
            2,
            0x0F89F1868aF3b14a5eca86ed9a5404A742a11454,
            1_999_999_999,
            0xb0086366436e8e1e4f93948efac82100cf4ef86e26e67d78235c824c7c0bf402
        );
        r[3] = PrivatePayroll.ClaimRequest(
            1,
            1,
            3,
            0x1EB52434E761a893f069bb5C8a7C6665f8c4884C,
            4_200_250_000,
            0x1f5b90a4bfd1375beef5a22e5929e2dadf51288ebe0162827d72f1ccfa52e463
        );
        p[0] = [
            bytes32(0x81f859e13e8b830694d62ee14c6babc8852320da48a4ade6c516729aba571c3d),
            0x76af5b0939aceb1bf8bdf4aca969eb1e66784e81b994ad5f2c95626401d0f21a
        ];
        p[1] = [
            bytes32(0xa2ec7bc04675f3656cb1ae9e4b6bb2b78a270a61a54a3250b62ca1f4112a6cac),
            0x5c56a5e5a38d0854de848adc5cbe46849484f66235ff785d278105210572b551
        ];
        p[2] = [
            bytes32(0x8e709af169bdd1d36015bac9d39abd0774a445b71d8ce455c229294e875fc64b),
            0x76af5b0939aceb1bf8bdf4aca969eb1e66784e81b994ad5f2c95626401d0f21a
        ];
        p[3] = [
            bytes32(0xfb4ba39aaf1b04bbc36e2a3e94dea1a281f8a7525211c899941ed8c3a49ec138),
            0x5c56a5e5a38d0854de848adc5cbe46849484f66235ff785d278105210572b551
        ];
    }

    function _toDyn(bytes32[2] memory a) internal pure returns (bytes32[] memory d) {
        d = new bytes32[](2);
        d[0] = a[0];
        d[1] = a[1];
    }

    function test_Fixture_LeafMatchesTool() public view {
        (PrivatePayroll.ClaimRequest[4] memory r,) = _fixtureReqs();
        assertEq(payroll.leafHash(r[0]), 0x8e709af169bdd1d36015bac9d39abd0774a445b71d8ce455c229294e875fc64b);
        assertEq(r[0].employee, vm.addr(0xA11CE));
        assertEq(r[3].employee, vm.addr(0xD4E));
    }

    function test_Fixture_AllEmployeesClaim() public {
        assertEq(payrollId, 1);
        (uint256 periodId,) = _fund(FIXTURE_ROOT, FIXTURE_TOTAL);
        assertEq(periodId, 1);
        (PrivatePayroll.ClaimRequest[4] memory r, bytes32[2][4] memory p) = _fixtureReqs();

        // employee 0 claims directly
        vm.prank(r[0].employee);
        payroll.claim(r[0], _toDyn(p[0]), r[0].employee);
        // employee 1 claims to a fresh address
        address fresh = makeAddr("fresh");
        vm.prank(r[1].employee);
        payroll.claim(r[1], _toDyn(p[1]), fresh);
        // employee 2 authorizes a relayer (EIP-712) to claim to a fresh address
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _sign(0xCA401, payroll.claimAuthorizationDigest(1, 1, 2, fresh, dl));
        vm.prank(relayer);
        payroll.claimWithAuthorization(r[2], _toDyn(p[2]), fresh, dl, sig);
        // employee 3 claims directly
        vm.prank(r[3].employee);
        payroll.claim(r[3], _toDyn(p[3]), r[3].employee);

        assertEq(usdc.balanceOf(r[0].employee), 2_500_000_000);
        assertEq(usdc.balanceOf(fresh), 3_100_500_000 + 1_999_999_999);
        assertEq(usdc.balanceOf(r[3].employee), 4_200_250_000);
        assertEq(payroll.getPeriod(1, 1).claimed, FIXTURE_TOTAL);
    }

    // ── createPayroll / deposit / withdraw ──────────────────────────────────

    function test_CreatePayroll_IncrementsAndEmits() public {
        vm.expectEmit(true, true, false, false);
        emit PrivatePayroll.PayrollCreated(2, stranger);
        vm.prank(stranger);
        assertEq(payroll.createPayroll(), 2);
        assertEq(payroll.getPayroll(2).employer, stranger);
        assertEq(payroll.payrollCount(), 2);
    }

    function test_CreatePayroll_RevertsWhenPaused() public {
        vm.prank(protocolOwner);
        payroll.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(stranger);
        payroll.createPayroll();
    }

    function test_Deposit_AddsToPool() public {
        uint256 beforeBal = usdc.balanceOf(address(payroll));
        vm.expectEmit(true, false, false, true);
        emit PrivatePayroll.Deposited(payrollId, 5 * USDC);
        vm.prank(employer);
        payroll.deposit(payrollId, 5 * USDC);
        assertEq(payroll.getPayroll(payrollId).pool, 1_000_005 * USDC);
        assertEq(usdc.balanceOf(address(payroll)), beforeBal + 5 * USDC);
    }

    function test_Deposit_Reverts() public {
        vm.startPrank(employer);
        vm.expectRevert(PrivatePayroll.ZeroAmount.selector);
        payroll.deposit(payrollId, 0);
        vm.expectRevert(PrivatePayroll.UnknownPayroll.selector);
        payroll.deposit(99, 1);
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, uint256(1) << 128)
        );
        payroll.deposit(payrollId, uint256(1) << 128);
        vm.stopPrank();

        vm.expectRevert(PrivatePayroll.NotEmployer.selector);
        vm.prank(stranger);
        payroll.deposit(payrollId, 1);

        vm.prank(protocolOwner);
        payroll.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(employer);
        payroll.deposit(payrollId, 1);
    }

    function test_Deposit_RevertsOnFeeOnTransferToken() public {
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken();
        StablePilotRegistry reg2 = new StablePilotRegistry(address(fot), treasury, registryOwner);
        PrivatePayroll pp = new PrivatePayroll(address(reg2), protocolOwner);
        fot.mint(employer, 100);
        vm.startPrank(employer);
        fot.approve(address(pp), 100);
        uint256 id = pp.createPayroll();
        vm.expectRevert(PrivatePayroll.DepositMismatch.selector);
        pp.deposit(id, 100);
        vm.stopPrank();
    }

    function test_EmployerFunctions_RevertOnUnknownPayroll() public {
        vm.startPrank(employer);
        vm.expectRevert(PrivatePayroll.UnknownPayroll.selector);
        payroll.withdrawUnallocated(99, 1);
        vm.expectRevert(PrivatePayroll.UnknownPayroll.selector);
        payroll.reclaimExpired(99, 1);
        vm.expectRevert(PrivatePayroll.UnknownPayroll.selector);
        payroll.pausePayroll(99);
        vm.expectRevert(PrivatePayroll.UnknownPayroll.selector);
        payroll.unpausePayroll(99);
        vm.stopPrank();
    }

    function test_Withdraw_ReturnsUnallocated() public {
        uint256 beforeBal = usdc.balanceOf(employer);
        vm.expectEmit(true, false, false, true);
        emit PrivatePayroll.Withdrawn(payrollId, 400 * USDC);
        vm.prank(employer);
        payroll.withdrawUnallocated(payrollId, 400 * USDC);
        assertEq(usdc.balanceOf(employer), beforeBal + 400 * USDC);
        assertEq(payroll.getPayroll(payrollId).pool, 999_600 * USDC);
    }

    function test_Withdraw_AllowedWhilePaused() public {
        vm.prank(protocolOwner);
        payroll.pause();
        vm.startPrank(employer);
        payroll.pausePayroll(payrollId);
        payroll.withdrawUnallocated(payrollId, 1_000_000 * USDC);
        vm.stopPrank();
        assertEq(payroll.getPayroll(payrollId).pool, 0);
    }

    function test_Withdraw_Reverts() public {
        vm.startPrank(employer);
        vm.expectRevert(PrivatePayroll.ZeroAmount.selector);
        payroll.withdrawUnallocated(payrollId, 0);
        vm.expectRevert(PrivatePayroll.InsufficientPool.selector);
        payroll.withdrawUnallocated(payrollId, 1_000_000 * USDC + 1);
        vm.stopPrank();
        vm.expectRevert(PrivatePayroll.NotEmployer.selector);
        vm.prank(stranger);
        payroll.withdrawUnallocated(payrollId, 1);
    }

    // ── fundPeriod & registry fee ───────────────────────────────────────────

    function test_FundPeriod_ChargesRegistryFeeToTreasury() public {
        uint256 total = 10_000 * USDC;
        uint256 expectedFee = registry.computeFee(registry.MODULE_PAYROLL(), total, employer);
        assertEq(expectedFee, 50 * USDC); // 0.5%
        assertEq(payroll.quoteFee(payrollId, total), expectedFee);
        uint256 employerBefore = usdc.balanceOf(employer);
        uint256 contractBefore = usdc.balanceOf(address(payroll));

        vm.expectEmit(true, true, false, true, address(registry));
        emit StablePilotRegistry.FeeCollected(0, employer, expectedFee, total);
        vm.expectEmit(true, true, false, true, address(payroll));
        emit PrivatePayroll.PeriodFunded(payrollId, 1, bytes32(uint256(1)), total, _deadline(), expectedFee);
        vm.prank(employer);
        (uint256 periodId, uint256 fee) = payroll.fundPeriod(payrollId, bytes32(uint256(1)), total, _deadline());

        assertEq(periodId, 1);
        assertEq(fee, expectedFee);
        assertEq(usdc.balanceOf(treasury), expectedFee);
        assertEq(usdc.balanceOf(employer), employerBefore - expectedFee); // fee paid by employer
        assertEq(usdc.balanceOf(address(payroll)), contractBefore); // pool untouched by fee
        assertEq(payroll.getPayroll(payrollId).pool, 1_000_000 * USDC - total);

        PrivatePayroll.Period memory per = payroll.getPeriod(payrollId, 1);
        assertEq(per.root, bytes32(uint256(1)));
        assertEq(per.total, total);
        assertEq(per.claimed, 0);
        assertEq(per.deadline, _deadline());
        assertFalse(per.reclaimed);
    }

    function test_FundPeriod_PartnerDiscountApplied() public {
        vm.prank(registryOwner);
        registry.setPartnerDiscount(employer, 50);
        (, uint256 fee) = _fund(bytes32(uint256(1)), 10_000 * USDC);
        assertEq(fee, 25 * USDC);
        assertEq(usdc.balanceOf(treasury), 25 * USDC);
    }

    function test_FundPeriod_NoFeeWhenDisabledOrZeroRate() public {
        vm.prank(registryOwner);
        registry.setFeesEnabled(false);
        (, uint256 fee) = _fund(bytes32(uint256(1)), 10_000 * USDC);
        assertEq(fee, 0);

        vm.startPrank(registryOwner);
        registry.setFeesEnabled(true);
        registry.setFeeRate(0, 0);
        vm.stopPrank();
        (, fee) = _fund(bytes32(uint256(2)), 10_000 * USDC);
        assertEq(fee, 0);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_FundPeriod_RevertsIfNotRegisteredModule() public {
        vm.prank(registryOwner);
        registry.removeModule(address(payroll));
        vm.expectRevert(StablePilotRegistry.NotModule.selector);
        _fund(bytes32(uint256(1)), 10_000 * USDC);
    }

    function test_FundPeriod_RevertsIfRegisteredUnderWrongModuleId() public {
        vm.prank(registryOwner);
        registry.addModule(address(payroll), 1);
        vm.expectRevert(StablePilotRegistry.ModuleIdMismatch.selector);
        _fund(bytes32(uint256(1)), 10_000 * USDC);
    }

    function test_FundPeriod_RevertsWithoutRegistryAllowance() public {
        vm.prank(employer);
        usdc.approve(address(registry), 0);
        vm.expectRevert(); // MockERC20 allowance underflow inside registry.collectFee
        _fund(bytes32(uint256(1)), 10_000 * USDC);
    }

    function test_FundPeriod_InputValidation() public {
        vm.startPrank(employer);
        vm.expectRevert(PrivatePayroll.ZeroRoot.selector);
        payroll.fundPeriod(payrollId, 0, 1, _deadline());
        vm.expectRevert(PrivatePayroll.ZeroAmount.selector);
        payroll.fundPeriod(payrollId, bytes32(uint256(1)), 0, _deadline());
        vm.expectRevert(PrivatePayroll.InsufficientPool.selector);
        payroll.fundPeriod(payrollId, bytes32(uint256(1)), 1_000_000 * USDC + 1, _deadline());
        uint64 minDl = uint64(block.timestamp) + payroll.MIN_CLAIM_WINDOW();
        uint64 maxDl = uint64(block.timestamp) + payroll.MAX_CLAIM_WINDOW();
        vm.expectRevert(PrivatePayroll.InvalidDeadline.selector);
        payroll.fundPeriod(payrollId, bytes32(uint256(1)), 1, minDl - 1);
        vm.expectRevert(PrivatePayroll.InvalidDeadline.selector);
        payroll.fundPeriod(payrollId, bytes32(uint256(1)), 1, maxDl + 1);
        payroll.fundPeriod(payrollId, bytes32(uint256(1)), 1, minDl); // boundaries OK
        (uint256 p2,) = payroll.fundPeriod(payrollId, bytes32(uint256(1)), 1, maxDl);
        assertEq(p2, 2);
        vm.expectRevert(PrivatePayroll.UnknownPayroll.selector);
        payroll.fundPeriod(42, bytes32(uint256(1)), 1, minDl);
        vm.stopPrank();

        vm.expectRevert(PrivatePayroll.NotEmployer.selector);
        vm.prank(stranger);
        payroll.fundPeriod(payrollId, bytes32(uint256(1)), 1, minDl);
    }

    function test_FundPeriod_RevertsWhenPaused() public {
        vm.prank(employer);
        payroll.pausePayroll(payrollId);
        vm.expectRevert(PrivatePayroll.PayrollIsPaused.selector);
        _fund(bytes32(uint256(1)), 1);

        vm.prank(employer);
        payroll.unpausePayroll(payrollId);
        vm.prank(protocolOwner);
        payroll.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _fund(bytes32(uint256(1)), 1);
    }

    // ── claims ──────────────────────────────────────────────────────────────

    function test_Claim_DirectAndToFreshRecipient() public {
        (PrivatePayroll.ClaimRequest[] memory r, bytes32[] memory leaves, uint256 periodId) = _twoEmployees();

        vm.expectEmit(true, true, false, true);
        emit PrivatePayroll.Claimed(payrollId, periodId, 0);
        vm.prank(r[0].employee);
        payroll.claim(r[0], MerkleBuilder.proof(leaves, 0), r[0].employee);
        assertEq(usdc.balanceOf(r[0].employee), r[0].amount);
        assertTrue(payroll.isClaimed(payrollId, periodId, 0));
        assertFalse(payroll.isClaimed(payrollId, periodId, 1));

        address fresh = makeAddr("fresh");
        vm.prank(r[1].employee);
        payroll.claim(r[1], MerkleBuilder.proof(leaves, 1), fresh);
        assertEq(usdc.balanceOf(fresh), r[1].amount);
        assertEq(usdc.balanceOf(r[1].employee), 0);
        assertEq(payroll.getPeriod(payrollId, periodId).claimed, r[0].amount + r[1].amount);
    }

    function test_Claim_RevertsDoubleClaim() public {
        (PrivatePayroll.ClaimRequest[] memory r, bytes32[] memory leaves,) = _twoEmployees();
        bytes32[] memory proof = MerkleBuilder.proof(leaves, 0);
        vm.startPrank(r[0].employee);
        payroll.claim(r[0], proof, r[0].employee);
        vm.expectRevert(PrivatePayroll.AlreadyClaimed.selector);
        payroll.claim(r[0], proof, makeAddr("other"));
        vm.stopPrank();
    }

    function test_Claim_RevertsWrongProofOrTamperedLeaf() public {
        (PrivatePayroll.ClaimRequest[] memory r, bytes32[] memory leaves,) = _twoEmployees();
        bytes32[] memory proof0 = MerkleBuilder.proof(leaves, 0);
        vm.startPrank(r[0].employee);

        vm.expectRevert(PrivatePayroll.InvalidProof.selector); // wrong proof
        payroll.claim(r[0], MerkleBuilder.proof(leaves, 1), r[0].employee);

        PrivatePayroll.ClaimRequest memory t = r[0];
        t.amount += 1; // inflated amount
        vm.expectRevert(PrivatePayroll.InvalidProof.selector);
        payroll.claim(t, proof0, r[0].employee);

        t = r[0];
        t.salt = bytes32(uint256(t.salt) ^ 1);
        vm.expectRevert(PrivatePayroll.InvalidProof.selector);
        payroll.claim(t, proof0, r[0].employee);

        t = r[0];
        t.index = 1; // index is bound in the leaf: cannot pick another bitmap slot
        vm.expectRevert(PrivatePayroll.InvalidProof.selector);
        payroll.claim(t, proof0, r[0].employee);
        vm.stopPrank();

        // someone else cannot use employee 0's leaf directly
        vm.expectRevert(PrivatePayroll.InvalidAuthorization.selector);
        vm.prank(stranger);
        payroll.claim(r[0], proof0, stranger);
    }

    function test_Claim_RevertsUnknownPeriodZeroRecipientPaused() public {
        (PrivatePayroll.ClaimRequest[] memory r, bytes32[] memory leaves,) = _twoEmployees();
        bytes32[] memory proof = MerkleBuilder.proof(leaves, 0);
        vm.startPrank(r[0].employee);
        vm.expectRevert(PrivatePayroll.ZeroAddress.selector);
        payroll.claim(r[0], proof, address(0));

        PrivatePayroll.ClaimRequest memory t = r[0];
        t.periodId = 9;
        vm.expectRevert(PrivatePayroll.UnknownPeriod.selector);
        payroll.claim(t, proof, r[0].employee);
        vm.stopPrank();

        vm.prank(employer);
        payroll.pausePayroll(payrollId);
        vm.expectRevert(PrivatePayroll.PayrollIsPaused.selector);
        vm.prank(r[0].employee);
        payroll.claim(r[0], proof, r[0].employee);
        vm.prank(employer);
        payroll.unpausePayroll(payrollId);

        vm.prank(protocolOwner);
        payroll.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(r[0].employee);
        payroll.claim(r[0], proof, r[0].employee);
    }

    function test_Claim_WindowBoundary() public {
        (PrivatePayroll.ClaimRequest[] memory r, bytes32[] memory leaves, uint256 periodId) = _twoEmployees();
        uint256 dl = payroll.effectiveDeadline(payrollId, periodId);
        vm.warp(dl); // inclusive
        vm.prank(r[0].employee);
        payroll.claim(r[0], MerkleBuilder.proof(leaves, 0), r[0].employee);
        vm.warp(dl + 1);
        vm.expectRevert(PrivatePayroll.ClaimWindowClosed.selector);
        vm.prank(r[1].employee);
        payroll.claim(r[1], MerkleBuilder.proof(leaves, 1), r[1].employee);
    }

    function test_Claim_SolvencyGuard_RootOverCommitsTotal() public {
        // Employer posts a root whose leaves sum to 150 while funding only 100.
        address[] memory e = new address[](2);
        e[0] = makeAddr("a");
        e[1] = makeAddr("b");
        uint256[] memory a = new uint256[](2);
        a[0] = 80 * USDC;
        a[1] = 70 * USDC;
        (PrivatePayroll.ClaimRequest[] memory r, bytes32[] memory leaves, bytes32 root,) = _buildPeriod(payrollId, e, a);
        _fund(root, 100 * USDC);
        // another funded period whose money must stay untouched
        _fund(bytes32(uint256(7)), 500 * USDC);

        vm.prank(e[0]);
        payroll.claim(r[0], MerkleBuilder.proof(leaves, 0), e[0]);
        vm.expectRevert(PrivatePayroll.ExceedsPeriodTotal.selector);
        vm.prank(e[1]);
        payroll.claim(r[1], MerkleBuilder.proof(leaves, 1), e[1]);
    }

    function test_Claim_ZeroAmountLeaf() public {
        address[] memory e = new address[](2);
        e[0] = makeAddr("a");
        e[1] = makeAddr("b");
        uint256[] memory a = new uint256[](2);
        a[0] = 0;
        a[1] = 10 * USDC;
        (PrivatePayroll.ClaimRequest[] memory r, bytes32[] memory leaves, bytes32 root, uint256 total) =
            _buildPeriod(payrollId, e, a);
        (uint256 periodId,) = _fund(root, total);
        vm.prank(e[0]);
        payroll.claim(r[0], MerkleBuilder.proof(leaves, 0), e[0]);
        assertTrue(payroll.isClaimed(payrollId, periodId, 0));
        assertEq(usdc.balanceOf(e[0]), 0);
    }

    function test_Claim_SingleLeafTree() public {
        address[] memory e = new address[](1);
        e[0] = makeAddr("solo");
        uint256[] memory a = new uint256[](1);
        a[0] = 1_234_567_891; // 1234.567891 USDC
        (PrivatePayroll.ClaimRequest[] memory r, bytes32[] memory leaves, bytes32 root, uint256 total) =
            _buildPeriod(payrollId, e, a);
        assertEq(root, leaves[0]);
        _fund(root, total);
        vm.prank(e[0]);
        payroll.claim(r[0], new bytes32[](0), e[0]);
        assertEq(usdc.balanceOf(e[0]), 1_234_567_891);
    }

    // ── claimWithAuthorization ──────────────────────────────────────────────

    function _sigSetup(uint256 pk)
        internal
        returns (PrivatePayroll.ClaimRequest memory r, bytes32[] memory proof, uint256 periodId)
    {
        address[] memory e = new address[](2);
        e[0] = vm.addr(pk);
        e[1] = makeAddr("other");
        uint256[] memory a = new uint256[](2);
        a[0] = 4_000 * USDC;
        a[1] = 1_000 * USDC;
        (PrivatePayroll.ClaimRequest[] memory reqs, bytes32[] memory leaves, bytes32 root, uint256 total) =
            _buildPeriod(payrollId, e, a);
        (periodId,) = _fund(root, total);
        r = reqs[0];
        proof = MerkleBuilder.proof(leaves, 0);
    }

    function test_ClaimWithAuthorization_EOA() public {
        uint256 pk = 0xA11CE;
        (PrivatePayroll.ClaimRequest memory r, bytes32[] memory proof, uint256 periodId) = _sigSetup(pk);
        address fresh = makeAddr("fresh");
        uint256 dl = block.timestamp + 1 days;
        bytes memory sig = _sign(pk, payroll.claimAuthorizationDigest(payrollId, periodId, 0, fresh, dl));
        vm.prank(relayer);
        payroll.claimWithAuthorization(r, proof, fresh, dl, sig);
        assertEq(usdc.balanceOf(fresh), 4_000 * USDC);
        assertEq(usdc.balanceOf(relayer), 0);

        // replay of the same authorization fails
        vm.expectRevert(PrivatePayroll.AlreadyClaimed.selector);
        vm.prank(relayer);
        payroll.claimWithAuthorization(r, proof, fresh, dl, sig);
    }

    function test_ClaimWithAuthorization_EIP7702DelegatedEOA() public {
        uint256 pk = 0xA11CE;
        (PrivatePayroll.ClaimRequest memory r, bytes32[] memory proof, uint256 periodId) = _sigSetup(pk);
        // Simulate an EIP-7702 delegation: the EOA now has code (without ERC-1271 support).
        vm.etch(r.employee, hex"ef0100aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        address fresh = makeAddr("fresh");
        uint256 dl = block.timestamp + 1 days;
        bytes memory sig = _sign(pk, payroll.claimAuthorizationDigest(payrollId, periodId, 0, fresh, dl));
        vm.prank(relayer);
        payroll.claimWithAuthorization(r, proof, fresh, dl, sig);
        assertEq(usdc.balanceOf(fresh), 4_000 * USDC);
    }

    function test_ClaimWithAuthorization_Rejections() public {
        uint256 pk = 0xA11CE;
        (PrivatePayroll.ClaimRequest memory r, bytes32[] memory proof, uint256 periodId) = _sigSetup(pk);
        address fresh = makeAddr("fresh");
        uint256 dl = block.timestamp + 1 days;
        bytes memory sig = _sign(pk, payroll.claimAuthorizationDigest(payrollId, periodId, 0, fresh, dl));

        vm.startPrank(relayer);
        // relayer redirects funds to itself
        vm.expectRevert(PrivatePayroll.InvalidAuthorization.selector);
        payroll.claimWithAuthorization(r, proof, relayer, dl, sig);
        // relayer extends the deadline
        vm.expectRevert(PrivatePayroll.InvalidAuthorization.selector);
        payroll.claimWithAuthorization(r, proof, fresh, dl + 1, sig);
        // signature from the wrong key
        bytes memory bad = _sign(0xBAD, payroll.claimAuthorizationDigest(payrollId, periodId, 0, fresh, dl));
        vm.expectRevert(PrivatePayroll.InvalidAuthorization.selector);
        payroll.claimWithAuthorization(r, proof, fresh, dl, bad);
        // malformed signature
        vm.expectRevert(PrivatePayroll.InvalidAuthorization.selector);
        payroll.claimWithAuthorization(r, proof, fresh, dl, hex"1234");
        vm.stopPrank();

        vm.warp(dl + 1);
        vm.expectRevert(PrivatePayroll.AuthorizationExpired.selector);
        vm.prank(relayer);
        payroll.claimWithAuthorization(r, proof, fresh, dl, sig);
    }

    function test_ClaimWithAuthorization_ERC1271Wallet() public {
        uint256 ownerPk = 0xB0B;
        MockERC1271Wallet wallet = new MockERC1271Wallet(vm.addr(ownerPk));
        address[] memory e = new address[](1);
        e[0] = address(wallet);
        uint256[] memory a = new uint256[](1);
        a[0] = 777 * USDC;
        (PrivatePayroll.ClaimRequest[] memory reqs,, bytes32 root, uint256 total) = _buildPeriod(payrollId, e, a);
        (uint256 periodId,) = _fund(root, total);
        address fresh = makeAddr("fresh");
        uint256 dl = block.timestamp + 1 days;
        bytes memory sig = _sign(ownerPk, payroll.claimAuthorizationDigest(payrollId, periodId, 0, fresh, dl));

        wallet.setRejectAll(true);
        vm.expectRevert(PrivatePayroll.InvalidAuthorization.selector);
        vm.prank(relayer);
        payroll.claimWithAuthorization(reqs[0], new bytes32[](0), fresh, dl, sig);

        wallet.setRejectAll(false);
        vm.prank(relayer);
        payroll.claimWithAuthorization(reqs[0], new bytes32[](0), fresh, dl, sig);
        assertEq(usdc.balanceOf(fresh), 777 * USDC);
    }

    function test_EIP712_DomainAndDigest() public view {
        bytes32 expectedDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("StablePilot PrivatePayroll"),
                keccak256("1"),
                block.chainid,
                address(payroll)
            )
        );
        assertEq(payroll.domainSeparator(), expectedDomain);
        bytes32 structHash =
            keccak256(abi.encode(payroll.CLAIM_AUTHORIZATION_TYPEHASH(), 1, 2, 3, address(0xBEEF), 1000));
        assertEq(
            payroll.claimAuthorizationDigest(1, 2, 3, address(0xBEEF), 1000),
            keccak256(abi.encodePacked("\x19\x01", expectedDomain, structHash))
        );
    }

    // ── reclaim ─────────────────────────────────────────────────────────────

    function test_Reclaim_AfterDeadlineReturnsUnclaimed() public {
        (PrivatePayroll.ClaimRequest[] memory r, bytes32[] memory leaves, uint256 periodId) = _twoEmployees();
        vm.prank(r[0].employee);
        payroll.claim(r[0], MerkleBuilder.proof(leaves, 0), r[0].employee);

        uint256 dl = payroll.effectiveDeadline(payrollId, periodId);
        vm.warp(dl);
        vm.expectRevert(PrivatePayroll.ClaimWindowOpen.selector);
        vm.prank(employer);
        payroll.reclaimExpired(payrollId, periodId);

        vm.warp(dl + 1);
        uint256 beforeBal = usdc.balanceOf(employer);
        vm.expectEmit(true, true, false, true);
        emit PrivatePayroll.PeriodReclaimed(payrollId, periodId, r[1].amount);
        vm.prank(employer);
        assertEq(payroll.reclaimExpired(payrollId, periodId), r[1].amount);
        assertEq(usdc.balanceOf(employer), beforeBal + r[1].amount);
        assertTrue(payroll.getPeriod(payrollId, periodId).reclaimed);

        vm.expectRevert(PrivatePayroll.AlreadyReclaimed.selector);
        vm.prank(employer);
        payroll.reclaimExpired(payrollId, periodId);
    }

    function _overlappingPauses(uint256 duration) internal {
        vm.prank(employer);
        payroll.pausePayroll(payrollId);
        vm.prank(protocolOwner);
        payroll.pause();
        vm.warp(block.timestamp + duration);
        vm.prank(protocolOwner);
        payroll.unpause();
        vm.prank(employer);
        payroll.unpausePayroll(payrollId);
    }

    /// Regression (found by invariant_BalanceCoversLiabilities): overlapping payroll + global pauses
    /// are counted twice, which can push an expired period's effective deadline back into the future.
    /// A reclaimed period must still reject claims, otherwise the claim would be paid out of other
    /// periods' / the pool's money.
    function test_Claim_RevertsAfterReclaimEvenIfPauseReopensWindow() public {
        (PrivatePayroll.ClaimRequest[] memory r, bytes32[] memory leaves, uint256 periodId) = _twoEmployees();
        vm.warp(payroll.effectiveDeadline(payrollId, periodId) + 1);
        vm.prank(employer);
        payroll.reclaimExpired(payrollId, periodId);

        _overlappingPauses(20 days);
        assertGt(payroll.effectiveDeadline(payrollId, periodId), block.timestamp); // window "re-opened"

        uint256 poolBefore = payroll.getPayroll(payrollId).pool;
        vm.expectRevert(PrivatePayroll.AlreadyReclaimed.selector);
        vm.prank(r[0].employee);
        payroll.claim(r[0], MerkleBuilder.proof(leaves, 0), r[0].employee);
        assertEq(payroll.getPayroll(payrollId).pool, poolBefore);
    }

    /// A single pause after expiry does not re-open the window (deadline and clock move together)...
    function test_Claim_SinglePauseAfterExpiryDoesNotReopen() public {
        (PrivatePayroll.ClaimRequest[] memory r, bytes32[] memory leaves, uint256 periodId) = _twoEmployees();
        vm.warp(payroll.effectiveDeadline(payrollId, periodId) + 1);
        vm.prank(employer);
        payroll.pausePayroll(payrollId);
        vm.warp(block.timestamp + 2 days);
        vm.prank(employer);
        payroll.unpausePayroll(payrollId);
        vm.expectRevert(PrivatePayroll.ClaimWindowClosed.selector);
        vm.prank(r[0].employee);
        payroll.claim(r[0], MerkleBuilder.proof(leaves, 0), r[0].employee);
    }

    /// ...but overlapping pauses (double-counted) can re-open a not-yet-reclaimed period (favours employees).
    function test_Claim_ExpiredButUnreclaimedReopenedByOverlappingPauses() public {
        (PrivatePayroll.ClaimRequest[] memory r, bytes32[] memory leaves, uint256 periodId) = _twoEmployees();
        vm.warp(payroll.effectiveDeadline(payrollId, periodId) + 1);
        _overlappingPauses(2 days);
        vm.prank(r[0].employee);
        payroll.claim(r[0], MerkleBuilder.proof(leaves, 0), r[0].employee);
        assertEq(usdc.balanceOf(r[0].employee), r[0].amount);
    }

    function test_Reclaim_FullyClaimedReturnsZero() public {
        (PrivatePayroll.ClaimRequest[] memory r, bytes32[] memory leaves, uint256 periodId) = _twoEmployees();
        for (uint256 i; i < 2; ++i) {
            vm.prank(r[i].employee);
            payroll.claim(r[i], MerkleBuilder.proof(leaves, i), r[i].employee);
        }
        vm.warp(payroll.effectiveDeadline(payrollId, periodId) + 1);
        uint256 beforeBal = usdc.balanceOf(employer);
        vm.prank(employer);
        assertEq(payroll.reclaimExpired(payrollId, periodId), 0);
        assertEq(usdc.balanceOf(employer), beforeBal);
    }

    function test_Reclaim_Reverts() public {
        (,, uint256 periodId) = _twoEmployees();
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(PrivatePayroll.NotEmployer.selector);
        vm.prank(stranger);
        payroll.reclaimExpired(payrollId, periodId);
        vm.expectRevert(PrivatePayroll.UnknownPeriod.selector);
        vm.prank(employer);
        payroll.reclaimExpired(payrollId, 99);
        vm.prank(protocolOwner);
        payroll.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(employer);
        payroll.reclaimExpired(payrollId, periodId);
    }

    // ── pause accounting ────────────────────────────────────────────────────

    function test_PayrollPause_ExtendsDeadline() public {
        (PrivatePayroll.ClaimRequest[] memory r, bytes32[] memory leaves, uint256 periodId) = _twoEmployees();
        uint256 nominal = payroll.effectiveDeadline(payrollId, periodId);

        vm.warp(block.timestamp + 10 days);
        vm.prank(employer);
        payroll.pausePayroll(payrollId);
        vm.warp(block.timestamp + 5 days);
        assertEq(payroll.effectiveDeadline(payrollId, periodId), nominal + 5 days); // while paused
        vm.prank(employer);
        payroll.unpausePayroll(payrollId);
        assertEq(payroll.effectiveDeadline(payrollId, periodId), nominal + 5 days);

        // Past the nominal deadline an employee can still claim; employer cannot reclaim yet.
        vm.warp(nominal + 1 days);
        vm.expectRevert(PrivatePayroll.ClaimWindowOpen.selector);
        vm.prank(employer);
        payroll.reclaimExpired(payrollId, periodId);
        vm.prank(r[0].employee);
        payroll.claim(r[0], MerkleBuilder.proof(leaves, 0), r[0].employee);

        // A period funded after the pause is not extended by it.
        (uint256 p2,) = _fund(bytes32(uint256(5)), 1);
        assertEq(payroll.effectiveDeadline(payrollId, p2), _deadline());
    }

    function test_GlobalPause_ExtendsDeadline() public {
        (,, uint256 periodId) = _twoEmployees();
        uint256 nominal = payroll.effectiveDeadline(payrollId, periodId);
        vm.prank(protocolOwner);
        payroll.pause();
        vm.warp(block.timestamp + 3 days);
        assertEq(payroll.effectiveDeadline(payrollId, periodId), nominal + 3 days);
        vm.prank(protocolOwner);
        payroll.unpause();
        assertEq(payroll.globalPausedTotal(), 3 days);
        assertEq(payroll.globalPausedSince(), 0);
        assertEq(payroll.effectiveDeadline(payrollId, periodId), nominal + 3 days);
    }

    function test_PausePayroll_Reverts() public {
        vm.startPrank(employer);
        vm.expectRevert(PrivatePayroll.PayrollNotPaused.selector);
        payroll.unpausePayroll(payrollId);
        payroll.pausePayroll(payrollId);
        vm.expectRevert(PrivatePayroll.PayrollIsPaused.selector);
        payroll.pausePayroll(payrollId);
        vm.stopPrank();
        vm.expectRevert(PrivatePayroll.NotEmployer.selector);
        vm.prank(stranger);
        payroll.unpausePayroll(payrollId);
        vm.expectRevert(PrivatePayroll.UnknownPeriod.selector);
        payroll.effectiveDeadline(payrollId, 1);
    }

    // ── owner controls ──────────────────────────────────────────────────────

    function test_Owner_PauseOnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, employer));
        vm.prank(employer);
        payroll.pause();
        vm.prank(protocolOwner);
        payroll.pause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, employer));
        vm.prank(employer);
        payroll.unpause();
    }

    function test_Owner_SetRegistry() public {
        StablePilotRegistry reg2 = new StablePilotRegistry(address(usdc), treasury, registryOwner);
        vm.expectEmit(true, true, false, false);
        emit PrivatePayroll.RegistryUpdated(address(registry), address(reg2));
        vm.prank(protocolOwner);
        payroll.setRegistry(address(reg2));
        assertEq(address(payroll.registry()), address(reg2));

        vm.startPrank(protocolOwner);
        vm.expectRevert(PrivatePayroll.ZeroAddress.selector);
        payroll.setRegistry(address(0));
        MockRegistryStub wrongToken = new MockRegistryStub(address(0xdead), 0);
        vm.expectRevert(PrivatePayroll.TokenMismatch.selector);
        payroll.setRegistry(address(wrongToken));
        MockRegistryStub wrongModule = new MockRegistryStub(address(usdc), 3);
        vm.expectRevert(PrivatePayroll.ModuleIdMismatch.selector);
        payroll.setRegistry(address(wrongModule));
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        payroll.setRegistry(address(reg2));
    }

    function test_Owner_RenounceDisabledAndTwoStepTransfer() public {
        vm.expectRevert(PrivatePayroll.RenounceOwnershipDisabled.selector);
        vm.prank(protocolOwner);
        payroll.renounceOwnership();

        vm.prank(protocolOwner);
        payroll.transferOwnership(stranger);
        assertEq(payroll.owner(), protocolOwner);
        vm.prank(stranger);
        payroll.acceptOwnership();
        assertEq(payroll.owner(), stranger);
    }

    // ── fuzz ────────────────────────────────────────────────────────────────

    /// Fee charged on funding always equals registry.computeFee and lands in the treasury.
    function testFuzz_FundPeriod_FeeMatchesRegistry(uint256 total, uint16 bps, uint8 discount) public {
        total = bound(total, 1, 1_000_000 * USDC);
        bps = uint16(bound(bps, 0, 500));
        discount = uint8(bound(discount, 49, 100)); // 49 => no partner discount
        vm.startPrank(registryOwner);
        registry.setFeeRate(0, bps);
        if (discount >= 50) registry.setPartnerDiscount(employer, discount);
        vm.stopPrank();

        uint256 expected = registry.computeFee(0, total, employer);
        assertEq(payroll.quoteFee(payrollId, total), expected);
        uint256 employerBefore = usdc.balanceOf(employer);
        uint256 contractBefore = usdc.balanceOf(address(payroll));

        (, uint256 fee) = _fund(bytes32(uint256(1)), total);

        assertEq(fee, expected);
        assertEq(usdc.balanceOf(treasury), expected);
        assertEq(usdc.balanceOf(employer), employerBefore - expected);
        assertEq(usdc.balanceOf(address(payroll)), contractBefore);
        assertLe(fee, (total * 500) / 10_000);
    }

    /// Every employee in a random tree can claim exactly once; sum of claims == total.
    function testFuzz_ClaimAll_ExactlyOnce(uint8 n, uint256 seed) public {
        n = uint8(bound(n, 1, 40));
        address[] memory e = new address[](n);
        uint256[] memory a = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            e[i] = address(uint160(uint256(keccak256(abi.encode(seed, "emp", i))) | 1));
            a[i] = bound(uint256(keccak256(abi.encode(seed, "amt", i))), 0, 20_000 * USDC);
        }
        (PrivatePayroll.ClaimRequest[] memory r, bytes32[] memory leaves, bytes32 root, uint256 total) =
            _buildPeriod(payrollId, e, a);
        vm.assume(total > 0);
        (uint256 periodId,) = _fund(root, total);
        uint256 balBefore = usdc.balanceOf(address(payroll));

        for (uint256 i; i < n; ++i) {
            bytes32[] memory proof = MerkleBuilder.proof(leaves, i);
            vm.prank(e[i]);
            payroll.claim(r[i], proof, e[i]);
            vm.expectRevert(PrivatePayroll.AlreadyClaimed.selector);
            vm.prank(e[i]);
            payroll.claim(r[i], proof, e[i]);
        }
        assertEq(payroll.getPeriod(payrollId, periodId).claimed, total);
        assertEq(usdc.balanceOf(address(payroll)), balBefore - total);
    }

    /// Any tampered amount fails proof verification.
    function testFuzz_Claim_TamperedAmountFails(uint256 fakeAmount) public {
        (PrivatePayroll.ClaimRequest[] memory r, bytes32[] memory leaves,) = _twoEmployees();
        vm.assume(fakeAmount != r[0].amount);
        PrivatePayroll.ClaimRequest memory t = r[0];
        t.amount = fakeAmount;
        vm.expectRevert(PrivatePayroll.InvalidProof.selector);
        vm.prank(t.employee);
        payroll.claim(t, MerkleBuilder.proof(leaves, 0), t.employee);
    }

    /// Deadline must be inside [now + MIN, now + MAX].
    function testFuzz_FundPeriod_DeadlineBounds(uint64 offset) public {
        uint64 dl = uint64(block.timestamp) + uint64(bound(offset, 0, 1000 days));
        bool ok =
            dl >= block.timestamp + payroll.MIN_CLAIM_WINDOW() && dl <= block.timestamp + payroll.MAX_CLAIM_WINDOW();
        if (!ok) vm.expectRevert(PrivatePayroll.InvalidDeadline.selector);
        vm.prank(employer);
        payroll.fundPeriod(payrollId, bytes32(uint256(1)), 1, dl);
    }

    /// Reclaim is possible iff the effective deadline has passed.
    function testFuzz_Reclaim_OnlyAfterDeadline(uint256 warpBy) public {
        (,, uint256 periodId) = _twoEmployees();
        warpBy = bound(warpBy, 0, 400 days);
        uint256 dl = payroll.effectiveDeadline(payrollId, periodId);
        vm.warp(block.timestamp + warpBy);
        if (block.timestamp <= dl) vm.expectRevert(PrivatePayroll.ClaimWindowOpen.selector);
        vm.prank(employer);
        payroll.reclaimExpired(payrollId, periodId);
    }
}
