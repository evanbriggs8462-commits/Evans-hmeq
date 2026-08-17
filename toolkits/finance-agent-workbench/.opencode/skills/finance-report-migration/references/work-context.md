# Work Context for the Finance Migration Agent

## Purpose

This workbench supports a manufacturing-finance analyst modernizing legacy
reports and recurring close or operational workflows. The agent is expected to
produce concrete, reviewable work—not merely explain what a data engineer
could do.

The usual goal is one-for-one business parity first, followed by a separately
measured improvement in reliability, refresh time, maintainability, or user
experience. A migration is incomplete if it reproduces a number but loses the
meaning, drill path, hierarchy behavior, filter context, or operational timing
that made the old report useful.

## Sanitized working landscape

Typical inputs and systems include:

- SAP-style FI/SD line items, spool/XML exports, and large Excel extracts;
- general-ledger, special-purpose/profitability, planning, consolidation, and
  operational source data with overlapping definitions, including
  LongView/OneStream-style outputs;
- PeopleSoft-style business-unit, account, product, and profit-center
  hierarchies, including effective-dated mappings;
- Power Query M with helper/sample-file queries and combine-file patterns;
- governed Databricks tables, views, SQL warehouses, Unity Catalog metadata,
  notebooks, jobs, and curated Genie knowledge;
- Power BI Desktop and Premium/Fabric workspaces, DAX Studio, Tabular Editor 2,
  XMLA/TOM, PBIP/PBIR, refresh history, and scheduled daily consumption.

Typical report subjects include backlog, sales, standard or integrated gross
margin, month-to-date performance, plant/region/product/market views, and
controller or executive drill paths. Material complexities often include
multiple ledgers, regional sales organizations, intercompany or intracompany
markup, FX conversion, profit-center mappings, and changing hierarchies.

Abbreviations such as GL, SPL, PCA, OU, and BU are local business terms, not
universal synonyms. Resolve their exact meaning and ownership from the approved
private context before using them in joins or metric logic.

This file intentionally omits company names, real report names, target values,
hosts, IDs, schemas, table names, paths, screenshots, and records. Those values
belong only in the ignored local context or another company-approved private
repository.

## Recurring objectives

The agent should recognize these as related parts of one program:

1. replace manual or spool-driven reports with governed, repeatable pipelines;
2. reverse-engineer existing PBIX/M/DAX logic without assuming it is correct;
3. use Databricks and Genie to accelerate discovery while keeping finance
   validation deterministic;
4. move appropriate source shaping or reusable calculations upstream without
   breaking Power BI semantics;
5. reduce refresh contention and repeated large imports using evidence from
   both the BI and source-compute layers;
6. preserve an audit trail and make each migration reusable for the next
   report; and
7. allow a lower-cost local model to continue work with minimal re-discovery.

## What the operator values

- Lead with a concrete result or artifact.
- Keep routine narration short, but preserve technical evidence and caveats
  that affect correctness.
- Use tools and inspect artifacts before asking broad questions.
- Do not repeatedly ask for context already present in the repository, task
  brief, local overlay, or prior receipt.
- Do not overstate limitations: safe local inspection, code changes, candidate
  generation, tests, and read-only analysis should continue within scope.
- Do not improvise a live write. Publication and production mutation require an
  exact target, rollback, and explicit gate.
- Explain tradeoffs at the analyst's level: connect technical changes to
  parity, close timing, controller trust, capacity, cost, and maintenance.

## Default interpretation of common requests

| Request | Default meaning |
|---|---|
| “Migrate this report” | Preserve current business behavior, create a governed candidate, prove parity, then separate optimizations. |
| “Make this repeatable” | Convert discoveries into parameterized wrappers, schemas, fixtures, tests, and a resumable handoff. |
| “Use Genie” | Use curated domain context to discover candidate objects/SQL, then capture and independently verify the result. |
| “Fix it” | Diagnose the failing layer, make the smallest in-scope candidate change, run relevant checks, and report the postcondition. |
| “Push this context” | Encode durable instructions, references, templates, tests, and routing—not a chat transcript or roadmap alone. |
| “Optimize refresh” | Establish where time is spent and propose a stagger/architecture change; do not automatically rewrite queries or schedules. |
| “Edit the visual” | Work through PBIP/PBIR or supported report-authoring tools; do not pretend DAX Studio or TE2 edits the report canvas. |

## Private local overlay

Copy `context/local-context.example.json` to
`context/local-context.json` in the approved workstation repository and fill
only values permitted by company policy. The real file is ignored by Git.

Use the overlay for:

- approved aliases for workspaces, models, reports, warehouses, catalogs,
  schemas, Genie Agents, source shares, and staging roots;
- private report portfolio, refresh window, and capacity facts;
- metric targets and exact finance definitions;
- source-of-truth hierarchy, account, ledger, FX, sign, and exclusion rules;
- approved tool paths, versions, and capability receipts; and
- known source quirks and sanitized internal runbook links.

Loading a field into model context sends it to the configured model provider
unless the model is genuinely local. Read only the fields required by the task
and only when that provider/model is approved for `WORK_INTERNAL` data. If it
is not, use only a pre-generated approved projection or an installed
deterministic redaction adapter to expose approved aliases, hashes, counts, and
rule classifications. If neither exists, omit private values and return
`MISSING_CONTEXT`/`MISSING_PREREQUISITE`; never ask the model to perform the
redaction. Never dump the whole overlay into a prompt, receipt, log,
screenshot, Git diff, or model context.

If the overlay is absent, continue with public-safe inventory and candidate
work. Mark any decision that needs a private rule `MISSING_CONTEXT`; do not
silently fill it with an industry convention.
