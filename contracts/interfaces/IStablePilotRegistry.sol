// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Subset of StablePilotRegistry used by StablePilot modules.
interface IStablePilotRegistry {
    function MODULE_PAYROLL() external view returns (uint8);
    function usdc() external view returns (address);
    function collectFee(uint8 moduleId, uint256 txAmount, address payer) external returns (uint256 feeAmount);
    function computeFee(uint8 moduleId, uint256 txAmount, address payer) external view returns (uint256 feeAmount);
}
