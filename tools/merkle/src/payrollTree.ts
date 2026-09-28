import { randomBytes } from "node:crypto";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";

/**
 * Leaf encoding — MUST match PrivatePayroll.leafHash():
 *   keccak256(bytes.concat(keccak256(abi.encode(payrollId, periodId, index, employee, amount, salt))))
 * which is exactly OpenZeppelin StandardMerkleTree's leaf hash for these types. Internal nodes use
 * sorted-pair keccak256, verified on-chain by OpenZeppelin MerkleProof.
 */
export const LEAF_ENCODING = ["uint256", "uint256", "uint256", "address", "uint256", "bytes32"] as const;

export const USDC_DECIMALS = 6;

export interface PayrollRow {
  employee: string;
  /** USDC base units (6 decimals). */
  amount: bigint;
  salt: string;
}

export interface ClaimEntry {
  payrollId: string;
  periodId: string;
  index: number;
  employee: string;
  amount: string;
  amountUsdc: string;
  salt: string;
  leaf: string;
  proof: string[];
}

export interface PayrollTreeOutput {
  payrollId: string;
  periodId: string;
  root: string;
  total: string;
  totalUsdc: string;
  leafEncoding: readonly string[];
  entries: ClaimEntry[];
}

const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/;
const USDC_RE = /^\d+(\.\d{1,6})?$/;

/** Parses a decimal USDC string ("2500.5") into 6-decimal base units, rejecting >6 decimals. */
export function parseUsdc(value: string): bigint {
  const v = value.trim();
  if (!USDC_RE.test(v)) throw new Error(`invalid USDC amount "${value}" (max ${USDC_DECIMALS} decimals)`);
  const [whole, frac = ""] = v.split(".");
  return BigInt(whole) * 10n ** BigInt(USDC_DECIMALS) + BigInt(frac.padEnd(USDC_DECIMALS, "0"));
}

export function formatUsdc(units: bigint): string {
  const s = units.toString().padStart(USDC_DECIMALS + 1, "0");
  const whole = s.slice(0, -USDC_DECIMALS);
  const frac = s.slice(-USDC_DECIMALS).replace(/0+$/, "");
  return frac ? `${whole}.${frac}` : whole;
}

export function randomSalt(): string {
  return "0x" + randomBytes(32).toString("hex");
}

/**
 * CSV format (header required): employee,amount_usdc[,salt]
 * - employee: 0x address (the key that will claim or sign the claim authorization)
 * - amount_usdc: decimal USDC, e.g. 2500 or 2500.50 (max 6 decimals)
 * - salt: optional 32-byte hex; a random one is generated if empty. Salts hide amounts — keep them secret.
 */
export function parseCsv(text: string, saltSource: () => string = randomSalt): PayrollRow[] {
  const lines = text.split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
  if (lines.length === 0) throw new Error("empty CSV");
  const header = lines[0].split(",").map((h) => h.trim().toLowerCase());
  const iEmp = header.indexOf("employee");
  const iAmt = header.indexOf("amount_usdc");
  const iSalt = header.indexOf("salt");
  if (iEmp < 0 || iAmt < 0) throw new Error("CSV header must contain: employee,amount_usdc[,salt]");

  return lines.slice(1).map((line, n) => {
    const cols = line.split(",").map((c) => c.trim());
    const employee = cols[iEmp];
    if (!ADDRESS_RE.test(employee) || /^0x0{40}$/.test(employee)) {
      throw new Error(`row ${n + 1}: invalid employee address "${employee}"`);
    }
    const amount = parseUsdc(cols[iAmt] ?? "");
    const salt = iSalt >= 0 && cols[iSalt] ? cols[iSalt] : saltSource();
    if (!BYTES32_RE.test(salt)) throw new Error(`row ${n + 1}: invalid salt "${salt}"`);
    return { employee, amount, salt: salt.toLowerCase() };
  });
}

export function buildPayrollTree(rows: PayrollRow[], payrollId: bigint, periodId: bigint): PayrollTreeOutput {
  if (rows.length === 0) throw new Error("no payroll rows");
  if (payrollId <= 0n || periodId <= 0n) throw new Error("payrollId and periodId start at 1");

  const values = rows.map((r, index) => [
    payrollId.toString(),
    periodId.toString(),
    index.toString(),
    r.employee,
    r.amount.toString(),
    r.salt,
  ]);
  const tree = StandardMerkleTree.of(values, [...LEAF_ENCODING]);
  const total = rows.reduce((acc, r) => acc + r.amount, 0n);

  const entries: ClaimEntry[] = [];
  for (const [i, v] of tree.entries()) {
    entries.push({
      payrollId: v[0] as string,
      periodId: v[1] as string,
      index: Number(v[2]),
      employee: v[3] as string,
      amount: v[4] as string,
      amountUsdc: formatUsdc(BigInt(v[4] as string)),
      salt: v[5] as string,
      leaf: tree.leafHash(v),
      proof: tree.getProof(i),
    });
  }
  entries.sort((a, b) => a.index - b.index);

  return {
    payrollId: payrollId.toString(),
    periodId: periodId.toString(),
    root: tree.root,
    total: total.toString(),
    totalUsdc: formatUsdc(total),
    leafEncoding: LEAF_ENCODING,
    entries,
  };
}
