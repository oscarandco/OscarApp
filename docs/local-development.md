# Local development with the restored Docker database

Verified on 9 November 2026 in `C:\Projects\Oscar App`, using Docker Desktop's local Linux engine. This environment is for developing the service product-cost feature described in the [architecture brief](service-product-costs-architecture.md).

## Start and sign in

Start Docker Desktop, then run these commands from the project directory:

```powershell
Set-Location -LiteralPath 'C:\Projects\Oscar App'
npm ci
npm run local:up
npm run dev:local
```

`npm ci` is needed on first checkout or after dependency changes. The restored database volume and ignored local files must already exist on this computer; `local:up` deliberately does not download production data, apply migrations, reset a database or create an empty replacement.

Open **http://127.0.0.1:5173/app/admin/weekly-payroll**. The yellow **Local development · Docker database** banner identifies the local instance.

Use the generated account `local-admin@oscarapp.test`. Its random password is in `local-db.local/login.json`; display it locally with:

```powershell
npm run local:credentials
```

This account exists only in the local Auth copy. It has an active admin access mapping without a staff assignment, so admin payroll works; personal My sales data is not assigned to a real employee. Existing copied users' passwords and staff records are unchanged.

The normal `npm run dev` command still uses the existing environment files. **Use `npm run dev:local` for this work.** It injects both the local URL and local anon key into the Vite process; it never edits `.env`. Docker mode refuses a hosted database URL. Local API keys are generated separately from the hosted project's keys; the service-role key stays in server-side tooling and Docker configuration.

## Services and commands

| Service | Address / role |
| --- | --- |
| React/Vite app | `http://127.0.0.1:5173` |
| Kong API gateway | `http://127.0.0.1:54321` |
| PostgreSQL 17 | `127.0.0.1:54322`, database/user/password `postgres` for this local instance |
| Mailpit email capture | `http://127.0.0.1:54324` |
| Auth, PostgREST, Storage, SMTP | Internal Docker services; no separate host ports |

Published ports bind explicitly to `127.0.0.1`. The Docker network is a normal bridge; this is not a network sandbox. Local SMTP targets Mailpit, SMS is disabled, local Edge Function routes return HTTP 501, and the copied production import configuration is empty.

| Command | Effect |
| --- | --- |
| `npm run local:up` | Start/reuse the six local services and ensure the test admin exists |
| `npm run dev:local` | Run Vite against the local API; keep this terminal running |
| `npm run local:status` | Show Docker service status |
| `npm run local:check` | Check original backup hashes, saved payroll baseline, Auth, RPC permissions and API results |
| `npm run local:audit` | Record local function/view fingerprints, frontend RPC name coverage and migration-file inventory |
| `npm run local:schema-parity` | Compare 14 critical pre-feature schema definitions with repository baseline `c6748c7` in an isolated restore |
| `npm run local:feature-check` | Run historical/API checks and all rollback-only service-cost, plan and permission fixtures; save ignored local logs |
| `npm run local:checkpoint` | Save a full local database checkpoint and verify a restore into a new scratch database |
| `npm run local:credentials` | Display the local-only test login |
| `npm run local:down` | Stop/remove local containers and network; retain both database and Storage volumes |

Press **Ctrl+C** in the frontend terminal to stop Vite. `local:down` does not stop that frontend process. To start again, run `local:up` and `dev:local`.

The versioned Compose file is [dev/local/compose.yaml](../dev/local/compose.yaml). It adopts the existing `oscarapp-db` container and external volume `supabase_db_oscarapp-local`. The old ignored DB-only Compose file is superseded. Do not start the earlier Supabase CLI stack alongside this stack; they share the volume and ports. Do not delete the volume or use reset commands.

## Saved baseline and verification

`local-db.local/payroll-baseline.json` contains the original 12,915 line calculations, 505 staff/location/week summary rows and 362 detail rows for the week starting 26 October 2026. It records both actual and theoretical values, rates, categories and paid-staff/plan identities. The check compares the selected existing fields so future additions can be assessed against the original results.

The initial baseline was captured once with `npm run local:check -- --capture-baseline`. That option refuses to overwrite an existing file. Do not replace the baseline to make a regression pass. Intentional new fixtures or calculation changes will need explicitly scoped assertions when the feature is implemented.

After an authorised plan rename, `local:check` permits differences only in the display-only `derived_staff_paid_plan_name` field. All other saved line fields, including permanent plan IDs, rates and financial amounts, still have to match exactly. It reports the number of changed labels and separately verifies that every current label matches its unchanged plan ID in the database. The original baseline file is retained.

