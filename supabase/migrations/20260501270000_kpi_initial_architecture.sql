-- =====================================================================
-- KPI initial data architecture (hybrid actuals model).
--
-- This migration is intentionally additive and backend-only. It does
-- not touch quote payload logic, totals logic, linked-extra rollup
-- behaviour, or any existing reporting view. It introduces seven new
-- tables that, taken together, support:
--
--   * Live current-open-month operational KPIs computed on demand from
--     existing sales tables/views (no row in kpi_monthly_values until
--     the month is closed and finalised).
--   * Closed historical months stored as canonical facts in
--     kpi_monthly_values.
--   * Retention / frequency KPIs computed monthly and snapshotted into
--     kpi_monthly_values (those calculations are too expensive to do
--     live every page load and need a fixed cohort definition).
--   * Uploaded KPIs (CSV / spreadsheet imports) flowing through
--     kpi_upload_batches + kpi_upload_rows, then promoted into
--     kpi_monthly_values on accept.
--   * Manual / admin-entered KPIs flowing through kpi_manual_inputs,
--     then promoted into kpi_monthly_values.
--   * Targets stored separately from actuals in kpi_targets, with
--     month-to-date pacing supported via a per-KPI / per-target
--     proration method (default `linear_calendar_days`).
--   * Per-staff monthly capacity in staff_capacity_monthly, reserved
--     for capacity / utilisation use cases. NOTE: staff_capacity_monthly
--     is NOT the source for stylist_profitability — that KPI uses
--     staff_members.fte as its FTE denominator (see the
--     stylist_profitability seed row for the full rationale).
--
-- Role enforcement: aligned with the existing access-profile model.
-- All seven tables are enabled for RLS and grant SELECT to elevated
-- users (admin / manager / superadmin) via private.user_has_elevated_access().
-- Writes (INSERT/UPDATE/DELETE) are deliberately *not* granted to
-- authenticated; mutations must go through SECURITY DEFINER RPCs in a
-- follow-up migration that re-enforces elevated-only or admin-only as
-- appropriate. Keeps this migration purely structural.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. kpi_definitions
--    Catalogue of every KPI the app knows about. One row per code.
--    Drives both the live RPC dispatch (live_rpc_name) and the
--    closed-month finalisation pipeline (finalisation_rpc_name).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.kpi_definitions (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code                     text NOT NULL,
  display_name             text NOT NULL,
  description              text,
  -- Coarse grouping for navigation / dashboards. Constrained to a
  -- closed list rather than a strict ENUM so adding a future group
  -- is a simple migration without an ALTER TYPE.
  goal_group               text NOT NULL,
  value_type               text NOT NULL,
  unit                     text,
  direction                text NOT NULL DEFAULT 'higher_is_better',
  period_grain             text NOT NULL DEFAULT 'monthly',
  -- How the KPI is produced. `live_calculated` = computed on demand
  -- by an RPC, never stored. `calculated_monthly` = computed by a
  -- finalisation RPC and stored in kpi_monthly_values once a month
  -- is closed. `uploaded` = comes in via kpi_upload_*. `manual` =
  -- entered by an admin via kpi_manual_inputs. `hybrid` = current
  -- open month is live, prior months are stored.
  source_type              text NOT NULL,
  -- Whether the KPI is meaningful to compare against a month-to-date
  -- prorated target (e.g. revenue). Headcount/percent/retention
  -- KPIs typically set this to false.
  supports_mtd_pacing      boolean NOT NULL DEFAULT false,
  mtd_proration_method     text,
  live_rpc_name            text,
  finalisation_rpc_name    text,
  default_level_type       text NOT NULL DEFAULT 'business',
  -- Locked KPI visibility tiers (per docs/KPI App Architecture.md):
  --   'stylist' = visible to stylist + manager + admin
  --              (stylist sees own scope only; manager/admin see all scopes)
  --   'manager' = visible to manager + admin only
  --   'admin'   = visible to admin only (e.g. EBITDA, Operational Costs,
  --              COGS %, Support Staff Cost %, Stock Value)
  -- The reporting RPCs are responsible for enforcing this against the
  -- caller's access role, plus enforcing the self-scope rule on
  -- stylists.
  visibility_tier          text NOT NULL DEFAULT 'admin',
  is_active                boolean NOT NULL DEFAULT true,
  sort_order               integer NOT NULL DEFAULT 0,
  notes                    text,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT kpi_definitions_code_not_blank
    CHECK (btrim(code) <> ''),
  CONSTRAINT kpi_definitions_code_unique UNIQUE (code),
  CONSTRAINT kpi_definitions_goal_group_check CHECK (
    goal_group IN (
      'financial', 'operational', 'client', 'staff', 'retention', 'stock'
    )
  ),
  CONSTRAINT kpi_definitions_value_type_check CHECK (
    value_type IN ('currency', 'count', 'percent', 'ratio', 'minutes', 'number')
  ),
  CONSTRAINT kpi_definitions_direction_check CHECK (
    direction IN ('higher_is_better', 'lower_is_better')
  ),
  CONSTRAINT kpi_definitions_period_grain_check CHECK (
    period_grain IN ('monthly', 'quarterly', 'rolling_6m', 'rolling_12m', 'snapshot')
  ),
  CONSTRAINT kpi_definitions_source_type_check CHECK (
    source_type IN ('live_calculated', 'calculated_monthly', 'uploaded', 'manual', 'hybrid')
  ),
  CONSTRAINT kpi_definitions_mtd_proration_check CHECK (
    mtd_proration_method IS NULL
    OR mtd_proration_method IN ('linear_calendar_days', 'none')
  ),
  CONSTRAINT kpi_definitions_default_level_type_check CHECK (
    default_level_type IN ('business', 'location', 'staff')
  ),
  CONSTRAINT kpi_definitions_visibility_tier_check CHECK (
    visibility_tier IN ('stylist', 'manager', 'admin')
  ),
  -- A KPI that supports MTD pacing must declare *how* to prorate.
  CONSTRAINT kpi_definitions_mtd_requires_method CHECK (
    NOT supports_mtd_pacing OR mtd_proration_method IS NOT NULL
  )
);

