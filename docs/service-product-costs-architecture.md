# Service product costs and commission architecture

Status: agreed scope implemented and verified locally; ready for business review and real configuration. Updated 9 November 2026, Pacific/Auckland.

OscarApp will deduct a configured product cost from eligible service revenue before calculating commission. Kitomba remains the source of selling prices and quantities. OscarApp will own the service-cost settings, remuneration rules and reporting.

This is the implementation brief and decision record for the work; it is not itself an executable harness. Database backup, local restoration and local frontend/Auth/API integration are complete. The service-cost model, shared calculations, configuration and payroll readiness are implemented locally; the browser flow was verified with synthetic November data and cleaned back to the original historical baseline. The final consolidated regression, independently restored-database migration test and production build passed. Repeatable historical/API checks, rollback-only acceptance fixtures and a restore-tested local checkpoint are available. Real costs and staff/benchmark transition settings still require business configuration. Production rollout is not authorised. See the [local development runbook](local-development.md) and [implementation evidence/configuration steps](service-product-costs-implementation.md).

## Purpose and scope

Commission currently uses the full ex-GST sale amount. Oscar & Co wants a fixed allowance for product consumed during a service to be non-commissionable. This must work for employee commission and contractor arrangements, with the new plans assigned effective **1 November 2026**.

For one service unit:

| Item | Amount |
| --- | ---: |
| Imported sale amount ex GST | $149.57 |
| Example configured product cost ex GST | $30.00 |
| Commissionable amount | $119.57 |
| Commission at 35% | $41.85 |

The $30 is an example and test fixture, not a default to load into real services. The highlighted source sale was dated 30 October 2026 and must retain its original $52.35 commission.

Included:

- Service-cost configuration, dated cost history and shared costs for both salons.
- Safe remuneration-plan duplication, renaming, archiving and dated staff assignment.
- A dated standard-plan benchmark for theoretical commission.
- New-service discovery and missing-cost resolution during weekly payroll review.
- Consistent calculation through actual, theoretical and assistant commission, reporting and contractor invoice preparation.

Excluded:

- Maintaining selling prices, durations, retail stock costs or inventory consumption in the new section.
- Replacing Kitomba, building appointments/POS, or creating an automatic Kitomba catalogue integration.
- Automatic matching of credits to original invoices.
- Recalculating saved contractor invoices in place.
- Production deployment as part of the current local development work.

## Confirmed decisions

| Decision | Agreed behaviour |
| --- | --- |
| Selling prices | Use the actual ex-GST line amount from Sales Daily Sheets, including discounts. Do not maintain another selling-price list. |
| Eligibility | Apply product-cost deductions to the app's final Service classification. Preserve existing non-commission exclusions and product-classification overrides. |
| Quantity | Cost is per service unit. Quantity two deducts twice the configured unit cost. |
| Locations | One service cost applies across Takapuna and Orewa. Location does not determine the amount. |
| Discounts | Reduce the sale amount but leave the product cost unchanged. |
| Positive sales | Commission is zero when product cost meets or exceeds the sale amount. |
| Cost history | Store amounts with effective dates. A later cost change must not rewrite earlier calculations. |
| Missing costs | Unconfigured and explicitly $0 are different states. Never silently substitute $0 for a missing required cost. |
| Plan selection | Actual commission follows the person's plan effective on the sale date. |
| Theoretical commission | Use a standard benchmark plan effective on the sale date, including its deduction setting and applicable service cost. |
| Credits | Preserve negative commission in the credit week. Handle rare exceptional refunds manually rather than implementing invoice-matching automation. |
| Historical scope | No need to maintain old, cost-free services for periods under the old rules. Retain cost history once it has been used. |
| Payroll review | Resolve required missing costs before displaying the selected week's commission totals. Closing a modal does not resolve the issue. |
| Usage information | Show whether each service appears in imported sales and its last sale date, across both salons. Use transaction dates, not upload dates. |

