# Digital Transformation Toolkit — Power BI extraction

This repository is the team's Power BI extraction toolkit. Use OpenCode to run repeatable, read-only exports from a semantic model open in Power BI Desktop or published behind an XMLA endpoint.

The toolkit has two supported jobs:

- export core model metadata with Tabular Editor 2
- run an explicitly reviewed DAX query and save the result with DAX Studio `dscmd`

It does not edit or save a PBIX, publish a model, inspect Power BI service state, or extract report-page and visual layout. DAX runs through the semantic model; on DirectQuery or Direct Lake models, a query can reach backing data and create load or cost.

## Start here

1. Configure your approved OpenCode provider and API key outside this repository, as described in [docs/OPENCODE_SETUP.md](docs/OPENCODE_SETUP.md).
2. Follow [QUICKSTART.md](QUICKSTART.md).
3. Open this repository's root folder in OpenCode. OpenCode will load [AGENTS.md](AGENTS.md).
4. Use the handoff prompt in [prompts/OPENCODE_HANDOFF.md](prompts/OPENCODE_HANDOFF.md).

## What the core inventory creates

One Tabular Editor connection produces:

- `tables.csv`
- `measures.csv`, including DAX expressions
- `columns.csv`, including calculated-column expressions when available
- `relationships.csv`
- `partitions.csv`, including Power Query M or other partition expressions
- `expressions.csv`, including shared Power Query expressions and parameters
- `inventory_manifest.json`, including connection mode, tool and toolkit versions, exporter hash, row counts, file sizes, and output hashes

Outputs are written to `EVIDENCE_ROOT`, which should be outside the cloned repository.

The core inventory does not export hierarchies and levels, calculation items or dynamic format expressions, perspectives, roles and RLS rules, cultures and translations, data-source objects, refresh policies, or report layout. Add any of those only through a separate reviewed change; do not infer them from the six CSVs.

## Repository map

| Path | Purpose |
|---|---|
| `AGENTS.md` | Instructions and safety limits loaded by OpenCode |
| `opencode.json` | Project permissions that deny edits and unlisted commands |
| `powershell/` | Preflight, inventory, and DAX wrappers |
| `te2/readonly/` | Allowlisted Tabular Editor export script |
| `dax/queries/` | Connection test and copyable query template |
| `templates/.env.example` | Local executable and evidence paths |
| `docs/` | OpenCode setup, security, and troubleshooting |

## Security boundary

The wrappers issue read-only metadata and query operations, but local scripts are not a substitute for Power BI permissions. Use a read-only account for XMLA connections. Never store an OpenCode key, access token, PBIX/PBIT file, or generated evidence in this repository.

See [docs/SECURITY.md](docs/SECURITY.md) for the full operating boundary.

## License

MIT. See [LICENSE](LICENSE).
