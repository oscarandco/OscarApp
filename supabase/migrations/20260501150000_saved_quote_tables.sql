-- Saved Quote tables (MVP).
-- Snapshot-first: every stylist-visible label/price/config used at save time
-- is copied into these tables so a saved quote can be reprinted byte-for-byte
-- even if admins later edit or archive any config.
--
-- No RLS, no RPCs, no delete-protection triggers, and no views in this
-- migration. Grants are service_role only for now.


-- 1. Header row per saved quote.
CREATE TABLE IF NOT EXISTS public.saved_quotes (
  id                        uuid           NOT NULL DEFAULT gen_random_uuid(),
  guest_name                text,
  stylist_user_id           uuid           NOT NULL,
  stylist_staff_member_id   uuid,
  stylist_display_name      text           NOT NULL,
  quote_date                date           NOT NULL DEFAULT current_date,
  notes                     text,
  grand_total               numeric(12, 2) NOT NULL,
  green_fee_applied         numeric(10, 2) NOT NULL,
  settings_snapshot         jsonb          NOT NULL DEFAULT '{}'::jsonb,
  created_at                timestamptz    NOT NULL DEFAULT now(),
  updated_at                timestamptz    NOT NULL DEFAULT now(),

  CONSTRAINT saved_quotes_pkey PRIMARY KEY (id),

  CONSTRAINT saved_quotes_stylist_user_fk
    FOREIGN KEY (stylist_user_id) REFERENCES auth.users(id)
    ON DELETE RESTRICT,

  CONSTRAINT saved_quotes_stylist_staff_member_fk
    FOREIGN KEY (stylist_staff_member_id) REFERENCES public.staff_members(id)
    ON DELETE SET NULL,

  CONSTRAINT saved_quotes_stylist_display_name_not_blank
    CHECK (length(btrim(stylist_display_name)) > 0),

  CONSTRAINT saved_quotes_grand_total_non_negative
    CHECK (grand_total >= 0),

  CONSTRAINT saved_quotes_green_fee_non_negative
    CHECK (green_fee_applied >= 0)
);

COMMENT ON TABLE public.saved_quotes IS
  'Header row per saved guest quote. Snapshot-first: settings_snapshot and stylist_display_name preserve state at save time.';

COMMENT ON COLUMN public.saved_quotes.settings_snapshot IS
  'Full QuoteSettings at save time (green fee, page title, toggles). Shape validated by app layer.';