Money remains ex GST throughout the deduction calculation. The original sale amount, GST and sales totals remain intact. This is a commission-basis adjustment, not a discount on the customer's sale or an actual stock-accounting entry.

## Existing architecture and constraints

The frontend uses React, TypeScript, Vite, Tailwind and TanStack Query. Supabase provides Auth, Postgres, Storage and Edge Functions. Payroll data is calculated through database views and RPCs; a frontend-only subtraction would leave other reporting and invoices inconsistent.

The repository baseline for this planning work is commit `c6748c7`.

| Existing component | Relevance |
| --- | --- |
| [Staff assignment model](../supabase/migrations/20260828120000_staff_role_assignments.sql) and [write RPC](../supabase/migrations/20260828120300_apply_staff_role_assignment.sql) | Staff role/pay history already has effective start/end dates. Staff Configuration prompts for the effective date of plan changes. |
| [Commission core](../supabase/migrations/20260828123000_theoretical_assistant_commission.sql) | Actual paid-staff plan selection uses `staff_profile_at(..., sale_date)`. Rates still multiply the full `price_ex_gst`. The theoretical benchmark is selected by the literal name `commission`. |
| [Plan API](../src/lib/remunerationPlansApi.ts) | Renaming updates the plan row only. Rate updates overwrite existing values. Creating a blank plan sets rates to zero and assistant eligibility to false. |
| [Staff API](../src/lib/staffMembersApi.ts) | Staff plan links are name strings. The plan selector does not yet filter inactive plans. |
| [Plan deletion guard](../supabase/migrations/20260430260000_admin_delete_remuneration_plan_if_unused.sql) | Checks current staff references; it must also protect historical assignments and benchmark references. |
| [Products configuration](../src/features/admin/pages/ProductConfigurationPage.tsx) | Classification overrides matched to sale descriptions, including professional products and special cases. Keep this purpose separate from service costs. |
| [Quote services](../supabase/migrations/20260501120000_quote_config_core_tables.sql) | A quote-builder structure, not the canonical imported service-cost catalogue. |
| [Weekly payroll dashboard](../src/features/admin/pages/AdminWeeklyCommissionDashboardPage.tsx) | The page at `/app/admin/weekly-payroll`; add readiness checking here. |
| [Contractor invoice tables](../supabase/migrations/20260825120300_contractor_invoices_tables.sql) | Saved invoice headers and lines are snapshots. New previews/creation use payroll calculations; saved invoices stay unchanged. |
| [Latest sales import application](../supabase/migrations/20260504120100_apply_sales_daily_sheets_import_result_in_apply_fn.sql) | Preserves Kitomba `PROD_ID` in raw sales rows, plus quantity and ex-GST line totals. |

**Plan-name reuse is unsafe today.** Historical assignments store the text "Commission". Renaming the old plan and creating a new plan with that name would make those assignments resolve to the replacement. Backfill and use permanent plan IDs before performing the rename/create transition. Check all effective-plan lookups, including assistant eligibility and staff-paid attribution.

Historical assignment gaps also need checking: existing views can fall back to the current staff profile where history is absent. Do not rely on that fallback to preserve old plan selection during this migration.

## Proposed data design

These are logical entities, not final SQL table names. Use additive migrations and retain the original sale records.

| Entity | Responsibility |
| --- | --- |
| Service | Permanent OscarApp ID, display name, configuration status and source identity. No selling price. |
| Source service mapping | Link imported identifiers and, where necessary, reviewed description aliases to the service. |
| Service cost version | Service ID, non-negative ex-GST cost per unit, effective interval and audit fields. Prevent overlapping intervals for a service. |
| Remuneration plan | Existing rates and assistant settings, plus the deduction flag and working archive controls. |
| Staff plan reference | Permanent plan ID in current staff and dated assignment history, backfilled from existing names before changing plan labels. |
| Theoretical benchmark period | Effective interval and permanent benchmark-plan ID. Exactly one applicable standard benchmark per supported sale date. |

