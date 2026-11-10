# Staff surveys and survey builder

Implemented and verified locally, with both database migrations applied to production on 10 November 2026. The frontend is released through the existing `main` branch deployment to https://oscar-app-wine.vercel.app.

## Production release

Only the original **Quarterly team pulse** definition was seeded in production. Additional surveys and responses created during local review were not copied. The initial survey has ten required agreement questions, revised question 6, two optional written prompts, a 14-day response window and automatic quarterly runs starting **1 January 2027**. No run was launched during deployment; an admin can use **Launch now** when ready.

Production checks confirmed admin access, non-admin and anonymous denial, RLS, revoked direct writes and private scheduler access. The hourly cron job is active. Counts and complete row digests for existing commission calculations, staff, access mappings and invoices remained unchanged. Production contains one survey definition and zero runs, participants or responses after the migrations.

A fresh roles/schema/data backup with SHA-256 checksums is retained outside Git at `local-db.local/backups/20261110-survey-release/`. The pre-feature permission rows, constraints and function are also saved in `local-db.local/survey-production-before.json`. That targeted snapshot predates both migrations; the full backup was taken after the initial migration and before the builder migration. Production verification and security-advisor reports are retained alongside it under `local-db.local/`.

## Local review

Open **http://127.0.0.1:5173/app/admin/surveys**. Use `npm run local:up` and `npm run dev:local` if the stack/app is stopped, and check for the yellow local development banner.

**Admin → Surveys → Survey library** contains reusable survey definitions. The existing **Quarterly team pulse** is preserved with its ten agreement questions (including revised question 6) and two optional written questions. Its automatic schedule remains enabled from **1 January 2027**.

Choose **Create survey** to set:

- A name and introduction/purpose.
- Between 1 and 50 questions, in any order, each required or optional.
- A schedule, first run date and response-window length.
- Whether automatic runs are enabled. New schedules are paused until explicitly enabled.

Question formats:

| Format | Configuration / response |
| --- | --- |
| Agreement scale | 1 Strongly disagree, 2 Disagree, 3 Neutral, 4 Agree, 5 Strongly agree |
| Number rating | 1–5 or 1–10, with editable low/high endpoint labels |
| Yes / No | A deliberate No is a complete answer |
| Multiple choice | Pick one of 2–10 custom, distinct options |
| Checkboxes | Pick several of 2–10 custom, distinct options |
| Written answer | Up to 2,000 characters |

Use **Preview survey** to try the exact employee controls without saving responses. Add, remove or move questions with the controls on each question card. Saving edits affects future runs; existing runs retain snapshots of their name, introduction, question wording, types, options and scales.

**Duplicate** creates an editable copy with automatic scheduling off and manual launch selected. **Archive** stops future scheduled runs while preserving existing runs and responses; **Show archived → Restore** makes the survey available again and resumes its saved schedule if enabled.

## Schedules and launches

All schedule dates and closing boundaries use `Pacific/Auckland`.

| Frequency | Behaviour |
| --- | --- |
| Manual | Launch from the library when needed |
| Once | One scheduled occurrence on the first run date |
| Weekly | Repeats every seven days from the first date |
| Monthly | Repeats on the same day of each month |
| Every 3 months | Repeats every three months from the first date; use 1 January for calendar quarters |
| Yearly | Repeats each year on the first date’s month/day |

If a date does not exist in a month, that month’s last day is used, without drifting later occurrences. For example, a 31 January monthly schedule uses 28/29 February and then 31 March. Yearly 29 February schedules use 28 February in non-leap years.

The default response window is 14 days. Windows can be 1–60 days, with weekly schedules limited to 7 and monthly schedules to 28 to avoid routine overlap. Scheduled runs open at midnight and close at midnight at the start of the date `duration_days` later.

The existing **oscar-quarterly-staff-survey** cron job now checks all enabled, unarchived definitions hourly. It retries a due occurrence for up to seven days, while that occurrence’s response window remains open. Local scheduling requires Docker to be running; production scheduling runs independently in hosted Supabase. Missed older runs are not recreated en masse; admins can launch manually.

