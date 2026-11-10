# Shared payroll reporting performance

Production fix applied on 10 November 2026, Pacific/Auckland. Staff Trends, Weekly Payroll, My Sales and contractor invoice preparation depend on the same classification and commission views. Slow reads in those views caused statement timeouts across multiple pages.

## Cause and final change

`staff_profile_at` and `private.service_commission_basis` return at most one row, but their default planner estimates were 1,000 rows. Repeated lateral joins inflated the estimated summary cardinality to 51,867,000,000,000,000 rows. Setting `ROWS 1` corrects planning without limiting actual results or changing either function body, permissions or security settings.

The shared parity and commission views also repeated scalar `staff_plan_id_at` calls inside plan-table scans. They now reuse the effective assignment rows already joined for the commission, work and paid staff, and join dated benchmark periods directly. Assignment presence is tested explicitly: an existing assignment with a NULL plan ID remains NULL; only a missing assignment uses the staff fallback plan ID. Plan names reuse the corresponding plan joins. Classification, attribution, date boundaries and money formulas are preserved.

The commission view uses direct arithmetic for ready and not-required rows. Its four existing `require_ready_commission` calls remain on the unresolved/NULL status paths. This avoids repeated PL/pgSQL calls on normal rows while retaining unresolved-cost errors. Interactive reporting entry points explicitly disable JIT; their timeouts and access checks remain unchanged.

No reporting cache or materialized view was added. Imports, cost changes and dated staff assignments continue to affect live calculations immediately. Existing saved invoices remain snapshots.

## Verification

Temporary views in rollback-only production transactions compared every complete calculated sales row against the previous definitions. Both the dated-plan join change and the ready-guard change matched exactly. Lookup function bodies, ACLs and other settings were checked unchanged apart from the row estimates. Anonymous and ordinary staff access restrictions passed, and unresolved costs still raise the existing error.

Seven calls were tested with an 8-second statement limit using the existing authorised account. These are observed database times, not browser or network latency guarantees:

| Report call | Rows | Time |
| --- | ---: | ---: |
| Staff Trends / Weekly Payroll summary | 870 | 5.96 s |
| Weekly Payroll lines for 2 November | 386 | 0.15 s |
| My Sales trend | 52 | 1.37 s |
| My Sales location summary | 105 | 4.09 s |
| Contractor invoice pay weeks | 53 | 0.04 s |
| Contractor invoice batch | 1 JSON result | 0.13 s |
| Payroll cost readiness | 0 outstanding issues | 0.69 s |

Recovery definitions, full-row comparison scripts, EXPLAIN evidence and timing reports are retained outside Git under `local-db.local/`. The four migrations beginning `20261110084146`, `20261110084828`, `20261110085108` and `20261110085715` record the production schema changes. No source sales, saved cost amounts or invoice records are rewritten by these migrations.
