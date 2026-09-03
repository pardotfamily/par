// Points web/indexer/keeper env files at the stack from the latest mainnet
// broadcast. Usage: node mainnet-envs.mjs [label]
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const run = JSON.parse(readFileSync(join(here, "broadcast/Deploy.s.sol/4663/run-latest.json"), "utf8"));
const label = process.argv[2] ?? "stack";

const created = Object.fromEntries(
  run.transactions
    .filter((t) => t.transactionType === "CREATE" || t.transactionType === "CREATE2")
    .map((t) => [t.contractName, t.contractAddress])
);
const blocks = run.receipts.map((r) => Number(BigInt(r.blockNumber)));
const startBlock = Math.min(...blocks);
const factoryBlock = Number(
  BigInt(run.receipts.find((r) => r.contractAddress?.toLowerCase() === created.PairPadLaunchFactory.toLowerCase())?.blockNumber ?? startBlock)
);

const need = ["PairPadLaunchFactory", "PairPadRouter", "PairPadQuotePricer", "PairPadLaunchHook", "PairPadLaunchLocker"];
for (const n of need) if (!created[n]) throw new Error(`broadcast has no ${n}`);

const keys = {
  "web/.env.local": {
    NEXT_PUBLIC_FACTORY_ADDRESS: created.PairPadLaunchFactory,
    NEXT_PUBLIC_ROUTER_ADDRESS: created.PairPadRouter,
    NEXT_PUBLIC_QUOTE_PRICER_ADDRESS: created.PairPadQuotePricer,
    NEXT_PUBLIC_LAUNCH_HOOK_ADDRESS: created.PairPadLaunchHook,
    NEXT_PUBLIC_LOCKER_ADDRESS: created.PairPadLaunchLocker,
  },
  "indexer/.env.local": {
    FACTORY_ADDRESS: created.PairPadLaunchFactory,
    QUOTE_PRICER_ADDRESS: created.PairPadQuotePricer,
    LAUNCH_HOOK_ADDRESS: created.PairPadLaunchHook,
    ROUTER_ADDRESS: created.PairPadRouter,
    START_BLOCK: String(factoryBlock),
  },
  "keeper/.env": {
    FACTORY_ADDRESS: created.PairPadLaunchFactory,
    QUOTE_PRICER_ADDRESS: created.PairPadQuotePricer,
    LAUNCH_HOOK_ADDRESS: created.PairPadLaunchHook,
    START_BLOCK: String(factoryBlock),
  },
};

const today = new Date().toISOString().slice(0, 10);
for (const [file, map] of Object.entries(keys)) {
  const path = join(root, file);
  let c = readFileSync(path, "utf8");
  for (const [k, v] of Object.entries(map)) {
    const re = new RegExp(`^${k}=.*$`, "m");
    // Keys introduced by a newer stack are appended rather than required.
    c = re.test(c) ? c.replace(re, `${k}=${v}`) : `${c.trimEnd()}\n${k}=${v}\n`;
  }
  c = c.replace(/MAINNET deployment \(.*?\)\./, `MAINNET deployment (${today}, ${label}, factory block ${factoryBlock}).`);
  writeFileSync(path, c);
  console.log(`=== ${file}`);
  for (const k of Object.keys(map)) console.log(`${k}=${map[k]}`);
}
console.log("deploy blocks", startBlock, "..", Math.max(...blocks), "factory block", factoryBlock);