**Launch now** accepts a manual closing date within the next 60 days. It is independent of the configured future schedule. A survey can be manually launched once per NZ calendar date, with no overlapping run of the same survey. Different surveys can be open together. Manual and scheduled launches share locking and occurrence uniqueness checks, so retries/races do not create duplicate runs. An overlapping manual run can prevent the next scheduled occurrence; its first-week retries still apply.

Automated checks remove their own temporary surveys and runs. Surveys created manually during local review stay local and are not copied to production. Use the default pulse or create your own survey and launch it when ready.

## Employees, privacy and reporting

Eligible recipients are active staff with active app access at launch. Each run captures the assigned user account, staff identity, name and email. Changes to staff mappings/new accounts affect future runs. An admin account without a staff assignment can manage surveys but is not invited.

**Main → Surveys** shows assigned open surveys and the employee’s own history. Invitations appear after login or when a survey becomes available in an existing tab. **Remind me later** (or Escape) saves a 24-hour server-side delay, surviving reloads and other devices. It does not prevent answering from Surveys; the invitation returns after expiry in a long-lived tab.

Draft answers save after a short pause with visible saving/error feedback. **Save and return later** saves before leaving. Revision checks reject stale writes from another session. All required questions must be answered to submit; optional questions can be skipped. Submitted responses are final. The introduction explicitly explains that authorised admins can see submitted answers **by name**, while drafts remain private.

**Admin → Surveys → Runs & results** supports filtering by survey and reviewing each run. It shows participation and:

- Numeric means and distributions using each question’s configured scale.
- Yes/no and choice counts/percentages among staff who answered that question.
- Multi-selection counts (percentages can total more than 100%).
- Named written feedback and complete individual submissions.
- Numeric comparisons against the previous run of the same survey only when question ID, wording, type, scale and option configuration match.

Optional unanswered questions are excluded from question averages/percentages. Mixed numeric scales are not combined into one misleading score. Employee history displays an average only when numeric questions all use the same scale.

Results refresh periodically and can be refreshed manually. Closing a run early prevents further submissions and preserves existing results/private drafts; future scheduled runs are unaffected.

## Mobile completion and analysis

The employee form is designed for phones, with agreement faces running from strong frown to broad smile while keeping the numbers and text labels visible. Agreement controls were checked at 320, 360, 390 and 430 CSS pixels wide, with at least 44-pixel touch widths and no horizontal overflow. The introduction keeps named-admin access and draft privacy visible; longer usage information is expandable. Required labels are red. Survey-generated copy and exports use no em dashes.

A sticky progress indicator shows required answers completed. The footer stays compact, with save status and action buttons. **Submit answers** remains available to click when incomplete; only then does a modal list the missing required questions and skipped optional count. **Go to first unanswered** scrolls and focuses the relevant control. No submission is sent until required answers are complete and the final confirmation is accepted. Optional questions do not block submission. Server validation remains unchanged.

Results offer an **Analysis view** selector:

- **Summary charts** groups agreement scores into disagree (1-2), neutral (3) and agree (4-5), and provides means, medians and answer counts. Other question formats retain their own distributions.
- **Question breakdown** shows counts, percentages, numeric means, skipped answers, written feedback and unchanged-question comparisons.
- **Trends across runs** charts a selected rating question across up to eight runs of the same survey, ending with the selected run. The table below provides the same values and sample sizes. Changed questions, missing answers and failed requests leave gaps rather than false zeros.

## XLSX and PDF downloads

Use **Export results** within a run. Only submitted responses are exported. Choose **Names and emails** or **Randomised response IDs**, plus whether to include written answers.

- Named exports include staff names, emails and NZ submission times.
- Randomised exports shuffle respondents, assign new response labels for each download and omit names, emails, account IDs and exact submission times. There is no hidden identity lookup. Written answers are excluded by default because their content may identify people; admins can deliberately include them.
- XLSX contains **Summary**, **Responses**, and **Questions** sheets. Responses are raw numbers/booleans/text, with multiple selections represented as JSON arrays. Question codes map to wording, types, scale labels and options. Text beginning with `=` stays literal and is never interpreted as a formula. Raw response headers and the identity column are frozen.
- PDF contains a summary and each respondent's answers, with wrapping, automatic pagination, page numbers, and a bundled open font supporting Māori macrons. Font licence text is distributed at `/licenses/NotoSans-OFL.txt`.

