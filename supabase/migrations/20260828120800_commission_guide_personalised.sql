-- Commission Guide v4 (personalised redesign).
--
-- This migration replaces public.get_staff_commission_guide(uuid, date)
-- so the returned envelope supports a personalised staff page:
--
--   eligible_sections             only categories where this staff's
--                                 current plan has rate > 0
--   not_eligible_sections         only categories that are actually
--                                 relevant to this staff (main service
--                                 rate when missing, voucher sales,
--                                 catch-all "other non-commission", plus
--                                 any 0-rate category that appeared in
--                                 recent sale lines for this staff)
--   recent_items_to_be_aware_of   named products / services the staff
--                                 has actually been involved in over the
--                                 last 90 days that have a special rule
--                                 or no-commission treatment
--   admin_full_product_guide      full product_master classification
--                                 list, populated only for elevated
--                                 callers (admins / managers)
--
-- Plan summary plain English uses the simpler wording requested in the
-- redesign brief (wage / commission / contractor / none).
--
-- The legacy fields (rate_cards, classification_table, exclusions,
-- special_cases, examples, plan_summary.important_notes) are still
-- returned for backwards compatibility but are no longer used by the
-- staff page.
--
-- Classification precedence is unchanged from v3 (name overrides ->
-- voucher / unclassified -> asterisk -> product_type Professional /
-- Retail -> product_type '-' -> system_type fallback). Recent-items
-- classification reads commission_category_final straight off
-- public.v_commission_calculations_core so it matches payroll exactly.
--
-- This migration does NOT change payroll, commission calculations,
-- remuneration rates, Product Configuration, voucher logic, KPIs,
-- contractor invoices, or role / pay history. It is a read-only
-- presentation change.
--
-- Visible strings in this RPC deliberately contain NO em dashes (U+2014)
-- so the staff page is em-dash-free end to end.

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

  v_rate_cards        jsonb;
  v_classification    jsonb;
  v_exclusions        jsonb;
  v_special           jsonb;
  v_examples          jsonb;
  v_summary           jsonb;
  v_notes             jsonb;

  v_eligible_sections     jsonb := '[]'::jsonb;
  v_not_eligible_sections jsonb := '[]'::jsonb;
  v_recent_items          jsonb := '[]'::jsonb;
  v_recent_categories     text[];
  v_admin_full_guide      jsonb := '[]'::jsonb;

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

  -- Treat 0 as "no rate" for "eligible / not eligible" decisions.
  IF v_rate_service      IS NOT NULL AND v_rate_service      <= 0 THEN v_rate_service      := NULL; END IF;
  IF v_rate_retail       IS NOT NULL AND v_rate_retail       <= 0 THEN v_rate_retail       := NULL; END IF;
  IF v_rate_professional IS NOT NULL AND v_rate_professional <= 0 THEN v_rate_professional := NULL; END IF;
  IF v_rate_toner        IS NOT NULL AND v_rate_toner        <= 0 THEN v_rate_toner        := NULL; END IF;
  IF v_rate_ext_product  IS NOT NULL AND v_rate_ext_product  <= 0 THEN v_rate_ext_product  := NULL; END IF;
  IF v_rate_ext_service  IS NOT NULL AND v_rate_ext_service  <= 0 THEN v_rate_ext_service  := NULL; END IF;

  -- 4b. Detect plan style.
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
  -- 5. Recent items the staff has actually been involved in (last 90 days).
  --    Source: v_commission_calculations_core (commission_category_final
  --    is the authoritative payroll classification). We pre-classify here
  --    so the page never has to interpret raw codes.
  -- ===========================================================================
  v_lookback_start := v_as_of - 90;

  WITH lines AS (
    SELECT
      vc.product_service_name,
      vc.commission_category_final AS cc,
      vc.sale_date
    FROM public.v_commission_calculations_core vc
    WHERE vc.sale_date >= v_lookback_start
      AND vc.sale_date <= v_as_of
      AND (
            vc.staff_commission_id    = v_target
         OR vc.staff_work_id          = v_target
         OR vc.derived_staff_paid_id  = v_target
      )
      AND vc.product_service_name IS NOT NULL
      AND vc.commission_category_final IS NOT NULL
      -- Only categories that benefit from explanation. Plain `service`
      -- and plain `retail_product` are boring for staff (they are the
      -- default and need no per-item callout).
      AND vc.commission_category_final IN (
            'no_commission_voucher','no_commission_greenfee',
            'no_commission_redo','no_commission_trainingproduct',
            'no_commission_miscellaneousproduct','no_commission_unclassified',
            'professional_product','toner_with_other_service',
            'extensions_product','extensions_service'
      )
  ),
  agg AS (
    SELECT
      btrim(product_service_name) AS name,
      cc,
      COUNT(*)::int               AS recent_line_count,
      MAX(sale_date)              AS last_seen
    FROM lines
    GROUP BY btrim(product_service_name), cc
  ),
  ranked AS (
    SELECT a.*,
           ROW_NUMBER() OVER (ORDER BY recent_line_count DESC, last_seen DESC, name ASC) AS rn
    FROM agg a
  )
  SELECT
    COALESCE(jsonb_agg(
      jsonb_build_object(
        'product_or_service',  r.name,
        'commission_category', r.cc,
        'recent_line_count',   r.recent_line_count,
        'last_seen',           r.last_seen,
        'treatment', CASE r.cc
          WHEN 'service'                              THEN 'Salon service'
          WHEN 'retail_product'                       THEN 'Retail product'
          WHEN 'professional_product'                 THEN 'Treatment / professional product'
          WHEN 'toner_with_other_service'             THEN 'Toner added to another service'
          WHEN 'extensions_product'                   THEN 'Extension hair / product'
          WHEN 'extensions_service'                   THEN 'Extension labour'
          ELSE 'No commission'
        END,
        'plain_english', CASE r.cc
          WHEN 'no_commission_voucher' THEN
            'Voucher sale. No commission when sold, because a voucher is a prepayment.'
          WHEN 'no_commission_greenfee' THEN
            'No commission. Green fees are not staff service sales.'
          WHEN 'no_commission_redo' THEN
            'No commission. Redo or rework lines are not treated as new commissionable sales.'
          WHEN 'no_commission_trainingproduct' THEN
            'No commission. Training items are excluded from commission.'
          WHEN 'no_commission_miscellaneousproduct' THEN
            CASE
              WHEN lower(r.name) = 'coffee'
                THEN 'No commission. Coffee is not treated as a hair service or retail product.'
              ELSE 'No commission. Not treated as a hair service or retail product.'
            END
          WHEN 'no_commission_unclassified' THEN
            'No commission yet. This item has not been classified, so commission will only apply once it is reviewed and mapped.'
          WHEN 'professional_product' THEN
            'Treatment / professional product. This uses the treatment/product rate, not the salon service rate.'
          WHEN 'toner_with_other_service' THEN
            'Toner added to another service. This uses the toner/product rate, not the main service rate.'
          WHEN 'extensions_product' THEN
            'Extension hair or bond product. This uses the extensions product rate.'
          WHEN 'extensions_service' THEN
            'Extension install / removal / maintenance labour. This uses the extensions labour rate.'
          ELSE 'See the rate cards above for how this is treated.'
        END
      )
      ORDER BY r.rn
    ), '[]'::jsonb)
  INTO v_recent_items
  FROM ranked r
  WHERE r.rn <= 12;

  -- Categories present in the recent_items list (used below to decide
  -- which 0-rate "not eligible" cards are worth showing).
  SELECT COALESCE(ARRAY_AGG(DISTINCT (item ->> 'commission_category')), ARRAY[]::text[])
    INTO v_recent_categories
  FROM jsonb_array_elements(v_recent_items) item;

  -- ===========================================================================
  -- 6. Eligible for commission.
  -- ===========================================================================
  IF v_rate_service IS NOT NULL THEN
    v_eligible_sections := v_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'service',
      'label',    CASE v_plan_style WHEN 'contractor' THEN 'Salon services (contractor rate)' ELSE 'Salon services' END,
      'rate',     v_rate_service,
      'summary',
        'You earn ' || to_char(round(v_rate_service * 100, 1), 'FM999990.##')
        || '% on eligible salon services, based on the ex GST sale value.',
      'example',  jsonb_build_object(
        'sale_ex_gst',   100,
        'commission',    round(100 * v_rate_service, 2),
        'plain_english', 'A $100 service earns $'
          || trim(to_char(round(100 * v_rate_service, 2), 'FM999999990.00')) || ' commission.'
      )
    ))::jsonb;
  END IF;

  IF v_rate_retail IS NOT NULL THEN
    v_eligible_sections := v_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'retail_product',
      'label',    'Retail products',
      'rate',     v_rate_retail,
      'summary',
        'You earn ' || to_char(round(v_rate_retail * 100, 1), 'FM999990.##')
        || '% on eligible take-home retail products.',
      'example',  jsonb_build_object(
        'sale_ex_gst',   30,
        'commission',    round(30 * v_rate_retail, 2),
        'plain_english', 'A $30 retail sale earns $'
          || trim(to_char(round(30 * v_rate_retail, 2), 'FM999999990.00')) || ' commission.'
      )
    ))::jsonb;
  END IF;

  IF v_rate_professional IS NOT NULL THEN
    v_eligible_sections := v_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'professional_product',
      'label',    'Treatment / professional products',
      'rate',     v_rate_professional,
      'summary',
        'Some treatments and professional products use the product/treatment rate. You earn '
        || to_char(round(v_rate_professional * 100, 1), 'FM999990.##') || '% on these.',
      'example',  jsonb_build_object(
        'sale_ex_gst',   40,
        'commission',    round(40 * v_rate_professional, 2),
        'plain_english', 'A $40 treatment product earns $'
          || trim(to_char(round(40 * v_rate_professional, 2), 'FM999999990.00')) || ' commission.'
      )
    ))::jsonb;
  END IF;

  IF v_rate_toner IS NOT NULL THEN
    v_eligible_sections := v_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'toner_with_other_service',
      'label',    'Toner added to another service',
      'rate',     v_rate_toner,
      'summary',
        'Toner added to another service uses this rate, not the main service rate. You earn '
        || to_char(round(v_rate_toner * 100, 1), 'FM999990.##') || '%.',
      'example',  jsonb_build_object(
        'sale_ex_gst',   30,
        'commission',    round(30 * v_rate_toner, 2),
        'plain_english', 'A $30 toner line earns $'
          || trim(to_char(round(30 * v_rate_toner, 2), 'FM999999990.00')) || ' commission.'
      )
    ))::jsonb;
  END IF;

  IF v_rate_ext_product IS NOT NULL THEN
    v_eligible_sections := v_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'extensions_product',
      'label',    'Extension hair / product',
      'rate',     v_rate_ext_product,
      'summary',
        'Extension hair or bond products use this rate. You earn '
        || to_char(round(v_rate_ext_product * 100, 1), 'FM999990.##') || '%.',
      'example',  jsonb_build_object(
        'sale_ex_gst',   250,
        'commission',    round(250 * v_rate_ext_product, 2),
        'plain_english', 'A $250 extension product sale earns $'
          || trim(to_char(round(250 * v_rate_ext_product, 2), 'FM999999990.00')) || ' commission.'
      )
    ))::jsonb;
  END IF;

  IF v_rate_ext_service IS NOT NULL THEN
    v_eligible_sections := v_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'extensions_service',
      'label',    'Extension service / labour',
      'rate',     v_rate_ext_service,
      'summary',
        'Extension install, removal, or maintenance labour uses this rate. You earn '
        || to_char(round(v_rate_ext_service * 100, 1), 'FM999990.##') || '%.',
      'example',  jsonb_build_object(
        'sale_ex_gst',   150,
        'commission',    round(150 * v_rate_ext_service, 2),
        'plain_english', 'A $150 extension service earns $'
          || trim(to_char(round(150 * v_rate_ext_service, 2), 'FM999999990.00')) || ' commission.'
      )
    ))::jsonb;
  END IF;

  -- ===========================================================================
  -- 7. Not eligible for commission.
  --
  --    Always-included rows: voucher_sales (universal),
  --    other_non_commission (universal catch-all).
  --    Always-included if the rate is null AND it's the main service
  --    rate (this is the central "why don't I earn service commission?"
  --    question for wage staff).
  --    Conditionally included: niche 0-rate categories only if a recent
  --    line for this staff falls into that category.
  -- ===========================================================================

  -- Main service (only if missing and the plan style is wage / none).
  IF v_rate_service IS NULL THEN
    v_not_eligible_sections := v_not_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'service',
      'label',    'Salon services',
      'plain_english',
        CASE v_plan_style
          WHEN 'wage'       THEN 'You are paid hourly for salon service work, so service commission does not apply on your ' || v_plan_label_friendly || ' plan.'
          WHEN 'contractor' THEN 'Your current ' || v_plan_label_friendly || ' plan does not pay a separate service commission percentage.'
          WHEN 'none'       THEN 'No remuneration plan is set, so no service commission applies.'
          ELSE 'Your current ' || v_plan_label_friendly || ' plan does not pay service commission.'
        END
    ))::jsonb;
  END IF;

  -- Retail (only if missing AND staff has recent retail-ish activity OR
  -- the plan has no rates at all; otherwise we leave it out to keep the
  -- section short).
  IF v_rate_retail IS NULL AND v_plan_style = 'none' THEN
    v_not_eligible_sections := v_not_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'retail_product',
      'label',    'Retail products',
      'plain_english', 'No remuneration plan is set, so no retail commission applies.'
    ))::jsonb;
  END IF;

  -- Treatment / professional products (only if a recent line for this
  -- staff actually fell into that bucket).
  IF v_rate_professional IS NULL
     AND ('professional_product' = ANY (v_recent_categories) OR v_plan_style = 'none')
  THEN
    v_not_eligible_sections := v_not_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'professional_product',
      'label',    'Treatment / professional products',
      'plain_english',
        CASE v_plan_style
          WHEN 'none' THEN 'No remuneration plan is set, so no commission applies.'
          ELSE 'Your current ' || v_plan_label_friendly || ' plan does not pay commission on treatment or professional product lines.'
        END
    ))::jsonb;
  END IF;

  -- Toner added to another service.
  IF v_rate_toner IS NULL
     AND ('toner_with_other_service' = ANY (v_recent_categories) OR v_plan_style = 'none')
  THEN
    v_not_eligible_sections := v_not_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'toner_with_other_service',
      'label',    'Toners added to another service',
      'plain_english',
        CASE v_plan_style
          WHEN 'none' THEN 'No remuneration plan is set, so no commission applies.'
          ELSE 'Your current ' || v_plan_label_friendly || ' plan does not pay commission on toner lines.'
        END
    ))::jsonb;
  END IF;

  -- Extension product.
  IF v_rate_ext_product IS NULL
     AND ('extensions_product' = ANY (v_recent_categories) OR v_plan_style = 'none')
  THEN
    v_not_eligible_sections := v_not_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'extensions_product',
      'label',    'Extension hair / product',
      'plain_english',
        CASE v_plan_style
          WHEN 'none' THEN 'No remuneration plan is set, so no commission applies.'
          ELSE 'Your current ' || v_plan_label_friendly || ' plan does not pay commission on extension hair or product lines.'
        END
    ))::jsonb;
  END IF;

  -- Extension service / labour.
  IF v_rate_ext_service IS NULL
     AND ('extensions_service' = ANY (v_recent_categories) OR v_plan_style = 'none')
  THEN
    v_not_eligible_sections := v_not_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'extensions_service',
      'label',    'Extension service / labour',
      'plain_english',
        CASE v_plan_style
          WHEN 'none' THEN 'No remuneration plan is set, so no commission applies.'
          ELSE 'Your current ' || v_plan_label_friendly || ' plan does not pay commission on extension labour.'
        END
    ))::jsonb;
  END IF;

  -- Voucher sales (always relevant).
  v_not_eligible_sections := v_not_eligible_sections || jsonb_build_array(jsonb_build_object(
    'category', 'voucher_sales',
    'label',    'Voucher sales',
    'plain_english',
      'Voucher sales do not earn commission when sold because they are prepayments. When a voucher is later used, the actual service or product is treated normally.'
  ))::jsonb;

  -- Catch-all for the named exclusions.
  v_not_eligible_sections := v_not_eligible_sections || jsonb_build_array(jsonb_build_object(
    'category', 'other_non_commission_items',
    'label',    'Other non-commission items',
    'plain_english',
      'Coffee, green fees, redos, training items and unclassified items do not earn commission.'
  ))::jsonb;

  -- ===========================================================================
  -- 8. Plan summary (new friendlier wording).
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

  -- Legacy "important_notes" (kept on the envelope for any old client
  -- code, but the redesigned staff page does not render them). We keep
  -- the structured shape from v3 so the type contract does not break.
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
  -- 9. Legacy rate cards (kept for backwards compatibility; the staff
  --    page no longer uses these).
  -- ===========================================================================
  v_rate_cards := jsonb_build_array(
    jsonb_build_object(
      'label',    'Salon services',
      'category', 'service',
      'rate',     v_rate_service,
      'has_rate', v_rate_service IS NOT NULL,
      'plain_english',
        CASE WHEN v_rate_service IS NULL
          THEN 'You are paid wages for salon services on this plan. Retail product commission may still apply.'
          ELSE 'You earn this rate on eligible salon services.'
        END
    ),
    jsonb_build_object(
      'label',    'Retail products',
      'category', 'retail_product',
      'rate',     v_rate_retail,
      'has_rate', v_rate_retail IS NOT NULL,
      'plain_english',
        CASE WHEN v_rate_retail IS NULL
          THEN 'Your current plan does not pay commission on take-home retail products.'
          ELSE 'You earn this rate on eligible take-home retail products.'
        END
    ),
    jsonb_build_object(
      'label',    'Professional / treatment products',
      'category', 'professional_product',
      'rate',     v_rate_professional,
      'has_rate', v_rate_professional IS NOT NULL,
      'plain_english',
        CASE WHEN v_rate_professional IS NULL
          THEN 'Your current plan does not pay commission on treatment or professional product lines.'
          ELSE 'You earn this rate on treatment / professional products (including items tagged with a *).'
        END
    ),
    jsonb_build_object(
      'label',    'Toner added to another service',
      'category', 'toner_with_other_service',
      'rate',     v_rate_toner,
      'has_rate', v_rate_toner IS NOT NULL,
      'plain_english',
        CASE WHEN v_rate_toner IS NULL
          THEN 'Your current plan does not have a separate toner-with-other-service rate.'
          ELSE 'You earn this rate on toner added to another service.'
        END
    ),
    jsonb_build_object(
      'label',    'Extensions, hair / product',
      'category', 'extensions_product',
      'rate',     v_rate_ext_product,
      'has_rate', v_rate_ext_product IS NOT NULL,
      'plain_english',
        CASE WHEN v_rate_ext_product IS NULL
          THEN 'Your current plan does not have a separate extensions hair / product rate.'
          ELSE 'You earn this rate on extension hair or bonded extension product.'
        END
    ),
    jsonb_build_object(
      'label',    'Extensions, service / labour',
      'category', 'extensions_service',
      'rate',     v_rate_ext_service,
      'has_rate', v_rate_ext_service IS NOT NULL,
      'plain_english',
        CASE WHEN v_rate_ext_service IS NULL
          THEN 'Your current plan does not have a separate extensions labour rate.'
          ELSE 'You earn this rate on extension install / removal / maintenance labour.'
        END
    )
  );

  -- ===========================================================================
  -- 10. Full product classification table (legacy "classification_table",
  --     and new "admin_full_product_guide" returned only when elevated).
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
                THEN 'Treated as a professional / treatment product (the trailing * tags it that way).'
              ELSE 'Configured as a professional / treatment product.'
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
            'Not classified yet. No commission until it is reviewed and mapped.'
          ELSE 'Not currently mapped to a commission category.'
        END
    )
    ORDER BY d.name
  ), '[]'::jsonb)
    INTO v_classification
  FROM derived d;

  -- Admin-only mirror: empty list for non-elevated callers.
  IF v_elevated THEN
    v_admin_full_guide := v_classification;
  ELSE
    v_admin_full_guide := '[]'::jsonb;
  END IF;

  -- Legacy exclusions and special cases preserved as empty stubs (the
  -- staff page no longer reads them). Kept on the envelope so the type
  -- contract does not break.
  v_exclusions := '[]'::jsonb;
  v_special    := '[]'::jsonb;
  v_examples   := '[]'::jsonb;

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
    'not_eligible_sections', v_not_eligible_sections,
    'recent_items_to_be_aware_of', v_recent_items,
    'recent_lookback_days',  90,
    'admin_full_product_guide',    v_admin_full_guide,

    -- Legacy fields (kept for backwards compatibility).
    'rate_cards',            v_rate_cards,
    'classification_table',  v_classification,
    'exclusions',            v_exclusions,
    'special_cases',         v_special,
    'examples',              v_examples,

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
  'Read-only Commission Guide for staff (v4 personalised, 20260828120800). '
  'Returns eligible_sections (categories with rate > 0 on this plan), '
  'not_eligible_sections (only the categories relevant to this staff: '
  'missing main service rate, voucher_sales catch-all, other_non_commission '
  'catch-all, plus any 0-rate niche category with a recent line for this '
  'staff), recent_items_to_be_aware_of (named items the staff has been '
  'involved in over the last 90 days that have a special rule or no-commission '
  'treatment, classified using v_commission_calculations_core.commission_category_final), '
  'and admin_full_product_guide (full classification list, empty for non-elevated callers). '
  'Legacy fields (rate_cards, classification_table, exclusions, special_cases, '
  'examples) are still returned for backwards compatibility but are no longer '
  'rendered on the staff page. No payroll, commission, rate, Product Configuration, '
  'voucher, KPI, or contractor-invoice logic is changed.';
