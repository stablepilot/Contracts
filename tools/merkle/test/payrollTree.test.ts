import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { buildPayrollTree, formatUsdc, LEAF_ENCODING, parseCsv, parseUsdc } from "../src/payrollTree.js";

const fixture = (name: string) => fileURLToPath(new URL(`../fixtures/${name}`, import.meta.url));

test("fixture matches the committed test vector used by the Solidity tests", () => {
  const rows = parseCsv(readFileSync(fixture("example.csv"), "utf8"));
  const out = buildPayrollTree(rows, 1n, 1n);
  const expected = JSON.parse(readFileSync(fixture("example.expected.json"), "utf8"));
  assert.deepEqual(JSON.parse(JSON.stringify(out)), expected);
  assert.equal(out.root, "0x697e19a1415787e47e118f3333f7273e08a1a92ba21f24c89170d832de14727f");
});

test("every proof verifies against the root", () => {
  const rows = parseCsv(readFileSync(fixture("example.csv"), "utf8"));
  const out = buildPayrollTree(rows, 1n, 1n);
  for (const e of out.entries) {
    const v = [e.payrollId, e.periodId, String(e.index), e.employee, e.amount, e.salt];
    assert.ok(StandardMerkleTree.verify(out.root, [...LEAF_ENCODING], v, e.proof));
  }
  assert.equal(out.total, rows.reduce((a, r) => a + r.amount, 0n).toString());
});

test("USDC parsing is exact to 6 decimals", () => {
  assert.equal(parseUsdc("2500"), 2_500_000_000n);
  assert.equal(parseUsdc("0.000001"), 1n);
  assert.equal(parseUsdc("3100.5"), 3_100_500_000n);
  assert.throws(() => parseUsdc("1.0000001"));
  assert.throws(() => parseUsdc("-1"));
  assert.equal(formatUsdc(1_999_999_999n), "1999.999999");
  assert.equal(formatUsdc(5n), "0.000005");
});

test("missing salts are generated randomly and differ per row", () => {
  const rows = parseCsv(
    "employee,amount_usdc\n0x1111111111111111111111111111111111111111,1\n0x1111111111111111111111111111111111111111,1\n",
  );
  assert.notEqual(rows[0].salt, rows[1].salt);
  const a = buildPayrollTree(rows, 1n, 1n);
  assert.notEqual(a.entries[0].leaf, a.entries[1].leaf);
});

test("rejects bad input", () => {
  assert.throws(() => parseCsv("employee,amount_usdc\n0x123,1\n"));
  assert.throws(() => parseCsv("employee,amount_usdc\n0x0000000000000000000000000000000000000000,1\n"));
  assert.throws(() => parseCsv("wallet,amount\n"));
  assert.throws(() => buildPayrollTree([], 1n, 1n));
  assert.throws(() => buildPayrollTree(parseCsv("employee,amount_usdc\n0x1111111111111111111111111111111111111111,1\n"), 0n, 1n));
});
