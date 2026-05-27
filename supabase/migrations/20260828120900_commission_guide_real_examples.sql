-- Commission Guide v5 (real-data examples + tightened eligible labels).
--
-- This migration replaces public.get_staff_commission_guide(uuid, date)
-- to (1) tighten the friendly labels used in eligible_sections and
-- (2) embed a real sale-line example in each eligible card.
--
-- Friendly labels for eligible_sections:
--   service                    -> Salon Services
--   retail_product             -> Retail Products
--   professional_product       -> Treatment Products
--   toner_with_other_service   -> Toner Lines
--   extensions_product         -> Extension Products
--   extensions_service         -> Extension Labour
--
-- Example object shape (added to each eligible_sections entry):
--   {
--     product_service_name: text,
--     price_incl_gst:       numeric,
--     price_ex_gst:         numeric,
--     rate:                 numeric (this staff's plan rate, NOT the row's rate),
--     commission:           numeric (round(price_ex_gst * rate, 2)),
--     is_staff_specific:    boolean,
--     source_staff_display_name: text
--   }
--
-- How the example is chosen:
--   1. Prefer a sale line for the selected staff member in the last 90
--      days from p_as_of_date where the staff is one of
--      staff_commission_id / staff_work_id / derived_staff_paid_id, the
--      row's commission_category_final matches the target category, and
--      price_ex_gst > 0. Pick the most recent (then highest price) row.
--   2. If no staff-specific row exists, fall back to the most recent
--      sale line (last 365 days) for any staff in that category.
--   3. If neither exists, the example field is NULL and the UI shows
--      "No recent example found.".
--   The commission amount is always computed using the selected staff's
--   current plan rate, regardless of who actually sold the example line.
--
-- This migration does NOT change payroll, commission calculations,
-- remuneration rates, Product Configuration, voucher logic, KPIs,
-- contractor invoices, or role / pay history. It is read-only RPC copy
-- and presentation. All visible strings deliberately contain NO em
-- dashes (U+2014).

