-- Quote Configuration core tables: settings, sections, services, options, role prices.
-- No views, no RLS, no RPCs, no cross-table triggers in this migration.

-- 1. Singleton global settings. Enforced to a single row via id = 1.
CREATE TABLE IF NOT EXISTS public.quote_settings (
  id                   smallint       NOT NULL DEFAULT 1,
  green_fee_amount     numeric(10, 2) NOT NULL DEFAULT 0,
  notes_enabled        boolean        NOT NULL DEFAULT true,
  guest_name_required  boolean        NOT NULL DEFAULT false,
  quote_page_title     text           NOT NULL DEFAULT 'Guest Quote',
  active               boolean        NOT NULL DEFAULT true,
  updated_at           timestamptz    NOT NULL DEFAULT now(),

  CONSTRAINT quote_settings_pkey PRIMARY KEY (id),
  CONSTRAINT quote_settings_singleton CHECK (id = 1),
  CONSTRAINT quote_settings_green_fee_non_negative CHECK (green_fee_amount >= 0),
  CONSTRAINT quote_settings_page_title_not_blank
    CHECK (length(btrim(quote_page_title)) > 0)
);

COMMENT ON TABLE public.quote_settings IS
  'Global Guest Quote settings. Single row (id = 1) enforced by CHECK.';

GRANT ALL ON TABLE public.quote_settings TO service_role;


-- 2. Quote sections. Summary labels are intentionally allowed to repeat so that
-- e.g. "Toner - All Over" and "Toner - Dimension" can both roll up as "Toner".
CREATE TABLE IF NOT EXISTS public.quote_sections (
  id                 uuid        NOT NULL DEFAULT gen_random_uuid(),
  name               text        NOT NULL,
  summary_label      text        NOT NULL,
  display_order      integer     NOT NULL,
  active             boolean     NOT NULL DEFAULT true,
  section_help_text  text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT quote_sections_pkey PRIMARY KEY (id),
  CONSTRAINT quote_sections_name_not_blank
    CHECK (length(btrim(name)) > 0),
  CONSTRAINT quote_sections_summary_label_not_blank
    CHECK (length(btrim(summary_label)) > 0),
  CONSTRAINT quote_sections_display_order_min
    CHECK (display_order >= 1),
  -- Deferrable so the reorder RPC can swap two rows inside a single transaction.
  CONSTRAINT quote_sections_display_order_unique
    UNIQUE (display_order) DEFERRABLE INITIALLY IMMEDIATE
);

COMMENT ON TABLE public.quote_sections IS
  'Ordered list of Guest Quote sections. Archive via active = false.';

COMMENT ON COLUMN public.quote_sections.summary_label IS
  'Label used when grouping sections on the saved quote summary footer. Duplicates are intentional.';

CREATE INDEX IF NOT EXISTS idx_quote_sections_active_display_order
  ON public.quote_sections (active, display_order);

GRANT ALL ON TABLE public.quote_sections TO service_role;