Use decimal database arithmetic for money. Preserve the existing rounding convention unless a separately reviewed change is necessary; line display rounding and rounding aggregated payroll can differ.

Cost and benchmark lookups must use the line's sale date. Define interval boundary conventions explicitly and reject overlaps or accidental gaps. Existing staff-history date semantics must remain compatible.

Archived plans and services remain available to historical calculations. Archive means unavailable for new assignment or normal editing; it must not filter them out of historical joins. Protect referenced plans and used cost history from accidental destructive edits.

The new tables and RPCs must follow the existing role/page-permission model, with database-enforced access controls. Reading a report does not grant permission to edit costs or plans.

## Service identity and initial catalogue

The [manual reference dataset](reference/kitomba-service-names-2026-11-09.json) preserves all **245 distinct names** copied from the five Kitomba pages: 50 + 50 + 50 + 50 + 45. "Capacity" is the first entry, not a column heading.

The list includes 47 names beginning with `zOLD` or `z OLD`, 23 ending in `*`, and internal diary tasks. Those labels are review aids, not automatic eligibility decisions. Starred names may already be classified as Professional Product by OscarApp. Preserve that classification behaviour.

The stock CSV reviewed earlier contained Retail and Professional stock items, with no Service rows. Its `cost_excl` values are not the agreed per-service deductions.

The manual dataset supplies names only. It does not contain Kitomba product IDs, confirmed location mappings, selling prices or service costs. Its coverage of both salons must be checked against imported data.

Before seeding the application:

1. Compare the names with final classifications and identities in imported sales.
2. Prefer verified Kitomba product identifiers. Check whether IDs are shared across salons or need a source/location scope.
3. If the same service has different IDs, map them to one shared OscarApp service-cost record.
4. Use reviewed exact description matching where no reliable ID is available. Do not silently fuzzy-match or merge similar names.
5. Review old entries, tasks, non-commission cases and professional products. Only activate the applicable cost settings.

Keep existing historical sale descriptions in sales data without requiring old cost-free catalogue rows. Once a cost has affected commission, retain its service identity and cost history even if the service is later archived.

## Calculation and remuneration transition

### Positive service sales

For a normal eligible sale whose actual plan enables the deduction:

```text
total product cost = quantity × cost per unit effective on sale date
commissionable amount = max(imported ex-GST line amount − total product cost, 0)
commission = commissionable amount × applicable commission rate
```

The imported amount is already the line total. Multiply the unit cost by quantity; do not multiply the line sale total by quantity again.

When the plan disables deduction, retain the existing basis. Preserve current attribution, category-rate selection, assistant eligibility and non-commission rules.

Expose the applied product-cost deduction and commissionable amount in line detail alongside the original price and rate. A required missing cost must be represented as unresolved, not as a completed zero-cost calculation or a silently omitted line.

### Actual remuneration plans

Checkbox label:

> Deduct service product costs before calculating commission

Supporting text:

> Commission on service sales is calculated after subtracting the configured product cost per unit from the sale amount excluding GST. Discounts reduce the sale amount but do not reduce the product cost. Commission on a sale cannot fall below zero.

The explanation applies to positive sales; credits retain signed treatment.

After permanent plan links are in place:

1. Retain the old Commission plan's rates and settings, with deduction disabled, and label it "Commission to 31 October 2026".
2. Duplicate it as "Commission", copying every rate and assistant setting, then enable deduction.
3. Apply the equivalent old/new version process to the contractor plan. Confirm the final contractor labels during configuration.
4. Assign affected staff to their new plans effective 1 November 2026 through Role and pay history. This is not a change to their employment start date.
5. Archive the old plans for new assignment while retaining historical use.

Do not update old rates to introduce the new arrangement. Editing historical plan settings can change live calculated reports even without re-importing a CSV.

### Theoretical commission

Add a small benchmark schedule within Remuneration:

| Sale date | Standard benchmark |
| --- | --- |
| Reporting history through 31 October 2026 | Old Commission plan |
| From 1 November 2026 | New Commission plan with product-cost deduction |

