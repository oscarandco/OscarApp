-- Staff-facing Commission Guide.
--
-- Adds:
--   1. 'commission_guide' page id to public.role_page_permissions CHECK +
--      seeds defaults (all roles 'full' except reception/reception_uat which
--      get 'none'). Expands the update_role_page_permission allowlist.
--   2. public.get_staff_commission_guide(p_staff_member_id, p_as_of_date)
--      read-only RPC returning a jsonb envelope used by the new UI page.
--
-- The RPC is built from live data:
--   * effective staff profile from public.staff_profile_at(uuid, date)
--   * plan + rates from public.remuneration_plans /
--     public.remuneration_plan_rates
--   * product classification from public.product_master (the table the
--     Product Configuration admin page edits — column names are
--     product_description / system_type / product_type)
--
-- This migration does NOT change commission formulas, payroll views,
-- KPI calculations, contractor invoice logic, voucher exclusion,
-- saved invoices, or Product Configuration logic.

-- ---------------------------------------------------------------------------
-- 1) Extend the role_page_permissions page_id CHECK constraint.
-- ---------------------------------------------------------------------------
ALTER TABLE public.role_page_permissions
  DROP CONSTRAINT IF EXISTS role_page_permissions_page_id_check;

ALTER TABLE public.role_page_permissions
  ADD CONSTRAINT role_page_permissions_page_id_check CHECK (
    page_id IN (
      'my_payroll',
      'guest_quote',
      'previous_quotes',
      'kpi_dashboard',
      'weekly_payroll',
      'commission_breakdown',
      'imports',
      'staff',
      'products',
      'quotes',
      'remuneration',
      'access',
      'role_permissions',
      'contractor_invoices',
      'business_settings',
      'commission_guide'
    )
  );

-- ---------------------------------------------------------------------------
-- 2) Seed defaults for the new page id.
--    * Reception (and reception_uat) do not earn commission, so 'none'.
--    * All other roles get 'full' — each user only ever sees data for
--      themselves unless they pass private.user_has_elevated_access(),
--      which gates the staff picker inside the RPC.
--    ON CONFLICT DO NOTHING so environments that have already been
--    customised are not overwritten.
-- ---------------------------------------------------------------------------
INSERT INTO public.role_page_permissions (page_id, role_key, access_level)
VALUES
  ('commission_guide', 'assistant',      'full'),
  ('commission_guide', 'stylist',        'full'),
  ('commission_guide', 'reception',      'none'),
  ('commission_guide', 'manager',        'full'),
  ('commission_guide', 'assistant_uat',  'full'),
  ('commission_guide', 'stylist_uat',    'full'),
  ('commission_guide', 'reception_uat',  'none'),
  ('commission_guide', 'manager_uat',    'full'),
  ('commission_guide', 'admin',          'full')
ON CONFLICT (page_id, role_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3) Expand update_role_page_permission's allowlist (mirror the new id).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_role_page_permission(
  p_page_id text,
  p_role_key text,
  p_access_level text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_norm_page text;
  v_norm_role text;
  v_norm_level text;
  v_row public.role_page_permissions%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF NOT (SELECT private.user_can_manage_access_mappings()) THEN
    RAISE EXCEPTION 'Forbidden' USING ERRCODE = '42501';
  END IF;

  v_norm_page  := lower(trim(COALESCE(p_page_id, '')));
  v_norm_role  := lower(trim(COALESCE(p_role_key, '')));
  v_norm_level := lower(trim(COALESCE(p_access_level, '')));

  IF v_norm_page = '' OR v_norm_role = '' OR v_norm_level = '' THEN
    RAISE EXCEPTION 'page_id, role_key, and access_level are required';
  END IF;

  IF v_norm_role NOT IN (
    'assistant','stylist','reception','manager',
    'assistant_uat','stylist_uat','reception_uat','manager_uat','admin'
  ) THEN
    RAISE EXCEPTION 'Invalid role_key';
  END IF;

  IF v_norm_level NOT IN ('none', 'view', 'full') THEN
    RAISE EXCEPTION 'Invalid access_level';
  END IF;

  IF v_norm_page NOT IN (
    'my_payroll','guest_quote','previous_quotes','kpi_dashboard',
    'weekly_payroll','commission_breakdown','imports','staff','products',
    'quotes','remuneration','access','role_permissions','contractor_invoices',
    'business_settings','commission_guide'
  ) THEN
    RAISE EXCEPTION 'Invalid page_id';
  END IF;

  -- Lockout guards (unchanged).
  IF v_norm_page = 'role_permissions' AND v_norm_role = 'admin' AND v_norm_level <> 'full' THEN
    RAISE EXCEPTION 'Admin must retain Full access to Role permissions';
  END IF;

  IF v_norm_page = 'access' AND v_norm_role = 'admin' AND v_norm_level = 'none' THEN
    RAISE EXCEPTION 'Admin must retain at least View access to Access';
  END IF;

  INSERT INTO public.role_page_permissions (page_id, role_key, access_level)
  VALUES (v_norm_page, v_norm_role, v_norm_level)
  ON CONFLICT (page_id, role_key)
  DO UPDATE SET access_level = EXCLUDED.access_level, updated_at = now()
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

