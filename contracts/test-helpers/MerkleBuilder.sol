// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Test-only Merkle tree builder using sorted-pair keccak256 (compatible with OZ MerkleProof).
/// Odd nodes are carried up unhashed. Any tree built this way verifies with MerkleProof.
library MerkleBuilder {
    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length > 0, "MerkleBuilder: no leaves");
        bytes32[] memory layer = leaves;
        while (layer.length > 1) {
            layer = _next(layer);
        }
        return layer[0];
    }

    function proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory out) {
        require(index < leaves.length, "MerkleBuilder: index out of range");
        bytes32[] memory tmp = new bytes32[](64);
        uint256 len;
        bytes32[] memory layer = leaves;
        while (layer.length > 1) {
            uint256 sibling = index ^ 1;
            if (sibling < layer.length) tmp[len++] = layer[sibling];
            index /= 2;
            layer = _next(layer);
        }
        out = new bytes32[](len);
        for (uint256 i; i < len; ++i) {
            out[i] = tmp[i];
        }
    }

    function _next(bytes32[] memory layer) private pure returns (bytes32[] memory nxt) {
        uint256 n = (layer.length + 1) / 2;
        nxt = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            uint256 j = 2 * i;
            nxt[i] = j + 1 < layer.length ? hashPair(layer[j], layer[j + 1]) : layer[j];
        }
    }
}
