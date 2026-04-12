# Deployment — Oscar & Co payroll SPA

Vite + React static client. **All data** comes from **Supabase Auth** and **Postgres RPC functions** (see `src/lib/supabaseRpc.ts`). There is no custom backend server in this repo.

## Required environment variables

Set these in your hosting provider’s environment UI or in a `.env` file for local builds:

| Variable | Purpose |
|----------|---------|
| `VITE_SUPABASE_URL` | Supabase project URL (e.g. `https://xxxx.supabase.co`) |
| `VITE_SUPABASE_ANON_KEY` | Supabase **anon** (public) key for browser use |

Optional:

| Variable | Purpose |
|----------|---------|
| `VITE_ENABLE_APP_LOGGING` | Set to `true` for slightly more verbose client error logs (console only) |

**Never** put the service role key in the frontend. Only the anon key is intended for the browser.

### Local development

1. Copy `.env.example` to `.env` in the project root.
2. Set `VITE_SUPABASE_URL` to your Supabase **Project URL** and `VITE_SUPABASE_ANON_KEY` to the **anon** public key (Dashboard → Settings → API).
3. Restart the dev server (`npm run dev`) so Vite picks up the new variables.

If either variable is missing or empty, the app shows a configuration screen instead of crashing.

Database RPCs used by the app (including admin access management) must exist in your Supabase project. Apply the SQL files under `supabase/migrations/` using the Supabase SQL editor or the Supabase CLI (`supabase db push` / linked project), then verify in **Database → Functions** (or run a quick RPC from the API docs page).

### Sales Daily Sheets import (`/app/admin/imports`)

There is no separate app server: the browser uploads the CSV to Storage, then calls RPC `trigger_sales_daily_sheets_import(p_storage_path text)` (elevated users only). That RPC validates the object and runs one of:

1. **Edge Function (default path)** — `supabase/functions/sales-daily-sheets-import` downloads the file with the service role, parses CSV into `public.sales_daily_sheets_staged_rows`, returns JSON to Postgres. The RPC invokes it **synchronously** using the Postgres **`http`** extension (`extensions.http_post`).
2. **Optional SQL hook** — if `app.sales_daily_import_edge_url` / `app.internal_import_secret` are not set, the RPC calls `public.sales_daily_sheets_import_pipeline_sql(p_batch_id uuid, p_storage_path text)` when that function exists.
3. **Optional payroll merge** — after staging, `private.run_sales_daily_sheets_merge_if_installed` runs `public.apply_sales_daily_sheets_to_payroll(uuid)` when you define it (loads staging into your reporting tables so commission/payroll RPCs see new data).

**One-time database configuration** (SQL editor, replace placeholders):

```sql
ALTER DATABASE postgres SET app.sales_daily_import_edge_url =
  'https://<project-ref>.supabase.co/functions/v1/sales-daily-sheets-import';
ALTER DATABASE postgres SET app.internal_import_secret = '<long random secret>';
```

Set the same secret for the Edge Function: `supabase secrets set INTERNAL_IMPORT_SECRET=<same value>` (or Dashboard → Edge Functions → secrets). Deploy the function: `supabase functions deploy sales-daily-sheets-import`.

Enable the **`http`** extension under **Database → Extensions** if `CREATE EXTENSION` in migrations did not run.

Optional frontend env (defaults are fine): `VITE_SALES_DAILY_SHEETS_BUCKET`, `VITE_SALES_DAILY_SHEETS_PATH_PREFIX` (see `.env.example`).

## Build and preview

```bash
npm ci
npm run build
```

Output: `dist/`

Local preview of the production build:

```bash
npm run preview
```

## HTTPS

Serve the app over **HTTPS** in production. Supabase auth and modern browser APIs expect a secure context for session storage and cookies behavior.

## Static hosting

Any static host that can:

- Serve `index.html` for unknown paths (**SPA fallback**), so client routes like `/app/payroll` load the app instead of 404.
- Inject or configure the env vars above at **build time** (Vite bakes `VITE_*` into the bundle).

Examples: Netlify, Vercel, Cloudflare Pages, AWS S3 + CloudFront, Azure Static Web Apps. Configure each platform’s “redirects” or “rewrites” so all routes fall back to `/index.html`.

## Security headers (hosting layer)

Configure at the CDN or host (not in this repo):

- **CSP** (Content-Security-Policy): start strict and allow `https://*.supabase.co` for API/auth as needed; allow `'self'` for scripts/styles from your origin.
- **HTTPS** only (HSTS optional once stable).
- Avoid embedding this app in untrusted iframes if you use `X-Frame-Options` / `frame-ancestors`.

Exact CSP values depend on your Supabase region and any fonts/CDNs you add.

## Smoke testing before go-live

See `docs/smoke-checklist.md`.
