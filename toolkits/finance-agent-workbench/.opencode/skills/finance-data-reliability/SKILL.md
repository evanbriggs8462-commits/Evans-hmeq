---
name: finance-data-reliability
description: Build and troubleshoot reliable finance-data workflows involving large XML or spool exports, PowerShell file-share staging, Python streaming inspection, Databricks read-only reconciliation, and Power BI external tools. Use for ingestion, parsing, reconciliation, migration, validation, or automation tasks, and for failures involving VPN or UNC access, killed or timed-out child processes, partial files, XML or schema drift, DAX Studio, Tabular Editor 2, TOM, M partitions, PBIX semantic models, or Databricks differences.
---

# Finance Data Reliability

Act as an orchestrator. Convert recurring work into deterministic, versioned wrappers with explicit inputs, bounded execution, assertions, and sanitized receipts. Keep source and remote systems read-only unless the user authorizes an exact write target.

## Load the relevant reference

- If the task mentions **large XML, SAP spool exports, file sizes in gigabytes, UNC or mapped-drive sources, VPN/SMB, OneDrive staging, `Get-Content`, `read_bytes`, `ReadAllBytes`, regex XML inspection, bounded prefix reads, child-process termination, or an interactive shell timeout**, read [references/large-xml-smb-runbook.md](references/large-xml-smb-runbook.md) before issuing another content-read or copy command.
- If the task mentions a **long-running or quiet command, elapsed timer, heartbeat, no output, frozen/stuck/broken session, status polling, or process liveness**, read [long-running task observability](../../../docs/long-running-task-observability.md) before selecting an execution method.
- If the task mentions **DAX Studio, Tabular Editor 2/TE2, TOM, PBIX, Power BI Desktop, semantic models, measures, relationships, M partitions, refresh, processing, save, or publish**, read [references/power-bi-boundaries.md](references/power-bi-boundaries.md) before proposing commands or changes.
- If the task mentions **Databricks, Unity Catalog, SQL warehouses, Delta tables, reconciliation, row counts, balances, dates, currency, grain, keys, or source-to-target comparisons**, read [references/databricks-reconciliation.md](references/databricks-reconciliation.md) before writing SQL or judging a mismatch.
- If the task mentions **VPN, UNC or network shares, PowerShell failures, killed children, timeouts, locks, partial copies, XML parse errors, encoding, memory, schema drift, retries, or intermittent behavior**, read [references/failure-taxonomy.md](references/failure-taxonomy.md) before retrying or patching.
- Load every matching reference when the task crosses boundaries.

## Run the workflow

1. Define the source, target, expected grain, date range, measures, tolerances, and success evidence. State unresolved assumptions.
2. Inspect effective configuration, permissions, tool versions, and target identity without exposing credentials.
3. Capture a read-only baseline and input fingerprint. For remote files, establish that the producer has finished before staging.
4. Define "local" as an approved, non-synced fixed volume with validated ancestry and sufficient capacity. Never treat a OneDrive/workspace subdirectory as an implicit staging root.
5. Stage remote input once with `scripts/Stage-Spool.ps1`, then atomically finalize it only after the source restat, local size, and integrity checks pass. For transfers longer than the agent shell limit, use an approved terminal or job runner and return the receipt.
6. For a bounded child that fits within the host limit but may be quiet, use `runwatch` for elapsed-time/liveness evidence. Treat heartbeat as liveness only, never progress. Use an approved external runner when the host limit may be exceeded.
7. Parse only the finalized local artifact with streaming APIs. Never load an unbounded XML export into one string, DOM, pipeline object collection, or model prompt. Never treat a prefix or regex match as XML validation.
8. Reconcile in layers: structural checks, global totals, grouped totals, then key-level exceptions. Diagnose differences before changing transformation logic.
9. If a write is requested, present the proposed diff and validation plan. Require the gate described in `AGENTS.md` before applying it.
10. Validate the postcondition independently, including a round-trip read when possible. Emit a sanitized receipt and clearly separate observed, inferred, and verified conclusions.

Use medium reasoning for routine cases and high reasoning for ambiguous cross-system failures. Treat Plan/Build mode as a separate tool-permission control.
