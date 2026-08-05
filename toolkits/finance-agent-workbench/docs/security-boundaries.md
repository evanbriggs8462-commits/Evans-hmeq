# Security and data boundaries

## Never commit

- API tokens, PATs, passwords, connection strings, cookies, or authorization headers.
- Real server/share names, usernames, client names, report names, or internal endpoint hostnames.
- Raw or sampled SAP/PeopleSoft/LongView/Databricks records unless explicitly approved and irreversibly anonymized.
- PBIX/PBIT files, screenshots, query results, XML exports, Parquet output, manifests containing real paths, or model conversation payloads.
- Proprietary chart-of-account, profit-center, product, customer, or organizational hierarchies outside a company-owned repository.

## Authority boundaries

- Read-only inspection is the default.
- Source exports are never renamed, moved, or deleted by the agent workflow.
- Databricks reconciliation uses parameterized, allowlisted `SELECT` templates against a pinned snapshot where possible.
- Power BI/TE2 metadata writes require a backup, diff, validation, and explicit promotion gate.
- Processing, refresh, publish, catalog writes, Git push, and cleanup are separate operations requiring their own authority.

## Logging

Prefer aliases over physical endpoints and paths. Receipts may include hashes, sizes, timestamps, record counts, schema versions, error classes, and tool versions. They should not contain raw rows or credentials.

Keep diagnostic output on stderr and machine-readable results on stdout. Redact before asking an external model to analyze logs.

## Supply chain

Pin and review dependencies. Prefer Python's standard library for the default XML path. Do not let an agent install packages, modules, binaries, or PowerShell Gallery content on a managed workstation without approval.

## Command permissions

Treat a shell command as write-capable unless every accepted argument is constrained by a narrow wrapper. Many apparently read-only commands accept an output path, load plugins, or execute project code. This repository therefore asks before every shell invocation; the wrapper's own path and postcondition checks are a second boundary, not a reason to broadly auto-allow a command prefix.
