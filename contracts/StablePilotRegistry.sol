// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title StablePilotRegistry
/// @notice Per-transaction USDC protocol fee registry for StablePilot modules.
contract StablePilotRegistry is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 public constant MODULE_PAYROLL = 0;
    uint8 public constant MODULE_SUPPLY = 1;
    uint8 public constant MODULE_DARKPOOL = 2;
    uint8 public constant MODULE_ZKCREDIT = 3;

    uint16 public constant MAX_FEE_BPS = 500;
    uint8 public constant MIN_DISCOUNT = 50;
    uint8 public constant MAX_DISCOUNT = 100;

    IERC20 public immutable usdc;
    address public treasury;
    address public pendingTreasury;
    bool public feesEnabled;

    /// @notice Fee rate (in bps) for each module id.
    mapping(uint8 => uint16) public feeRateBps;
    /// @notice Registered module addresses permitted to collect fees.
    mapping(address => bool) public isModule;
    /// @notice Registered module id bound to each module address.
    mapping(address => uint8) public registeredModuleId;
    /// @notice Partner fee multiplier: 50-100, where 0 means no partner discount.
    mapping(address => uint8) public discountMultiplier;

    event FeeCollected(uint8 indexed moduleId, address indexed payer, uint256 feeAmount, uint256 txAmount);
    event FeeRateSet(uint8 indexed moduleId, uint16 oldBps, uint16 newBps);
    event FeesToggled(bool enabled);
    event ModuleAdded(address indexed module, uint8 moduleId);
    event ModuleRemoved(address indexed module);
    event PartnerDiscountSet(address indexed partner, uint8 multiplier);
    event PartnerDiscountRemoved(address indexed partner);
    event TreasuryUpdateProposed(address indexed pendingTreasury);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    error NotModule();
    error ModuleIdMismatch();
    error FeeBpsTooHigh(uint16 bps);
    error InvalidDiscount(uint8 multiplier);
    error ZeroAddress(string param);
    error NotPendingTreasury();
    error RenounceOwnershipDisabled();

    /// @notice Initializes the registry with USDC token, treasury, and owner.
    /// @param _usdc USDC token address.
    /// @param _treasury Treasury recipient for collected fees.
    /// @param _initialOwner Initial contract owner.
    constructor(address _usdc, address _treasury, address _initialOwner) Ownable(_initialOwner) {
        if (_usdc == address(0)) revert ZeroAddress("usdc");
        if (_treasury == address(0)) revert ZeroAddress("treasury");
        // Note: Ownable(_initialOwner) already reverts with OwnableInvalidOwner if _initialOwner is zero.
        usdc = IERC20(_usdc);
        treasury = _treasury;
        feesEnabled = false;
    }

    /// @notice Collects protocol fee in USDC from payer to treasury for a module transaction.
    /// @param moduleId StablePilot module id.
    /// @param txAmount Transaction amount basis used for fee calculation.
    /// @param payer Address paying the USDC fee.
    /// @return feeAmount The final transferred fee amount.
    function collectFee(uint8 moduleId, uint256 txAmount, address payer)
        external
        nonReentrant
        returns (uint256 feeAmount)
    {
        if (!isModule[msg.sender]) revert NotModule();
        if (moduleId != registeredModuleId[msg.sender]) revert ModuleIdMismatch();
        if (!feesEnabled || feeRateBps[moduleId] == 0) return 0;

        uint8 dm = discountMultiplier[payer];
        // Combine into a single division to avoid divide-before-multiply precision loss.
        // If no partner discount (dm == 0), treat as full fee (dm = 100).
        uint256 effectiveDm = dm == 0 ? 100 : uint256(dm);
        feeAmount = (txAmount * feeRateBps[moduleId] * effectiveDm) / (10_000 * 100);

        if (feeAmount == 0) return 0;

        usdc.safeTransferFrom(payer, treasury, feeAmount);
        emit FeeCollected(moduleId, payer, feeAmount, txAmount);
    }

    /// @notice Computes the fee that would be charged for a transaction.
    /// @param moduleId StablePilot module id.
    /// @param txAmount Transaction amount basis used for fee calculation.
    /// @param payer Address whose discount multiplier is applied.
    /// @return feeAmount The computed fee amount.
    function computeFee(uint8 moduleId, uint256 txAmount, address payer) external view returns (uint256 feeAmount) {
        if (!feesEnabled || feeRateBps[moduleId] == 0) return 0;

        uint8 dm = discountMultiplier[payer];
        uint256 effectiveDm = dm == 0 ? 100 : uint256(dm);
        feeAmount = (txAmount * feeRateBps[moduleId] * effectiveDm) / (10_000 * 100);
    }

    /// @notice Sets module fee rate in basis points.
    /// @dev On mainnet this function should be called through a TimelockController. Direct owner calls are permitted on testnet only.
    /// @param moduleId StablePilot module id.
    /// @param bps Fee rate in bps (0-500).
    function setFeeRate(uint8 moduleId, uint16 bps) external onlyOwner {
        if (bps > MAX_FEE_BPS) revert FeeBpsTooHigh(bps);

        uint16 oldBps = feeRateBps[moduleId];
        emit FeeRateSet(moduleId, oldBps, bps);
        feeRateBps[moduleId] = bps;
    }

    /// @notice Enables or disables fee collection globally.
    /// @dev On mainnet this function should be called through a TimelockController. Direct owner calls are permitted on testnet only.
    /// @param enabled True to enable fees, false to disable.
    function setFeesEnabled(bool enabled) external onlyOwner {
        feesEnabled = enabled;
        emit FeesToggled(enabled);
    }

    /// @notice Registers a module address as authorized fee collector.
    /// @dev On mainnet this function should be called through a TimelockController. Direct owner calls are permitted on testnet only.
    /// @param module Module contract address.
    /// @param id StablePilot module id for the module address.
    function addModule(address module, uint8 id) external onlyOwner {
        if (module == address(0)) revert ZeroAddress("module");
        isModule[module] = true;
        registeredModuleId[module] = id;
        emit ModuleAdded(module, id);
    }

    /// @notice Removes a module address from authorized fee collectors.
    /// @param module Module contract address.
    function removeModule(address module) external onlyOwner {
        isModule[module] = false;
        registeredModuleId[module] = 0;
        emit ModuleRemoved(module);
    }

    /// @notice Sets partner fee discount multiplier.
    /// @dev On mainnet this function should be called through a TimelockController. Direct owner calls are permitted on testnet only.
    /// @param partner Partner address.
    /// @param multiplier Discount multiplier (50-100).
    function setPartnerDiscount(address partner, uint8 multiplier) external onlyOwner {
        if (partner == address(0)) revert ZeroAddress("partner");
        if (multiplier < MIN_DISCOUNT || multiplier > MAX_DISCOUNT) revert InvalidDiscount(multiplier);

        discountMultiplier[partner] = multiplier;
        emit PartnerDiscountSet(partner, multiplier);
    }

    /// @notice Removes partner discount and restores full fee.
    /// @param partner Partner address.
    function removePartnerDiscount(address partner) external onlyOwner {
        discountMultiplier[partner] = 0;
        emit PartnerDiscountRemoved(partner);
    }

    /// @notice Proposes a new treasury address.
    /// @param _pendingTreasury Address that must accept to become treasury.
    function setPendingTreasury(address _pendingTreasury) external onlyOwner {
        if (_pendingTreasury == address(0)) revert ZeroAddress("pendingTreasury");

        pendingTreasury = _pendingTreasury;
        emit TreasuryUpdateProposed(_pendingTreasury);
    }

    /// @notice Accepts treasury role by pending treasury address.
    function acceptTreasury() external {
        if (msg.sender != pendingTreasury) revert NotPendingTreasury();

        address oldTreasury = treasury;
        treasury = pendingTreasury;
        pendingTreasury = address(0);
        emit TreasuryUpdated(oldTreasury, treasury);
    }

    /// @notice Rescues ERC20 tokens accidentally sent to this contract.
    /// @param token Token address to rescue.
    /// @param to Recipient address.
    /// @param amount Token amount to rescue.
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress("to");

        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    /// @notice Disables ownership renouncement to avoid leaving the contract without governance.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }
}