ALTER TABLE public.kpi_definitions OWNER TO postgres;

CREATE TRIGGER trg_kpi_definitions_updated_at
  BEFORE UPDATE ON public.kpi_definitions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


-- ---------------------------------------------------------------------
-- Customer name normalisation function.
--
-- Locked rules (docs/KPI App Architecture.md): identity for the
-- guests_per_month and new_clients_per_month KPIs is derived from
-- Sales Daily Sheets WHOLE NAME, normalised in this exact order:
--   1. truncate from the first '(' onward
--   2. truncate from the first standalone numeric suffix onward
--      (a digit run preceded by whitespace and at end-of-string or
--      followed by whitespace)
--   3. if the remaining name ends with a standalone trailing A, B,
--      or C (case-insensitive), strip it
--   4. collapse repeated whitespace, trim, lowercase
--
-- Examples:
--   'Ashley Smythe (75)'          -> 'ashley smythe'
--   'Alice Vermunt 60'            -> 'alice vermunt'
--   'Christine Ridley C'          -> 'christine ridley'
--   'Rachael Hausman 60 A'        -> 'rachael hausman'
--   'Zara Ellis (comp winner)'    -> 'zara ellis'
--
-- Known v1 limitation (accepted): names like
-- 'Savannagh (Mari) Primrose' are over-normalised. The raw WHOLE
-- NAME is intentionally never overwritten on the source rows; this
-- function is called on demand by the live KPI RPCs and (later) by
-- a derived view/index, so the raw value is preserved for audit and
-- future re-normalisation.
--
-- IMMUTABLE so it is safe to use in expression indexes.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.normalise_customer_name(p_raw text)
  RETURNS text
  LANGUAGE sql
  IMMUTABLE
  PARALLEL SAFE
  SET search_path = pg_catalog, public
AS $$
  SELECT NULLIF(
    -- 4. collapse whitespace + trim + lowercase
    lower(
      btrim(
        regexp_replace(
          -- 3. strip standalone trailing A / B / C (case-insensitive)
          regexp_replace(
            -- 2. truncate from first standalone numeric suffix onward.
            --    A "standalone numeric suffix" is a run of digits
            --    preceded by whitespace and either at end-of-string
            --    or followed by whitespace. The replacement keeps
            --    everything up to (but not including) the leading
            --    whitespace of that numeric run.
            regexp_replace(
              -- 1. truncate from first '(' onward
              split_part(p_raw, '(', 1),
              '\s+\d+(\s.*)?$',
              '',
              'g'
            ),
            '\s+[abcABC]\s*$',
            '',
            'g'
          ),
          '\s+',
          ' ',
          'g'
        )
      )
    ),
    ''
  );
$$;

