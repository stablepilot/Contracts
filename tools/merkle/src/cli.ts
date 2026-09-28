#!/usr/bin/env node
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { buildPayrollTree, parseCsv } from "./payrollTree.js";

const { values } = parseArgs({
  options: {
    csv: { type: "string" },
    "payroll-id": { type: "string" },
    "period-id": { type: "string" },
    out: { type: "string" },
    "split-dir": { type: "string" },
  },
});

if (!values.csv || !values["payroll-id"] || !values["period-id"]) {
  console.error(
    "usage: npm run build-tree -- --csv employees.csv --payroll-id <id> --period-id <id> [--out tree.json] [--split-dir claims/]",
  );
  process.exit(1);
}

const rows = parseCsv(readFileSync(values.csv, "utf8"));
const result = buildPayrollTree(rows, BigInt(values["payroll-id"]), BigInt(values["period-id"]));
const json = JSON.stringify(result, null, 2) + "\n";

if (values.out) writeFileSync(values.out, json);
else process.stdout.write(json);

if (values["split-dir"]) {
  mkdirSync(values["split-dir"], { recursive: true });
  for (const e of result.entries) {
    writeFileSync(join(values["split-dir"], `claim-${e.index}-${e.employee}.json`), JSON.stringify({ root: result.root, ...e }, null, 2) + "\n");
  }
}

console.error(
  `root=${result.root} total=${result.total} (${result.totalUsdc} USDC) entries=${result.entries.length}\n` +
    "Post root + total with PrivatePayroll.fundPeriod(). The output contains every salt and amount: " +
    "treat it as confidential and give each employee only their own claim file.",
);
