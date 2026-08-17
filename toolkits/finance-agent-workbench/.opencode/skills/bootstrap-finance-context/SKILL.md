---
name: bootstrap-finance-context
description: Create or update the ignored private context overlay that gives a lower-cost local finance agent exact approved aliases, report facts, tool capabilities, semantic rules, source quirks, and operating preferences. Use when adopting the workbench, when context/local-context.json is absent or stale, or when the model repeatedly rediscovers Power BI, Databricks, hierarchy, ledger, metric, refresh, or tool-boundary facts.
---

# Bootstrap Private Finance Context

1. Read `context/catalog.json`, `context/local-context.example.json`, and
   `../finance-report-migration/references/work-context.md`.
2. Resolve the model boundary before loading private artifacts. Create or
   update exact `WORK_INTERNAL` fields only with a genuinely local approved
   model or a provider/model explicitly approved for that data class. Never
   stage, commit, paste, or send the whole overlay to any model or service.
3. Populate approved aliases and facts from existing local artifacts, sanitized
   capability receipts, company-approved runbooks, and explicit operator
   decisions. Reuse evidence; do not perform broad live discovery by default.
4. Exclude credentials, tokens, authorization headers, raw rows, personal data,
   sensitive query text, and unrestricted platform-object dumps.
5. Record each important rule with provenance, observed/confirmed status,
   effective date or snapshot, and expiry/review trigger where applicable.
6. Keep exact finance definitions separate from examples. Do not infer a
   target, hierarchy, ledger equivalence, FX rule, sign rule, or tolerance.
7. Return a coverage summary, stale entries, contradictions, `MISSING_CONTEXT`
   fields, and the smallest approved evidence needed next.

Loading a selected field into OpenCode model context transmits that field to
the configured provider unless the model is genuinely local. Do so only when
the provider/model and data class are company-approved. Otherwise require a
pre-generated approved projection or installed deterministic redaction adapter
that emits approved aliases, hashes, counts, and classifications. If neither
exists, return `MISSING_PREREQUISITE` and do not load private artifacts or ask
the model to redact them. Never ask the model to redact raw private values.
Public template scaffolding may still continue.

An unavailable live adapter blocks only automatic discovery. Continue building
the local overlay from approved artifacts and leave unknown values explicit.
