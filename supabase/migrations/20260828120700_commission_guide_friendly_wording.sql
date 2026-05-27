-- Commission Guide v3 — staff-facing wording pass.
--
-- Replaces public.get_staff_commission_guide with a version whose wording
-- is friendlier for staff and whose `important_notes` are structured as
-- {heading, body} objects (the page renders them as headed cards).
--
-- Behavioural fixes / changes:
--   * Plain-English explanations for every classification_table category
--     now use the staff-facing wording the design pass requested.
--   * "0%" / "paid at 0%" phrasing is removed for non-payable rows; rows
--     fall back to "No commission" with a one-line reason instead.
--   * The plan summary headline + plain English now adapts to three
--     well-known plan styles (Wage / Contractor / Commission) and never
--     says "salon services are paid at 0%".
--   * `important_notes` is now an array of {heading, body} objects so the
--     UI can render bold headings without parsing inline markdown. The
--     six required headings are always present, with the Assistant work
--     note included when the plan supports assistants.
--   * Examples have been rewritten so the voucher example no longer
--     implies all voucher redemptions earn $0. Wage plans also get a
--     plain-English note attached to the voucher example.
--
-- Classification precedence (unchanged from 20260828120600 — kept here
-- for clarity):
--   1. Name overrides: green fee | redo | training product | miscellaneous | coffee
--   2. system_type Voucher / Unclassified
--   3. Asterisk suffix => professional_product
--   4. Explicit product_type Professional Product / Retail Product
--   5. product_type = '-' => no_commission_unclassified
--   6. system_type fallback Service / Retail
--
-- This migration does NOT change commission formulas, payroll views,
-- KPI calculations, contractor invoice logic, voucher exclusion, saved
-- invoices, or Product Configuration. It only replaces the read-only
-- Commission Guide RPC's wording layer.

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

  v_rate_cards     jsonb;
  v_classification jsonb;
  v_exclusions     jsonb;
  v_special        jsonb;
  v_examples       jsonb;
  v_summary        jsonb;
  v_notes          jsonb;

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

  -- 4b. Detect plan "style" for friendlier headline / summary wording.
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

  -- 5. Rate cards — friendlier wording for the "no rate on this plan"
  --    case (no more "paid at 0%").
  v_rate_cards := jsonb_build_array(
    jsonb_build_object(
      'label',    'Salon services',
      'category', 'service',
      'rate',     v_rate_service,
      'has_rate', v_rate_service IS NOT NULL,
      'plain_english',
        CASE
          WHEN v_rate_service IS NULL
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
        CASE
          WHEN v_rate_retail IS NULL
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
        CASE
          WHEN v_rate_professional IS NULL
            THEN 'Your current plan does not pay commission on treatment / professional product lines.'
          ELSE 'You earn this rate on treatment / professional products (including items tagged with a *).'
        END
    ),
    jsonb_build_object(
      'label',    'Toner added to another service',
      'category', 'toner_with_other_service',
      'rate',     v_rate_toner,
      'has_rate', v_rate_toner IS NOT NULL,
      'plain_english',
        CASE
          WHEN v_rate_toner IS NULL
            THEN 'Your current plan does not have a separate toner-with-other-service rate.'
          ELSE 'You earn this rate on toner added to another service — separate from the main service rate.'
        END
    ),
    jsonb_build_object(
      'label',    'Extensions — hair / product',
      'category', 'extensions_product',
      'rate',     v_rate_ext_product,
      'has_rate', v_rate_ext_product IS NOT NULL,
      'plain_english',
        CASE
          WHEN v_rate_ext_product IS NULL
            THEN 'Your current plan does not have a separate extensions hair / product rate.'
          ELSE 'You earn this rate on extension hair / bonded extension product.'
        END
    ),
    jsonb_build_object(
      'label',    'Extensions — service / labour',
      'category', 'extensions_service',
      'rate',     v_rate_ext_service,
      'has_rate', v_rate_ext_service IS NOT NULL,
      'plain_english',
        CASE
          WHEN v_rate_ext_service IS NULL
            THEN 'Your current plan does not have a separate extensions labour rate.'
          ELSE 'You earn this rate on extension install / removal / maintenance labour.'
        END
    )
  );

  -- 6. Classification table — same precedence as 20260828120600,
  --    refreshed plain-English wording per spec.
  WITH derived AS (
    SELECT
      pm.product_description AS name,
      pm.system_type,
      pm.product_type,
      CASE
        -- (A) Name-based no-commission overrides (mirror parity view).
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

        -- (B) system_type Voucher / Unclassified.
        WHEN lower(btrim(coalesce(pm.system_type, ''))) = 'voucher'
          THEN 'no_commission_voucher'
        WHEN lower(btrim(coalesce(pm.system_type, ''))) = 'unclassified'
          THEN 'no_commission_unclassified'

        -- (C) Asterisk suffix => professional_product.
        WHEN right(btrim(coalesce(pm.product_description, '')), 1) = '*'
          THEN 'professional_product'

        -- (D) Explicit product_type Professional / Retail.
        WHEN lower(btrim(coalesce(pm.product_type, ''))) = 'professional product'
          THEN 'professional_product'
        WHEN lower(btrim(coalesce(pm.product_type, ''))) = 'retail product'
          THEN 'retail_product'

        -- (E) product_type = '-' => no_commission_unclassified.
        WHEN lower(btrim(coalesce(pm.product_type, ''))) = '-'
          THEN 'no_commission_unclassified'

        -- (F) system_type fallback.
        WHEN lower(btrim(coalesce(pm.system_type, ''))) = 'service'
          THEN 'service'
        WHEN lower(btrim(coalesce(pm.system_type, ''))) = 'retail'
          THEN 'retail_product'

        ELSE NULL
      END AS commission_category
    FROM public.product_master pm
    WHERE pm.is_active = true
  )
  SELECT COALESCE(
    jsonb_agg(
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
            -- Payable categories.
            WHEN 'professional_product' THEN
              CASE
                WHEN right(btrim(coalesce(d.name, '')), 1) = '*'
                  THEN 'Treated as a professional / treatment product (the trailing * tags it that way), even if it can look like a service.'
                ELSE
                  'Product Configuration treats this as a professional / treatment product.'
              END
            WHEN 'service' THEN
              'Treated as a salon service.'
            WHEN 'retail_product' THEN
              'Treated as a take-home retail product.'

            -- No-commission categories.
            WHEN 'no_commission_voucher' THEN
              'Voucher sales are prepayments, not completed services or retail sales, so no commission is paid when the voucher is sold.'
            WHEN 'no_commission_greenfee' THEN
              'Green fees are not staff service sales, so no commission is paid.'
            WHEN 'no_commission_redo' THEN
              'Redo/rework lines are not treated as new commissionable sales.'
            WHEN 'no_commission_trainingproduct' THEN
              'Training items are excluded from commission.'
            WHEN 'no_commission_miscellaneousproduct' THEN
              CASE
                WHEN lower(btrim(coalesce(d.name, ''))) = 'coffee'
                  THEN 'Coffee is not treated as a hair service or retail product for commission.'
                ELSE
                  'Not treated as a hair service or retail product for commission.'
              END
            WHEN 'no_commission_unclassified' THEN
              'This item has not been classified yet. No commission is paid until it is reviewed and mapped.'

            ELSE
              'Not currently mapped to a commission category. Speak to the salon admin if you think this should earn commission.'
          END
      )
      ORDER BY d.name
    ),
    '[]'::jsonb
  )
    INTO v_classification
  FROM derived d;

  -- 7. "Items that do not earn commission" table (renamed in the UI).
  --    No internal Code column on the page — but the field is still
  --    returned for any future technical view.
  v_exclusions := jsonb_build_array(
    jsonb_build_object(
      'label',               'Voucher sales',
      'commission_category', 'no_commission_voucher',
      'plain_english',
        'Selling a voucher does not earn commission because it is a prepayment. When the voucher is later used to pay for an actual service or retail product, that item is treated normally.'
    ),
    jsonb_build_object(
      'label',               'Green fee',
      'commission_category', 'no_commission_greenfee',
      'plain_english',
        'Green fees are not staff service sales, so no commission is paid.'
    ),
    jsonb_build_object(
      'label',               'Redo / rework',
      'commission_category', 'no_commission_redo',
      'plain_english',
        'Redo/rework lines are not treated as new commissionable sales — the original service was already commissioned.'
    ),
    jsonb_build_object(
      'label',               'Training product',
      'commission_category', 'no_commission_trainingproduct',
      'plain_english',
        'Training items are excluded from commission.'
    ),
    jsonb_build_object(
      'label',               'Miscellaneous (including coffee)',
      'commission_category', 'no_commission_miscellaneousproduct',
      'plain_english',
        'Items like coffee and other generic miscellaneous lines are not treated as hair services or retail products for commission.'
    ),
    jsonb_build_object(
      'label',               'Unclassified items',
      'commission_category', 'no_commission_unclassified',
      'plain_english',
        'Items that have not been classified yet, or are marked with product type "-". No commission until they are reviewed and mapped.'
    )
  );

  -- 8. "Things that can affect commission" (renamed in the UI).
  v_special := jsonb_build_array(
    jsonb_build_object(
      'label',               'Asterisk (*) on the product name',
      'rule_key',            'asterisk_suffix_professional_product',
      'plain_english',
        'A trailing * on the product name treats it as a professional product, even if the item looks like a service.'
    ),
    jsonb_build_object(
      'label',               'Toner added to another service',
      'rule_key',            'toner_with_other_service',
      'plain_english',
        'Toner added on top of another service uses the toner/product rate, not the main service rate.'
    ),
    jsonb_build_object(
      'label',               'Bonded extensions / extensions bonds',
      'rule_key',            'extensions_product_header',
      'plain_english',
        'Bonded extension product (hair, bonds) uses the extensions product rate — separate from extension labour.'
    ),
    jsonb_build_object(
      'label',               'Extension labour (install / removal / maintenance / tapes)',
      'rule_key',            'extensions_service_header',
      'plain_english',
        'Extension labour uses the extensions labour rate — separate from extension product.'
    ),
    jsonb_build_object(
      'label',               'Voucher used to pay for a real service or product',
      'rule_key',            'voucher_payment_not_blocking',
      'plain_english',
        'If a guest pays for a service or product using a voucher, the actual item is treated normally. Voucher as a payment method does not block commission on the actual sale.'
    ),
    jsonb_build_object(
      'label',               'Zero-value commission rows',
      'rule_key',            'zero_value_commission_row',
      'plain_english',
        'Some commissionable lines settle at $0 commission (free or fully discounted). The row is still shown, just with no payable amount.'
    ),
    jsonb_build_object(
      'label',               'Held for review',
      'rule_key',            'hold_unexpected_issue',
      'plain_english',
        'Occasionally a row is held back for the admin to review. Once the issue is cleared, it flows into the next pay run.'
    )
  );

  -- 9. Examples — voucher example rewritten so it does NOT imply
  --    redemptions always earn $0.
  v_examples := jsonb_build_array();

  IF v_rate_service IS NOT NULL THEN
    v_examples := v_examples || jsonb_build_array(jsonb_build_object(
      'label',          'Standard salon service',
      'sale_ex_gst',    100,
      'rate',           v_rate_service,
      'commission',     round(100 * v_rate_service, 2),
      'category',       'service',
      'plain_english',
        'A $100 ex-GST eligible salon service earns $'
        || trim(to_char(round(100 * v_rate_service, 2), 'FM999999990.00'))
        || ' commission.'
    ))::jsonb;
  END IF;

  IF v_rate_retail IS NOT NULL THEN
    v_examples := v_examples || jsonb_build_array(jsonb_build_object(
      'label',          'Retail product',
      'sale_ex_gst',    30,
      'rate',           v_rate_retail,
      'commission',     round(30 * v_rate_retail, 2),
      'category',       'retail_product',
      'plain_english',
        'A $30 ex-GST eligible retail product earns $'
        || trim(to_char(round(30 * v_rate_retail, 2), 'FM999999990.00'))
        || ' commission.'
    ))::jsonb;
  END IF;

  IF v_rate_professional IS NOT NULL THEN
    v_examples := v_examples || jsonb_build_array(jsonb_build_object(
      'label',          'Treatment / professional product',
      'sale_ex_gst',    40,
      'rate',           v_rate_professional,
      'commission',     round(40 * v_rate_professional, 2),
      'category',       'professional_product',
      'plain_english',
        'A $40 ex-GST professional / treatment product earns $'
        || trim(to_char(round(40 * v_rate_professional, 2), 'FM999999990.00'))
        || ' commission.'
    ))::jsonb;
  END IF;

  IF v_rate_toner IS NOT NULL THEN
    v_examples := v_examples || jsonb_build_array(jsonb_build_object(
      'label',          'Toner added to another service',
      'sale_ex_gst',    30,
      'rate',           v_rate_toner,
      'commission',     round(30 * v_rate_toner, 2),
      'category',       'toner_with_other_service',
      'plain_english',
        'A $30 ex-GST toner added to another service earns $'
        || trim(to_char(round(30 * v_rate_toner, 2), 'FM999999990.00'))
        || ' commission at the toner rate.'
    ))::jsonb;
  END IF;

  IF v_rate_ext_product IS NOT NULL THEN
    v_examples := v_examples || jsonb_build_array(jsonb_build_object(
      'label',          'Extension hair / product',
      'sale_ex_gst',    250,
      'rate',           v_rate_ext_product,
      'commission',     round(250 * v_rate_ext_product, 2),
      'category',       'extensions_product',
      'plain_english',
        'A $250 ex-GST extension hair / product sale earns $'
        || trim(to_char(round(250 * v_rate_ext_product, 2), 'FM999999990.00'))
        || ' commission.'
    ))::jsonb;
  END IF;

  IF v_rate_ext_service IS NOT NULL THEN
    v_examples := v_examples || jsonb_build_array(jsonb_build_object(
      'label',          'Extension labour',
      'sale_ex_gst',    150,
      'rate',           v_rate_ext_service,
      'commission',     round(150 * v_rate_ext_service, 2),
      'category',       'extensions_service',
      'plain_english',
        'A $150 ex-GST extension labour line earns $'
        || trim(to_char(round(150 * v_rate_ext_service, 2), 'FM999999990.00'))
        || ' commission.'
    ))::jsonb;
  END IF;

  -- Voucher sold today.
  v_examples := v_examples || jsonb_build_array(jsonb_build_object(
    'label',          'Voucher sold',
    'sale_ex_gst',    50,
    'rate',           NULL,
    'commission',     0,
    'category',       'no_commission_voucher',
    'plain_english',
      'Sale: $50 voucher. Commission: No commission. Why: a voucher is a prepayment.'
  ))::jsonb;

  -- Voucher used later (deliberately NOT a $0 example).
  v_examples := v_examples || jsonb_build_array(jsonb_build_object(
    'label',          'Voucher used later',
    'sale_ex_gst',    NULL,
    'rate',           NULL,
    'commission',     NULL,
    'category',       'voucher_used_later',
    'plain_english',
      'If the voucher is later used to pay for an actual service or retail product, that actual item is treated normally. Whether commission is paid depends on your plan and the item sold.'
  ))::jsonb;

  -- Wage-plan reassurance example — only when the plan has no service rate.
  IF v_rate_service IS NULL AND v_eff_plan_name IS NOT NULL THEN
    v_examples := v_examples || jsonb_build_array(jsonb_build_object(
      'label',          'Your Wage plan and retail',
      'sale_ex_gst',    NULL,
      'rate',           NULL,
      'commission',     NULL,
      'category',       'wage_plan_note',
      'plain_english',
        'On your current ' || v_eff_plan_name ||
        ' plan, salon services do not earn service commission, but eligible retail products may still earn retail commission.'
    ))::jsonb;
  END IF;

  -- 10. Plan summary headline + plain English + structured notes.
  v_headline := CASE
    WHEN v_eff_role IS NOT NULL AND v_eff_plan_name IS NOT NULL
      THEN v_eff_role || ' — ' || v_eff_plan_name
    WHEN v_eff_plan_name IS NOT NULL
      THEN v_eff_plan_name
    WHEN v_eff_role IS NOT NULL
      THEN v_eff_role
    ELSE 'Commission setup'
  END;

  v_plain_english := CASE v_plan_style
    WHEN 'none' THEN
      'You are not currently on a remuneration plan, so no commission applies. If you think this is wrong, please talk to your manager.'
    WHEN 'wage' THEN
      'You are on the ' || v_eff_plan_name
        || ' plan. Salon services are paid through wages rather than service commission. You may still earn commission on eligible retail products, depending on the rules below.'
    WHEN 'contractor' THEN
      'You are on the ' || v_eff_plan_name
        || ' plan. Eligible services are paid at the contractor service rate, while products and special categories may use different rates.'
    ELSE
      'You are on the ' || v_eff_plan_name
        || ' plan. Eligible salon services, retail products, treatments, toners, and extension items use different rates. The guide below shows how each item is treated.'
  END;

  -- Structured important notes: each note is {heading, body}. Headings
  -- are stable strings (no markdown). The Assistant work note is always
  -- included; the body adapts when the plan supports assistants.
  v_notes := jsonb_build_array(
    jsonb_build_object(
      'heading', 'Vouchers',
      'body',
        'Selling a voucher does not earn commission because it is a prepayment. When the voucher is later used, the actual service or product is treated normally.'
    ),
    jsonb_build_object(
      'heading', 'Product setup matters',
      'body',
        'Some items come from Kitomba as one type, but Oscar & Co maps them differently for payroll. This is managed in Product Configuration.'
    ),
    jsonb_build_object(
      'heading', 'Treatments and professional products',
      'body',
        'Some treatments look like services, but are treated as professional products and use the product/treatment rate.'
    ),
    jsonb_build_object(
      'heading', 'Toners added to another service',
      'body',
        'Toner added to another service uses the toner/product rate, not the main service rate.'
    ),
    jsonb_build_object(
      'heading', 'Extensions',
      'body',
        'Extension hair/product and extension labour are treated separately.'
    ),
    jsonb_build_object(
      'heading', 'Assistant work',
      'body',
        CASE
          WHEN v_plan.id IS NOT NULL AND v_plan.can_use_assistants = true
            THEN 'Your plan supports using an assistant on commissionable services. If an assistant performs work for a stylist, commission may be paid to the stylist or to the assistant depending on the assistant''s role and pay plan at the time of the sale.'
          ELSE 'If an assistant performs work for a stylist, commission may be paid to the stylist or to the assistant depending on the assistant''s role and pay plan at the time of the sale.'
        END
    )
  );

  -- Optional extra note: plan conditions string if the salon admin set one.
  IF v_plan.id IS NOT NULL AND COALESCE(btrim(v_plan.conditions_text), '') <> '' THEN
    v_notes := v_notes || jsonb_build_array(jsonb_build_object(
      'heading', 'Plan conditions',
      'body',    btrim(v_plan.conditions_text)
    ))::jsonb;
  END IF;

  v_summary := jsonb_build_object(
    'headline',         v_headline,
    'plain_english',    v_plain_english,
    'important_notes',  v_notes,
    'plan_style',       v_plan_style,
    'using_fallback_to_current_profile', v_using_fallback
  );

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
    'plan_summary',         v_summary,
    'rate_cards',           v_rate_cards,
    'classification_table', v_classification,
    'exclusions',           v_exclusions,
    'special_cases',        v_special,
    'examples',             v_examples,
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
  'Read-only Commission Guide for staff (v3 wording pass 20260828120700). Same classification precedence as v2 (name overrides -> system_type Voucher/Unclassified -> asterisk -> product_type Professional/Retail -> product_type ''-'' -> system_type fallback). v3 returns structured important_notes ({heading, body}), a plan_summary.plan_style field (wage/contractor/commission/none) the UI uses to pick wording, friendlier rate-card and classification-row plain English (no more "paid at 0%"), and a voucher example that does not imply all redemptions earn $0.';
