# Smoke checklist — MVP handover

Run through this after deploy or before external testers. Use a **non-production** Supabase project first if possible.

## Environment

- [ ] **`VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`** are set for the build/deploy.
- [ ] With both **removed** or empty, the app shows the **configuration** screen (variable names listed, no secret values) — not a blank page.
- [ ] With env set, the app loads past that screen.

## Auth and access

- [ ] **Sign in** with a valid user (email/password or your configured provider).
- [ ] **Sign out** works and returns to login or clears session as expected.
- [ ] User with **no access row** sees the **no access** screen (not the main shell).
- [ ] User with **inactive access** sees the **access inactive** screen.
- [ ] User with active access reaches **My sales** (`/app/my-sales`).

## Stylist (standard user)

- [ ] **Weekly summary** loads (or empty state if no RPC rows).
- [ ] **Location** and **search** filters change the table; **Clear filters** resets.
- [ ] **View lines** opens detail for a week; **back** link returns to summary.
- [ ] Line detail loads or shows empty/error appropriately.

## Admin (elevated user)

- [ ] **Admin** nav links visible only for admin/manager (as defined by access profile).
- [ ] **Admin weekly summary** loads; **filters** work; **Clear filters** resets.
- [ ] **View lines** opens admin detail; **back** link works.
- [ ] Admin line detail loads or shows empty/error appropriately.

## Resilience

- [ ] **Error boundary**: trigger a render error in dev only (optional) — fallback with **Reload page** appears, or rely on normal navigation after a real bugfix.
- [ ] RPC/network errors show **retry** where implemented, not a white screen.

## Done

When all relevant boxes pass for your target environment, the MVP is ready for wider testing.
