// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import {IStablePilotRegistry} from "./interfaces/IStablePilotRegistry.sol";

/// @title PrivatePayroll (v1)
/// @notice Commitment-based USDC payroll for StablePilot on Arc.
/// Employers fund a pooled USDC balance, then post one Merkle root per pay period that commits to
/// every (employee, amount, salt) entry. Individual salaries are NOT stored on-chain; each employee
/// reveals only their own entry when they claim (pull payment), optionally to a fresh recipient.
///
/// Protocol fee: charged once per funded period through StablePilotRegistry.collectFee
/// (moduleId = MODULE_PAYROLL, txAmount = period total, payer = employer). The fee is pulled by the
/// registry directly from the employer, never from the payroll pool, so employees always receive
/// their full committed amount.
///
/// v1 privacy is limited (see PrivatePayroll-design.md): a claim reveals that employee's amount,
/// address and recipient in calldata and in the USDC Transfer. v2 replaces claims with ZK notes.
///
/// Leaf encoding (OpenZeppelin StandardMerkleTree compatible, double-hashed):
///   leaf = keccak256(bytes.concat(keccak256(abi.encode(payrollId, periodId, index, employee, amount, salt))))
/// with types (uint256, uint256, uint256, address, uint256, bytes32). Tree nodes use sorted-pair
/// keccak256 (MerkleProof). `amount` is in USDC base units (6 decimals on Arc's ERC-20 interface).
contract PrivatePayroll is Ownable2Step, ReentrancyGuard, Pausable, EIP712 {
    using SafeERC20 for IERC20;
    using BitMaps for BitMaps.BitMap;

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @notice Module id this contract must be registered under in StablePilotRegistry.
    uint8 public constant MODULE_PAYROLL = 0;
    /// @notice Minimum time employees get to claim a funded period.
    uint64 public constant MIN_CLAIM_WINDOW = 7 days;
    /// @notice Maximum claim window (bounds how long employer funds can be locked).
    uint64 public constant MAX_CLAIM_WINDOW = 730 days;

    bytes32 public constant CLAIM_AUTHORIZATION_TYPEHASH = keccak256(
        "ClaimAuthorization(uint256 payrollId,uint256 periodId,uint256 index,address recipient,uint256 deadline)"
    );

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    struct Payroll {
        address employer;
        bool paused;
        uint32 periodCount;
        uint64 pausedSince; // 0 when not paused
        uint64 pausedTotal; // cumulative seconds paused (completed pauses)
        uint128 pool; // unallocated USDC (base units)
    }

    struct Period {
        bytes32 root;
        uint128 total; // committed total for the period
        uint128 claimed; // sum claimed so far
        uint64 deadline; // nominal claim deadline (extended by pauses, see effectiveDeadline)
        uint64 globalPauseSnapshot; // globalPausedTotal at funding time
        uint64 payrollPauseSnapshot; // payroll.pausedTotal at funding time
        bool reclaimed;
    }

    /// @notice One leaf of a period's Merkle tree, revealed by the employee at claim time.
    struct ClaimRequest {
        uint256 payrollId;
        uint256 periodId;
        uint256 index;
        address employee;
        uint256 amount;
        bytes32 salt;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    IERC20 public immutable usdc;
    IStablePilotRegistry public registry;

    uint256 public payrollCount;
    uint64 public globalPausedSince;
    uint64 public globalPausedTotal;

    mapping(uint256 payrollId => Payroll) internal _payrolls;
    mapping(uint256 payrollId => mapping(uint256 periodId => Period)) internal _periods;
    mapping(uint256 payrollId => mapping(uint256 periodId => BitMaps.BitMap)) internal _claimed;

    // ---------------------------------------------------------------------
    // Events (amounts only where the USDC Transfer already makes them public)
    // ---------------------------------------------------------------------

    event PayrollCreated(uint256 indexed payrollId, address indexed employer);
    event Deposited(uint256 indexed payrollId, uint256 amount);
    event Withdrawn(uint256 indexed payrollId, uint256 amount);
    event PeriodFunded(
        uint256 indexed payrollId, uint256 indexed periodId, bytes32 root, uint256 total, uint64 deadline, uint256 fee
    );
    event Claimed(uint256 indexed payrollId, uint256 indexed periodId, uint256 index);
    event PeriodReclaimed(uint256 indexed payrollId, uint256 indexed periodId, uint256 amount);
    event PayrollPaused(uint256 indexed payrollId);
    event PayrollUnpaused(uint256 indexed payrollId);
    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error ZeroRoot();
    error NotEmployer();
    error UnknownPayroll();
    error UnknownPeriod();
    error PayrollIsPaused();
    error PayrollNotPaused();
    error InsufficientPool();
    error InvalidDeadline();
    error DepositMismatch();
    error ClaimWindowClosed();
    error ClaimWindowOpen();
    error AlreadyClaimed();
    error AlreadyReclaimed();
    error InvalidProof();
    error ExceedsPeriodTotal();
    error AuthorizationExpired();
    error InvalidAuthorization();
    error TokenMismatch();
    error ModuleIdMismatch();
    error RenounceOwnershipDisabled();

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param _registry StablePilotRegistry; its `usdc()` becomes this contract's settlement token.
    /// @param _initialOwner Protocol owner (global pause + registry pointer only; no access to funds).
    constructor(address _registry, address _initialOwner)
        Ownable(_initialOwner)
        EIP712("StablePilot PrivatePayroll", "1")
    {
        if (_registry == address(0)) revert ZeroAddress();
        address token = IStablePilotRegistry(_registry).usdc();
        if (token == address(0)) revert ZeroAddress();
        if (IStablePilotRegistry(_registry).MODULE_PAYROLL() != MODULE_PAYROLL) revert ModuleIdMismatch();
        usdc = IERC20(token);
        registry = IStablePilotRegistry(_registry);
    }

    // ---------------------------------------------------------------------
    // Modifiers / internal checks
    // ---------------------------------------------------------------------

    modifier onlyEmployer(uint256 payrollId) {
        address employer = _payrolls[payrollId].employer;
        if (employer == address(0)) revert UnknownPayroll();
        if (msg.sender != employer) revert NotEmployer();
        _;
    }

    // ---------------------------------------------------------------------
    // Employer: setup & funding
    // ---------------------------------------------------------------------

    /// @notice Creates a new payroll owned by the caller.
    function createPayroll() external whenNotPaused returns (uint256 payrollId) {
        payrollId = ++payrollCount;
        _payrolls[payrollId].employer = msg.sender;
        emit PayrollCreated(payrollId, msg.sender);
    }

    /// @notice Adds USDC to the payroll's unallocated pool. Caller must approve this contract.
    function deposit(uint256 payrollId, uint256 amount) external nonReentrant whenNotPaused onlyEmployer(payrollId) {
        if (amount == 0) revert ZeroAmount();
        Payroll storage p = _payrolls[payrollId];
        p.pool += SafeCast.toUint128(amount);

        uint256 balanceBefore = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        if (usdc.balanceOf(address(this)) - balanceBefore != amount) revert DepositMismatch();

        emit Deposited(payrollId, amount);
    }

    /// @notice Withdraws unallocated USDC back to the employer. Allowed even while paused.
    function withdrawUnallocated(uint256 payrollId, uint256 amount) external nonReentrant onlyEmployer(payrollId) {
        if (amount == 0) revert ZeroAmount();
        Payroll storage p = _payrolls[payrollId];
        if (amount > p.pool) revert InsufficientPool();
        // forge-lint: disable-next-line(unsafe-typecast) -- amount <= pool (uint128)
        p.pool -= uint128(amount);

        usdc.safeTransfer(msg.sender, amount);
        emit Withdrawn(payrollId, amount);
    }

    /// @notice Allocates `total` from the pool to a new pay period committed by `root`, and charges
    /// the protocol fee on `total` via StablePilotRegistry (pulled from the employer, who must have
    /// approved the registry for at least `quoteFee(payrollId, total)`).
    /// @param deadline Claim deadline (unix seconds), within [now + MIN_CLAIM_WINDOW, now + MAX_CLAIM_WINDOW].
    function fundPeriod(uint256 payrollId, bytes32 root, uint256 total, uint64 deadline)
        external
        nonReentrant
        whenNotPaused
        onlyEmployer(payrollId)
        returns (uint256 periodId, uint256 fee)
    {
        Payroll storage p = _payrolls[payrollId];
        if (p.paused) revert PayrollIsPaused();
        if (root == bytes32(0)) revert ZeroRoot();
        if (total == 0) revert ZeroAmount();
        if (total > p.pool) revert InsufficientPool();
        // forge-lint: disable-next-line(block-timestamp) -- day-scale windows; seconds of drift are irrelevant
        if (deadline < block.timestamp + MIN_CLAIM_WINDOW || deadline > block.timestamp + MAX_CLAIM_WINDOW) {
            revert InvalidDeadline();
        }

        // forge-lint: disable-next-line(unsafe-typecast) -- total <= pool (uint128)
        p.pool -= uint128(total);
        periodId = ++p.periodCount;
        _periods[payrollId][periodId] = Period({
            root: root,
            // forge-lint: disable-next-line(unsafe-typecast) -- total <= pool (uint128)
            total: uint128(total),
            claimed: 0,
            deadline: deadline,
            globalPauseSnapshot: globalPausedTotal,
            payrollPauseSnapshot: p.pausedTotal,
            reclaimed: false
        });

        // Registry: requires this contract to be a registered module with id MODULE_PAYROLL.
        // Returns 0 (no transfer) while fees are disabled or the payroll fee rate is 0.
        fee = registry.collectFee(MODULE_PAYROLL, total, msg.sender);

        emit PeriodFunded(payrollId, periodId, root, total, deadline, fee);
    }

    /// @notice After a period's (pause-adjusted) deadline, returns its unclaimed USDC to the employer.
    function reclaimExpired(uint256 payrollId, uint256 periodId)
        external
        nonReentrant
        whenNotPaused
        onlyEmployer(payrollId)
        returns (uint256 amount)
    {
        Period storage per = _periods[payrollId][periodId];
        if (per.root == bytes32(0)) revert UnknownPeriod();
        if (per.reclaimed) revert AlreadyReclaimed();
        // forge-lint: disable-next-line(block-timestamp) -- day-scale windows; seconds of drift are irrelevant
        if (block.timestamp <= _effectiveDeadline(payrollId, per)) revert ClaimWindowOpen();

        per.reclaimed = true;
        amount = per.total - per.claimed;
        if (amount > 0) usdc.safeTransfer(msg.sender, amount);
        emit PeriodReclaimed(payrollId, periodId, amount);
    }

    /// @notice Employer pauses claims and new periods for one payroll. Claim deadlines are extended
    /// by the time spent paused, so pausing can never be used to run out an employee's claim window.
    function pausePayroll(uint256 payrollId) external onlyEmployer(payrollId) {
        Payroll storage p = _payrolls[payrollId];
        if (p.paused) revert PayrollIsPaused();
        p.paused = true;
        p.pausedSince = uint64(block.timestamp);
        emit PayrollPaused(payrollId);
    }

    /// @notice Employer resumes a paused payroll.
    function unpausePayroll(uint256 payrollId) external onlyEmployer(payrollId) {
        Payroll storage p = _payrolls[payrollId];
        if (!p.paused) revert PayrollNotPaused();
        p.pausedTotal += uint64(block.timestamp) - p.pausedSince;
        p.paused = false;
        p.pausedSince = 0;
        emit PayrollUnpaused(payrollId);
    }

    // ---------------------------------------------------------------------
    // Employee: claims
    // ---------------------------------------------------------------------

    /// @notice Employee (the `employee` in the leaf) claims their salary to any `recipient`.
    function claim(ClaimRequest calldata c, bytes32[] calldata proof, address recipient)
        external
        nonReentrant
        whenNotPaused
    {
        if (msg.sender != c.employee) revert InvalidAuthorization();
        _claim(c, proof, recipient);
    }

    /// @notice Anyone (e.g. a relayer or the fresh recipient) submits a claim authorized by an EIP-712
    /// `ClaimAuthorization` signature from the leaf's employee (EOA, EIP-7702 account or ERC-1271 wallet).
    /// Replay is impossible: each (payrollId, periodId, index) can be claimed once.
    function claimWithAuthorization(
        ClaimRequest calldata c,
        bytes32[] calldata proof,
        address recipient,
        uint256 authDeadline,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        // forge-lint: disable-next-line(block-timestamp) -- day-scale windows; seconds of drift are irrelevant
        if (block.timestamp > authDeadline) revert AuthorizationExpired();
        bytes32 digest = claimAuthorizationDigest(c.payrollId, c.periodId, c.index, recipient, authDeadline);
        if (!_isValidSignature(c.employee, digest, signature)) revert InvalidAuthorization();
        _claim(c, proof, recipient);
    }

    function _claim(ClaimRequest calldata c, bytes32[] calldata proof, address recipient) internal {
        if (recipient == address(0)) revert ZeroAddress();
        Payroll storage p = _payrolls[c.payrollId];
        if (p.paused) revert PayrollIsPaused();
        Period storage per = _periods[c.payrollId][c.periodId];
        if (per.root == bytes32(0)) revert UnknownPeriod();
        // Once reclaimed, a period is closed for good, even if later pauses push its effective deadline out.
        if (per.reclaimed) revert AlreadyReclaimed();
        // forge-lint: disable-next-line(block-timestamp) -- day-scale windows; seconds of drift are irrelevant
        if (block.timestamp > _effectiveDeadline(c.payrollId, per)) revert ClaimWindowClosed();

        BitMaps.BitMap storage claimedMap = _claimed[c.payrollId][c.periodId];
        if (claimedMap.get(c.index)) revert AlreadyClaimed();
        if (!MerkleProof.verifyCalldata(proof, per.root, leafHash(c))) revert InvalidProof();
        // Solvency guard: a malformed root can never draw more than its own period's funding.
        if (c.amount > per.total - per.claimed) revert ExceedsPeriodTotal();

        claimedMap.set(c.index);
        // forge-lint: disable-next-line(unsafe-typecast) -- amount <= total - claimed (uint128)
        per.claimed += uint128(c.amount);

        if (c.amount > 0) usdc.safeTransfer(recipient, c.amount);
        emit Claimed(c.payrollId, c.periodId, c.index);
    }

    function _isValidSignature(address signer, bytes32 digest, bytes calldata signature) internal view returns (bool) {
        // Try plain ECDSA first so EIP-7702-delegated EOAs (which have code on Arc) still work,
        // then fall back to ERC-1271 for smart-contract wallets.
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == signer) return true;
        return SignatureChecker.isValidERC1271SignatureNow(signer, digest, signature);
    }

    // ---------------------------------------------------------------------
    // Owner (protocol) controls: no access to funds
    // ---------------------------------------------------------------------

    /// @notice Global emergency pause: stops new payrolls, deposits, funding, claims and reclaims.
    /// Employers can still withdraw unallocated funds. Claim deadlines are extended by the pause.
    function pause() external onlyOwner {
        globalPausedSince = uint64(block.timestamp);
        _pause();
    }

    /// @notice Lifts the global pause.
    function unpause() external onlyOwner {
        globalPausedTotal += uint64(block.timestamp) - globalPausedSince;
        globalPausedSince = 0;
        _unpause();
    }

    /// @notice Points the module at a new registry (registry migration, see registry design doc).
    function setRegistry(address newRegistry) external onlyOwner {
        if (newRegistry == address(0)) revert ZeroAddress();
        if (IStablePilotRegistry(newRegistry).usdc() != address(usdc)) revert TokenMismatch();
        if (IStablePilotRegistry(newRegistry).MODULE_PAYROLL() != MODULE_PAYROLL) revert ModuleIdMismatch();
        emit RegistryUpdated(address(registry), newRegistry);
        registry = IStablePilotRegistry(newRegistry);
    }

    /// @notice Renouncing would make the global pause irreversible; disabled.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Merkle leaf for a claim (must match tools/merkle).
    function leafHash(ClaimRequest calldata c) public pure returns (bytes32) {
        return
            keccak256(
                bytes.concat(keccak256(abi.encode(c.payrollId, c.periodId, c.index, c.employee, c.amount, c.salt)))
            );
    }

    /// @notice EIP-712 digest the employee signs to authorize a claim to `recipient`.
    function claimAuthorizationDigest(
        uint256 payrollId,
        uint256 periodId,
        uint256 index,
        address recipient,
        uint256 authDeadline
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(CLAIM_AUTHORIZATION_TYPEHASH, payrollId, periodId, index, recipient, authDeadline))
        );
    }

    /// @notice EIP-712 domain separator.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Protocol fee the employer will pay (to the treasury, via the registry) for funding `total`.
    function quoteFee(uint256 payrollId, uint256 total) external view returns (uint256) {
        return registry.computeFee(MODULE_PAYROLL, total, _payrolls[payrollId].employer);
    }

    function getPayroll(uint256 payrollId) external view returns (Payroll memory) {
        return _payrolls[payrollId];
    }

    function getPeriod(uint256 payrollId, uint256 periodId) external view returns (Period memory) {
        return _periods[payrollId][periodId];
    }

    function isClaimed(uint256 payrollId, uint256 periodId, uint256 index) external view returns (bool) {
        return _claimed[payrollId][periodId].get(index);
    }

    /// @notice Claim deadline including time the payroll and/or the whole contract spent paused.
    function effectiveDeadline(uint256 payrollId, uint256 periodId) external view returns (uint256) {
        Period storage per = _periods[payrollId][periodId];
        if (per.root == bytes32(0)) revert UnknownPeriod();
        return _effectiveDeadline(payrollId, per);
    }

    function _effectiveDeadline(uint256 payrollId, Period storage per) internal view returns (uint256) {
        Payroll storage p = _payrolls[payrollId];
        uint256 payrollPaused = p.pausedTotal + (p.paused ? block.timestamp - p.pausedSince : 0);
        uint256 globalPaused = globalPausedTotal + (paused() ? block.timestamp - globalPausedSince : 0);
        // Overlapping payroll + global pauses are counted twice (can even re-open an expired, not yet
        // reclaimed period). This only ever favours employees; reclaimed periods stay closed (_claim).
        return
            uint256(per.deadline) + (payrollPaused - per.payrollPauseSnapshot)
                + (globalPaused - per.globalPauseSnapshot);
    }
}
