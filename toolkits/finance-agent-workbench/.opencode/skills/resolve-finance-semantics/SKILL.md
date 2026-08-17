---
name: resolve-finance-semantics
description: Reconstruct and validate the business semantics behind a finance report or query. Use for grain, key, ledger, account, hierarchy, OU/BU/plant/product/profit-center mapping, effective dates, fiscal dates, sign, FX/currency, intercompany or intracompany markup, margin, null/blank/zero, duplicate, filter, or tolerance decisions before migration or reconciliation.
---

# Resolve Finance Semantics

1. Load `finance-report-migration`, its work context, and
   `../finance-report-migration/references/finance-semantics.md`.
2. Reuse the report inventory, task brief, and approved local context. Do not
   infer a finance rule from a field name or industry convention.
3. State the fact grain, natural keys, snapshot/transaction behavior, date
   roles, ledgers, hierarchy policy, currency/FX, signs, nulls, duplicates,
   inclusions, and tolerances.
4. Prove candidate keys/cardinalities and identify hierarchy overlaps, gaps,
   unmapped members, and effective-date ambiguity with deterministic queries or
   fixtures where available.
5. Separate legacy behavior, approved business rule, intentional correction,
   and unresolved question.
6. Return a contract candidate conforming to
   `schemas/finance-semantic-contract.schema.json` and `MISSING_CONTEXT` items.
   Do not write transformation code that depends on unresolved material rules.