CREATE INDEX IF NOT EXISTS idx_saved_quotes_stylist_user_created
  ON public.saved_quotes (stylist_user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_saved_quotes_quote_date
  ON public.saved_quotes (quote_date DESC);

GRANT ALL ON TABLE public.saved_quotes TO service_role;


-- 2. One row per selected service line in a saved quote.
-- FKs onto config tables are RESTRICT so config rows referenced by a saved
-- quote cannot be hard-deleted; enforcement is at the FK layer plus (later)
-- a named-error BEFORE DELETE trigger.
CREATE TABLE IF NOT EXISTS public.saved_quote_lines (
  id                              uuid           NOT NULL DEFAULT gen_random_uuid(),
  saved_quote_id                  uuid           NOT NULL,
  line_order                      integer        NOT NULL,

  service_id                      uuid,
  section_id                      uuid,

  section_name_snapshot           text           NOT NULL,
  section_summary_label_snapshot  text           NOT NULL,
  service_name_snapshot           text           NOT NULL,
  service_internal_key_snapshot   text,

  input_type_snapshot             text           NOT NULL,
  pricing_type_snapshot           text           NOT NULL,

  selected_role                   text,
  numeric_quantity                numeric(12, 2),
  numeric_unit_label_snapshot     text,
  extra_units_selected            integer,
  special_extra_rows_snapshot     jsonb,
  unit_price_snapshot             numeric(10, 2),
  line_total                      numeric(12, 2) NOT NULL,

  include_in_summary_snapshot     boolean        NOT NULL DEFAULT true,
  summary_group_snapshot          text           NOT NULL,
  config_snapshot                 jsonb          NOT NULL DEFAULT '{}'::jsonb,

  created_at                      timestamptz    NOT NULL DEFAULT now(),

  CONSTRAINT saved_quote_lines_pkey PRIMARY KEY (id),

  CONSTRAINT saved_quote_lines_saved_quote_fk
    FOREIGN KEY (saved_quote_id) REFERENCES public.saved_quotes(id)
    ON DELETE CASCADE,

  CONSTRAINT saved_quote_lines_service_fk
    FOREIGN KEY (service_id) REFERENCES public.quote_services(id)
    ON DELETE RESTRICT,

  CONSTRAINT saved_quote_lines_section_fk
    FOREIGN KEY (section_id) REFERENCES public.quote_sections(id)
    ON DELETE RESTRICT,

  CONSTRAINT saved_quote_lines_line_order_min
    CHECK (line_order >= 1),

  CONSTRAINT saved_quote_lines_section_name_not_blank
    CHECK (length(btrim(section_name_snapshot)) > 0),

  CONSTRAINT saved_quote_lines_section_summary_label_not_blank
    CHECK (length(btrim(section_summary_label_snapshot)) > 0),

  CONSTRAINT saved_quote_lines_service_name_not_blank
    CHECK (length(btrim(service_name_snapshot)) > 0),

  CONSTRAINT saved_quote_lines_summary_group_not_blank
    CHECK (length(btrim(summary_group_snapshot)) > 0),

  CONSTRAINT saved_quote_lines_input_type_allowed
    CHECK (input_type_snapshot IN (
      'checkbox',
      'role_radio',
      'option_radio',
      'dropdown',
      'numeric_input',
      'extra_units',
      'special_extra_product'
    )),

  CONSTRAINT saved_quote_lines_pricing_type_allowed
    CHECK (pricing_type_snapshot IN (
      'fixed_price',
      'role_price',
      'option_price',
      'numeric_multiplier',
      'extra_unit_price',
      'special_extra_product'
    )),

  CONSTRAINT saved_quote_lines_selected_role_allowed
    CHECK (selected_role IS NULL
           OR selected_role IN ('EMERGING', 'SENIOR', 'DIRECTOR', 'MASTER')),

  CONSTRAINT saved_quote_lines_extra_units_non_negative
    CHECK (extra_units_selected IS NULL OR extra_units_selected >= 0),

  CONSTRAINT saved_quote_lines_unit_price_non_negative
    CHECK (unit_price_snapshot IS NULL OR unit_price_snapshot >= 0),

  CONSTRAINT saved_quote_lines_line_total_non_negative
    CHECK (line_total >= 0),

  CONSTRAINT saved_quote_lines_saved_quote_line_order_unique
    UNIQUE (saved_quote_id, line_order)
);

COMMENT ON TABLE public.saved_quote_lines IS
  'One row per selected service in a saved quote. Snapshot columns capture service/section state at save time; FKs are traceability only.';

COMMENT ON COLUMN public.saved_quote_lines.config_snapshot IS
  'Full relevant pricing config blob at save time (role prices, numeric/extra_unit/special_extra configs, sibling options). Shape validated by app layer.';

CREATE INDEX IF NOT EXISTS idx_saved_quote_lines_saved_quote_line_order
  ON public.saved_quote_lines (saved_quote_id, line_order);

CREATE INDEX IF NOT EXISTS idx_saved_quote_lines_service
  ON public.saved_quote_lines (service_id)
  WHERE service_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_saved_quote_lines_section
  ON public.saved_quote_lines (section_id)
  WHERE section_id IS NOT NULL;

GRANT ALL ON TABLE public.saved_quote_lines TO service_role;


-- 3. Selected options per saved line. Most lines have 0 or 1 rows.
CREATE TABLE IF NOT EXISTS public.saved_quote_line_options (
  id                        uuid           NOT NULL DEFAULT gen_random_uuid(),
  saved_quote_line_id       uuid           NOT NULL,
  service_option_id         uuid,
  option_label_snapshot     text           NOT NULL,
  option_value_key_snapshot text           NOT NULL,
  option_price_snapshot     numeric(10, 2),

  CONSTRAINT saved_quote_line_options_pkey PRIMARY KEY (id),

  CONSTRAINT saved_quote_line_options_line_fk
    FOREIGN KEY (saved_quote_line_id) REFERENCES public.saved_quote_lines(id)
    ON DELETE CASCADE,

  CONSTRAINT saved_quote_line_options_option_fk
    FOREIGN KEY (service_option_id) REFERENCES public.quote_service_options(id)
    ON DELETE RESTRICT,

  CONSTRAINT saved_quote_line_options_label_not_blank
    CHECK (length(btrim(option_label_snapshot)) > 0),

  CONSTRAINT saved_quote_line_options_value_key_not_blank
    CHECK (length(btrim(option_value_key_snapshot)) > 0),

  CONSTRAINT saved_quote_line_options_price_non_negative
    CHECK (option_price_snapshot IS NULL OR option_price_snapshot >= 0)
);

COMMENT ON TABLE public.saved_quote_line_options IS
  'Selected option rows per saved quote line. Label/value/price are snapshot columns; service_option_id is traceability only.';

CREATE INDEX IF NOT EXISTS idx_saved_quote_line_options_line
  ON public.saved_quote_line_options (saved_quote_line_id);

CREATE INDEX IF NOT EXISTS idx_saved_quote_line_options_option
  ON public.saved_quote_line_options (service_option_id)
  WHERE service_option_id IS NOT NULL;

GRANT ALL ON TABLE public.saved_quote_line_options TO service_role;


-- 4. Explicit per-section totals at save time, in display order. Stored
-- separately (rather than recomputed from lines) so the summary footer on a
-- saved quote is stable even if section grouping rules change later.
CREATE TABLE IF NOT EXISTS public.saved_quote_section_totals (
  id                              uuid           NOT NULL DEFAULT gen_random_uuid(),
  saved_quote_id                  uuid           NOT NULL,
  display_order                   integer        NOT NULL,
  section_summary_label_snapshot  text           NOT NULL,
  section_name_snapshot           text,
  section_total                   numeric(12, 2) NOT NULL,
  created_at                      timestamptz    NOT NULL DEFAULT now(),

  CONSTRAINT saved_quote_section_totals_pkey PRIMARY KEY (id),

  CONSTRAINT saved_quote_section_totals_saved_quote_fk
    FOREIGN KEY (saved_quote_id) REFERENCES public.saved_quotes(id)
    ON DELETE CASCADE,

  CONSTRAINT saved_quote_section_totals_display_order_min
    CHECK (display_order >= 1),

  CONSTRAINT saved_quote_section_totals_summary_label_not_blank
    CHECK (length(btrim(section_summary_label_snapshot)) > 0),

  CONSTRAINT saved_quote_section_totals_total_non_negative
    CHECK (section_total >= 0),

  CONSTRAINT saved_quote_section_totals_saved_quote_display_order_unique
    UNIQUE (saved_quote_id, display_order)
);

COMMENT ON TABLE public.saved_quote_section_totals IS
  'Snapshot section totals per saved quote, in the display order shown on the saved quote summary footer.';

CREATE INDEX IF NOT EXISTS idx_saved_quote_section_totals_saved_quote_order
  ON public.saved_quote_section_totals (saved_quote_id, display_order);

GRANT ALL ON TABLE public.saved_quote_section_totals TO service_role;


-- updated_at trigger. Only saved_quotes is mutable post-save (headers might
-- get a notes/cancel edit later); lines, line options, and section totals
-- are write-once so they do not get updated_at columns or triggers.
DROP TRIGGER IF EXISTS trg_saved_quotes_updated_at ON public.saved_quotes;
CREATE TRIGGER trg_saved_quotes_updated_at
  BEFORE UPDATE ON public.saved_quotes
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();
