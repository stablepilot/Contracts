// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice ERC-1271 smart wallet controlled by one ECDSA key (test-only).
contract MockERC1271Wallet {
    address public immutable signer;
    bool public rejectAll;

    constructor(address _signer) {
        signer = _signer;
    }

    function setRejectAll(bool v) external {
        rejectAll = v;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (rejectAll) return 0xffffffff;
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        return (err == ECDSA.RecoverError.NoError && recovered == signer) ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @notice Registry stub with configurable `usdc()` / `MODULE_PAYROLL()` for constructor/setRegistry tests.
contract MockRegistryStub {
    address public usdc;
    uint8 public MODULE_PAYROLL;

    constructor(address _usdc, uint8 _moduleId) {
        usdc = _usdc;
        MODULE_PAYROLL = _moduleId;
    }
}

/// @notice Minimal ERC-20 that delivers 1 unit less than requested on transferFrom (fee-on-transfer).
contract MockFeeOnTransferToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - 1;
        return true;
    }
}
