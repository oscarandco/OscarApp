# Frontend MVP — developer notes

This document captures **current assumptions** and **known tradeoffs** for the salon payroll / commission React client. It is not a substitute for backend documentation.

- **Deploy / hosting:** see [`DEPLOY.md`](../DEPLOY.md) in the repo root.
- **Pre-release testing:** see [`smoke-checklist.md`](./smoke-checklist.md).

## Data access

- All payroll data flows through **`src/lib/supabaseRpc.ts`** only (no direct `from('table')` or view selects in the app).
- Core RPCs: `get_my_access_profile`, `get_my_commission_summary_weekly`, `get_my_commission_lines_weekly`, `get_admin_payroll_summary_weekly`, `get_admin_payroll_lines_weekly`.
- Admin access management (see `supabase/migrations/`): `get_admin_access_mappings`, `search_staff_members`, `search_auth_users`, `create_access_mapping`, `update_access_mapping`.

## RPC shape assumptions

- Summary RPCs return **arrays of rows**; each row may represent a **split** (e.g. pay week × location, and possibly staff in admin scope). Rows are **not** deduplicated by week in the UI.
- Line RPCs take **`p_pay_week_start`** as a **date string** (typically `YYYY-MM-DD`). The UI validates route params to roughly match that contract (see `src/lib/routeParams.ts`).
- **Extra columns**: TypeScript types list **known** fields; the RPC may return additional scalar columns — tables render any keys present on the row objects.
- **Location**: Summary and line RPCs should return **`location_id`** and **`location_name`** (from `public.locations`, typically via `JOIN` on `locations.id`). The UI shows **`location_name`** in filters and tables; **`location_id`** remains the filter value and fallback when the name is absent.
- **Nullable fields**: Cells treat `null`, `undefined`, and blank strings as empty and show an em dash (—).

## Access roles (app behaviour)

- Normalization lives in **`src/features/access/normalizeAccessProfile.ts`** (and `accessContext`). Stored roles align with the DB: **`self`** (staff / “stylist” in UI copy), **`manager`**, and **`admin`**; elevated routes use **`manager`** + **`admin`** (and legacy **`superadmin`** if present). Optional RPC flags may also apply.
- Users without an access row, or with inactive access, are handled by **`AppBootstrapGate`** (no main shell).

## MVP tradeoffs

1. **Summary stats “total commission”** sums **`total_actual_commission`** across **all displayed summary rows**. Because each row can be a location split, this is a **sum of splits shown**, not necessarily a single deduplicated “per week” total.
2. **Detail week header** (`pay_week_end`, `pay_date`) is taken from the **first line** returned when present; lines that disagree are not merged server-side in the UI.
3. **Route param validation** is **best-effort** in the browser (date pattern + parse). Edge-case strings that pass the client check could still fail server-side.
4. **Table column order** is opinionated (preferred keys first); remaining keys are sorted alphabetically.

## Client-side summary filters (stylist + admin)

- **Location** and **search** filter only the rows already returned by the weekly summary RPC (no extra network calls).
- Stylist search matches **`derived_staff_paid_display_name`**. Admin search matches **`derived_staff_paid_display_name`** or **`staff_full_name`** when present.
- Stats cards and totals reflect **filtered** rows only.

## Areas to tighten later

- Column-level formatting driven by a **schema map** from the backend (instead of key-name heuristics).
- **Deduplicated** weekly totals when the product definition requires it.
- **CSV / PDF export** and richer **filtering** (out of scope for this MVP).
- **Automated tests** against a mocked RPC layer or Supabase test project.

## Testing hooks

A small set of **`data-testid`** attributes marks main pages and tables (see payroll/admin pages and table wrappers). Use for e2e or smoke tests; not exhaustive.