ALTER FUNCTION public.normalise_customer_name(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.normalise_customer_name(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.normalise_customer_name(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.normalise_customer_name(text) TO service_role;


-- ---------------------------------------------------------------------
-- 2. kpi_monthly_values
--    Canonical store for:
--      - closed/finalised historical months
--      - retention/frequency KPI snapshots
--      - uploaded KPI outputs (after acceptance)
--      - manual/admin KPI outputs
--      - hybrid/derived KPI outputs where appropriate
--
--    NOT the source of truth for live current-open-month operational
--    KPIs — those are computed on demand by their live_rpc_name and
--    deliberately skip this table to keep current-month figures
--    self-correcting against late sales corrections.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.kpi_monthly_values (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kpi_definition_id   uuid NOT NULL REFERENCES public.kpi_definitions(id) ON DELETE RESTRICT,
  period_grain        text NOT NULL,
  -- For monthly grain, period_start = 1st of month, period_end = last
  -- of month. For rolling_6m/12m, the *anchor* month start/end. For
  -- snapshot, the snapshot date in both columns.
  period_start        date NOT NULL,
  period_end          date NOT NULL,
  scope_type          text NOT NULL,
  location_id         uuid REFERENCES public.locations(id) ON DELETE RESTRICT,
  staff_member_id     uuid REFERENCES public.staff_members(id) ON DELETE RESTRICT,
  value               numeric(18, 4) NOT NULL,
  -- Optional transparency fields for ratio/percent KPIs so consumers
  -- can re-derive the percent and audit the inputs (e.g. retail$ /
  -- total$ for retail_percent).
  value_numerator     numeric(18, 4),
  value_denominator   numeric(18, 4),
  source_type         text NOT NULL,
  status              text NOT NULL DEFAULT 'final',
  finalised_at        timestamptz,
  finalised_by        uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  upload_batch_id     uuid,
  manual_input_id     uuid,
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT kpi_monthly_values_period_grain_check CHECK (
    period_grain IN ('monthly', 'quarterly', 'rolling_6m', 'rolling_12m', 'snapshot')
  ),
  CONSTRAINT kpi_monthly_values_period_order_check CHECK (period_end >= period_start),
  CONSTRAINT kpi_monthly_values_scope_type_check CHECK (
    scope_type IN ('business', 'location', 'staff')
  ),
  CONSTRAINT kpi_monthly_values_source_type_check CHECK (
    source_type IN ('calculated_monthly', 'uploaded', 'manual', 'hybrid', 'live_snapshot')
  ),
  CONSTRAINT kpi_monthly_values_status_check CHECK (
    status IN ('draft', 'final', 'superseded')
  ),
  -- Scope columns must match scope_type so we never get a 'staff'
  -- row without a staff_member_id, etc.
  CONSTRAINT kpi_monthly_values_scope_consistency CHECK (
    (scope_type = 'business' AND location_id IS NULL AND staff_member_id IS NULL) OR
    (scope_type = 'location' AND location_id IS NOT NULL AND staff_member_id IS NULL) OR
    (scope_type = 'staff'    AND staff_member_id IS NOT NULL)
  )
);

ALTER TABLE public.kpi_monthly_values OWNER TO postgres;

CREATE TRIGGER trg_kpi_monthly_values_updated_at
  BEFORE UPDATE ON public.kpi_monthly_values
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Unique-final fact per scope. Partial index so superseded/draft rows
-- can coexist with the current canonical 'final' row. NULL scope
-- columns are coalesced to a sentinel uuid (matches the convention
-- used by ux_staff_member_user_access_user_staff_role in the baseline).
CREATE UNIQUE INDEX ux_kpi_monthly_values_final_scope
  ON public.kpi_monthly_values (
    kpi_definition_id,
    period_grain,
    period_start,
    scope_type,
    COALESCE(location_id,     '00000000-0000-0000-0000-000000000000'::uuid),
    COALESCE(staff_member_id, '00000000-0000-0000-0000-000000000000'::uuid)
  )
  WHERE status = 'final';

-- Hot-path lookup indexes. Most reads will be "give me the last N
-- months for this KPI" or "give me one month for this KPI at this
-- scope".
CREATE INDEX ix_kpi_monthly_values_kpi_period
  ON public.kpi_monthly_values (kpi_definition_id, period_start DESC);
CREATE INDEX ix_kpi_monthly_values_location_period
  ON public.kpi_monthly_values (location_id, period_start DESC)
  WHERE location_id IS NOT NULL;
CREATE INDEX ix_kpi_monthly_values_staff_period
  ON public.kpi_monthly_values (staff_member_id, period_start DESC)
  WHERE staff_member_id IS NOT NULL;


-- ---------------------------------------------------------------------
-- 3. kpi_targets
--    Targets are deliberately separate from actuals. One row per
--    (kpi, grain, period_start, scope). MTD pacing reads
--    target_value × prorate(...) at query time inside the reporting
--    RPC; this table never stores a derived MTD value.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.kpi_targets (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kpi_definition_id    uuid NOT NULL REFERENCES public.kpi_definitions(id) ON DELETE RESTRICT,
  period_grain         text NOT NULL,
  period_start         date NOT NULL,
  period_end           date NOT NULL,
  scope_type           text NOT NULL,
  location_id          uuid REFERENCES public.locations(id) ON DELETE RESTRICT,
  staff_member_id      uuid REFERENCES public.staff_members(id) ON DELETE RESTRICT,
  target_value         numeric(18, 4) NOT NULL,
  stretch_value        numeric(18, 4),
  -- Per-target override of the KPI definition's default proration
  -- method. NULL means "use kpi_definitions.mtd_proration_method".
  mtd_proration_method text,
  notes                text,
  created_by           uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT kpi_targets_period_grain_check CHECK (
    period_grain IN ('monthly', 'quarterly', 'rolling_6m', 'rolling_12m', 'snapshot')
  ),
  CONSTRAINT kpi_targets_period_order_check CHECK (period_end >= period_start),
  CONSTRAINT kpi_targets_scope_type_check CHECK (
    scope_type IN ('business', 'location', 'staff')
  ),
  CONSTRAINT kpi_targets_mtd_proration_check CHECK (
    mtd_proration_method IS NULL
    OR mtd_proration_method IN ('linear_calendar_days', 'none')
  ),
  CONSTRAINT kpi_targets_scope_consistency CHECK (
    (scope_type = 'business' AND location_id IS NULL AND staff_member_id IS NULL) OR
    (scope_type = 'location' AND location_id IS NOT NULL AND staff_member_id IS NULL) OR
    (scope_type = 'staff'    AND staff_member_id IS NOT NULL)
  )
);

ALTER TABLE public.kpi_targets OWNER TO postgres;

CREATE TRIGGER trg_kpi_targets_updated_at
  BEFORE UPDATE ON public.kpi_targets
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE UNIQUE INDEX ux_kpi_targets_scope
  ON public.kpi_targets (
    kpi_definition_id,
    period_grain,
    period_start,
    scope_type,
    COALESCE(location_id,     '00000000-0000-0000-0000-000000000000'::uuid),
    COALESCE(staff_member_id, '00000000-0000-0000-0000-000000000000'::uuid)
  );

CREATE INDEX ix_kpi_targets_kpi_period
  ON public.kpi_targets (kpi_definition_id, period_start DESC);


-- ---------------------------------------------------------------------
-- 4. kpi_manual_inputs
--    One canonical row per (kpi, grain, period_start, scope) for
--    manually entered KPIs. Updates are upserts; an audit history
--    can be added later as a separate kpi_manual_input_history table
--    if/when required (kept out for "smallest safe change" now).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.kpi_manual_inputs (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kpi_definition_id   uuid NOT NULL REFERENCES public.kpi_definitions(id) ON DELETE RESTRICT,
  period_grain        text NOT NULL,
  period_start        date NOT NULL,
  period_end          date NOT NULL,
  scope_type          text NOT NULL,
  location_id         uuid REFERENCES public.locations(id) ON DELETE RESTRICT,
  staff_member_id     uuid REFERENCES public.staff_members(id) ON DELETE RESTRICT,
  value               numeric(18, 4) NOT NULL,
  value_numerator     numeric(18, 4),
  value_denominator   numeric(18, 4),
  notes               text,
  entered_by          uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  entered_at          timestamptz NOT NULL DEFAULT now(),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT kpi_manual_inputs_period_grain_check CHECK (
    period_grain IN ('monthly', 'quarterly', 'rolling_6m', 'rolling_12m', 'snapshot')
  ),
  CONSTRAINT kpi_manual_inputs_period_order_check CHECK (period_end >= period_start),
  CONSTRAINT kpi_manual_inputs_scope_type_check CHECK (
    scope_type IN ('business', 'location', 'staff')
  ),
  CONSTRAINT kpi_manual_inputs_scope_consistency CHECK (
    (scope_type = 'business' AND location_id IS NULL AND staff_member_id IS NULL) OR
    (scope_type = 'location' AND location_id IS NOT NULL AND staff_member_id IS NULL) OR
    (scope_type = 'staff'    AND staff_member_id IS NOT NULL)
  )
);

ALTER TABLE public.kpi_manual_inputs OWNER TO postgres;

CREATE TRIGGER trg_kpi_manual_inputs_updated_at
  BEFORE UPDATE ON public.kpi_manual_inputs
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE UNIQUE INDEX ux_kpi_manual_inputs_scope
  ON public.kpi_manual_inputs (
    kpi_definition_id,
    period_grain,
    period_start,
    scope_type,
    COALESCE(location_id,     '00000000-0000-0000-0000-000000000000'::uuid),
    COALESCE(staff_member_id, '00000000-0000-0000-0000-000000000000'::uuid)
  );


-- ---------------------------------------------------------------------
-- 5. kpi_upload_batches
--    Header row per upload (CSV/spreadsheet). One batch can target a
--    single KPI (kpi_definition_id NOT NULL) or be multi-KPI
--    (kpi_definition_id NULL) — kpi_upload_rows always carries its
--    own kpi_definition_id so multi-KPI uploads are supported.
--
--    Location is owned at the batch/header level (locked decision):
--    the Utilisation and Future Utilisation reports are one file per
--    location, so location_id on the batch is the AUTHORITATIVE
--    source for every row in the file. kpi_upload_rows therefore
--    does NOT carry a location_id — for any 'location'-scoped row
--    the location is read from the parent batch. The upload RPC
--    will require location_id NOT NULL for utilisation /
--    future_utilisation batches; it stays nullable here because
--    other KPI uploads (e.g. a future business-wide CSV) may not be
--    bound to a single location.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.kpi_upload_batches (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kpi_definition_id   uuid REFERENCES public.kpi_definitions(id) ON DELETE RESTRICT,
  location_id         uuid REFERENCES public.locations(id) ON DELETE RESTRICT,
  file_name           text,
  file_storage_path   text,
  uploaded_by         uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  uploaded_at         timestamptz NOT NULL DEFAULT now(),
  period_grain        text,
  period_start        date,
  period_end          date,
  row_count           integer NOT NULL DEFAULT 0,
  accepted_count      integer NOT NULL DEFAULT 0,
  rejected_count      integer NOT NULL DEFAULT 0,
  status              text NOT NULL DEFAULT 'pending',
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT kpi_upload_batches_period_grain_check CHECK (
    period_grain IS NULL
    OR period_grain IN ('monthly', 'quarterly', 'rolling_6m', 'rolling_12m', 'snapshot')
  ),
  CONSTRAINT kpi_upload_batches_status_check CHECK (
    status IN ('pending', 'processing', 'accepted', 'rejected', 'partially_accepted')
  ),
  CONSTRAINT kpi_upload_batches_counts_check CHECK (
    row_count >= 0 AND accepted_count >= 0 AND rejected_count >= 0
    AND accepted_count + rejected_count <= row_count
  )
);

ALTER TABLE public.kpi_upload_batches OWNER TO postgres;

CREATE TRIGGER trg_kpi_upload_batches_updated_at
  BEFORE UPDATE ON public.kpi_upload_batches
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX ix_kpi_upload_batches_status_uploaded_at
  ON public.kpi_upload_batches (status, uploaded_at DESC);
CREATE INDEX ix_kpi_upload_batches_location_uploaded_at
  ON public.kpi_upload_batches (location_id, uploaded_at DESC)
  WHERE location_id IS NOT NULL;


-- ---------------------------------------------------------------------
-- 6. kpi_upload_rows
--    One row per parsed line in an upload. Carries its own
--    kpi_definition_id and (where relevant) staff_member_id, but
--    does NOT carry a location_id — location is owned by the parent
--    kpi_upload_batches row (one file = one location). For
--    'location'-scoped rows the location is read from the batch; for
--    'staff'-scoped rows the staff member is here and the location
--    is still inherited from the batch via the join.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.kpi_upload_rows (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  upload_batch_id     uuid NOT NULL REFERENCES public.kpi_upload_batches(id) ON DELETE CASCADE,
  kpi_definition_id   uuid NOT NULL REFERENCES public.kpi_definitions(id) ON DELETE RESTRICT,
  period_grain        text NOT NULL,
  period_start        date NOT NULL,
  period_end          date NOT NULL,
  scope_type          text NOT NULL,
  staff_member_id     uuid REFERENCES public.staff_members(id) ON DELETE RESTRICT,
  value               numeric(18, 4),
  -- Original parsed row payload for debug / replay. Capped at JSON
  -- (no schema enforcement) so the loader can store whatever
  -- combination of source columns it received. For utilisation /
  -- future_utilisation uploads this carries: name, working_hours,
  -- billable_appointments, admin_stuff, paid_leave, unpaid_leave,
  -- percent_billable, percent_utilisation. The non-captured columns
  -- (PAID CUSTOM, APPTS ON CUST TIME, UNPAID CUSTOM) are dropped at
  -- parse time and never persisted.
  raw_row             jsonb,
  row_status          text NOT NULL DEFAULT 'pending',
  error_message       text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT kpi_upload_rows_period_grain_check CHECK (
    period_grain IN ('monthly', 'quarterly', 'rolling_6m', 'rolling_12m', 'snapshot')
  ),
  CONSTRAINT kpi_upload_rows_period_order_check CHECK (period_end >= period_start),
  CONSTRAINT kpi_upload_rows_scope_type_check CHECK (
    scope_type IN ('business', 'location', 'staff')
  ),
  -- Scope consistency for upload rows: location is always inherited
  -- from the parent batch, so only staff_member_id is asserted here.
  -- 'business' / 'location' rows must not carry a staff_member_id;
  -- 'staff' rows must.
  CONSTRAINT kpi_upload_rows_scope_consistency CHECK (
    (scope_type IN ('business', 'location') AND staff_member_id IS NULL) OR
    (scope_type = 'staff' AND staff_member_id IS NOT NULL)
  ),
  CONSTRAINT kpi_upload_rows_row_status_check CHECK (
    row_status IN ('pending', 'accepted', 'rejected')
  ),
  CONSTRAINT kpi_upload_rows_value_required_when_accepted CHECK (
    row_status <> 'accepted' OR value IS NOT NULL
  )
);

ALTER TABLE public.kpi_upload_rows OWNER TO postgres;

CREATE TRIGGER trg_kpi_upload_rows_updated_at
  BEFORE UPDATE ON public.kpi_upload_rows
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX ix_kpi_upload_rows_batch ON public.kpi_upload_rows (upload_batch_id);
CREATE INDEX ix_kpi_upload_rows_kpi_period
  ON public.kpi_upload_rows (kpi_definition_id, period_start);


-- ---------------------------------------------------------------------
-- 7. staff_capacity_monthly
--    Per-staff capacity (in minutes) per calendar month. Reserved for
--    capacity / utilisation use cases (e.g. utilisation /
--    future_utilisation denominators if/when those KPIs move from
--    `uploaded` to a natively calculated source). One row per
--    (staff_member_id, period_start).
--
--    NOT used by stylist_profitability — that KPI's FTE denominator
--    is sourced from staff_members.fte. Do not introduce a coupling
--    from stylist_profitability to this table.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.staff_capacity_monthly (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_member_id     uuid NOT NULL REFERENCES public.staff_members(id) ON DELETE RESTRICT,
  period_start        date NOT NULL,
  period_end          date NOT NULL,
  capacity_minutes    integer NOT NULL,
  working_days        integer,
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT staff_capacity_monthly_period_order_check
    CHECK (period_end >= period_start),
  CONSTRAINT staff_capacity_monthly_minutes_nonneg
    CHECK (capacity_minutes >= 0),
  CONSTRAINT staff_capacity_monthly_working_days_nonneg
    CHECK (working_days IS NULL OR working_days >= 0)
);

ALTER TABLE public.staff_capacity_monthly OWNER TO postgres;

CREATE TRIGGER trg_staff_capacity_monthly_updated_at
  BEFORE UPDATE ON public.staff_capacity_monthly
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE UNIQUE INDEX ux_staff_capacity_monthly_staff_period
  ON public.staff_capacity_monthly (staff_member_id, period_start);


-- ---------------------------------------------------------------------
-- Optional FK back-references on kpi_monthly_values.
-- Added after the upload + manual tables exist so the FK targets are
-- guaranteed valid. ON DELETE SET NULL so deleting a batch / input
-- record does not cascade-drop the canonical fact (the fact's value
-- stays correct, just the link to its provenance is dropped).
-- ---------------------------------------------------------------------
ALTER TABLE public.kpi_monthly_values
  ADD CONSTRAINT kpi_monthly_values_upload_batch_fkey
    FOREIGN KEY (upload_batch_id)
    REFERENCES public.kpi_upload_batches(id)
    ON DELETE SET NULL;

ALTER TABLE public.kpi_monthly_values
  ADD CONSTRAINT kpi_monthly_values_manual_input_fkey
    FOREIGN KEY (manual_input_id)
    REFERENCES public.kpi_manual_inputs(id)
    ON DELETE SET NULL;


-- =====================================================================
-- RLS: enable on all 7 tables; SELECT for elevated only; no writes
-- granted to authenticated. Mutations must go through SECURITY
-- DEFINER RPCs in a follow-up migration. This deliberately mirrors
-- the existing product_master_elevated_rls / saved_quote_rls patterns.
-- =====================================================================

ALTER TABLE public.kpi_definitions          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kpi_monthly_values       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kpi_targets              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kpi_manual_inputs        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kpi_upload_batches       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kpi_upload_rows          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff_capacity_monthly   ENABLE ROW LEVEL SECURITY;

-- SELECT-only grants to authenticated (no INSERT/UPDATE/DELETE).
GRANT SELECT ON public.kpi_definitions          TO authenticated;
GRANT SELECT ON public.kpi_monthly_values       TO authenticated;
GRANT SELECT ON public.kpi_targets              TO authenticated;
GRANT SELECT ON public.kpi_manual_inputs        TO authenticated;
GRANT SELECT ON public.kpi_upload_batches       TO authenticated;
GRANT SELECT ON public.kpi_upload_rows          TO authenticated;
GRANT SELECT ON public.staff_capacity_monthly   TO authenticated;

DO $do$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'kpi_definitions',
    'kpi_monthly_values',
    'kpi_targets',
    'kpi_manual_inputs',
    'kpi_upload_batches',
    'kpi_upload_rows',
    'staff_capacity_monthly'
  ] LOOP
    EXECUTE format(
      'DROP POLICY IF EXISTS "%1$s_elevated_select" ON public.%1$s;',
      t
    );
    EXECUTE format(
      'CREATE POLICY "%1$s_elevated_select"
         ON public.%1$s
         FOR SELECT
         TO authenticated
         USING ((SELECT private.user_has_elevated_access()));',
      t
    );
  END LOOP;
END
$do$;


-- =====================================================================
-- Seed kpi_definitions.
--
-- Notes on the 5 live-validation candidates
-- -----------------------------------------
-- revenue, guests_per_month, new_clients_per_month,
-- average_client_spend and retail_percent are all set to
-- source_type='hybrid' so the current open month is computed live by
-- their live_rpc_name, and closed months are read from
-- kpi_monthly_values (written by their finalisation_rpc_name once a
-- month is closed). They are also flagged supports_mtd_pacing=true
-- with linear_calendar_days proration EXCEPT retail_percent, which
-- is a ratio and does not prorate sensibly — the percentage is
-- naturally MTD on its own.
--
-- Open question for product: average_client_spend is a per-guest
-- ratio; we have left supports_mtd_pacing=false because pacing a
-- ratio against a target is rarely meaningful (the metric is
-- self-normalising). Flip to true if a product use case emerges.
--
-- Retention / frequency KPIs are calculated_monthly, not hybrid:
-- their cohort definitions are too expensive (and date-sensitive) to
-- recompute live every page load, and they are not meaningful as
-- MTD figures.
-- =====================================================================

INSERT INTO public.kpi_definitions (
  code, display_name, description, goal_group, value_type, unit,
  direction, period_grain, source_type, supports_mtd_pacing,
  mtd_proration_method, live_rpc_name, finalisation_rpc_name,
  default_level_type, visibility_tier, sort_order
) VALUES
  -- 1. revenue ---------------------------------------------------------
  ('revenue',
   'Revenue',
   'Total sales (ex GST) for the period.',
   'financial', 'currency', 'NZD',
   'higher_is_better', 'monthly', 'hybrid', true,
   'linear_calendar_days',
   'public.get_kpi_revenue_live',
   'public.finalise_kpi_revenue_monthly',
   'location', 'stylist', 10),

  -- 2. guests_per_month -----------------------------------------------
  ('guests_per_month',
   'Guests per month',
   'Distinct guests served in the period.',
   'operational', 'count', 'guests',
   'higher_is_better', 'monthly', 'hybrid', true,
   'linear_calendar_days',
   'public.get_kpi_guests_per_month_live',
   'public.finalise_kpi_guests_per_month_monthly',
   'location', 'stylist', 20),

  -- 3. new_clients_per_month ------------------------------------------
  ('new_clients_per_month',
   'New clients per month',
   'Guests with no prior visit before this period.',
   'client', 'count', 'clients',
   'higher_is_better', 'monthly', 'hybrid', true,
   'linear_calendar_days',
   'public.get_kpi_new_clients_per_month_live',
   'public.finalise_kpi_new_clients_per_month_monthly',
   'location', 'stylist', 30),

  -- 4. utilisation -----------------------------------------------------
  -- Sourced from the externally produced "Staff Utilisation" report
  -- (uploaded per period). No native calculation is attempted — the
  -- uploaded number is treated as the authoritative monthly value.
  ('utilisation',
   'Utilisation',
   'Productive vs. available time per stylist for the period. Sourced from uploaded Staff Utilisation report.',
   'staff', 'percent', '%',
   'higher_is_better', 'monthly', 'uploaded', false,
   NULL, NULL, NULL,
   'staff', 'stylist', 40),

  -- 5. future_utilisation ---------------------------------------------
  -- Same source as utilisation (Staff Utilisation report), reporting
  -- forward-booked time for the upcoming week. Uploaded each Friday
  -- as a point-in-time view of the next week, so period_grain is
  -- `snapshot` (NOT `monthly`): each upload supersedes the previous
  -- snapshot rather than aggregating into a calendar month.
  ('future_utilisation',
   'Future utilisation',
   'Forward-booked vs. available time per stylist for the upcoming week. Uploaded each Friday from the Staff Utilisation report as a point-in-time snapshot.',
   'staff', 'percent', '%',
   'higher_is_better', 'snapshot', 'uploaded', false,
   NULL, NULL, NULL,
   'staff', 'stylist', 50),

  -- 6. average_client_spend -------------------------------------------
  ('average_client_spend',
   'Average client spend',
   'Revenue ÷ distinct guests for the period.',
   'financial', 'currency', 'NZD',
   'higher_is_better', 'monthly', 'hybrid', false,
   NULL,
   'public.get_kpi_average_client_spend_live',
   'public.finalise_kpi_average_client_spend_monthly',
   'location', 'stylist', 60),

  -- 7. retail_percent --------------------------------------------------
  -- Intentional decision: retail_percent is INTENTIONALLY NOT in the
  -- currently locked stylist-visible KPI list (per
  -- docs/KPI App Architecture.md §3.2). It is kept seeded at the
  -- `manager` tier so it is visible to managers and admins as a
  -- location-level operational KPI, and so it can participate in the
  -- live-KPI validation phase (§9 of the locked decisions explicitly
  -- includes it). If/when the product decision changes to expose it
  -- to stylists, flip visibility_tier to 'stylist' here — no other
  -- code change is required.
  ('retail_percent',
   'Retail %',
   'Retail sales ÷ total sales for the period. Manager/admin scope only in v1.',
   'financial', 'percent', '%',
   'higher_is_better', 'monthly', 'hybrid', false,
   NULL,
   'public.get_kpi_retail_percent_live',
   'public.finalise_kpi_retail_percent_monthly',
   'location', 'manager', 70),

  -- 8. client_frequency -----------------------------------------------
  ('client_frequency',
   'Client frequency',
   'Average visits per active guest (rolling window). Snapshotted monthly.',
   'retention', 'ratio', 'visits/guest',
   'higher_is_better', 'rolling_12m', 'calculated_monthly', false,
   NULL, NULL,
   'public.finalise_kpi_client_frequency_monthly',
   'location', 'stylist', 80),

  -- 9. client_retention_6m --------------------------------------------
  ('client_retention_6m',
   'Client retention (6m)',
   'Share of guests from prior 6m window that returned in this period.',
   'retention', 'percent', '%',
   'higher_is_better', 'rolling_6m', 'calculated_monthly', false,
   NULL, NULL,
   'public.finalise_kpi_client_retention_6m_monthly',
   'location', 'stylist', 90),

  -- 10. client_retention_12m -------------------------------------------
  ('client_retention_12m',
   'Client retention (12m)',
   'Share of guests from prior 12m window that returned in this period.',
   'retention', 'percent', '%',
   'higher_is_better', 'rolling_12m', 'calculated_monthly', false,
   NULL, NULL,
   'public.finalise_kpi_client_retention_12m_monthly',
   'location', 'stylist', 100),

  -- 11. new_client_retention_6m ----------------------------------------
  ('new_client_retention_6m',
   'New client retention (6m)',
   'Share of new clients from prior 6m that returned in this period.',
   'retention', 'percent', '%',
   'higher_is_better', 'rolling_6m', 'calculated_monthly', false,
   NULL, NULL,
   'public.finalise_kpi_new_client_retention_6m_monthly',
   'location', 'stylist', 110),

  -- 12. new_client_retention_12m ---------------------------------------
  ('new_client_retention_12m',
   'New client retention (12m)',
   'Share of new clients from prior 12m that returned in this period.',
   'retention', 'percent', '%',
   'higher_is_better', 'rolling_12m', 'calculated_monthly', false,
   NULL, NULL,
   'public.finalise_kpi_new_client_retention_12m_monthly',
   'location', 'stylist', 120),

  -- 13. stylist_profitability ------------------------------------------
  -- Definition (per the KPI brief): total sales for each stylist
  -- divided by their FTE for the period. Reported per stylist and
  -- rolled up to location/business. Currency-per-FTE, NOT a percent
  -- and NOT a cost-margin formula.
  --
  -- DEFAULT FTE SOURCE: public.staff_members.fte (numeric(5,4),
  -- already present in the schema as of 20260430290000_staff_
  -- configuration_access.sql). The live and finalisation RPCs read
  -- FTE from staff_members.fte directly — no manual entry, no
  -- staging table, and staff_capacity_monthly is intentionally NOT
  -- used as the FTE source. staff_capacity_monthly remains reserved
  -- for capacity-minutes / utilisation calculations.
  --
  -- If a future requirement needs month-varying FTE (e.g. someone
  -- changes from 0.8 to 1.0 mid-quarter and we want the historical
  -- months to keep their old FTE), introduce an additive monthly
  -- override table at that point — but only if a real gap in
  -- staff_members.fte is demonstrated. Until then, the single
  -- staff_members.fte column is the source of truth.
  --
  -- Source classification is `hybrid` because the sales numerator is
  -- naturally live from existing sales tables and the FTE
  -- denominator is an immediately-available system column.
  ('stylist_profitability',
   'Stylist profitability',
   'Total sales per stylist ÷ that stylist''s FTE for the period (NZD per FTE). FTE sourced from staff_members.fte. Rolled up to location and business.',
   'staff', 'currency', 'NZD per FTE',
   'higher_is_better', 'monthly', 'hybrid', false,
   NULL,
   'public.get_kpi_stylist_profitability_live',
   'public.finalise_kpi_stylist_profitability_monthly',
   'staff', 'stylist', 130),

  -- 14. assistant_utilisation_ratio ------------------------------------
  -- Locked KPI name (replaces the earlier apprentice_ratio /
  -- use_of_assistants_ratio sketches).
  --
  -- Definition:
  --   assistant_utilisation_ratio
  --     = sum(sales ex GST where assistant_redirect_candidate = true)
  --     / sum(sales ex GST where row is eligible)
  --
  -- "Eligible" mirrors the existing commission pipeline's eligibility
  -- (excludes internal, excludes the same exclusions already applied
  -- when computing per-stylist sales).
  --
  -- Source: REUSE the existing assistant_redirect_candidate flag
  -- already derived in public.v_sales_transactions_enriched and
  -- consumed by public.v_commission_calculations_core. The current
  -- rule there is effectively:
  --   * staff_work_id IS NOT NULL
  --   * staff_paid_id IS NOT NULL
  --   * staff_work_id <> staff_paid_id
  --   * staff_work_primary_role = 'assistant'
  --   * staff_work_remuneration_plan = 'wage'
  -- This KPI does NOT introduce a parallel apprentice-classification
  -- model. If the assistant-redirect rule is changed, this KPI moves
  -- with it automatically.
  --
  -- Per stylist (the staff_paid identity), then rolled up to location
  -- and business. Hybrid: live for the open month from the existing
  -- enriched/commission views; finalised into kpi_monthly_values at
  -- month close so historical months are immutable against future
  -- assistant-rule changes.
  ('assistant_utilisation_ratio',
   'Assistant utilisation ratio',
   'Assistant-helped sales (ex GST) ÷ total eligible sales (ex GST), per stylist (paid identity), rolled up to location and business. Source: existing assistant_redirect_candidate flag in v_sales_transactions_enriched.',
   'staff', 'percent', '%',
   'higher_is_better', 'monthly', 'hybrid', false,
   NULL,
   'public.get_kpi_assistant_utilisation_ratio_live',
   'public.finalise_kpi_assistant_utilisation_ratio_monthly',
   'staff', 'stylist', 140),

  -- 15. ebitda ---------------------------------------------------------
  -- Manual: typed in by an admin once the books are closed.
  ('ebitda',
   'EBITDA',
   'Earnings before interest, tax, depreciation and amortisation. Entered by admin.',
   'financial', 'currency', 'NZD',
   'higher_is_better', 'monthly', 'manual', false,
   NULL, NULL, NULL,
   'location', 'admin', 150),

  -- 16. operational_costs ----------------------------------------------
  ('operational_costs',
   'Operational costs',
   'Total operational costs for the period. Entered by admin or uploaded.',
   'financial', 'currency', 'NZD',
   'lower_is_better', 'monthly', 'manual', false,
   NULL, NULL, NULL,
   'location', 'admin', 160),

  -- 17. cogs_percent ---------------------------------------------------
  ('cogs_percent',
   'COGS %',
   'Cost of goods sold ÷ revenue. Entered by admin or uploaded.',
   'financial', 'percent', '%',
   'lower_is_better', 'monthly', 'manual', false,
   NULL, NULL, NULL,
   'location', 'admin', 170),

  -- 18. stock_value_target ---------------------------------------------
  ('stock_value_target',
   'Stock value (target)',
   'Target month-end stock on hand (NZD).',
   'stock', 'currency', 'NZD',
   'higher_is_better', 'monthly', 'manual', false,
   NULL, NULL, NULL,
   'location', 'admin', 180),

  -- 19. stock_value_actual ---------------------------------------------
  ('stock_value_actual',
   'Stock value (actual)',
   'Actual month-end stock on hand (NZD). Uploaded from stock take.',
   'stock', 'currency', 'NZD',
   'higher_is_better', 'snapshot', 'uploaded', false,
   NULL, NULL, NULL,
   'location', 'admin', 190),

  -- 20. support_staff_cost_percent -------------------------------------
  -- No reliable wages source exists in the current schema (no
  -- payroll/wages table or view that captures support-staff cost).
  -- Until a wages feed lands, this KPI is admin-entered. Re-classify
  -- to `calculated_monthly` (or `hybrid`) once a wages source exists.
  ('support_staff_cost_percent',
   'Support staff cost %',
   'Support staff wage cost ÷ revenue. Entered by admin until a wages source is available.',
   'staff', 'percent', '%',
   'lower_is_better', 'monthly', 'manual', false,
   NULL, NULL, NULL,
   'location', 'admin', 200)
ON CONFLICT (code) DO NOTHING;
