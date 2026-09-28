// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {StablePilotRegistry} from "../StablePilotRegistry.sol";
import {PrivatePayroll} from "../PrivatePayroll.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {MerkleBuilder} from "../test-helpers/MerkleBuilder.sol";

/// @notice Drives PrivatePayroll through random sequences of employer/employee/owner actions.
contract PayrollHandler is Test {
    PrivatePayroll public immutable payroll;
    StablePilotRegistry public immutable registry;
    MockERC20 public immutable usdc;
    address public immutable protocolOwner;
    address public immutable registryOwner;

    address[2] public employers;
    uint256[2] public payrollIds;
    address[5] public employees;

    struct PeriodRef {
        uint256 payrollId;
        uint256 periodId;
    }

    PeriodRef[] public periods;
    mapping(uint256 => mapping(uint256 => PrivatePayroll.ClaimRequest[])) internal _reqs;
    mapping(uint256 => mapping(uint256 => bytes32[])) internal _leaves;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => bool))) public ghostClaimed;

    uint256 public ghost_deposited;
    uint256 public ghost_withdrawn;
    uint256 public ghost_claimed;
    uint256 public ghost_reclaimed;
    uint256 public ghost_fees;
    uint256 public ghost_doubleClaimSucceeded;
    uint256 public ghost_claimAfterWindowSucceeded;
    uint256 public ghost_reclaimBeforeWindowSucceeded;
    uint256 public ghost_claimAfterReclaimSucceeded;
    mapping(uint256 => mapping(uint256 => bool)) public ghostReclaimed;
    uint256 public calls_claim;
    uint256 public calls_reclaim;

    constructor(
        PrivatePayroll _payroll,
        StablePilotRegistry _registry,
        MockERC20 _usdc,
        address _protocolOwner,
        address _registryOwner
    ) {
        payroll = _payroll;
        registry = _registry;
        usdc = _usdc;
        protocolOwner = _protocolOwner;
        registryOwner = _registryOwner;
        for (uint256 i; i < 2; ++i) {
            employers[i] = makeAddr(string(abi.encodePacked("employer", vm.toString(i))));
            usdc.mint(employers[i], type(uint128).max);
            vm.startPrank(employers[i]);
            usdc.approve(address(payroll), type(uint256).max);
            usdc.approve(address(registry), type(uint256).max);
            payrollIds[i] = payroll.createPayroll();
            vm.stopPrank();
        }
        for (uint256 i; i < 5; ++i) {
            employees[i] = makeAddr(string(abi.encodePacked("employee", vm.toString(i))));
        }
    }

    function periodsLength() external view returns (uint256) {
        return periods.length;
    }

    // ── employer actions ────────────────────────────────────────────────────

    function deposit(uint256 who, uint256 amount) external {
        who = bound(who, 0, 1);
        amount = bound(amount, 1, 1_000_000e6);
        if (payroll.paused()) return;
        vm.prank(employers[who]);
        payroll.deposit(payrollIds[who], amount);
        ghost_deposited += amount;
    }

    function withdraw(uint256 who, uint256 amount) external {
        who = bound(who, 0, 1);
        uint256 pool = payroll.getPayroll(payrollIds[who]).pool;
        if (pool == 0) return;
        amount = bound(amount, 1, pool);
        vm.prank(employers[who]);
        payroll.withdrawUnallocated(payrollIds[who], amount);
        ghost_withdrawn += amount;
    }

    /// Funds a period whose leaves sum to `total` (or over-commit it when `overCommit` is set,
    /// to exercise the per-period solvency guard).
    function fundPeriod(uint256 who, uint256 n, uint256 seed, bool overCommit) external {
        who = bound(who, 0, 1);
        n = bound(n, 1, 6);
        uint256 pid = payrollIds[who];
        PrivatePayroll.Payroll memory p = payroll.getPayroll(pid);
        if (payroll.paused() || p.paused) return;

        uint256 periodId = p.periodCount + 1;
        uint256 sum;
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            uint256 amount = bound(uint256(keccak256(abi.encode(seed, i))), 0, 50_000e6);
            PrivatePayroll.ClaimRequest memory r = PrivatePayroll.ClaimRequest(
                pid, periodId, i, employees[i % 5], amount, keccak256(abi.encode(pid, periodId, i, seed))
            );
            _reqs[pid][periodId].push(r);
            leaves[i] = payroll.leafHash(r);
            _leaves[pid][periodId].push(leaves[i]);
            sum += amount;
        }
        uint256 total = overCommit ? sum / 2 : sum;
        if (total == 0 || total > p.pool) {
            delete _reqs[pid][periodId];
            delete _leaves[pid][periodId];
            return;
        }
        uint256 expectedFee = registry.computeFee(0, total, employers[who]);
        vm.prank(employers[who]);
        (uint256 got, uint256 fee) =
            payroll.fundPeriod(pid, MerkleBuilder.root(leaves), total, uint64(block.timestamp + 7 days));
        assertEq(got, periodId);
        assertEq(fee, expectedFee);
        ghost_fees += fee;
        periods.push(PeriodRef(pid, periodId));
    }

    function reclaim(uint256 periodSeed) external {
        if (periods.length == 0 || payroll.paused()) return;
        PeriodRef memory ref = periods[bound(periodSeed, 0, periods.length - 1)];
        PrivatePayroll.Period memory per = payroll.getPeriod(ref.payrollId, ref.periodId);
        address employer = payroll.getPayroll(ref.payrollId).employer;
        bool expired = block.timestamp > payroll.effectiveDeadline(ref.payrollId, ref.periodId);
        vm.prank(employer);
        try payroll.reclaimExpired(ref.payrollId, ref.periodId) returns (uint256 amount) {
            if (!expired) ghost_reclaimBeforeWindowSucceeded++;
            assertEq(amount, per.total - per.claimed);
            ghostReclaimed[ref.payrollId][ref.periodId] = true;
            ghost_reclaimed += amount;
            calls_reclaim++;
        } catch {}
    }

    function togglePayrollPause(uint256 who) external {
        who = bound(who, 0, 1);
        uint256 pid = payrollIds[who];
        bool isPaused = payroll.getPayroll(pid).paused; // read before prank (prank applies to next call)
        vm.prank(employers[who]);
        if (isPaused) payroll.unpausePayroll(pid);
        else payroll.pausePayroll(pid);
    }

    // ── employee actions ────────────────────────────────────────────────────

    function claim(uint256 periodSeed, uint256 leafSeed, uint256 recipientSeed) external {
        if (periods.length == 0) return;
        PeriodRef memory ref = periods[bound(periodSeed, 0, periods.length - 1)];
        PrivatePayroll.ClaimRequest[] storage reqs = _reqs[ref.payrollId][ref.periodId];
        uint256 i = bound(leafSeed, 0, reqs.length - 1);
        PrivatePayroll.ClaimRequest memory r = reqs[i];
        bytes32[] memory proof = MerkleBuilder.proof(_leaves[ref.payrollId][ref.periodId], i);
        address recipient = address(uint160(bound(recipientSeed, 1, 1000)));
        bool windowOpen = block.timestamp <= payroll.effectiveDeadline(ref.payrollId, ref.periodId);

        vm.prank(r.employee);
        try payroll.claim(r, proof, recipient) {
            if (ghostClaimed[ref.payrollId][ref.periodId][i]) ghost_doubleClaimSucceeded++;
            if (!windowOpen) ghost_claimAfterWindowSucceeded++;
            if (ghostReclaimed[ref.payrollId][ref.periodId]) ghost_claimAfterReclaimSucceeded++;
            ghostClaimed[ref.payrollId][ref.periodId][i] = true;
            ghost_claimed += r.amount;
            calls_claim++;
        } catch {}
    }

    // ── protocol / environment ──────────────────────────────────────────────

    function toggleGlobalPause() external {
        bool isPaused = payroll.paused();
        vm.prank(protocolOwner);
        if (isPaused) payroll.unpause();
        else payroll.pause();
    }

    function setFeeRate(uint16 bps) external {
        vm.prank(registryOwner);
        registry.setFeeRate(0, uint16(bound(bps, 0, 500)));
    }

    function warp(uint256 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 1, 10 days));
    }
}