Use permanent plan IDs, not display names. This is a standard comparison arrangement, independent of a person's actual plan. A person remaining on Wage can therefore have $52.35 theoretical commission for the example October sale and $41.85 for an equivalent November sale.

Actual and theoretical amounts must resolve their deduction settings separately. Update assistant and theoretical-assistant amounts consistently without subtracting the cost repeatedly in successive reporting layers.

### Credits and manual exceptions

Keep negative commission in the week of the credit date. Under the same plan, rate and unit cost, a matching full credit with amount −$149.57 and quantity −1 should mirror the $41.85 positive-sale commission as **−$41.85**.

A zero floor applied indiscriminately to every signed line would incorrectly erase credit commission. A negative line must also reverse the cost sign rather than subtracting another positive $30 from the negative sale amount.

The agreed scope deliberately excludes automatic original-invoice matching. An October sale credited after the November change may need a manual correction to reverse the exact original amount. Incorrect "Internal" attribution also needs review; do not infer a staff member solely from the customer/product name.

There is no dedicated manual commission-adjustment facility in the current app. The operating method for rare exceptions and partial credits remains to be specified; do not invent one or claim exact original-sale reversal for every credit.

## Admin experience

### Service product costs

Add a Configuration menu entry separate from Products and Quotes. The list should support search, bulk cost entry and filters for missing costs, explicit $0, configured and archived entries.

Show:

- Service name.
- Product cost per unit ex GST.
- Effective from date and cost history.
- Seen in imported sales.
- Last sale date.
- Optional location availability/usage context; it does not change the shared cost.

Usage is derived from retained imported sales across both salons. "Not seen in imported sales" does not mean "never sold in Kitomba". Last sale date uses the transaction date, not import time. The precise treatment of credit-only records and renamed services belongs in the identity/usage implementation review.

Allow an admin to add a service before its first sale. Sales imports provide automatic discovery of previously unknown identities and flag required missing costs. Sales-only discovery cannot detect an unsold service; no automatic pre-sale catalogue synchronisation has been agreed.

An import or name refresh must preserve OscarApp's cost history. New real cost amounts are entered by the business; do not seed the $30 example or assume every service costs $0.

### Weekly payroll readiness

On opening or changing the selected pay week:

1. Check all relevant lines across both salons, independently of display filters.
2. Identify required costs missing for each sale date under the applicable actual or theoretical plan.
3. Deduplicate the issues into service/date requirements. One service may need more than one cost interval in a week.
4. Open a modal when unresolved requirements exist.

Suggested modal title: **3 services need product costs**.

Provide service name, affected units/date range, unit cost ex GST and effective date. Suggest the first affected eligible sale date for the effective date, and let the admin confirm it. Do not create or overwrite historical intervals silently.

The action is **Save costs and review commission**. Store normal cost-history records, recheck readiness and refresh all affected calculations. A saved cost applies across both salons and subsequent relevant weeks, not just the current modal.

Closing the modal leaves a persistent **Commission awaiting product costs** banner and a Review costs action. Show an awaiting-costs state instead of apparently final commission totals. Sales totals can remain visible. Costs are resolved by a dated amount, including explicit $0, not by dismissing an alert.

Old plans and periods that do not require deductions must not generate cost-setup alerts. New Retail or Professional products alone must not trigger this service-cost gate.

The database/reporting design must preserve unresolved status and prevent alternate RPCs or contractor invoice creation from treating incomplete amounts as final. Define how each affected screen presents that status; a frontend modal alone is insufficient.

## Local database and recovery baseline

The source project is `qrqmramuvdqlvrtpvajo`, in organisation `pfipobimxnnjfhhcjnyh`, region Singapore (`ap-southeast-1`). The source database was PostgreSQL 17.6 at export.

A database export and successful local restore were completed on 9 November 2026. The host-local files below are ignored by Git and are not recreated by checking out the repository.