ALTER FUNCTION public.update_role_page_permission(text, text, text) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.update_role_page_permission(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_role_page_permission(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_role_page_permission(text, text, text) TO service_role;


-- ---------------------------------------------------------------------------
-- 4) public.get_staff_commission_guide(p_staff_member_id, p_as_of_date)
--
-- Returns a single jsonb envelope. The RPC is read-only and SECURITY DEFINER:
--
--   * Caller must be authenticated.
--   * Caller must have at least 'view' on the 'commission_guide' page.
--   * p_staff_member_id may be NULL -> resolves to the caller's own
--     staff_member_user_access.staff_member_id.
--   * If p_staff_member_id is supplied AND not the caller's own staff
--     id, caller must also have elevated access.
--
-- The envelope shape is documented in the page's TypeScript types
-- (src/features/commission-guide/types/commissionGuide.ts). Keep them
-- in sync when you change keys here.
-- ---------------------------------------------------------------------------
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

  -- Caller's own staff_member_id (may be null for purely-elevated logins
  -- with no staff mapping, in which case they MUST supply p_staff_member_id).
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

  -- Self-or-elevated gate.
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

  -- 3. Effective profile at v_as_of. staff_profile_at returns
  --    SETOF staff_role_assignments (most recent matching row).
  SELECT *
    INTO v_profile
  FROM public.staff_profile_at(v_target, v_as_of)
  LIMIT 1;

  IF v_profile IS NULL OR v_profile.id IS NULL THEN
    -- No effective assignment for this date — fall back to current
    -- staff_members snapshot so the page is always useful.
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

  -- 4. Load plan row + build rates map.
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

  -- 5. Rate cards: one entry per category present on this plan, plus a
  --    placeholder entry for any "missing" category that staff might
  --    expect (e.g. wage plans without a service rate -> "no service
  --    commission on this plan"). Order matches the staff mental model:
  --    services first, then retail, professional, toner, extensions.
  v_rate_cards := jsonb_build_array(
    jsonb_build_object(
      'label',            'Salon services',
      'category',         'service',
      'rate',             v_rate_service,
      'has_rate',         v_rate_service IS NOT NULL,
      'plain_english',
        CASE
          WHEN v_rate_service IS NULL
            THEN 'This plan does not pay commission on standard salon services. Wage-based plans use this setup.'
          ELSE 'Standard salon services are paid at this rate of the ex-GST sale value.'
        END
    ),
    jsonb_build_object(
      'label',            'Retail products',
      'category',         'retail_product',
      'rate',             v_rate_retail,
      'has_rate',         v_rate_retail IS NOT NULL,
      'plain_english',
        CASE
          WHEN v_rate_retail IS NULL
            THEN 'This plan does not pay commission on retail products.'
          ELSE 'Retail products (take-home product sales) are paid at this rate.'
        END
    ),
    jsonb_build_object(
      'label',            'Professional / treatment products',
      'category',         'professional_product',
      'rate',             v_rate_professional,
      'has_rate',         v_rate_professional IS NOT NULL,
      'plain_english',
        CASE
          WHEN v_rate_professional IS NULL
            THEN 'This plan does not pay commission on professional / treatment products.'
          ELSE 'Treatment / professional products (items used during a service or treatments tagged with a *) are paid at this rate.'
        END
    ),
    jsonb_build_object(
      'label',            'Toner added to another service',
      'category',         'toner_with_other_service',
      'rate',             v_rate_toner,
      'has_rate',         v_rate_toner IS NOT NULL,
      'plain_english',
        CASE
          WHEN v_rate_toner IS NULL
            THEN 'This plan has no toner-with-other-service rate. Toner is paid at the standard service rate when applicable.'
          ELSE 'Toner added to another service is paid at this rate — different from the main service rate.'
        END
    ),
    jsonb_build_object(
      'label',            'Extensions — hair / product',
      'category',         'extensions_product',
      'rate',             v_rate_ext_product,
      'has_rate',         v_rate_ext_product IS NOT NULL,
      'plain_english',
        CASE
          WHEN v_rate_ext_product IS NULL
            THEN 'This plan has no separate extensions-product rate.'
          ELSE 'Extension hair / bonded extension product is paid at this rate.'
        END
    ),
    jsonb_build_object(
      'label',            'Extensions — service / labour',
      'category',         'extensions_service',
      'rate',             v_rate_ext_service,
      'has_rate',         v_rate_ext_service IS NOT NULL,
      'plain_english',
        CASE
          WHEN v_rate_ext_service IS NULL
            THEN 'This plan has no separate extensions-service rate.'
          ELSE 'Extension install / removal / maintenance labour is paid at this rate.'
        END
    )
  );

  -- 6. Classification table from public.product_master. The derivation
  --    here mirrors public.v_sales_transactions_powerbi_parity:
  --      * '*' suffix on product name -> professional_product
  --      * configured product_type = 'Professional Product' -> professional_product
  --      * configured product_type = 'Retail Product'       -> retail_product
  --      * else system_type 'Service'  -> service
  --      * else system_type 'Retail'   -> retail_product
  --      * else system_type 'Voucher'  -> no_commission_voucher
  --      * else system_type 'Unclassified' -> no_commission_unclassified
  WITH derived AS (
    SELECT
      pm.product_description AS name,
      pm.system_type,
      pm.product_type,
      CASE
        WHEN btrim(pm.product_description) LIKE '%*'
          THEN 'professional_product'
        WHEN lower(btrim(coalesce(pm.product_type, ''))) = 'professional product'
          THEN 'professional_product'
        WHEN lower(btrim(coalesce(pm.product_type, ''))) = 'retail product'
          THEN 'retail_product'
        WHEN lower(btrim(coalesce(pm.system_type, ''))) = 'service'
          THEN 'service'
        WHEN lower(btrim(coalesce(pm.system_type, ''))) = 'retail'
          THEN 'retail_product'
        WHEN lower(btrim(coalesce(pm.system_type, ''))) = 'voucher'
          THEN 'no_commission_voucher'
        WHEN lower(btrim(coalesce(pm.system_type, ''))) = 'unclassified'
          THEN 'no_commission_unclassified'
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
            WHEN 'professional_product' THEN
              CASE
                WHEN btrim(d.name) LIKE '%*'
                  THEN 'Although this can look like a service, the trailing * tags it as a professional product, so payroll pays the professional-product rate.'
                ELSE
                  'Product Configuration classifies this as a professional / treatment product, so payroll pays the professional-product rate.'
              END
            WHEN 'service' THEN
              'Salon service. Paid at the standard service rate for your plan.'
            WHEN 'retail_product' THEN
              'Retail product. Paid at the retail rate for your plan.'
            WHEN 'no_commission_voucher' THEN
              'Voucher line. No commission is paid when the voucher itself is sold (it''s a prepayment, not a completed service or product).'
            WHEN 'no_commission_unclassified' THEN
              'Currently unclassified in Product Configuration. No commission until a system / product type is set.'
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

  -- 7. Exclusions / no-commission table. These are sale-level rules in
  --    v_sales_transactions_powerbi_parity (not driven by product_master).
  v_exclusions := jsonb_build_array(
    jsonb_build_object(
      'label',               'Voucher sales',
      'commission_category', 'no_commission_voucher',
      'plain_english',
        'Voucher sales do not earn commission when sold because they are prepayments. Commission may still be earned later when the voucher is used to pay for an actual commissionable service or product.'
    ),
    jsonb_build_object(
      'label',               'Green fee',
      'commission_category', 'no_commission_greenfee',
      'plain_english',
        'Environmental / green fee line. No commission — this is a small fee added to the bill, not paid work.'
    ),
    jsonb_build_object(
      'label',               'Redo / rework',
      'commission_category', 'no_commission_redo',
      'plain_english',
        'A redo or rework of an earlier service. No commission — the original service was already commissioned.'
    ),
    jsonb_build_object(
      'label',               'Training product',
      'commission_category', 'no_commission_trainingproduct',
      'plain_english',
        'Items sold at staff / training pricing. No commission.'
    ),
    jsonb_build_object(
      'label',               'Miscellaneous product',
      'commission_category', 'no_commission_miscellaneousproduct',
      'plain_english',
        'Generic miscellaneous line. No commission unless reclassified in Product Configuration.'
    ),
    jsonb_build_object(
      'label',               'Unclassified imports',
      'commission_category', 'no_commission_unclassified',
      'plain_english',
        'Imported lines that are not yet mapped in Product Configuration. No commission until they are classified.'
    ),
    jsonb_build_object(
      'label',               'Coffee / refunds / other non-commission lines',
      'commission_category', 'no_commission_unclassified',
      'plain_english',
        'Sundry, refunds, and similar lines fall through to the unclassified / non-commission bucket and do not earn commission.'
    )
  );

  -- 8. Special-cases / gotchas table. These are payroll-level statuses
  --    or sale-level header rules that staff often ask about.
  v_special := jsonb_build_array(
    jsonb_build_object(
      'label',               'Asterisk (*) on the product name',
      'rule_key',            'asterisk_suffix_professional_product',
      'plain_english',
        'A trailing * on the product name forces it to be paid as a professional product, even if the underlying item looks like a service.'
    ),
    jsonb_build_object(
      'label',               'Toner added to another service',
      'rule_key',            'toner_with_other_service',
      'plain_english',
        'When toner is added on top of another service, the line is classified as Toner with other service and paid at the toner/product rate — not the main service rate.'
    ),
    jsonb_build_object(
      'label',               'Bonded extensions / extensions bonds',
      'rule_key',            'extensions_product_header',
      'plain_english',
        'Bonded extension product (hair, bonds) is paid at the extensions-product rate, separately from the extension labour itself.'
    ),
    jsonb_build_object(
      'label',               'Extensions install / removal / maintenance (Tapes)',
      'rule_key',            'extensions_service_header',
      'plain_english',
        'Extension service labour (install, removal, maintenance, tapes) is paid at the extensions-service rate, separately from the extension product.'
    ),
    jsonb_build_object(
      'label',               'Voucher used to pay for a commissionable item',
      'rule_key',            'voucher_payment_not_blocking',
      'plain_english',
        'If a guest pays for a real service or product using a voucher, that service / product still earns its normal commission. The voucher payment method does not block commission on the actual sale.'
    ),
    jsonb_build_object(
      'label',               'Zero-value commission rows',
      'rule_key',            'zero_value_commission_row',
      'plain_english',
        'Some valid commissionable lines settle at $0 commission (free, fully discounted, or rate * value = $0). These still appear as commissioned rows in payroll, just with $0 commission.'
    ),
    jsonb_build_object(
      'label',               'Held / needs review',
      'rule_key',            'hold_unexpected_issue',
      'plain_english',
        'Occasionally a row is held back for admin review (an unexpected issue with the import or configuration). It is not paid yet — once the admin clears the issue, it flows into the next pay run.'
    )
  );

  -- 9. Examples — generated from the actual plan rates so the numbers
  --    always match the rate cards above. Categories without a rate
  --    on this plan are skipped.
  v_examples := jsonb_build_array();

  IF v_rate_service IS NOT NULL THEN
    v_examples := v_examples || jsonb_build_array(jsonb_build_object(
      'label',          'Standard service',
      'sale_ex_gst',    100,
      'rate',           v_rate_service,
      'commission',     round(100 * v_rate_service, 2),
      'category',       'service',
      'plain_english',
        'If an eligible salon service is $100 ex GST, your commission is $'
        || trim(to_char(round(100 * v_rate_service, 2), 'FM999999990.00')) || '.'
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
        'If a retail product is $30 ex GST, your commission is $'
        || trim(to_char(round(30 * v_rate_retail, 2), 'FM999999990.00')) || '.'
    ))::jsonb;
  END IF;

  IF v_rate_professional IS NOT NULL THEN
    v_examples := v_examples || jsonb_build_array(jsonb_build_object(
      'label',          'Professional product (e.g. *-tagged treatment)',
      'sale_ex_gst',    40,
      'rate',           v_rate_professional,
      'commission',     round(40 * v_rate_professional, 2),
      'category',       'professional_product',
      'plain_english',
        'If a professional / treatment product is $40 ex GST, your commission is $'
        || trim(to_char(round(40 * v_rate_professional, 2), 'FM999999990.00')) || '.'
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
        'If toner added to another service is $30 ex GST, your commission is $'
        || trim(to_char(round(30 * v_rate_toner, 2), 'FM999999990.00')) || '.'
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
        'If $250 of extension hair / product is sold ex GST, your commission is $'
        || trim(to_char(round(250 * v_rate_ext_product, 2), 'FM999999990.00')) || '.'
    ))::jsonb;
  END IF;

  IF v_rate_ext_service IS NOT NULL THEN
    v_examples := v_examples || jsonb_build_array(jsonb_build_object(
      'label',          'Extension service / labour',
      'sale_ex_gst',    150,
      'rate',           v_rate_ext_service,
      'commission',     round(150 * v_rate_ext_service, 2),
      'category',       'extensions_service',
      'plain_english',
        'If $150 of extension service / labour is sold ex GST, your commission is $'
        || trim(to_char(round(150 * v_rate_ext_service, 2), 'FM999999990.00')) || '.'
    ))::jsonb;
  END IF;

  -- Voucher example — always included; the numbers reference v_rate_service
  -- when it exists, otherwise it is purely qualitative.
  v_examples := v_examples || jsonb_build_array(jsonb_build_object(
    'label',          'Voucher sold today, used later for a service',
    'sale_ex_gst',    0,
    'rate',           NULL,
    'commission',     0,
    'category',       'no_commission_voucher',
    'plain_english',
      CASE
        WHEN v_rate_service IS NULL THEN
          'Selling a $50 voucher today earns $0 commission (it''s a prepayment). When that voucher is later used to pay for an eligible service, the service still earns its normal commission.'
        ELSE
          'Selling a $50 voucher today earns $0 commission (it''s a prepayment). When that voucher is later used to pay for a $100 ex-GST service, that service still earns $'
          || trim(to_char(round(100 * v_rate_service, 2), 'FM999999990.00'))
          || ' commission.'
      END
  ))::jsonb;

  -- 10. Plan summary headline + plain English + important notes.
  v_headline := CASE
    WHEN v_eff_role IS NOT NULL AND v_eff_plan_name IS NOT NULL
      THEN v_eff_role || ' — ' || v_eff_plan_name
    WHEN v_eff_plan_name IS NOT NULL
      THEN v_eff_plan_name
    WHEN v_eff_role IS NOT NULL
      THEN v_eff_role
    ELSE 'Commission setup'
  END;

  v_plain_english := CASE
    WHEN v_eff_plan_name IS NULL
      THEN 'You are not currently on a remuneration plan, so no commission applies. If you think this is wrong, please talk to your manager.'
    WHEN v_rate_service IS NULL AND v_rate_retail IS NOT NULL
      THEN 'You''re on the ' || v_eff_plan_name || ' plan. This is a wage-based plan — standard salon services don''t earn extra commission, but retail products and certain other categories may.'
    WHEN v_rate_service IS NOT NULL
      THEN 'You''re on the ' || v_eff_plan_name || ' plan. Most eligible salon services are paid at '
           || trim(to_char(round(v_rate_service * 100, 0), 'FM999990')) || '%, with separate rates for retail, professional products, toner, and extensions where they apply.'
    ELSE 'You''re on the ' || v_eff_plan_name || ' plan. Commission applies to the categories listed below.'
  END;

  v_notes := jsonb_build_array();

  v_notes := v_notes || jsonb_build_array(
    'Voucher sales do not earn commission when sold (they are prepayments). Commission is paid when the voucher is later used for a real service or product.'
  )::jsonb;

  v_notes := v_notes || jsonb_build_array(
    'Some items appear one way in the imported Kitomba data but Oscar & Co classifies them differently for payroll. The Product Configuration page controls this mapping.'
  )::jsonb;

  v_notes := v_notes || jsonb_build_array(
    'Some treatments appear like services, but payroll treats them as professional products and pays the product rate.'
  )::jsonb;

  v_notes := v_notes || jsonb_build_array(
    'Toner added to another service is paid at the toner/product rate, not the main service rate.'
  )::jsonb;

  v_notes := v_notes || jsonb_build_array(
    'Extension product/hair and extension service/labour are handled separately.'
  )::jsonb;

  IF v_plan.id IS NOT NULL AND v_plan.can_use_assistants = true THEN
    v_notes := v_notes || jsonb_build_array(
      'This plan supports using an assistant on commissionable services.'
    )::jsonb;
  END IF;

  IF v_plan.id IS NOT NULL AND COALESCE(btrim(v_plan.conditions_text), '') <> '' THEN
    v_notes := v_notes || jsonb_build_array(
      'Plan conditions: ' || btrim(v_plan.conditions_text)
    )::jsonb;
  END IF;

  v_summary := jsonb_build_object(
    'headline',         v_headline,
    'plain_english',    v_plain_english,
    'important_notes',  v_notes,
    'using_fallback_to_current_profile', v_using_fallback
  );

  -- 11. Final envelope.
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
  'Read-only Commission Guide for staff. Returns a jsonb envelope with the effective profile (via staff_profile_at), plain-English plan summary, rate cards, product classification table (from product_master), exclusions, gotchas, and worked examples. Caller must have at least view access on the commission_guide page; non-elevated callers can only view their own staff member id.';
