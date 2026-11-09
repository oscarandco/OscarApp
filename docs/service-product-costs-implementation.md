# Service product costs: local implementation and review

Updated 9 November 2026, Pacific/Auckland. The feature is implemented in Docker. The core browser flow, full regression runner and independent fresh-restore migration test pass. Browser verification of the latest sorting, archive-date, integrated benchmark controls and unobstructed save bars also passed. The [architecture brief](service-product-costs-architecture.md) remains the decision record. This document records what was built, how to configure it locally and what has been verified; it does not authorise production changes.

## Delivered structure

- An additive [base feature migration](../supabase/migrations/20261109090656_service_product_costs.sql) and [archive-date follow-up migration](../supabase/migrations/20261109100957_service_cost_archive_dates.sql), developed against the restored local database. Before production rollout, the base backfill was corrected to preserve existing staff/history timestamps by temporarily suspending only each timestamp trigger and restoring its exact prior state inside the transaction. Existing source migrations are not replayed.
- Permanent plan IDs in current staff and role/pay history, plus a frozen original-plan fallback for genuine historical gaps. Explicitly unconfigured dated assignments stay unconfigured.
- A dated theoretical benchmark schedule independent of each person's actual remuneration plan.
- Separate service-cost identities, exact-name aliases, location-scoped Kitomba source-ID mappings and dated decimal ex-GST unit costs. The manual reference names and imported source identities supply catalogue coverage; neither supplies selling prices or fabricated real costs.
- Cost deduction in the shared commission engine, with actual and theoretical settings resolved separately and the existing assistant attribution preserved. Unresolved required costs remain distinguishable from explicit zero.
- Configuration → Service product costs, with compact rows, sortable data headers, archive dates, remuneration duplication and archive controls; ID-based dated staff assignment; weekly payroll readiness and cost-entry modal; additional deduction/basis fields in payroll line detail.
- A **Use this plan for theoretical commission** checkbox within the selected remuneration plan. Choosing a different plan opens an effective-date confirmation; compact read-only benchmark history replaces the separate benchmark editing controls.
- Server-side access checks and unresolved-commission guards protect alternate reporting/invoice routes. A modal alone is not the gate. Staff table/history read and write policies also follow Staff view/full permissions so a view-only user cannot bypass the dated assignment RPC through a direct table write.

The selling price is still the imported ex-GST line total. Cost is per service unit, shared across both salons. Discounts reduce sale revenue while unit cost remains fixed. A positive sale has a zero commission floor; a signed credit reverses the cost sign instead of being erased by that floor. No original-invoice matching automation was added.

The migrations are the canonical reviewable database changes, applied in timestamp order. Files under `dev/sql/` are authoring references, not a separate deployment sequence; applying the migrations does not require an assembler script or replaying those fragments. Do not regenerate the base migration to incorporate the follow-up.

## Configure and review locally

Use the [Docker runbook](local-development.md) to start the environment. Confirm the yellow local-development banner and use the local test admin. The existing hosted `.env` is not the local launch configuration.