| Local item | Current state |
| --- | --- |
| Working directory | `C:/Projects/Oscar App` |
| Database container | `oscarapp-db` |
| Database | `postgres`, PostgreSQL 17.11 |
| Published endpoint | `127.0.0.1:54322`, verified reachable from Windows |
| Compose file | `dev/local/compose.yaml`, started with `npm run local:up` |
| Docker volume | `supabase_db_oscarapp-local`, external persistent volume |
| Backup directory | `local-db.local/backups/20261109T075855Z/` (timestamp is UTC) |
| Backup files | `roles.sql`, `schema.sql`, `data.sql`, `checksums.json`, restore log and verification results |
| Local sanitisation | The copied row in `private.sales_daily_sheets_import_config` was deleted locally to remove its production import endpoint/secret configuration. The backup files retain the original source data. |
| Frontend and API | `npm run dev:local` uses `127.0.0.1:5173` and the local API at `127.0.0.1:54321`, with a visible Docker banner. Auth, PostgREST, Storage, gateway and Mailpit run locally; Studio and Edge Functions are not mirrored. Existing `.env` is unchanged. |
| Development checkpoint | `local-db.local/checkpoints/2026-11-09T08-36-47-986Z/`, full local dump restore-tested in a new database without replacing the working database |

The initial Supabase CLI stack established the managed schemas and volume, then was stopped. The database now runs under the separate Compose file with explicit localhost binding. Do not start the CLI stack alongside it: they would compete for port 54322 and the same database volume.

The successful restore used the local `supabase_admin` role in one transaction, with triggers disabled during data loading, because the ordinary local role could not restore managed Storage metadata. Verification was performed through `postgres`. This is a local restore detail, not a reason to broaden production application privileges.

The export contains sensitive database and Auth data. Keep it, credentials and local environment files out of Git. Storage metadata is included; actual Storage files and hosted Edge Function/Auth/SMTP configuration are not a complete part of this database-only copy.

Verified source/local comparisons:

| Dataset or calculation | Matching result |
| --- | ---: |
| Sales transactions | 12,915 |
| Imported sale date range | 4 November 2025 through 31 October 2026 |
| Staff | 44 |
| Staff role/pay assignments | 52 |
| Remuneration plans | 3 |
| Plan rates | 18 |
| Saved contractor invoices | 42 |
| Commission-core line count | 12,915 |
| Sum of sale amounts ex GST | $908,173.49 |
| Sum of actual commission ex GST | $226,494.43 |
| Sum of theoretical commission ex GST | $274,576.77 |

The monetary totals are aggregates from `v_commission_calculations_core`, not a single week's payroll or contractor invoice balance. `npm run local:check` now compares 12,915 saved line calculations, 505 weekly summary rows and 362 detail rows for the week of 26 October, verifies the corresponding authenticated RPCs, access denials and original backup hashes. Browser sign-in, payroll, Jarod's line preview and session reload were verified. The restored sales currently end before the cutover, so November tests still need controlled local fixtures alongside the feature model.

The local migration-history table is absent. `npm run local:schema-parity` has verified 14 critical final definitions against repository baseline `c6748c7` in an isolated restore of the pre-feature checkpoint. `npm run local:audit` records current frontend RPC coverage, definition fingerprints and the migration-file inventory. This does not prove every old migration ran; do not replay the folder or invent applied-history entries. The additive feature migration is tested separately against the restored schema.

The working tree was clean before these planning documents. The feature migration is applied locally only. No production payroll-data change, push or deployment has been performed.

## Implementation sequence

### 1 Establish the local development environment

Local app/Auth/API startup, browser verification, saved line/week baselines, source provenance for 14 critical objects and a complete restore-tested checkpoint are done. October/November fixtures now exist in rollback-only harnesses. Detailed evidence, commands and limits are in the [local runbook](local-development.md).