Once a new Commission plan has product-cost deduction enabled or the benchmark schedule has multiple periods, `local:feature-check` keeps the current configuration intact and runs the original-state acceptance fixtures in an isolated restore of the pre-configuration checkpoint. It still checks the working database's historical baseline and authenticated APIs before and after. This avoids replaying fixtures whose setup assumes the original three-plan arrangement over a deliberately configured cutover.

Verified:

- Password sign-in, active admin access, authenticated payroll summary/detail RPCs, line preview and browser session persistence after reload.
- The weekly payroll page shows $7,931.95 actual commission and $26,207.78 sales ex GST for 26 October. Jarod's preview shows $1,120.60 commission; invoice INV98610 still shows $149.57 ex GST, 35%, $52.35 commission.
- Anonymous admin-payroll requests fail. The existing RPC returns HTTP 400 / `P0001` / `Access denied`; the check recognises this denial rather than requiring HTTP 401/403.
- All 60 literal frontend RPC names exist in the restored database. This is a name-coverage check, not a complete semantic audit of every migration or RPC branch.
- Original source-backup SHA-256 checksums match. A complete local checkpoint was restored successfully into a fresh database in the same PostgreSQL cluster; counts and the full commission-core digest match.
- `npm run build` and ESLint for the changed TypeScript/React files pass. The repository-wide lint command already has unrelated errors/warnings; these were not part of the local setup change.

Browser evidence is saved locally at `local-db.local/local-payroll.png`.

## Recovery checkpoints

The original source exports remain unchanged in `local-db.local/backups/20261109T075855Z/`. Their schema export does not include a full set of managed Auth/Storage table definitions or Supabase migration bookkeeping. Preserve these exports as source evidence; they are not a standalone fresh-cluster bootstrap.

For local development recovery, use `npm run local:checkpoint`. It saves `database.dump`, `roles.sql` and `verification.json` under a timestamped `local-db.local/checkpoints/` directory. The database dump includes managed Auth/Storage definitions and local Auth data. The command restore-tests it in a uniquely named, newly created database, compares counts and a commission digest, then removes only that scratch database. It never overwrites the working database. On failure it leaves the scratch database for inspection and reports its name.

The first complete restore-tested checkpoint is `local-db.local/checkpoints/2026-11-09T08-36-47-986Z/`. Restore verification covers the same local PostgreSQL 17 cluster with its existing Supabase roles and extensions. Recreating a whole Docker installation on another machine also requires compatible roles/extensions, managed-service images and the separate local runtime settings.

To inspect/recover a checkpoint without replacing `postgres`:

1. Select the checkpoint and verify `database.dump` against `verification.json`'s SHA-256.
2. Copy it into `oscarapp-db` with `docker cp`.
3. Create a **new, uniquely named empty database**, using local `supabase_admin` and `template0`.
4. Run `pg_restore --exit-on-error -U supabase_admin --dbname <new-database> <container-dump-path>` inside `oscarapp-db`.
5. Compare the saved counts/digest and inspect the restored schema before deciding on any switch to it. The [checkpoint script](../scripts/local/checkpoint.mjs) contains the exact tested command sequence.

Keep backups, runtime credentials, test login, generated gateway configuration, baseline and screenshots in the ignored `local-db.local/` directory. They contain sensitive copied business/Auth data and must stay out of Git.

## Feature implementation and local boundaries

The service-cost migration has been applied only to Docker. See [implementation and local configuration](service-product-costs-implementation.md) for the delivered structure, test evidence and local review steps. The catalogue, plan controls, dated benchmark and missing-cost modal/adjusted preview have been verified in the browser, then cleaned back to the original October baseline. The final consolidated regression runner, independent fresh-restore migration test and production build all passed. The feature is ready for local business review and configuration.

The local `supabase_migrations.schema_migrations` table is absent. Fourteen critical final definitions matched repository baseline `c6748c7` in an isolated pre-feature restore. This is source provenance for the affected calculation/history/reporting objects, not proof that every old migration ran. **Do not run the migration folder from the beginning, blindly repair migration history, or run a linked database push.** No applied-history entries were invented.

Imported sales end on 31 October 2026. The service-cost harness builds October/November boundary scenarios in rollback-only transactions. The original payroll baseline remains unchanged; no real product costs, staff cutover or new benchmark were silently loaded.

Storage metadata is copied and the local Storage API runs, but historical file bytes have not been copied. Old invoice PDFs and old CSV objects may therefore be unavailable locally. Hosted Edge Functions, production SMTP/SMS, Realtime and Studio are not mirrored. Sales import processing remains disabled until it has an explicitly local implementation/configuration; existing imported sales remain available for reporting.

The service-cost implementation remains local. No production database change, push or deployment is included.