contract PrivatePayrollInvariantTest is Test {
    MockERC20 internal usdc;
    StablePilotRegistry internal registry;
    PrivatePayroll internal payroll;
    PayrollHandler internal handler;

    address internal treasury = makeAddr("treasury");
    address internal registryOwner = makeAddr("registryOwner");
    address internal protocolOwner = makeAddr("protocolOwner");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        registry = new StablePilotRegistry(address(usdc), treasury, registryOwner);
        payroll = new PrivatePayroll(address(registry), protocolOwner);
        vm.startPrank(registryOwner);
        registry.addModule(address(payroll), 0);
        registry.setFeeRate(0, 100);
        registry.setFeesEnabled(true);
        vm.stopPrank();

        handler = new PayrollHandler(payroll, registry, usdc, protocolOwner, registryOwner);
        targetContract(address(handler));
    }

    /// Conservation: everything employers put in (deposits + fees) is accounted for as
    /// claimed + reclaimed + withdrawn + fees (treasury) + contract balance.
    function invariant_FundsConserved() public view {
        uint256 balance = usdc.balanceOf(address(payroll));
        assertEq(
            handler.ghost_deposited() + handler.ghost_fees(),
            handler.ghost_claimed() + handler.ghost_reclaimed() + handler.ghost_withdrawn() + usdc.balanceOf(treasury)
                + balance
        );
    }

    /// Fees reach the treasury and match registry.computeFee at funding time.
    function invariant_TreasuryEqualsFees() public view {
        assertEq(usdc.balanceOf(treasury), handler.ghost_fees());
    }

    /// Contract balance equals the sum of unallocated pools plus outstanding period liabilities.
    function invariant_BalanceCoversLiabilities() public view {
        uint256 liabilities;
        for (uint256 i; i < 2; ++i) {
            liabilities += payroll.getPayroll(handler.payrollIds(i)).pool;
        }
        uint256 n = handler.periodsLength();
        for (uint256 i; i < n; ++i) {
            (uint256 pid, uint256 periodId) = handler.periods(i);
            PrivatePayroll.Period memory per = payroll.getPeriod(pid, periodId);
            assertLe(per.claimed, per.total, "period over-claimed");
            if (!per.reclaimed) liabilities += per.total - per.claimed;
        }
        assertEq(usdc.balanceOf(address(payroll)), liabilities);
    }

    /// No leaf is ever paid twice, no claim after the window or after a reclaim, no reclaim before expiry.
    function invariant_NoDoubleClaimOrWindowViolation() public view {
        assertEq(handler.ghost_doubleClaimSucceeded(), 0);
        assertEq(handler.ghost_claimAfterWindowSucceeded(), 0);
        assertEq(handler.ghost_reclaimBeforeWindowSucceeded(), 0);
        assertEq(handler.ghost_claimAfterReclaimSucceeded(), 0);
    }

    /// Call summary (visible with -vv): shows the campaign really exercises claims and reclaims.
    function invariant_callSummary() public view {
        console2.log("successful claims:", handler.calls_claim());
        console2.log("successful reclaims:", handler.calls_reclaim());
        console2.log("periods funded:", handler.periodsLength());
    }
}