-- 3. Quote services. One row per service inside a section. The three JSONB
-- sidecar columns each apply to exactly one pricing_type; the table-level
-- CHECK enforces that the correct field is populated and the others are null.
CREATE TABLE IF NOT EXISTS public.quote_services (
  id                        uuid           NOT NULL DEFAULT gen_random_uuid(),
  section_id                uuid           NOT NULL,
  name                      text           NOT NULL,
  internal_key              text,
  active                    boolean        NOT NULL DEFAULT true,
  display_order             integer        NOT NULL,
  help_text                 text,
  summary_label_override    text,

  input_type                text           NOT NULL,
  pricing_type              text           NOT NULL,

  visible_roles             text[]         NOT NULL DEFAULT ARRAY[]::text[],

  fixed_price               numeric(10, 2),
  numeric_config            jsonb,
  extra_unit_config         jsonb,
  special_extra_config      jsonb,

  link_to_base_service_id   uuid,

  include_in_quote_summary  boolean        NOT NULL DEFAULT true,
  summary_group_override    text,
  admin_notes               text,

  created_at                timestamptz    NOT NULL DEFAULT now(),
  updated_at                timestamptz    NOT NULL DEFAULT now(),

  CONSTRAINT quote_services_pkey PRIMARY KEY (id),

  CONSTRAINT quote_services_section_fk
    FOREIGN KEY (section_id) REFERENCES public.quote_sections(id)
    ON DELETE RESTRICT,

  -- Self-FK: extras can link to the base service they depend on (e.g. extra
  -- foils → foils amount). If the base service disappears, clear the link.
  CONSTRAINT quote_services_link_to_base_fk
    FOREIGN KEY (link_to_base_service_id) REFERENCES public.quote_services(id)
    ON DELETE SET NULL,

  CONSTRAINT quote_services_name_not_blank
    CHECK (length(btrim(name)) > 0),

  CONSTRAINT quote_services_internal_key_format
    CHECK (internal_key IS NULL OR internal_key ~ '^[a-z0-9_]+$'),

  CONSTRAINT quote_services_display_order_min
    CHECK (display_order >= 1),

  CONSTRAINT quote_services_fixed_price_non_negative
    CHECK (fixed_price IS NULL OR fixed_price >= 0),

  CONSTRAINT quote_services_link_to_base_not_self
    CHECK (link_to_base_service_id IS NULL OR link_to_base_service_id <> id),

  CONSTRAINT quote_services_input_type_allowed
    CHECK (input_type IN (
      'checkbox',
      'role_radio',
      'option_radio',
      'dropdown',
      'numeric_input',
      'extra_units',
      'special_extra_product'
    )),

  CONSTRAINT quote_services_pricing_type_allowed
    CHECK (pricing_type IN (
      'fixed_price',
      'role_price',
      'option_price',
      'numeric_multiplier',
      'extra_unit_price',
      'special_extra_product'
    )),

  CONSTRAINT quote_services_visible_roles_allowed
    CHECK (visible_roles <@ ARRAY['EMERGING','SENIOR','DIRECTOR','MASTER']::text[]),

  -- Deferrable so transactional reorder within a section can swap rows.
  CONSTRAINT quote_services_section_order_unique
    UNIQUE (section_id, display_order) DEFERRABLE INITIALLY IMMEDIATE,

  -- Ensures the right sidecar config is populated for each pricing_type and
  -- no stale sidecars are left over when the pricing_type is changed.
  CONSTRAINT quote_services_pricing_config_matches CHECK (
       (pricing_type = 'fixed_price'
         AND fixed_price IS NOT NULL
         AND numeric_config IS NULL
         AND extra_unit_config IS NULL
         AND special_extra_config IS NULL)
    OR (pricing_type = 'role_price'
         AND fixed_price IS NULL
         AND numeric_config IS NULL
         AND extra_unit_config IS NULL
         AND special_extra_config IS NULL)
    OR (pricing_type = 'option_price'
         AND fixed_price IS NULL
         AND numeric_config IS NULL
         AND extra_unit_config IS NULL
         AND special_extra_config IS NULL)
    OR (pricing_type = 'numeric_multiplier'
         AND fixed_price IS NULL
         AND numeric_config IS NOT NULL
         AND extra_unit_config IS NULL
         AND special_extra_config IS NULL)
    OR (pricing_type = 'extra_unit_price'
         AND fixed_price IS NULL
         AND numeric_config IS NULL
         AND extra_unit_config IS NOT NULL
         AND special_extra_config IS NULL)
    OR (pricing_type = 'special_extra_product'
         AND fixed_price IS NULL
         AND numeric_config IS NULL
         AND extra_unit_config IS NULL
         AND special_extra_config IS NOT NULL)
  )
);

COMMENT ON TABLE public.quote_services IS
  'Services inside a quote section. Pricing config lives on the matching sidecar column per pricing_type.';

COMMENT ON COLUMN public.quote_services.visible_roles IS
  'Roles shown in stylist quote UI. Subset of (EMERGING, SENIOR, DIRECTOR, MASTER).';

COMMENT ON COLUMN public.quote_services.numeric_config IS
  'JSONB sidecar; populated when pricing_type = numeric_multiplier. Shape is validated by the app layer.';

COMMENT ON COLUMN public.quote_services.extra_unit_config IS
  'JSONB sidecar; populated when pricing_type = extra_unit_price. Shape is validated by the app layer.';

COMMENT ON COLUMN public.quote_services.special_extra_config IS
  'JSONB sidecar; populated when pricing_type = special_extra_product. Shape is validated by the app layer.';

COMMENT ON COLUMN public.quote_services.link_to_base_service_id IS
  'Optional linkage for extra-unit services to their base service (lifted out of JSONB so it can be FK-enforced).';