CREATE OR REPLACE FUNCTION public.get_staff_commission_guide(
  p_staff_member_id uuid DEFAULT NULL,
  p_as_of_date      date DEFAULT current_date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, private, pg_temp
AS $fn$
DECLARE
  v_caller       uuid    := auth.uid();
  v_caller_staff uuid;
  v_target       uuid;
  v_elevated     boolean := false;
  v_as_of        date    := COALESCE(p_as_of_date, current_date);
  v_lookback_start date;
  v_fallback_start date;

  v_staff_row    record;
  v_profile      record;
  v_plan         record;
  v_rates_map    jsonb   := '{}'::jsonb;

  v_rate_service        numeric;
  v_rate_retail         numeric;
  v_rate_professional   numeric;
  v_rate_toner          numeric;
  v_rate_ext_product    numeric;
  v_rate_ext_service    numeric;

  v_rate_cards          jsonb;
  v_classification      jsonb;
  v_admin_full_guide    jsonb := '[]'::jsonb;
  v_summary             jsonb;
  v_notes               jsonb;

  v_eligible_sections     jsonb := '[]'::jsonb;
  v_not_eligible_sections jsonb := '[]'::jsonb;
  v_recent_items          jsonb := '[]'::jsonb;
  v_examples_map          jsonb := '{}'::jsonb;

  v_eff_role            text;
  v_eff_secondary_roles text;
  v_eff_employment_type text;
  v_eff_plan_name       text;
  v_eff_fte             numeric;
  v_eff_location_id     uuid;
  v_eff_location_name   text;
  v_eff_start           date;
  v_using_fallback      boolean := false;

  v_headline       text;
  v_plain_english  text;
  v_plan_style     text;  -- 'wage' | 'contractor' | 'commission' | 'none'

  v_plan_label_friendly text;
  v_staff_display_name  text;
BEGIN
  -- 1. Auth + page access.
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;
  IF NOT (SELECT private.user_has_page_access('commission_guide', 'view')) THEN
    RAISE EXCEPTION 'not authorized to view the commission guide'
      USING ERRCODE = '42501';
  END IF;

  v_elevated := (SELECT private.user_has_elevated_access());

  SELECT a.staff_member_id
    INTO v_caller_staff
  FROM public.staff_member_user_access a
  WHERE a.user_id   = v_caller
    AND a.is_active = true
  LIMIT 1;

  v_target := COALESCE(p_staff_member_id, v_caller_staff);

  IF v_target IS NULL THEN
    RAISE EXCEPTION
      'no staff member id supplied and caller has no active staff mapping'
      USING ERRCODE = '22023';
  END IF;

  IF v_target IS DISTINCT FROM v_caller_staff AND NOT v_elevated THEN
    RAISE EXCEPTION
      'not authorized to view the commission guide for another staff member'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Load staff row.
  SELECT sm.id, sm.full_name, sm.display_name, sm.is_active,
         sm.primary_role, sm.secondary_roles, sm.employment_type,
         sm.remuneration_plan, sm.fte, sm.primary_location_id
    INTO v_staff_row
  FROM public.staff_members sm
  WHERE sm.id = v_target;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'staff member not found: %', v_target
      USING ERRCODE = 'P0002';
  END IF;

  v_staff_display_name := COALESCE(
    NULLIF(btrim(v_staff_row.display_name), ''),
    NULLIF(btrim(v_staff_row.full_name), ''),
    'this staff member'
  );

  -- 3. Effective profile at v_as_of.
  SELECT *
    INTO v_profile
  FROM public.staff_profile_at(v_target, v_as_of)
  LIMIT 1;

  IF v_profile IS NULL OR v_profile.id IS NULL THEN
    v_using_fallback      := true;
    v_eff_role            := v_staff_row.primary_role;
    v_eff_secondary_roles := v_staff_row.secondary_roles;
    v_eff_employment_type := v_staff_row.employment_type;
    v_eff_plan_name       := v_staff_row.remuneration_plan;
    v_eff_fte             := v_staff_row.fte;
    v_eff_location_id     := v_staff_row.primary_location_id;
    v_eff_start           := NULL;
  ELSE
    v_eff_role            := v_profile.primary_role;
    v_eff_secondary_roles := v_profile.secondary_roles;
    v_eff_employment_type := v_profile.employment_type;
    v_eff_plan_name       := v_profile.remuneration_plan;
    v_eff_fte             := v_profile.fte;
    v_eff_location_id     := v_profile.primary_location_id;
    v_eff_start           := v_profile.effective_start_date;
  END IF;

  IF v_eff_location_id IS NOT NULL THEN
    SELECT l.name INTO v_eff_location_name
    FROM public.locations l
    WHERE l.id = v_eff_location_id;
  END IF;

  -- 4. Plan + rates map.
  IF v_eff_plan_name IS NOT NULL THEN
    SELECT p.id, p.plan_name, p.can_use_assistants,
           p.conditions_text, p.staff_on_this_plan_text, p.is_active
      INTO v_plan
    FROM public.remuneration_plans p
    WHERE p.plan_name = v_eff_plan_name
    LIMIT 1;
  END IF;

  IF v_plan.id IS NOT NULL THEN
    SELECT COALESCE(
      jsonb_object_agg(r.commission_category, r.rate),
      '{}'::jsonb
    )
      INTO v_rates_map
    FROM public.remuneration_plan_rates r
    WHERE r.remuneration_plan_id = v_plan.id;
  END IF;

  v_rate_service      := NULLIF(v_rates_map ->> 'service',                  '')::numeric;
  v_rate_retail       := NULLIF(v_rates_map ->> 'retail_product',           '')::numeric;
  v_rate_professional := NULLIF(v_rates_map ->> 'professional_product',     '')::numeric;
  v_rate_toner        := NULLIF(v_rates_map ->> 'toner_with_other_service', '')::numeric;
  v_rate_ext_product  := NULLIF(v_rates_map ->> 'extensions_product',       '')::numeric;
  v_rate_ext_service  := NULLIF(v_rates_map ->> 'extensions_service',       '')::numeric;

  -- Treat 0 as "no rate" for eligibility decisions.
  IF v_rate_service      IS NOT NULL AND v_rate_service      <= 0 THEN v_rate_service      := NULL; END IF;
  IF v_rate_retail       IS NOT NULL AND v_rate_retail       <= 0 THEN v_rate_retail       := NULL; END IF;
  IF v_rate_professional IS NOT NULL AND v_rate_professional <= 0 THEN v_rate_professional := NULL; END IF;
  IF v_rate_toner        IS NOT NULL AND v_rate_toner        <= 0 THEN v_rate_toner        := NULL; END IF;
  IF v_rate_ext_product  IS NOT NULL AND v_rate_ext_product  <= 0 THEN v_rate_ext_product  := NULL; END IF;
  IF v_rate_ext_service  IS NOT NULL AND v_rate_ext_service  <= 0 THEN v_rate_ext_service  := NULL; END IF;

  v_plan_style := CASE
    WHEN v_eff_plan_name IS NULL THEN 'none'
    WHEN lower(coalesce(v_eff_employment_type, '')) = 'contractor'
      OR lower(coalesce(v_eff_plan_name, ''))      LIKE '%contractor%'
      THEN 'contractor'
    WHEN v_rate_service IS NULL
      OR lower(coalesce(v_eff_plan_name, ''))      LIKE '%wage%'
      THEN 'wage'
    ELSE 'commission'
  END;

  v_plan_label_friendly := COALESCE(v_eff_plan_name, 'current');

  -- ===========================================================================
  -- 5. Build a per-category map of real example sale lines.
  --    Prefer the selected staff in the last 90 days.
  --    Fall back to any staff in the last 365 days.
  -- ===========================================================================
  v_lookback_start := v_as_of - 90;
  v_fallback_start := v_as_of - 365;

  WITH staff_candidates AS (
    SELECT
      vc.commission_category_final AS cc,
      vc.product_service_name,
      vc.price_incl_gst,
      vc.price_ex_gst,
      vc.sale_date,
      ROW_NUMBER() OVER (
        PARTITION BY vc.commission_category_final
        ORDER BY vc.sale_date DESC, vc.price_ex_gst DESC
      ) AS rn
    FROM public.v_commission_calculations_core vc
    WHERE vc.commission_category_final IN (
            'service','retail_product','professional_product',
            'toner_with_other_service','extensions_product','extensions_service'
          )
      AND vc.price_ex_gst IS NOT NULL
      AND vc.price_ex_gst > 0
      AND NULLIF(btrim(vc.product_service_name), '') IS NOT NULL
      AND vc.sale_date >= v_lookback_start
      AND vc.sale_date <= v_as_of
      AND (
        vc.staff_commission_id      = v_target
        OR vc.staff_work_id         = v_target
        OR vc.derived_staff_paid_id = v_target
      )
  ),
  staff_top AS (
    SELECT cc, product_service_name, price_incl_gst, price_ex_gst
    FROM staff_candidates
    WHERE rn = 1
  ),
  fallback_candidates AS (
    SELECT
      vc.commission_category_final AS cc,
      vc.product_service_name,
      vc.price_incl_gst,
      vc.price_ex_gst,
      COALESCE(
        NULLIF(btrim(vc.derived_staff_paid_display_name), ''),
        NULLIF(btrim(vc.work_display_name), ''),
        NULLIF(btrim(vc.commission_display_name), ''),
        'another staff member'
      ) AS source_staff,
      vc.sale_date,
      ROW_NUMBER() OVER (
        PARTITION BY vc.commission_category_final
        ORDER BY vc.sale_date DESC, vc.price_ex_gst DESC
      ) AS rn
    FROM public.v_commission_calculations_core vc
    WHERE vc.commission_category_final IN (
            'service','retail_product','professional_product',
            'toner_with_other_service','extensions_product','extensions_service'
          )
      AND vc.price_ex_gst IS NOT NULL
      AND vc.price_ex_gst > 0
      AND NULLIF(btrim(vc.product_service_name), '') IS NOT NULL
      AND vc.sale_date >= v_fallback_start
      AND vc.sale_date <= v_as_of
  ),
  fallback_top AS (
    SELECT cc, product_service_name, price_incl_gst, price_ex_gst, source_staff
    FROM fallback_candidates
    WHERE rn = 1
  ),
  picked AS (
    SELECT
      cc,
      jsonb_build_object(
        'product_service_name',      product_service_name,
        'price_incl_gst',            price_incl_gst,
        'price_ex_gst',              price_ex_gst,
        'is_staff_specific',         TRUE,
        'source_staff_display_name', v_staff_display_name
      ) AS ex
    FROM staff_top
    UNION ALL
    SELECT
      ft.cc,
      jsonb_build_object(
        'product_service_name',      ft.product_service_name,
        'price_incl_gst',            ft.price_incl_gst,
        'price_ex_gst',              ft.price_ex_gst,
        'is_staff_specific',         FALSE,
        'source_staff_display_name', ft.source_staff
      ) AS ex
    FROM fallback_top ft
    WHERE NOT EXISTS (
      SELECT 1 FROM staff_top st WHERE st.cc = ft.cc
    )
  )
  SELECT COALESCE(jsonb_object_agg(cc, ex), '{}'::jsonb)
    INTO v_examples_map
  FROM picked;

  -- ===========================================================================
  -- 6. Eligible for commission (compact format, real example).
  --    Labels match the redesign spec exactly.
  -- ===========================================================================

  IF v_rate_service IS NOT NULL THEN
    v_eligible_sections := v_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'service',
      'label',    'Salon Services',
      'rate',     v_rate_service,
      'summary',  'Salon services on this plan.',
      'example',  CASE
        WHEN v_examples_map -> 'service' IS NULL THEN NULL
        ELSE (v_examples_map -> 'service') || jsonb_build_object(
          'rate',       v_rate_service,
          'commission', round(((v_examples_map -> 'service' ->> 'price_ex_gst')::numeric) * v_rate_service, 2)
        )
      END
    ))::jsonb;
  END IF;

  IF v_rate_retail IS NOT NULL THEN
    v_eligible_sections := v_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'retail_product',
      'label',    'Retail Products',
      'rate',     v_rate_retail,
      'summary',  'Eligible take-home retail products.',
      'example',  CASE
        WHEN v_examples_map -> 'retail_product' IS NULL THEN NULL
        ELSE (v_examples_map -> 'retail_product') || jsonb_build_object(
          'rate',       v_rate_retail,
          'commission', round(((v_examples_map -> 'retail_product' ->> 'price_ex_gst')::numeric) * v_rate_retail, 2)
        )
      END
    ))::jsonb;
  END IF;

  IF v_rate_professional IS NOT NULL THEN
    v_eligible_sections := v_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'professional_product',
      'label',    'Treatment Products',
      'rate',     v_rate_professional,
      'summary',  'Treatment / professional product lines.',
      'example',  CASE
        WHEN v_examples_map -> 'professional_product' IS NULL THEN NULL
        ELSE (v_examples_map -> 'professional_product') || jsonb_build_object(
          'rate',       v_rate_professional,
          'commission', round(((v_examples_map -> 'professional_product' ->> 'price_ex_gst')::numeric) * v_rate_professional, 2)
        )
      END
    ))::jsonb;
  END IF;

  IF v_rate_toner IS NOT NULL THEN
    v_eligible_sections := v_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'toner_with_other_service',
      'label',    'Toner Lines',
      'rate',     v_rate_toner,
      'summary',  'Toner added to another service.',
      'example',  CASE
        WHEN v_examples_map -> 'toner_with_other_service' IS NULL THEN NULL
        ELSE (v_examples_map -> 'toner_with_other_service') || jsonb_build_object(
          'rate',       v_rate_toner,
          'commission', round(((v_examples_map -> 'toner_with_other_service' ->> 'price_ex_gst')::numeric) * v_rate_toner, 2)
        )
      END
    ))::jsonb;
  END IF;

  IF v_rate_ext_product IS NOT NULL THEN
    v_eligible_sections := v_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'extensions_product',
      'label',    'Extension Products',
      'rate',     v_rate_ext_product,
      'summary',  'Extension hair or bond product.',
      'example',  CASE
        WHEN v_examples_map -> 'extensions_product' IS NULL THEN NULL
        ELSE (v_examples_map -> 'extensions_product') || jsonb_build_object(
          'rate',       v_rate_ext_product,
          'commission', round(((v_examples_map -> 'extensions_product' ->> 'price_ex_gst')::numeric) * v_rate_ext_product, 2)
        )
      END
    ))::jsonb;
  END IF;

  IF v_rate_ext_service IS NOT NULL THEN
    v_eligible_sections := v_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'extensions_service',
      'label',    'Extension Labour',
      'rate',     v_rate_ext_service,
      'summary',  'Extension install / removal / maintenance labour.',
      'example',  CASE
        WHEN v_examples_map -> 'extensions_service' IS NULL THEN NULL
        ELSE (v_examples_map -> 'extensions_service') || jsonb_build_object(
          'rate',       v_rate_ext_service,
          'commission', round(((v_examples_map -> 'extensions_service' ->> 'price_ex_gst')::numeric) * v_rate_ext_service, 2)
        )
      END
    ))::jsonb;
  END IF;

  -- ===========================================================================
  -- 7. Plan summary (unchanged wording from v4).
  -- ===========================================================================
  v_headline := CASE
    WHEN v_eff_role IS NOT NULL AND v_eff_plan_name IS NOT NULL
      THEN v_eff_role || ' on the ' || v_eff_plan_name || ' plan'
    WHEN v_eff_plan_name IS NOT NULL
      THEN v_eff_plan_name || ' plan'
    WHEN v_eff_role IS NOT NULL
      THEN v_eff_role
    ELSE 'Your commission setup'
  END;

  v_plain_english := CASE v_plan_style
    WHEN 'none' THEN
      'You are not currently on a remuneration plan. If this looks wrong, please speak to your manager.'
    WHEN 'wage' THEN
      'You are on the ' || v_eff_plan_name
        || ' plan. You are paid hourly for salon service work. You may also earn commission on eligible retail products.'
    WHEN 'contractor' THEN
      'You are on the ' || v_eff_plan_name
        || ' plan. Eligible services are paid at your contractor service rate. Some product and special categories may use different rates.'
    ELSE
      'You are on the ' || v_eff_plan_name
        || ' plan. You can earn commission on eligible services, retail products, treatment products, toners, and extension items, depending on how each sale is treated.'
  END;

  v_notes := jsonb_build_array(
    jsonb_build_object(
      'heading', 'Vouchers',
      'body',
        'Selling a voucher does not earn commission because it is a prepayment. When the voucher is later used, the actual service or product is treated normally.'
    )
  );

  v_summary := jsonb_build_object(
    'headline',         v_headline,
    'plain_english',    v_plain_english,
    'important_notes',  v_notes,
    'plan_style',       v_plan_style,
    'using_fallback_to_current_profile', v_using_fallback
  );

  -- ===========================================================================
  -- 8. Legacy rate cards (kept for back-compat; staff page no longer uses).
  -- ===========================================================================
  v_rate_cards := jsonb_build_array(
    jsonb_build_object(
      'label',    'Salon Services',
      'category', 'service',
      'rate',     v_rate_service,
      'has_rate', v_rate_service IS NOT NULL,
      'plain_english',
        CASE WHEN v_rate_service IS NULL
          THEN 'No service commission on this plan.'
          ELSE 'You earn this rate on eligible salon services.'
        END
    ),
    jsonb_build_object(
      'label',    'Retail Products',
      'category', 'retail_product',
      'rate',     v_rate_retail,
      'has_rate', v_rate_retail IS NOT NULL,
      'plain_english',
        CASE WHEN v_rate_retail IS NULL
          THEN 'No retail commission on this plan.'
          ELSE 'You earn this rate on eligible take-home retail products.'
        END
    ),
    jsonb_build_object(
      'label',    'Treatment Products',
      'category', 'professional_product',
      'rate',     v_rate_professional,
      'has_rate', v_rate_professional IS NOT NULL,
      'plain_english',
        CASE WHEN v_rate_professional IS NULL
          THEN 'No treatment / professional product commission on this plan.'
          ELSE 'You earn this rate on treatment / professional products.'
        END
    ),
    jsonb_build_object(
      'label',    'Toner Lines',
      'category', 'toner_with_other_service',
      'rate',     v_rate_toner,
      'has_rate', v_rate_toner IS NOT NULL,
      'plain_english',
        CASE WHEN v_rate_toner IS NULL
          THEN 'No toner-line commission on this plan.'
          ELSE 'You earn this rate on toner added to another service.'
        END
    ),
    jsonb_build_object(
      'label',    'Extension Products',
      'category', 'extensions_product',
      'rate',     v_rate_ext_product,
      'has_rate', v_rate_ext_product IS NOT NULL,
      'plain_english',
        CASE WHEN v_rate_ext_product IS NULL
          THEN 'No extension product commission on this plan.'
          ELSE 'You earn this rate on extension hair or bonded product.'
        END
    ),
    jsonb_build_object(
      'label',    'Extension Labour',
      'category', 'extensions_service',
      'rate',     v_rate_ext_service,
      'has_rate', v_rate_ext_service IS NOT NULL,
      'plain_english',
        CASE WHEN v_rate_ext_service IS NULL
          THEN 'No extension labour commission on this plan.'
          ELSE 'You earn this rate on extension install / removal / maintenance.'
        END
    )
  );

  -- ===========================================================================
  -- 9. Full product classification (legacy table + admin-only view).
  -- ===========================================================================
  WITH derived AS (
    SELECT
      pm.product_description AS name,
      pm.system_type,
      pm.product_type,
      CASE
        WHEN lower(btrim(coalesce(pm.product_description, ''))) = 'green fee'
          THEN 'no_commission_greenfee'
        WHEN lower(btrim(coalesce(pm.product_description, ''))) = 'redo'
          THEN 'no_commission_redo'
        WHEN lower(btrim(coalesce(pm.product_description, ''))) = 'training product'
          THEN 'no_commission_trainingproduct'
        WHEN lower(btrim(coalesce(pm.product_description, ''))) = 'miscellaneous'
          THEN 'no_commission_miscellaneousproduct'
        WHEN lower(btrim(coalesce(pm.product_description, ''))) = 'coffee'
          THEN 'no_commission_miscellaneousproduct'
        WHEN lower(btrim(coalesce(pm.system_type, ''))) = 'voucher'
          THEN 'no_commission_voucher'
        WHEN lower(btrim(coalesce(pm.system_type, ''))) = 'unclassified'
          THEN 'no_commission_unclassified'
        WHEN right(btrim(coalesce(pm.product_description, '')), 1) = '*'
          THEN 'professional_product'
        WHEN lower(btrim(coalesce(pm.product_type, ''))) = 'professional product'
          THEN 'professional_product'
        WHEN lower(btrim(coalesce(pm.product_type, ''))) = 'retail product'
          THEN 'retail_product'
        WHEN lower(btrim(coalesce(pm.product_type, ''))) = '-'
          THEN 'no_commission_unclassified'
        WHEN lower(btrim(coalesce(pm.system_type, ''))) = 'service'
          THEN 'service'
        WHEN lower(btrim(coalesce(pm.system_type, ''))) = 'retail'
          THEN 'retail_product'
        ELSE NULL
      END AS commission_category
    FROM public.product_master pm
    WHERE pm.is_active = true
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'product_or_category',     d.name,
      'imported_type',           d.system_type,
      'configured_system_type',  d.system_type,
      'configured_product_type', d.product_type,
      'commission_category',     d.commission_category,
      'rate_for_this_plan',
        CASE
          WHEN d.commission_category IS NULL THEN NULL
          ELSE NULLIF(v_rates_map ->> d.commission_category, '')::numeric
        END,
      'counts_for_commission',
        d.commission_category IN (
          'service','retail_product','professional_product',
          'toner_with_other_service','extensions_product','extensions_service'
        ),
      'plain_english',
        CASE d.commission_category
          WHEN 'professional_product' THEN
            CASE
              WHEN right(btrim(coalesce(d.name, '')), 1) = '*'
                THEN 'Treated as a treatment product (the trailing * tags it that way).'
              ELSE 'Configured as a treatment product.'
            END
          WHEN 'service'        THEN 'Treated as a salon service.'
          WHEN 'retail_product' THEN 'Treated as a take-home retail product.'
          WHEN 'no_commission_voucher' THEN
            'Voucher sales are prepayments, so no commission is paid when the voucher is sold.'
          WHEN 'no_commission_greenfee' THEN
            'Green fees are not staff service sales, so no commission is paid.'
          WHEN 'no_commission_redo' THEN
            'Redo / rework lines are not treated as new commissionable sales.'
          WHEN 'no_commission_trainingproduct' THEN
            'Training items are excluded from commission.'
          WHEN 'no_commission_miscellaneousproduct' THEN
            CASE WHEN lower(btrim(coalesce(d.name, ''))) = 'coffee'
              THEN 'Coffee is not treated as a hair service or retail product.'
              ELSE 'Not treated as a hair service or retail product.'
            END
          WHEN 'no_commission_unclassified' THEN
            'Miscellaneous line item not loaded as a product or service in the system.'
          ELSE 'Not currently mapped to a commission category.'
        END
    )
    ORDER BY d.name
  ), '[]'::jsonb)
    INTO v_classification
  FROM derived d;

  IF v_elevated THEN
    v_admin_full_guide := v_classification;
  ELSE
    v_admin_full_guide := '[]'::jsonb;
  END IF;

  -- ===========================================================================
  -- 10. Legacy fields kept on the envelope so older clients still parse.
  --     The redesigned page does not render any of these.
  -- ===========================================================================
  RETURN jsonb_build_object(
    'as_of_date', v_as_of,
    'staff', jsonb_build_object(
      'staff_member_id',        v_staff_row.id,
      'display_name',           v_staff_row.display_name,
      'full_name',              v_staff_row.full_name,
      'is_active',              v_staff_row.is_active,
      'primary_role',           v_eff_role,
      'secondary_roles',        v_eff_secondary_roles,
      'employment_type',        v_eff_employment_type,
      'fte',                    v_eff_fte,
      'primary_location_id',    v_eff_location_id,
      'primary_location_name',  v_eff_location_name,
      'remuneration_plan',      v_eff_plan_name,
      'effective_start_date',   v_eff_start
    ),
    'plan', CASE
      WHEN v_plan.id IS NULL THEN NULL
      ELSE jsonb_build_object(
        'id',                       v_plan.id,
        'plan_name',                v_plan.plan_name,
        'can_use_assistants',       v_plan.can_use_assistants,
        'conditions_text',          v_plan.conditions_text,
        'staff_on_this_plan_text',  v_plan.staff_on_this_plan_text,
        'is_active',                v_plan.is_active,
        'rates',                    v_rates_map
      )
    END,
    'plan_summary',          v_summary,

    -- New personalised sections (used by the redesigned staff page).
    'eligible_sections',     v_eligible_sections,
    'not_eligible_sections', v_not_eligible_sections, -- empty; the page renders a static list instead
    'recent_items_to_be_aware_of', v_recent_items,    -- empty; the page does not render this section
    'recent_lookback_days',  90,
    'admin_full_product_guide',    v_admin_full_guide,

    -- Legacy fields (kept for backwards compatibility).
    'rate_cards',            v_rate_cards,
    'classification_table',  v_classification,
    'exclusions',            '[]'::jsonb,
    'special_cases',         '[]'::jsonb,
    'examples',              '[]'::jsonb,

    'caller', jsonb_build_object(
      'is_elevated', v_elevated,
      'is_self',     v_target IS NOT DISTINCT FROM v_caller_staff
    )
  );
END;
$fn$;

ALTER FUNCTION public.get_staff_commission_guide(uuid, date) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.get_staff_commission_guide(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_staff_commission_guide(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_staff_commission_guide(uuid, date) TO service_role;

COMMENT ON FUNCTION public.get_staff_commission_guide(uuid, date) IS
  'Read-only Commission Guide for staff (v5, 20260828120900). '
  'eligible_sections now uses friendlier labels (Salon Services, Retail Products, '
  'Treatment Products, Toner Lines, Extension Products, Extension Labour) and '
  'embeds a real sale-line example per card with product_service_name, '
  'price_incl_gst, price_ex_gst, rate, commission, is_staff_specific, '
  'source_staff_display_name. Examples prefer rows for the selected staff in the '
  'last 90 days (commission/work/derived-paid match), falling back to any staff '
  'in the last 365 days. The commission amount uses the selected staff plan rate. '
  'recent_items_to_be_aware_of and not_eligible_sections are intentionally returned '
  'as empty arrays. The page renders a static "what does not earn commission" list '
  'instead. No payroll, commission, rate, Product Configuration, voucher, KPI, or '
  'contractor-invoice logic changes.';