Files are generated in the browser. Export libraries and the PDF font load only when needed. Nothing is uploaded to an external reporting service. Randomisation removes structured identity fields but does not guarantee anonymity of question wording or deliberately included free text.

The browser acceptance check downloads all four named/randomised XLSX/PDF combinations. `scripts/local/verify-survey-exports.py`, run with the bundled Python, reads those downloads and verifies values, types, statistics, literal text, Unicode, and identity omission including workbook metadata. PDF pages are rendered with Poppler for visual review. These changes require no new database migration.

## Database and recovery

The initial migration is `supabase/migrations/20261110064507_quarterly_staff_surveys.sql`. The additive builder migration is `supabase/migrations/20261110071543_configurable_staff_surveys.sql`. Apply each once in the intended environment. The initial filename matches its production migration record; the builder filename was generated with the CLI after that migration to preserve execution order. Local SQL changes were tested in rollback transactions and then applied directly to the guarded Docker database; no local migration-history entries were invented.

The builder adds admin-only RLS-protected `staff_surveys`, immutable question-schema snapshots on runs, and typed answer objects keyed by stable question IDs. It migrates old numeric ratings and written comments into that representation without changing submission status or revision. Fixed-size mutation RPCs are retired so they cannot bypass the new type validation.

All exposed survey tables use RLS and explicit read grants, with direct client writes revoked. Employees read only their own participant record/answers. Named reporting, creation, editing, launching and archiving require active admin/superadmin access, enforced in SQL. Managers cannot read other staff responses. Public mutation wrappers use caller security; authenticated private implementations validate types, options, bounds, ownership, deadlines and revisions. Internal launch/scheduler functions have no client execute grants. New functions have fixed search paths and use database access mappings rather than user-editable JWT metadata for authorisation.

The [local development runbook](local-development.md) still applies: do not reset the working database, replay the old migration folder, or run a linked push for this local feature.

A pre-builder full checkpoint is at `local-db.local/checkpoints/2026-11-10T04-45-23-938Z/`. The checkpoint runner now accounts for pg_cron’s restriction to its configured database: the **complete recovery dump retains the extension and jobs**, while only their installation/data is excluded from a disposable scratch restore. The verification manifest records exclusions. Scratch restores never run the working database’s scheduled jobs.

## Verification and evidence

- `npm run build` and changed-file ESLint pass. Vite continues to report its large-bundle advisory.
- `npm run local:survey-check` runs rollback-only validation/privacy tests for all six answer types, required/optional answers, No/false, invalid options/scales, snapshots, stale revisions, named admin access, manager/inactive/anonymous denial, reminders, final submission, close/archive, short months, leap years, first-week retry and duplicate prevention.
- `npm run local:survey-migration-check` restores the pre-builder checkpoint to a new scratch database, seeds a legacy submitted pulse response, applies the builder migration, verifies all 12 question snapshots/answers/comments/revision/submission state and an unchanged payroll digest, then removes that scratch database. An alternative verified pre-builder checkpoint directory can be passed as its argument.
- `node scripts/local/survey-browser-check.mjs <absolute playwright/index.mjs> [chromium executable]` verifies creating/editing/scheduling/previewing a mixed-format survey, reorder/remove, mobile layout, manual launch, fixed snapshots, reminder expiry, draft recovery, all typed answers, history/comparisons, named admin reports, other-user/manager isolation, closing, duplication and archive/restore. It creates and cleans only its own temporary surveys/staff/accounts, preserves the default pulse, and blocks non-loopback browser requests.
- Supabase security advisors report zero survey-related warnings (10 existing warnings concern other objects).
- The upgraded launch function was executed successfully by an unattended temporary cron test; that test job was removed.
- `npm run local:check` confirms the original 12,915 commission lines and 505 weekly summaries, local Auth and reporting APIs still match their baseline.

Ignored evidence under `local-db.local/`: `survey-check.log`, `survey-browser-check.log`, `survey-migration-check.log`, `survey-security-advisors.json`, `survey-builder.png`, `survey-builder-mobile.png`, `survey-mixed-form.png`, `survey-library.png`, `survey-typed-results.png`, and `survey-typed-response.png`. Test fixture manifests contain synthetic IDs, without passwords/session tokens. Copied business/Auth data and screenshots remain outside Git.
