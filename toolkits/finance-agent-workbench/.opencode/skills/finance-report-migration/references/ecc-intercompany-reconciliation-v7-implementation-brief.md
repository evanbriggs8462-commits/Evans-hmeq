%md
# Implementation Brief: Correct and Harden the ECC Intercompany Reconciliation POC
Update the existing V7 unified SQL. Preserve its intended purpose: reconstruct ECC customer/vendor items open at month-end, assign intercompany partners, reconcile reciprocal entities, and report matching coverage and residual exposure. Do not merely explain these recommendations—implement them, document material assumptions, and provide before/after validation results.
## 1. Correct the reporting population
- Rename `period_end` to `cutoff_exclusive`; it represents the first day following the reporting month.
- Prefer an explicit configurable `as_of_date` rather than relying permanently on `CURRENT_DATE()`.
- Preserve the correct key-date logic:
  - `BUDAT < cutoff_exclusive`
  - item is uncleared or `AUGDT >= cutoff_exclusive`
- Normalize blank/null/initial clearing values such as `00000000`.
- Remove `b.gjahr >= p.min_gjahr`. Prior-year items can remain open and must not disappear from a true month-end balance.
- If performance requires historical restriction, derive it from a certified retained-history policy—not the previous month’s year.
- Consider BSID/BSAD and BSIK/BSAK if available, while ensuring both currently open and subsequently cleared items are included for historical key-date reconstruction.
## 2. Protect the ECC record grain
Use the complete available ECC/source key:
- BKPF: source system + `MANDT, BUKRS, BELNR, GJAHR`
- BSEG: source system + `MANDT, BUKRS, BELNR, GJAHR, BUZEI`
- T001: source system + `MANDT, BUKRS`
- KNA1: source system + `MANDT, KUNNR`
- LFA1: source system + `MANDT, LIFNR`
- VBRK: source system + `MANDT, VBELN`
Include these dimensions in joins, profiles and generated item keys. If the curated schema is guaranteed to contain one source/client only, add an assertion and document that invariant.
Determine whether the landed tables are current-state Delta tables or append-only CDC tables. `hdr__oper <> 'D'` is insufficient for append-only CDC. If necessary:
1. Rank records by the landing sequence/timestamp within the native key.
2. Retain the latest record only.
3. Exclude the key if its latest operation is a deletion.
4. Assert one row per native key before financial calculations.
## 3. Correct partner assignment
Keep these separately auditable:
- `posted_vbund`
- `vendor_master_vbund`
- `customer_master_vbund`
- `assigned_vbund`
- `partner_bukrs`
- `assignment_rule`
- `posted_master_conflict_flag`
- `vbund_assignment_status`
- `bukrs_mapping_status`
- `match_ready_status`
Select `assigned_vbund`, `partner_bukrs` and `assignment_rule` atomically from the same branch. Do not allow direct posted VBUND to determine `assigned_vbund` while `partner_bukrs` silently falls through to a different vendor/customer-master mapping.
Precedence:
1. Valid posted BSEG VBUND
2. LFA1 inference for `KOART='K'`
3. KNA1 inference for `KOART='D'`
4. Unassigned/conflict status
Treat `T001.RCOMP` as the ECC company-ID/VBUND-to-company-code relationship. Preserve one-to-many `RCOMP → BUKRS` mappings instead of silently converting them to null or arbitrarily selecting one BUKRS. Reconcile at company/VBUND level or use a governed enterprise crosswalk when an exact counterpart BUKRS cannot be determined. Use T880 for canonical company labels if available.
Supplemental KNA1/LFA1 codes without a governed BUKRS mapping may be valid remote company IDs, but they are not BUKRS-match-ready. Report them as `PARTNER_CODE_ONLY` or `REMOTE_ENTITY`; do not label them fully resolved and then silently remove them.
Correct the VBRK fallback:
`COALESCE(NULLIF(TRIM(KUNRG),''), NULLIF(TRIM(KUNAG),''))`
or normalize both partner roles with a union. Do not allow an empty `KUNRG` to suppress populated `KUNAG`. Scope all master validation by source/client.
## 4. Separate balance coverage from match eligibility
Create distinct populations:
- `all_open_ic_items`: every open D/K item with its assignment/conflict status
- `match_eligible_items`: subset with a valid reciprocal matching identity
- `unresolved_items`: items requiring mapping remediation
Build reported open balances from `all_open_ic_items`, not only `matchable`. Otherwise unresolved and ambiguous exposures disappear and the match rate is artificially inflated.
Report assignment coverage separately from matching coverage.
## 5. Rebuild candidate generation
Remove:
`AND a.ikey < b.ikey`
The D/K orientation already prevents symmetric duplicate edges because `a` is restricted to `KOART='D'`. The current comparison discards valid transactions whenever the receivable entity key sorts after the payable entity key.
Avoid the broad all-to-all D×K join inside every reciprocal entity/currency block. Generate rule-specific blocked candidates with `UNION ALL`, then retain the strongest evidence per `(a_key,b_key)`:
1. Exact normalized external reference
2. Document-reference linkage with fiscal-year/date context
3. Exact opposite amount plus a bounded date window
4. Controlled fuzzy amount/date candidate
5. Other documented evidence
Do not use identical `AUGBL` as a standalone cross-company match. Clearing-document numbers are scoped to company/year and can coincide accidentally.
Apply appropriate financial integrity controls:
- reciprocal company/partner relationship
- D item against K item
- opposite nonzero signs
- compatible transaction currency
- fiscal-year/date context for reused BELNR values
- amount/residual controls
- deterministic tie-breakers using item keys
Preserve evidence flags independently from the chosen rule:
- reference match
- document-reference match
- exact amount
- date within tolerance
- acceptable residual
- clearing evidence
- selected priority
- confidence/review status
## 6. Support split-OU and one-to-many billing
Before 1:1 line matching, add reference-level matching for:
- 1:1
- 1:N
- N:1
Group within reciprocal entity/company, transaction currency and a sufficiently strong normalized reference. Compare group totals and preserve every contributing FI item key.
Do not allow unrestricted N:M assignment. Escalate ambiguous N:M groups for review unless a governed document-flow key resolves the allocation.
Match the legal-entity transaction first. Apply OU/profit-center attribution afterward through an explicit crosswalk or retained source allocation; do not require seller OU to equal buyer OU.
## 7. Replace or accurately label the single-pass matcher
The dual `ROW_NUMBER()` with `ra=1 AND rb=1` is mutual-best selection, not a complete greedy or maximum matching algorithm. It can strand valid second choices.
Preferred implementation:
1. Execute highest-confidence matching stage.
2. Accept deterministic unique matches.
3. Remove consumed endpoints.
4. Run the next stage on remaining items.
5. Continue through controlled fuzzy/review stages.
If single-pass mutual-best matching is retained for performance, label it clearly as conservative mutual-best coverage and output candidate/ambiguity counts. Do not present it as complete reconciliation.
## 8. Govern tolerances
- Exact amount should use currency-appropriate minor units, not a universal `< 0.01`.
- P3 amount-only matching requires a date/reference constraint or should be review-only.
- P4 cannot use an economically unbounded 1% tolerance. Combine a relative tolerance with an absolute materiality cap.
- Example principle: residual must satisfy both the configured percentage and configured absolute currency cap.
- Preserve accepted-pair residual separately from unmatched-item exposure.
For different-document-currency items, do not force an automatic match. Classify them as `CURRENCY_MISMATCH` unless a governed FX rate type/date and reporting-currency conversion route is implemented. Carry the local-currency code alongside DMBTR.
## 9. Correct summary mathematics
Canonicalize entity pairs using `LEAST/GREATEST` inside the matching statistics.
Do not apply D-side `SUM(ABS(a_amt))` to both directional entity rows. Produce item-level coverage by expanding each accepted pair into two records—one for `a_key` and one for `b_key`—then aggregate each entity’s own matched item count and matched gross.
Directional match rate:
`matched_items_for_entity / total_items_for_entity * 100`
Canonical pair match rate:
`2 * matched_pairs / (items_entity_a + items_entity_b) * 100`
Report separately:
- paired item count
- unpaired item count
- paired gross by each side
- unpaired gross from an anti-join
- within-pair residual
- net signed exposure
- assignment coverage
- match coverage
Do not define unmatched dollars as directional gross minus an amount taken only from the receivable side. Do not repeat pair-level residuals on two directional rows where downstream aggregation will double count them. Prefer separate outputs for:
1. match detail
2. side/item coverage
3. one-row-per-canonical-pair summary
4. unresolved/mapping exceptions
## 10. Required validation gates
Before accepting the revision, demonstrate:
- No native ECC key duplicates after landing-state preparation.
- BKPF/BSEG row counts do not fan out after joining.
- Prior-year items still open at the cutoff remain included.
- Both lexical BUKRS directions produce candidates.
- No accepted item key appears in more than one match.
- Accepted 1:1 matches have one D and one K endpoint.
- Original item count and gross reconcile to paired plus unpaired populations.
- Every match rate is between 0% and 100%.
- Unmatched gross cannot become negative.
- Pair-level totals are not duplicated in dashboard aggregation.
- Supplemental, ambiguous and unresolved VBUND balances remain visible.
- Residual distributions are reported by matching rule.
- High-value and fuzzy matches receive manual sample validation.
- Output includes rule, evidence, item keys, amounts, dates, references and assignment lineage.
Optimize after correctness is proven. A single visually compact query is not more important than an auditable reconciliation result.
