# StablePilot Contracts

Foundry project for the **StablePilot** on-chain protocol contracts, extracted from the Arc Studio app.

- `contracts/StablePilotRegistry.sol` — per-transaction USDC protocol-fee registry for StablePilot modules
  (Payroll, Supply, DarkPool, zkCredit), with partner discounts, two-step ownership and two-step treasury updates.
- `contracts/PrivatePayroll.sol` — **v1 PrivatePayroll module** (not deployed yet): pooled USDC payroll with
  per-period Merkle commitments, pull-based claims (optionally to a fresh address / via relayer), protocol fee
  per funded period through `StablePilotRegistry`. Design + privacy table: `contracts/PrivatePayroll-design.md`.
- `contracts/script/DeployPrivatePayroll.s.sol` — deploy script (reads `REGISTRY_ADDRESS`, `USDC_ADDRESS`,
  `PAYROLL_OWNER`, `EXPECTED_CHAIN_ID`; defaults to Arc Testnet).
- `tools/merkle/` — TypeScript tool that builds a period's Merkle root and claim proofs from a CSV.
- `contracts/script/Create2Factory.sol`, `contracts/script/DeployCreate2.s.sol` — deterministic CREATE2 deployment helpers.
- `contracts/test/` — unit, fuzz and invariant tests; `contracts/test-helpers/MockERC20.sol` — test token.
- `contracts/contract-metadata/StablePilotRegistry.json` — ABI + deployment record (address, chain ID, tx hash).
- `contracts/StablePilotRegistry-design.md` — design document.

## Deployment

| Network     | Chain ID  | StablePilotRegistry |
|-------------|-----------|---------------------|
| Arc Testnet | `5042002` | [`0x1070dc6494402aacaa5e701139d27f20de6527ff`](https://explorer.testnet.arc.io/address/0x1070dc6494402aacaa5e701139d27f20de6527ff) |

USDC on Arc Testnet (ERC-20 interface of native USDC, 6 decimals): `0x3600000000000000000000000000000000000000`.

## Requirements

- [Foundry](https://getfoundry.sh) **v1.7.1** (see `.foundry-version`): `foundryup --install v1.7.1`
- Dependencies are git submodules pinned by tag (see `foundry.lock`):
  `forge-std` v1.16.2, `openzeppelin-contracts` v5.1.0.

## Build & test

```sh
git clone --recurse-submodules <repo-url>
cd stablepilot-contracts
# (or, in an existing clone) git submodule update --init --recursive

forge build --sizes
forge test -vvv

# Same settings as CI (1000 fuzz runs, fixed seed):
FOUNDRY_PROFILE=ci forge test -vvv
```

Compiler settings: solc 0.8.28, `evm_version = "paris"`, optimizer 200 runs.

## CI

`.github/workflows/test.yml` runs the **forge-test** job (build + full test suite with `FOUNDRY_PROFILE=ci`)
on every pull request, on pushes to `main`, and on manual dispatch.
**CI must pass before a PR is merged into `main`.**

## Secrets

Never commit private keys, mnemonics, RPC keys or `.env` files. `.env` is git-ignored; pass deployer
credentials via environment variables or a Foundry keystore (`cast wallet import`).

## License

[MIT](LICENSE) © StablePilot