-- Partial unique index rather than a table-level UNIQUE constraint so that
-- multiple rows with NULL internal_key remain allowed.
CREATE UNIQUE INDEX IF NOT EXISTS quote_services_internal_key_unique
  ON public.quote_services (internal_key)
  WHERE internal_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_quote_services_section_active_display_order
  ON public.quote_services (section_id, active, display_order);

GRANT ALL ON TABLE public.quote_services TO service_role;


-- 4. Options for option-input / option-priced services.
-- price is only meaningful when the parent service is pricing_type = option_price,
-- but cross-row enforcement is intentionally deferred (see §5 of the schema plan).
CREATE TABLE IF NOT EXISTS public.quote_service_options (
  id             uuid           NOT NULL DEFAULT gen_random_uuid(),
  service_id     uuid           NOT NULL,
  label          text           NOT NULL,
  value_key      text           NOT NULL,
  display_order  integer        NOT NULL,
  active         boolean        NOT NULL DEFAULT true,
  price          numeric(10, 2),
  created_at     timestamptz    NOT NULL DEFAULT now(),
  updated_at     timestamptz    NOT NULL DEFAULT now(),

  CONSTRAINT quote_service_options_pkey PRIMARY KEY (id),

  CONSTRAINT quote_service_options_service_fk
    FOREIGN KEY (service_id) REFERENCES public.quote_services(id)
    ON DELETE CASCADE,

  CONSTRAINT quote_service_options_label_not_blank
    CHECK (length(btrim(label)) > 0),

  CONSTRAINT quote_service_options_value_key_format
    CHECK (value_key ~ '^[a-z0-9_]+$'),

  CONSTRAINT quote_service_options_display_order_min
    CHECK (display_order >= 1),

  CONSTRAINT quote_service_options_price_non_negative
    CHECK (price IS NULL OR price >= 0),

  CONSTRAINT quote_service_options_service_value_key_unique
    UNIQUE (service_id, value_key),

  CONSTRAINT quote_service_options_service_order_unique
    UNIQUE (service_id, display_order) DEFERRABLE INITIALLY IMMEDIATE
);

COMMENT ON TABLE public.quote_service_options IS
  'Ordered options for services with option-based input or option-based pricing.';

CREATE INDEX IF NOT EXISTS idx_quote_service_options_service_active_display_order
  ON public.quote_service_options (service_id, active, display_order);

GRANT ALL ON TABLE public.quote_service_options TO service_role;


-- 5. Per-role prices for role_price services. Composite PK (service_id, role)
-- guarantees one price per role per service.
CREATE TABLE IF NOT EXISTS public.quote_service_role_prices (
  service_id  uuid           NOT NULL,
  role        text           NOT NULL,
  price       numeric(10, 2) NOT NULL,

  CONSTRAINT quote_service_role_prices_pkey
    PRIMARY KEY (service_id, role),

  CONSTRAINT quote_service_role_prices_service_fk
    FOREIGN KEY (service_id) REFERENCES public.quote_services(id)
    ON DELETE CASCADE,

  CONSTRAINT quote_service_role_prices_role_allowed
    CHECK (role IN ('EMERGING', 'SENIOR', 'DIRECTOR', 'MASTER')),

  CONSTRAINT quote_service_role_prices_non_negative
    CHECK (price >= 0)
);

COMMENT ON TABLE public.quote_service_role_prices IS
  'Per-role prices for role_price services. One row per (service_id, role).';

GRANT ALL ON TABLE public.quote_service_role_prices TO service_role;


-- Updated_at triggers using the existing project function public.set_updated_at().
DROP TRIGGER IF EXISTS trg_quote_settings_updated_at ON public.quote_settings;
CREATE TRIGGER trg_quote_settings_updated_at
  BEFORE UPDATE ON public.quote_settings
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_quote_sections_updated_at ON public.quote_sections;
CREATE TRIGGER trg_quote_sections_updated_at
  BEFORE UPDATE ON public.quote_sections
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_quote_services_updated_at ON public.quote_services;
CREATE TRIGGER trg_quote_services_updated_at
  BEFORE UPDATE ON public.quote_services
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_quote_service_options_updated_at ON public.quote_service_options;
CREATE TRIGGER trg_quote_service_options_updated_at
  BEFORE UPDATE ON public.quote_service_options
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();


-- Seed the singleton quote_settings row with the MVP defaults. Idempotent.
INSERT INTO public.quote_settings (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;