- Bring up a compatible local Auth/API stack without exposing the copied data beyond localhost or starting production integrations.
- Use a separate local frontend environment and clear local-development indicator. Do not point local tests at production.
- Preserve source backup/checksums, record a repeatable restore procedure and check database migration-history coverage. The application dump alone must not be assumed to preserve Supabase migration bookkeeping.
- Compare the restored live schema with repository migrations before writing new migrations.
- Capture line/week baselines and build isolated fixtures around the October/November boundary.

### 2 Add the database model and calculation

Completed locally in the canonical feature migration. Existing source calculations remain unchanged until a cost-enabled actual plan or benchmark applies.

- Backfill and validate permanent plan references before any plan rename.
- Add service identities/mappings, dated unit costs, deduction settings and benchmark periods.
- Implement archive protections, access controls, atomic validation and required cost-readiness status.
- Adjust the shared commission basis once, then propagate the results through actual, theoretical and assistant paths and the dependent RPCs.
- Preserve current behaviour by default until a cost-enabled plan and benchmark apply.

### 3 Add configuration and payroll UI

Completed locally and verified in the browser, including missing-cost dismissal, save, recalculation and adjusted line preview.

- Add Service product costs, bulk entry, history, usage columns and Add service.
- Add plan duplication/archiving, checkbox explanation and the theoretical benchmark schedule.
- Add the selected-week missing-cost modal and persistent readiness state.
- Add line-detail product-cost and commissionable-amount fields.
- Refresh the affected queries after changes; prevent stale totals or a race with newly imported unresolved services.

### 4 Verify locally and review with the business

Engineering verification passed: full rollback harnesses, before/after source baseline and APIs, independent restored-database migration, browser flow, build and lint comparison with no added diagnostics. Local business review and real configuration are the next step.

- Implement the acceptance checks below with database fixtures and meaningful UI tests.
- Reconcile both salons, totals, assistant attribution and saved invoices.
- Run build/lint checks and identify existing failures separately from new failures.
- Review the local app and enter the actual service costs. Resolve the technical review items below before calling the feature ready.

### 5 Prepare a separate production rollout

- Prepare reviewed, additive migrations and a tested rollback procedure.
- Take and verify a fresh backup immediately before production changes.
- Seed the reviewed service identities, configure real dated costs, create the plan versions, set benchmark periods and apply staff assignments.
- Reconcile the changed November results and unchanged earlier results before routine use.
- Prefer targeted rollback of calculation definitions/configuration over a full database restore that would discard later imports or activity.

**The user's no-push/no-deploy instruction remains in force.** Completing documentation or local development does not authorise a production rollout. No hosted paid development project or branch is required by this plan.

## Acceptance checks

These are the acceptance targets. Executable cost, plan and permission harnesses cover the core database behaviours, and the browser readiness/save/adjusted-preview flow is verified. The final consolidated regression and independently restored-database migration run passed. Exact evidence and limits are recorded in the [implementation document](service-product-costs-implementation.md).