1. Open **Configuration → Service product costs**. Review the manual reference names together with the records discovered in imported sales. Search and filter the list; check Seen in imported sales (Yes/No) and Last sale date. These dates describe retained imports across both salons, not all Kitomba history. Click a data-column header to cycle through ascending, descending and the original order. Money sorts numerically, dates chronologically, and blank values remain last; draft cost/date entries also sort without losing edits.
2. Review active services and archive irrelevant/old entries as appropriate. Kitomba Services, starred professional items and diary tasks are not interchangeable with OscarApp's final commission classification. Existing Products overrides still determine classification.
3. Enter the business's actual ex-GST **unit** costs with their effective dates. An intentional $0 is valid; blank is not equivalent to zero. Use Add service to prepare an unsold service before its first imported sale. Later imports discover new identities without replacing dated costs.
4. In **Remuneration**, rename the original Commission plan to **Commission to 31 October 2026**, duplicate it as **Commission**, preserve all rates/assistant settings and enable **Deduct service product costs before calculating commission** on the duplicate. Repeat for contractors using the agreed final plan labels. Referenced calculation settings/rates are protected; edit a new duplicate instead of modifying the old arrangement.
5. The local benchmark is already configured to use the new Commission plan from **1 November 2026**. For later changes, select the desired plan and choose **Use this plan for theoretical commission**, then confirm its effective date. The existing benchmark cannot be unchecked to leave a gap; choose a replacement plan instead. Save any plan edits first. Archived plans and view-only users cannot select a new benchmark. The compact history records earlier periods by permanent plan ID, so renaming a plan does not redirect old theoretical calculations.
6. In Staff, change each affected person's plan using **Role and pay history**, effective **1 November 2026**. This is not an employment-start-date change. Confirm the actual affected staff list instead of assigning every staff record indiscriminately.
7. Archive the old plans for new selection. Historical joins and the explicit Undo operation retain their original IDs. The legacy Wage plan name remains protected because existing attribution rules still depend on it.
8. Open weekly payroll. The system checks the selected week's applicable service costs across both salons independently of display filters. Resolve each dated requirement through **Save costs and review commission**. Closing the modal leaves the awaiting-costs banner and does not make commission final. Original sales totals remain available.

The initial implementation did not apply business configuration. On 9 November 2026, the new local plans and November theoretical benchmark were configured as described below. Real unit costs and dated staff moves still require business configuration. The $30 example is test data only. The source sales currently end on 31 October 2026, so November sale behaviour is verified through isolated fixtures until new local data is intentionally supplied.

### Archive dates

The Archived and All views include a sortable **Archived on** column. Future archive actions record a database timestamp. Reactivating a service clears that timestamp; archiving it again records the new archive time. Existing archived records without a recorded date show **Not recorded**. Their creation dates and last sale dates are not used to invent an archive date.

### Local plan setup completed 9 November 2026

At the user's request, the following configuration was applied only to Docker, in one transaction with historical-calculation checks before commit:

| Plan | Service rate | Product-cost deduction | Availability |
| --- | ---: | --- | --- |
| Commission | 35% | Enabled | Active |
| Contractor 45% | 45% | Enabled | Active |
| Commission to 31 October 2026 | 35% | Disabled | Archived; historical use retained |
| Contractor 45% to 31 October 2026 | 45% | Disabled | Archived; historical use retained |

Each new plan copies all six original rates and its assistant settings. Commission allows assistants; Contractor 45% does not. Wage remains unchanged.

The theoretical benchmark uses the original Commission ID through **31 October 2026**, then the new Commission ID from **1 November 2026**. Original plan IDs remain attached to existing staff and history. **Staff assignments were not moved by this plans-and-benchmark setup.** Assign the appropriate people to the new plans through dated Role and pay history when authorised.

All 12,915 pre-November calculation rows were checked before commit, excluding only plan display labels. Financial values, rates, identities, categories and other fields match. Full staff/assignment and saved-invoice digests are unchanged. The original baseline was not replaced. The ignored local audit is `local-db.local/november-plan-setup-2026-11-09T09-50-19-679Z.json`.

`npm run local:check` permits display-only plan renames while validating labels against their permanent IDs and checking every other baseline field. After this setup, `npm run local:feature-check` runs the original-state fixture suite in an isolated restore, preserving the working plan/benchmark configuration.

Post-configuration verification passed: historical baseline/Auth/API checks before and after the isolated acceptance suite, with configuration retained. Evidence: `local-db.local/feature-checks/2026-11-09T09-51-40-698Z.log`. The Remuneration UI also confirmed both new plans, archived originals and the 1 November benchmark boundary; screenshot: `local-db.local/november-plans-benchmark.png`.

## Verification evidence

The command `npm run local:feature-check` checks the working historical baseline/API before and after the acceptance suite. There are now four rollback-only SQL harnesses below. With the local cutover configured, these run in an isolated pre-configuration restore so the current plans and benchmark remain intact. The latest complete run passed on 9 November 2026; evidence is saved in `local-db.local/feature-checks/2026-11-09T10-13-06-392Z.log`. It includes the archive lifecycle, disjoint date-gap readiness, adjusted commission-guide and Staff direct-write permission assertions. Subsequent output is stored under the same ignored directory. Stop on a failure and inspect its log rather than regenerating a baseline to accept a changed result.

