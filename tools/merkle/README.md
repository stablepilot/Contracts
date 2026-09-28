# PrivatePayroll Merkle tool

Builds the per-period Merkle root and each employee's claim proof for `PrivatePayroll`.

```sh
cd tools/merkle
npm ci
npm run build-tree -- --csv employees.csv --payroll-id 1 --period-id 3 --out tree.json --split-dir claims/
npm test   # checks the committed test vector (fixtures/) that the Solidity tests also use
```

CSV: `employee,amount_usdc[,salt]`. Amounts are decimal USDC (max 6 decimals; converted to 6-decimal
base units). Leave `salt` empty to generate a random 32-byte salt; the salt hides the amount behind the
on-chain root, so keep it secret.

Leaf (matches `PrivatePayroll.leafHash`, OpenZeppelin `StandardMerkleTree`):

```
keccak256(bytes.concat(keccak256(abi.encode(payrollId, periodId, index, employee, amount, salt))))
types: (uint256, uint256, uint256, address, uint256, bytes32)
```

`periodId` must be the id the contract will assign: `getPayroll(payrollId).periodCount + 1`.

**The output (`tree.json`, `claims/`) contains every employee's amount and salt. It is confidential:
never commit it; send each employee only their own claim file.** (`tools/merkle/out/`, `tree*.json`
and `claims/` are git-ignored.)