| ID | Scenario | Expected result |
| --- | --- | --- |
| SC01 | Existing pre-November source lines with deduction disabled | Actual/theoretical values, categories, attribution and aggregate totals match the captured baseline. |
| SC02 | 30 October example, $149.57, 35% | $52.35 commission; no missing-cost alert under the old rules. |
| SC03 | Equivalent 1 November sale, one unit, $30 cost | $119.57 commissionable amount and $41.85 commission. |
| SC04 | Two units, imported line total $299.14, cost $30 each, rate 35% | Deduct $60; base $239.14; displayed commission $83.70 under the retained rounding convention. |
| SC05 | Discounted sale $120, one unit, $30 cost, rate 35% | Base $90 and commission $31.50; unit cost stays $30. |
| SC06 | Positive sale $20, one unit, $30 cost | Commission zero, never negative. |
| SC07 | Configured $0 versus no matching cost version | $0 is ready; a required absent cost remains unresolved and cannot silently become zero. |
| SC08 | Week beginning 26 October 2026 | Old rules through 31 October; new rules on 1 November, irrespective of week start or import date. |
| SC09 | Wage stylist across the cutover | Actual arrangement stays unchanged; theoretical commission follows the dated standard benchmark. |
| SC10 | Rename old plan and reuse "Commission" for the new plan | Old assignments still resolve to the old ID; archive does not break historical calculation. |
| SC11 | Later cost change and reporting rebuild | Earlier sales retain their applicable earlier cost; the new amount applies only within its effective interval. |
| SC12 | Service sold in both salons | The same mapped service uses one shared cost and one combined usage history. |
| SC13 | New eligible service in a selected pay week | One deduplicated readiness issue; modal opens, totals await costs, and closing the modal does not clear it. |
| SC14 | Save a valid dated cost or explicit $0 | Readiness is rechecked; affected actual/theoretical totals refresh; future weeks reuse the setting. |
| SC15 | Starred Professional Product, Retail, Green fee or another existing exclusion | Existing classification and exclusion rules remain intact; no inappropriate service-cost gate. |
| SC16 | Matching full credit under the same cost/rate as SC03 | Quantity −1 and amount −$149.57 produce −$41.85 in the credit week. Cross-rule and partial-credit exceptions remain visible for manual review. |
| SC17 | Existing saved contractor invoice and a newly generated preview | Saved snapshot stays unchanged; new calculation uses the shared engine and cannot treat required missing costs as ready. |
| SC18 | Assistant work and theoretical assistant comparison | Eligibility/attribution are preserved and each applicable calculation uses the correct adjusted basis once. |
| SC19 | Unknown ID, duplicate mapping, overlap, history gap, null/zero quantity | Explicit validation or review outcome; no arbitrary first-match, guessed quantity or silent historical reassignment. |
| SC20 | User without cost-management permission; concurrent import or edit | Edits are rejected server-side when unauthorised; readiness is checked against the data used for the calculation. |
| SC21 | Seen/last-sale metadata and a later CSV re-import | Usage reflects matching imported transaction history, not the upload timestamp; absence is labelled only as not seen in imports. |

## Implementation choices and business review

The engineering choices below are implemented and tested. The operational reviews and business inputs remain separate from the completed local verification.

- Source IDs are scoped by location, with permanent shared service identities and exact reviewed-name aliases. The business should review the catalogue for renamed/retired items and any source exceptions; no fuzzy merges are performed.
- Seen/last-sale metadata uses matching retained transactions across both salons, including signed credits, and source-ID aliases preserve recognised rename history. Imported appearance is not itself final Service eligibility.
- Staff/history IDs, frozen gap fallback, benchmark periods, interval constraints and indexes are implemented. Plan duplication/archiving and saved contractor-invoice preservation are covered by the harnesses.
- Unresolved costs retain explicit status; weekly readiness identifies disjoint missing date ranges, and commission-bearing reporting/invoice paths cannot present incomplete sums as final.
- Missing/zero quantities and inconsistent signed amount/quantity combinations produce an explicit unresolved review status rather than a guessed quantity.
- Rare cross-rule refunds or incorrect staff attribution still need a business correction method. A manual adjustment UI and automatic original-sale linkage are not included in the agreed scope.
- Stored/finalised values remain stored records; configuration changes must not silently rewrite saved invoices or closed historical records. Review deliberate refresh/correction of closed business records during any later operational rollout.
- Fourteen critical source definitions matched the repository baseline; the new migration and harnesses passed from an independent restored database. Migration bookkeeping remains absent, with no fabricated history entries. Cross-machine fresh-cluster bootstrap is outside the same-cluster restore check.
- Actual service cost amounts, final contractor labels and staff membership of the new plans are business configuration inputs, not inferred from stock purchase costs or this reference list. No real November cutover has been automatically configured.

## Related documentation

- [Local build and deployment notes](../DEPLOY.md)
- [Existing frontend assumptions](frontend-mvp-notes.md)
- [Existing smoke checklist](smoke-checklist.md)
- [KPI architecture](KPI%20App%20Architecture.md)

Update this brief when decisions or verified implementation status change. Keep the confirmed rules, pending work and completed checks distinct.