| Check | Evidence / scope |
| --- | --- |
| Source/repository provenance | `npm run local:schema-parity`: 14 critical final definitions from repository baseline `c6748c7` matched the pre-feature checkpoint after PostgreSQL canonicalisation in an isolated restored database. Covers commission/reporting views, staff profile/history entry points, My Sales trends and contractor creation. |
| Historical payroll | `npm run local:check`: original 12,915 commission lines, 505 weekly summary rows and the 362 detail rows for 26 October, together with local Auth, authenticated reporting RPCs and anonymous-access denial. |
| Plan transition | [Plan harness](../scripts/local/service-cost-plan-tests.sql): duplicate-rate fidelity; rename/reuse of Commission; frozen historical fallback; 1 November actual/theoretical boundaries; explicit NULL history; overlap rejection; archive/edit/delete guards; safe Undo; Wage-name guard and unauthorized mutation rejection. Passed against the integrated local migration with all fixtures rolled back. |
| Database permissions | [Permission harness](../scripts/local/service-cost-permission-tests.sql): actual `authenticated` and `anon` database roles; view-only reads; rejected cost/plan/staff writes; direct-table RLS bypass attempts including profile/plan-ID UPDATE and INSERT; alternate Staff-delete RPC denial; no-page-permission reads; private legacy function execution revoked; anonymous reads/writes denied. Passed, with all role-matrix fixture changes rolled back. |
| Cost calculations/reporting | [Cost harness](../scripts/local/service-cost-tests.sql): original example, quantity, discounts, floor, credits, actual/theoretical split, cost versions, readiness, assistant paths and saved invoice snapshots. Passed in the integrated feature-check run, with all fixtures rolled back. |
| Archive timestamps | [Archive harness](../scripts/local/service-cost-archive-tests.sql): recorded archive dates, reactivation clearing, later rearchive timestamps and existing unknown dates. Passed with fixtures rolled back. |
| Column sorting | [Sort tests](../scripts/local/service-cost-sort.test.mjs): five tests covering numeric, date, boolean, blank and draft-entry ordering. Passed. |
| Browser flow | Verified locally with a synthetic 2 November sale: modal opened automatically; dismissal left the awaiting-costs state with zero commission cards; saving $30 effective 1 November yielded $41.85 commission on $149.57 sales. Line preview showed $30 deduction and $119.57 basis; the corresponding commission-guide example returned $41.85. Catalogue usage/last-sale metadata, remuneration controls and benchmark schedule loaded. The catalogue contained 249 identities, 198 active during this check; that count is not a permanent catalogue size or an eligibility decision. |
| Cleanup and browser history | Synthetic service/staff/sale/configuration data was removed after verification. The page returned to the original 26 October values, $7,931.95 commission and $26,207.78 sales ex GST, without browser console errors. |
| Latest table and benchmark controls | Passed locally: Service headers cycle ascending/descending/off; No/Yes sorting works; compact rows remain approximately 37px high. Archived view shows the new archive-date column and omits cost-entry columns. A disposable archive verified the server-recorded date, then was removed; existing unknown dates show Not recorded. The plan checkbox correctly reflects the current benchmark, opens a dated confirmation for another active plan, and cancellation leaves the selection unchanged. Read-only history retains the 31 October/1 November boundary; no browser console errors were reported. |
| Save controls layout | The overlapping sticky footer was replaced by normal-flow Save product costs controls above and below the table. Browser checks at narrow and desktop widths confirmed no overlay over middle or final rows; both buttons reflect the same draft count and pending state. The temporary unsaved input was cleared without writing a cost. Screenshots: `local-db.local/service-cost-save-bar-fixed.png` and `local-db.local/service-cost-save-controls-top.png`. |
| Fresh-restore integration | Passed: both the base and archive-date migrations were applied to an independently restored pre-feature database; all four SQL harnesses passed and the original 12,915 baseline calculations remained unchanged. The disposable database was removed. Evidence: `local-db.local/feature-checks/fresh-restore.json`. |
| Build and repository checks | Latest production build passed (302 modules). `git diff --check` passed; Git reported only line-ending warnings. The earlier structured lint comparison across 43 changed TypeScript/React files found zero added diagnostics: 11 errors / 18 warnings before, 9 errors / 14 warnings after. Existing repository failures remain separate. Evidence: `local-db.local/feature-checks/lint-comparison.json`. |

Browser evidence is saved under ignored `local-db.local/`: `service-cost-alert.png`, `service-cost-resolved.png`, `service-cost-adjusted-preview.png`, `service-cost-catalogue.png`, `service-cost-sort-archive.png` and `plan-benchmark-control.png`.

The local Supabase migration-history table remains absent. The provenance check verifies the relevant final schema against the baseline repository; it does not prove every one of the old migration files ran or fabricate applied-history rows. Preserve the original source exports and checkpoint. The fresh-restore test proves the new additive migrations apply to that restored starting schema. A production rollout still requires reviewed prerequisites, a fresh backup, final operational review and separate explicit authorisation.

## Production rollout: 10 November 2026

The user separately authorised production deployment after the reviewed branch was merged into `main`. The live target is [OscarApp](https://oscar-app-wine.vercel.app), backed by Supabase project `qrqmramuvdqlvrtpvajo`. Automatic Vercel deployment from `main` is re-enabled for this release; the review branch remains disabled.

A fresh roles/schema/data backup was saved under the ignored `local-db.local/backups/20261109T105457Z-pre-production-rollout/` directory. Its complete 73-table data export was restored in a new local scratch database. All 14 critical source definitions matched, both migrations applied, and original calculations, staff/history timestamps, invoice snapshots and trigger states remained unchanged. The strengthened regression runner also passed all four SQL harnesses and all 12,915 historical lines. The scratch databases were removed; source backups were retained.

Only `20261109090656_service_product_costs` and `20261109100957_service_cost_archive_dates` were applied to production. A post-migration comparison confirmed every original calculation, staff/history field and invoice snapshot matched the source baseline. The current admin role successfully read 249 catalogue entries, both benchmark periods and the 362 payroll lines for 26 October, with no outstanding October cost issues. Anonymous access to the new catalogue RPC was denied. The production build passed.

Production now has the approved new **Commission** and **Contractor 45%** plans with product-cost deduction enabled, with all six original rates and assistant settings copied. The original plans are archived with their **to 31 October 2026** labels. Theoretical commission uses the original benchmark through 31 October, then the new Commission benchmark from 1 November 2026. The setup transaction asserted that historical calculations and staff assignments were unchanged; invoice snapshots and all financial totals were also verified afterward.

Real product costs remain unconfigured. Staff were not automatically moved to new plans: apply each agreed dated change through Staff Configuration. Docker's user-entered changes were not copied into production. This rollout does not replace Kitomba or alter the existing hosted import functions.

Deployment evidence and private backup data remain in ignored `local-db.local/` files, including `production-migration-verification.json`, `production-plan-setup-verification.json`, `production-authenticated-checks.json` and `fresh-production-backup-verification.json`.

## Deliberate limits and remaining business inputs

- Real per-service costs and the final affected staff/contractor list must come from the business. Neither the stock CSV's purchase costs nor the $30 illustration is a default.
- Rare partial credits, credits crossing the rule change or wrongly attributed Internal credits may need a business correction process. Automatic original-sale linkage and a new adjustment facility remain outside scope.
- Selling prices, stock consumption, appointment scheduling/POS and a replacement for Kitomba are outside this feature.
- Local Storage has copied metadata but not historical object bytes. Hosted import Edge Functions, production SMTP/SMS, Studio and Realtime are not mirrored. The local import route remains deliberately disabled until explicitly configured locally.
- The original local configuration review did not authorise rollout. The separate production deployment authorisation and completed database rollout are recorded above.
