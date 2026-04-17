-- Reviewable seed script for the real Guest Quote configuration.
--
-- THIS IS NOT A MIGRATION. Do not place it under supabase/migrations/.
-- Review / edit / apply manually once all remaining placeholders are resolved.
--
-- Sources of truth:
--   * STRUCTURE: the three stylist-quote screenshots supplied with the rebuild
--                request (sections, row names, input/pricing types).
--   * PRICING:   the final confirmed pricing decisions from the salon review
--                (supersedes both the screenshots and the earlier pricing
--                table wherever they disagreed).
--
-- SCOPE
--   quote_settings             (updates the singleton row; does not reinsert)
--   quote_sections             (14 sections in the agreed display order)
--   quote_services             (84 services)
--   quote_service_options      (option rows for option/radio/dropdown services)
--   quote_service_role_prices  (per-role prices only for truly role-priced rows)
--
-- RE-RUN SAFETY
--   Not idempotent. Aborts up front if quote_sections already has any rows.
--   To re-seed from scratch, run (in this exact order, same transaction):
--     DELETE FROM public.quote_service_role_prices;
--     DELETE FROM public.quote_service_options;
--     DELETE FROM public.quote_services;
--     DELETE FROM public.quote_sections;
--   then re-run this script.
--
-- HOW TO RUN AFTER REVIEW
--   psql "$SUPABASE_DB_URL" -f supabase/seeds/quote_config_real_data.sql
--   -- or paste into the Supabase SQL editor as a single statement.

BEGIN;

-- ---------------------------------------------------------------------------
-- 0. Safety guard.
-- ---------------------------------------------------------------------------
DO $abort$
BEGIN
  IF (SELECT count(*) FROM public.quote_sections) > 0 THEN
    RAISE EXCEPTION
      'quote_sections is not empty; aborting real-data seed. Delete existing rows first or edit the guard.';
  END IF;
END
$abort$;

-- ---------------------------------------------------------------------------
-- 1. Global Quote settings. Green Fee stays here (not a service).
-- ---------------------------------------------------------------------------
UPDATE public.quote_settings
   SET green_fee_amount    = 3.00,
       notes_enabled       = true,
       guest_name_required = false,
       quote_page_title    = 'Guest Quote',
       active              = true
 WHERE id = 1;

-- ---------------------------------------------------------------------------
-- 2..5. Sections + services + options + role prices (single DO block so
--       UUIDs flow via RETURNING; grouped by section for review).
-- ---------------------------------------------------------------------------
DO $seed$
DECLARE
  -- Section UUIDs.
  v_sec_cutting           uuid;
  v_sec_treatments        uuid;
  v_sec_colour            uuid;
  v_sec_bleach            uuid;
  v_sec_foils             uuid;
  v_sec_balayage          uuid;
  v_sec_toner_allover     uuid;
  v_sec_toner_dim         uuid;
  v_sec_extra_product     uuid;
  v_sec_keratin           uuid;
  v_sec_tape              uuid;
  v_sec_weft              uuid;
  v_sec_bonded            uuid;
  v_sec_creative_dir      uuid;

  -- Service UUIDs used across sibling inserts (options / role prices / links).
  v_svc_cuts_cbw              uuid;
  v_svc_cuts_fringe           uuid;
  v_svc_cuts_dry_style        uuid;
  v_svc_cuts_bw_above         uuid;
  v_svc_cuts_bw_below         uuid;
  v_svc_cuts_comp_bw_color    uuid;
  v_svc_cuts_comp_bw_prem     uuid;
  v_svc_cuts_wedding          uuid;
  v_svc_cuts_additional_mins  uuid;

  v_svc_trt_pigment_removal   uuid;
  v_svc_trt_abc               uuid;
  v_svc_trt_cat               uuid;
  v_svc_trt_k18_metal         uuid;
  v_svc_trt_k18_iles_std      uuid;
  v_svc_trt_k18_iles_lux      uuid;
  v_svc_trt_malibu_c          uuid;
  v_svc_trt_one_min_mask      uuid;

  v_svc_col_tsection          uuid;
  v_svc_col_retouch           uuid;
  v_svc_col_global            uuid;
  v_svc_col_combo_foils       uuid;

  v_svc_bl_retouch            uuid;
  v_svc_bl_global             uuid;
  v_svc_bl_over_bleach        uuid;
  v_svc_bl_bath               uuid;

  v_svc_fl_individual         uuid;
  v_svc_fl_individual_col     uuid;
  v_svc_fl_individual_extras  uuid;
  v_svc_fl_partial            uuid;
  v_svc_fl_half               uuid;
  v_svc_fl_full               uuid;
  v_svc_fl_full_plus          uuid;
  v_svc_fl_tipout             uuid;

  v_svc_bal_partial           uuid;
  v_svc_bal_half              uuid;
  v_svc_bal_full              uuid;
  v_svc_bal_full_extra        uuid;
  v_svc_bal_basin             uuid;

  v_svc_ta_wc_lt20            uuid;
  v_svc_ta_wc_20_39           uuid;
  v_svc_ta_wc_40_60           uuid;
  v_svc_ta_amaint_lt20        uuid;
  v_svc_ta_maint_20_39        uuid;
  v_svc_ta_maint_40_60        uuid;

  v_svc_td_wc_lt20            uuid;
  v_svc_td_wc_20_39           uuid;
  v_svc_td_wc_40_60           uuid;
  v_svc_td_maint_lt20         uuid;
  v_svc_td_maint_20_39        uuid;
  v_svc_td_maint_40_60        uuid;

  v_svc_ep_extra              uuid;

  v_svc_ker_cezanne           uuid;
  v_svc_ker_cezanne_extra     uuid;
  v_svc_ker_bkt               uuid;
  v_svc_ker_bkt_extra         uuid;

  v_svc_tp_jadore_22          uuid;
  v_svc_tp_jadore_16_invis    uuid;
  v_svc_tp_jadore_22_invis    uuid;
  v_svc_tp_great_lengths      uuid;
  v_svc_tp_install            uuid;
  v_svc_tp_maintenance        uuid;
  v_svc_tp_removal            uuid;

  v_svc_wft_blonde_60         uuid;
  v_svc_wft_blonde_120        uuid;
  v_svc_wft_brunette_60       uuid;
  v_svc_wft_brunette_120      uuid;
  v_svc_wft_install_mb        uuid;
  v_svc_wft_maint_mb          uuid;
  v_svc_wft_removal_mb        uuid;
  v_svc_wft_install_si        uuid;
  v_svc_wft_maint_si          uuid;
  v_svc_wft_removal_si        uuid;

  v_svc_bnd_30                uuid;
  v_svc_bnd_40                uuid;
  v_svc_bnd_50                uuid;
  v_svc_bnd_60                uuid;
  v_svc_bnd_fash              uuid;
  v_svc_bnd_rooted            uuid;
  v_svc_bnd_hair_prep         uuid;
  v_svc_bnd_install           uuid;
  v_svc_bnd_removal           uuid;

  v_svc_cd_cut_bw             uuid;
  v_svc_cd_blow_wave          uuid;
  v_svc_cd_style_lesson       uuid;
BEGIN
  -- =========================================================================
  -- SECTIONS (fixed order 1..14).
  -- =========================================================================
  INSERT INTO public.quote_sections (name, summary_label, display_order)
  VALUES ('Cutting and Styling',    'Cutting and Styling',    1)  RETURNING id INTO v_sec_cutting;
  INSERT INTO public.quote_sections (name, summary_label, display_order)
  VALUES ('Treatments',              'Treatments',             2)  RETURNING id INTO v_sec_treatments;
  INSERT INTO public.quote_sections (name, summary_label, display_order)
  VALUES ('Colour',                  'Colour',                 3)  RETURNING id INTO v_sec_colour;
  INSERT INTO public.quote_sections (name, summary_label, display_order)
  VALUES ('Bleach',                  'Bleach',                 4)  RETURNING id INTO v_sec_bleach;
  INSERT INTO public.quote_sections (name, summary_label, display_order)
  VALUES ('Foils',                   'Foils',                  5)  RETURNING id INTO v_sec_foils;
  INSERT INTO public.quote_sections (name, summary_label, display_order)
  VALUES ('Balayage/Hair Painting',  'Balayage/Hair Painting', 6)  RETURNING id INTO v_sec_balayage;
  -- Both Toner sections share summary_label 'Toner' so they roll up together.
  INSERT INTO public.quote_sections (name, summary_label, display_order)
  VALUES ('Toner - All Over',        'Toner',                  7)  RETURNING id INTO v_sec_toner_allover;
  INSERT INTO public.quote_sections (name, summary_label, display_order)
  VALUES ('Toner - Dimension',       'Toner',                  8)  RETURNING id INTO v_sec_toner_dim;
  INSERT INTO public.quote_sections (name, summary_label, display_order)
  VALUES ('Extra Product',           'Extra Product',          9)  RETURNING id INTO v_sec_extra_product;
  INSERT INTO public.quote_sections (name, summary_label, display_order)
  VALUES ('Keratin',                 'Keratin',               10)  RETURNING id INTO v_sec_keratin;
  INSERT INTO public.quote_sections (name, summary_label, display_order)
  VALUES ('Tape Extensions',         'Tape Extensions',       11)  RETURNING id INTO v_sec_tape;
  INSERT INTO public.quote_sections (name, summary_label, display_order)
  VALUES ('Weft Extensions',         'Weft Extensions',       12)  RETURNING id INTO v_sec_weft;
  INSERT INTO public.quote_sections (name, summary_label, display_order)
  VALUES ('Bonded Extensions',       'Bonded Extensions',     13)  RETURNING id INTO v_sec_bonded;
  INSERT INTO public.quote_sections (name, summary_label, display_order)
  VALUES ('Creative Director',       'Creative Director',     14)  RETURNING id INTO v_sec_creative_dir;

  -- =========================================================================
  -- 1. CUTTING AND STYLING (9 services)
  -- =========================================================================

  -- Cut and blow wave — 90 / 120 / 140 / 150
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_cutting, 'Cut and blow wave', 'cuts_cut_blow_wave', true, 1,
    'role_radio', 'role_price', ARRAY['EMERGING','SENIOR','DIRECTOR','MASTER'])
  RETURNING id INTO v_svc_cuts_cbw;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_cuts_cbw, 'EMERGING',   90),
    (v_svc_cuts_cbw, 'SENIOR',    120),
    (v_svc_cuts_cbw, 'DIRECTOR',  140),
    (v_svc_cuts_cbw, 'MASTER',    150);

  -- Fringe Trim — 20
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_cutting, 'Fringe Trim', 'cuts_fringe_trim', true, 2,
    'checkbox', 'fixed_price', 20)
  RETURNING id INTO v_svc_cuts_fringe;

  -- Dry Style — 45
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_cutting, 'Dry Style', 'cuts_dry_style', true, 3,
    'checkbox', 'fixed_price', 45)
  RETURNING id INTO v_svc_cuts_dry_style;

  -- Blow wave - above shldr — 70 / 95 / 95 / 95
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_cutting, 'Blow wave - above shldr', 'cuts_bw_above_shldr', true, 4,
    'role_radio', 'role_price', ARRAY['EMERGING','SENIOR','DIRECTOR','MASTER'])
  RETURNING id INTO v_svc_cuts_bw_above;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_cuts_bw_above, 'EMERGING',  70),
    (v_svc_cuts_bw_above, 'SENIOR',    95),
    (v_svc_cuts_bw_above, 'DIRECTOR',  95),
    (v_svc_cuts_bw_above, 'MASTER',    95);

  -- Blow wave - below shldr — 80 / 105 / 105 / 105
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_cutting, 'Blow wave - below shldr', 'cuts_bw_below_shldr', true, 5,
    'role_radio', 'role_price', ARRAY['EMERGING','SENIOR','DIRECTOR','MASTER'])
  RETURNING id INTO v_svc_cuts_bw_below;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_cuts_bw_below, 'EMERGING',   80),
    (v_svc_cuts_bw_below, 'SENIOR',    105),
    (v_svc_cuts_bw_below, 'DIRECTOR',  105),
    (v_svc_cuts_bw_below, 'MASTER',    105);

  -- Comp. blow wave w/ color — 0 (intentional complimentary)
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price, admin_notes)
  VALUES (v_sec_cutting, 'Comp. blow wave w/ color', 'cuts_comp_bw_color', true, 6,
    'checkbox', 'fixed_price', 0,
    'Complimentary blow wave when booked with a colour service.')
  RETURNING id INTO v_svc_cuts_comp_bw_color;

  -- Comp. blow wave prem — Snr/Dir/Mst all $80
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_cutting, 'Comp. blow wave prem', 'cuts_comp_bw_prem', true, 7,
    'role_radio', 'role_price', ARRAY['SENIOR','DIRECTOR','MASTER'])
  RETURNING id INTO v_svc_cuts_comp_bw_prem;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_cuts_comp_bw_prem, 'SENIOR',    80),
    (v_svc_cuts_comp_bw_prem, 'DIRECTOR',  80),
    (v_svc_cuts_comp_bw_prem, 'MASTER',    80);

  -- Hair-up and wedding hair — 102 / 122 / 143 / 143 (45 min booking)
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles, help_text)
  VALUES (v_sec_cutting, 'Hair-up and wedding hair', 'cuts_wedding_hair', true, 8,
    'role_radio', 'role_price', ARRAY['EMERGING','SENIOR','DIRECTOR','MASTER'],
    'Pricing based on a 45 minute booking.')
  RETURNING id INTO v_svc_cuts_wedding;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_cuts_wedding, 'EMERGING', 102),
    (v_svc_cuts_wedding, 'SENIOR',   122),
    (v_svc_cuts_wedding, 'DIRECTOR', 143),
    (v_svc_cuts_wedding, 'MASTER',   143);

  -- Additional mins reqd — per time band: 15=25, 30=50, 45=75, 60=100
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type)
  VALUES (v_sec_cutting, 'Additional mins reqd', 'cuts_additional_mins', true, 9,
    'option_radio', 'option_price')
  RETURNING id INTO v_svc_cuts_additional_mins;
  INSERT INTO public.quote_service_options (service_id, label, value_key, display_order, active, price) VALUES
    (v_svc_cuts_additional_mins, '15 min', 'mins_15', 1, true,  25),
    (v_svc_cuts_additional_mins, '30 min', 'mins_30', 2, true,  50),
    (v_svc_cuts_additional_mins, '45 min', 'mins_45', 3, true,  75),
    (v_svc_cuts_additional_mins, '60 min', 'mins_60', 4, true, 100);

  -- =========================================================================
  -- 2. TREATMENTS (8 services)
  -- =========================================================================

  -- Pigment Removal — 115
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_treatments, 'Pigment Removal', 'trt_pigment_removal', true, 1,
    'checkbox', 'fixed_price', 115)
  RETURNING id INTO v_svc_trt_pigment_removal;

  -- ABC Treatment — 40
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_treatments, 'ABC Treatment', 'trt_abc', true, 2,
    'checkbox', 'fixed_price', 40)
  RETURNING id INTO v_svc_trt_abc;

  -- CAT Treatment — Single (3g) = 10, Double (6g) = 15
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type)
  VALUES (v_sec_treatments, 'CAT Treatment', 'trt_cat', true, 3,
    'option_radio', 'option_price')
  RETURNING id INTO v_svc_trt_cat;
  INSERT INTO public.quote_service_options (service_id, label, value_key, display_order, active, price) VALUES
    (v_svc_trt_cat, 'Single (3g)', 'single_3g', 1, true, 10),
    (v_svc_trt_cat, 'Double (6g)', 'double_6g', 2, true, 15);

  -- K18 Metal Removal — 10
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_treatments, 'K18 Metal Removal', 'trt_k18_metal_removal', true, 4,
    'checkbox', 'fixed_price', 10)
  RETURNING id INTO v_svc_trt_k18_metal;

  -- K18 / Iles Standard — 50
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_treatments, 'K18 / Iles Standard', 'trt_k18_iles_standard', true, 5,
    'checkbox', 'fixed_price', 50)
  RETURNING id INTO v_svc_trt_k18_iles_std;

  -- K18 / IlesLuxury — 80
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_treatments, 'K18 / IlesLuxury', 'trt_k18_iles_luxury', true, 6,
    'checkbox', 'fixed_price', 80)
  RETURNING id INTO v_svc_trt_k18_iles_lux;

  -- Malibu C Products — 40
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_treatments, 'Malibu C Products', 'trt_malibu_c', true, 7,
    'checkbox', 'fixed_price', 40)
  RETURNING id INTO v_svc_trt_malibu_c;

  -- One Minute Mask — 30
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_treatments, 'One Minute Mask', 'trt_one_minute_mask', true, 8,
    'checkbox', 'fixed_price', 30)
  RETURNING id INTO v_svc_trt_one_min_mask;

  -- =========================================================================
  -- 3. COLOUR (4 services) — role_price, Em/Snr/Mst only
  -- =========================================================================

  -- T-Section (10g) — 120 / 140 / 150
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_colour, 'T-Section (10g)', 'col_tsection_10g', true, 1,
    'role_radio', 'role_price', ARRAY['EMERGING','SENIOR','MASTER'])
  RETURNING id INTO v_svc_col_tsection;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_col_tsection, 'EMERGING', 120),
    (v_svc_col_tsection, 'SENIOR',   140),
    (v_svc_col_tsection, 'MASTER',   150);

  -- Retouch (30g) — 172 / 190 / 207
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_colour, 'Retouch (30g)', 'col_retouch_30g', true, 2,
    'role_radio', 'role_price', ARRAY['EMERGING','SENIOR','MASTER'])
  RETURNING id INTO v_svc_col_retouch;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_col_retouch, 'EMERGING', 172),
    (v_svc_col_retouch, 'SENIOR',   190),
    (v_svc_col_retouch, 'MASTER',   207);

  -- Global Colour (50g) — 207 / 227 / 237
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_colour, 'Global Colour (50g)', 'col_global_50g', true, 3,
    'role_radio', 'role_price', ARRAY['EMERGING','SENIOR','MASTER'])
  RETURNING id INTO v_svc_col_global;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_col_global, 'EMERGING', 207),
    (v_svc_col_global, 'SENIOR',   227),
    (v_svc_col_global, 'MASTER',   237);

  -- Col Combo (30g) +Foils — 100 / 110 / 110
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_colour, 'Col Combo (30g) +Foils', 'col_combo_30g_foils', true, 4,
    'role_radio', 'role_price', ARRAY['EMERGING','SENIOR','MASTER'])
  RETURNING id INTO v_svc_col_combo_foils;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_col_combo_foils, 'EMERGING', 100),
    (v_svc_col_combo_foils, 'SENIOR',   110),
    (v_svc_col_combo_foils, 'MASTER',   110);

  -- =========================================================================
  -- 4. BLEACH (4 services) — role_price, Em/Snr/Mst only
  -- =========================================================================

  -- Bleach retouch (45g) — 225 / 245 / 255
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_bleach, 'Bleach retouch (45g)', 'bl_retouch_45g', true, 1,
    'role_radio', 'role_price', ARRAY['EMERGING','SENIOR','MASTER'])
  RETURNING id INTO v_svc_bl_retouch;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_bl_retouch, 'EMERGING', 225),
    (v_svc_bl_retouch, 'SENIOR',   245),
    (v_svc_bl_retouch, 'MASTER',   255);

  -- Global bleach (60g) — 315 / 330 / 340
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_bleach, 'Global bleach (60g)', 'bl_global_60g', true, 2,
    'role_radio', 'role_price', ARRAY['EMERGING','SENIOR','MASTER'])
  RETURNING id INTO v_svc_bl_global;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_bl_global, 'EMERGING', 315),
    (v_svc_bl_global, 'SENIOR',   330),
    (v_svc_bl_global, 'MASTER',   340);

  -- Colour over bleach — 110 / 110 / 110
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_bleach, 'Colour over bleach', 'bl_colour_over_bleach', true, 3,
    'role_radio', 'role_price', ARRAY['EMERGING','SENIOR','MASTER'])
  RETURNING id INTO v_svc_bl_over_bleach;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_bl_over_bleach, 'EMERGING', 110),
    (v_svc_bl_over_bleach, 'SENIOR',   110),
    (v_svc_bl_over_bleach, 'MASTER',   110);

  -- Bleach Bath — 100 / 110 / 110
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_bleach, 'Bleach Bath', 'bl_bath', true, 4,
    'role_radio', 'role_price', ARRAY['EMERGING','SENIOR','MASTER'])
  RETURNING id INTO v_svc_bl_bath;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_bl_bath, 'EMERGING', 100),
    (v_svc_bl_bath, 'SENIOR',   110),
    (v_svc_bl_bath, 'MASTER',   110);

  -- =========================================================================
  -- 5. FOILS (8 services)
  -- =========================================================================

  -- Individual — 180
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_foils, 'Individual', 'fl_individual', true, 1,
    'checkbox', 'fixed_price', 180)
  RETURNING id INTO v_svc_fl_individual;

  -- Individual (<10 Foils w/ Col.) — $10 each, quantity radio 1..5
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, help_text)
  VALUES (v_sec_foils, 'Individual (<10 Foils w/ Col.)', 'fl_individual_col', true, 2,
    'option_radio', 'option_price',
    'Individual foils when booked with colour. $10 per foil, pick a quantity 1..5.')
  RETURNING id INTO v_svc_fl_individual_col;
  INSERT INTO public.quote_service_options (service_id, label, value_key, display_order, active, price) VALUES
    (v_svc_fl_individual_col, '1', 'q1', 1, true, 10),
    (v_svc_fl_individual_col, '2', 'q2', 2, true, 20),
    (v_svc_fl_individual_col, '3', 'q3', 3, true, 30),
    (v_svc_fl_individual_col, '4', 'q4', 4, true, 40),
    (v_svc_fl_individual_col, '5', 'q5', 5, true, 50);

  -- Individual extras — extra_unit_price @ $10 each, linked to the row above.
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type,
    extra_unit_config, link_to_base_service_id,
    help_text)
  VALUES (v_sec_foils, 'Individual extras', 'fl_individual_extras', true, 3,
    'extra_units', 'extra_unit_price',
    jsonb_build_object(
      'baseIncludedAmountLabel', 'Included with Individual (<10 Foils w/ Col.)',
      'extraLabel',               'Extra foil',
      'extraUnitDisplaySuffix',   'units',
      'pricePerExtraUnit',        10,
      'maxExtras',                5,
      'optionStyle',              'radio_1_to_n'
    ),
    v_svc_fl_individual_col,
    'Extra individual foils on top of Individual (<10 Foils w/ Col.).')
  RETURNING id INTO v_svc_fl_individual_extras;

  -- Partial — 185 / 205 / 215
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_foils, 'Partial (1 - 20 foils / 1-30g)', 'fl_partial', true, 4,
    'role_radio', 'role_price', ARRAY['EMERGING','SENIOR','MASTER'])
  RETURNING id INTO v_svc_fl_partial;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_fl_partial, 'EMERGING', 185),
    (v_svc_fl_partial, 'SENIOR',   205),
    (v_svc_fl_partial, 'MASTER',   215);

  -- Half — 215 / 235 / 245
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_foils, 'Half (21-40 foils / 31-40g)', 'fl_half', true, 5,
    'role_radio', 'role_price', ARRAY['EMERGING','SENIOR','MASTER'])
  RETURNING id INTO v_svc_fl_half;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_fl_half, 'EMERGING', 215),
    (v_svc_fl_half, 'SENIOR',   235),
    (v_svc_fl_half, 'MASTER',   245);

  -- Full — 275 / 295 / 310
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_foils, 'Full (41-60 foils / 41g-60g)', 'fl_full', true, 6,
    'role_radio', 'role_price', ARRAY['EMERGING','SENIOR','MASTER'])
  RETURNING id INTO v_svc_fl_full;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_fl_full, 'EMERGING', 275),
    (v_svc_fl_full, 'SENIOR',   295),
    (v_svc_fl_full, 'MASTER',   310);

  -- Full+ — 305 / 325 / 340
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_foils, 'Full+ (>60 foils / 61g-80g)', 'fl_full_plus', true, 7,
    'role_radio', 'role_price', ARRAY['EMERGING','SENIOR','MASTER'])
  RETURNING id INTO v_svc_fl_full_plus;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_fl_full_plus, 'EMERGING', 305),
    (v_svc_fl_full_plus, 'SENIOR',   325),
    (v_svc_fl_full_plus, 'MASTER',   340);

  -- Tip-out surcharge 30g — 50
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_foils, 'Tip-out surcharge 30g', 'fl_tipout_30g', true, 8,
    'checkbox', 'fixed_price', 50)
  RETURNING id INTO v_svc_fl_tipout;

  -- =========================================================================
  -- 6. BALAYAGE / HAIR PAINTING (5 services)
  -- =========================================================================

  -- Partial (1-40g) — 235 / 255
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_balayage, 'Partial (1-40g)', 'bal_partial_1_40g', true, 1,
    'role_radio', 'role_price', ARRAY['SENIOR','MASTER'])
  RETURNING id INTO v_svc_bal_partial;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_bal_partial, 'SENIOR', 235),
    (v_svc_bal_partial, 'MASTER', 255);

  -- Half head (41-60g) — 275 / 295
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_balayage, 'Half head (41-60g)', 'bal_half_41_60g', true, 2,
    'role_radio', 'role_price', ARRAY['SENIOR','MASTER'])
  RETURNING id INTO v_svc_bal_half;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_bal_half, 'SENIOR', 275),
    (v_svc_bal_half, 'MASTER', 295);

  -- Full head (60-80g) — 335 / 355
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_balayage, 'Full head (60-80g)', 'bal_full_60_80g', true, 3,
    'role_radio', 'role_price', ARRAY['SENIOR','MASTER'])
  RETURNING id INTO v_svc_bal_full;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_bal_full, 'SENIOR', 335),
    (v_svc_bal_full, 'MASTER', 355);

  -- Full head extra (80-100g) — 365 / 385
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_balayage, 'Full head extra (80-100g)', 'bal_full_extra_80_100g', true, 4,
    'role_radio', 'role_price', ARRAY['SENIOR','MASTER'])
  RETURNING id INTO v_svc_bal_full_extra;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_bal_full_extra, 'SENIOR', 365),
    (v_svc_bal_full_extra, 'MASTER', 385);

  -- Basin Balayage — 30 (Emerging only)
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, visible_roles)
  VALUES (v_sec_balayage, 'Basin Balayage', 'bal_basin', true, 5,
    'role_radio', 'role_price', ARRAY['EMERGING'])
  RETURNING id INTO v_svc_bal_basin;
  INSERT INTO public.quote_service_role_prices (service_id, role, price) VALUES
    (v_svc_bal_basin, 'EMERGING', 30);

  -- =========================================================================
  -- 7. TONER - ALL OVER (6 services, summary label 'Toner')
  -- =========================================================================

  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_toner_allover, 'With Colour (<20g)', 'ta_with_col_lt20g', true, 1,
    'checkbox', 'fixed_price', 55)
  RETURNING id INTO v_svc_ta_wc_lt20;

  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_toner_allover, 'With Colour (20-39g)', 'ta_with_col_20_39g', true, 2,
    'checkbox', 'fixed_price', 65)
  RETURNING id INTO v_svc_ta_wc_20_39;

  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_toner_allover, 'With Colour (40-60g)', 'ta_with_col_40_60g', true, 3,
    'checkbox', 'fixed_price', 80)
  RETURNING id INTO v_svc_ta_wc_40_60;

  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_toner_allover, 'AMaint. (<20g incl BW)', 'ta_amaint_lt20g', true, 4,
    'checkbox', 'fixed_price', 125)
  RETURNING id INTO v_svc_ta_amaint_lt20;

  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_toner_allover, 'Maint. (20-39g incl BW)', 'ta_maint_20_39g', true, 5,
    'checkbox', 'fixed_price', 140)
  RETURNING id INTO v_svc_ta_maint_20_39;

  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_toner_allover, 'Maint. (40-60g incl BW)', 'ta_maint_40_60g', true, 6,
    'checkbox', 'fixed_price', 155)
  RETURNING id INTO v_svc_ta_maint_40_60;

  -- =========================================================================
  -- 8. TONER - DIMENSION (6 services, summary label 'Toner')
  -- =========================================================================

  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_toner_dim, 'With Colour (<20g)', 'td_with_col_lt20g', true, 1,
    'checkbox', 'fixed_price', 75)
  RETURNING id INTO v_svc_td_wc_lt20;

  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_toner_dim, 'With Colour (20-39g)', 'td_with_col_20_39g', true, 2,
    'checkbox', 'fixed_price', 85)
  RETURNING id INTO v_svc_td_wc_20_39;

  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_toner_dim, 'With Colour (40-60g)', 'td_with_col_40_60g', true, 3,
    'checkbox', 'fixed_price', 100)
  RETURNING id INTO v_svc_td_wc_40_60;

  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_toner_dim, 'Maint. (<20g incl BW)', 'td_maint_lt20g', true, 4,
    'checkbox', 'fixed_price', 145)
  RETURNING id INTO v_svc_td_maint_lt20;

  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_toner_dim, 'Maint. (20-39g incl BW)', 'td_maint_20_39g', true, 5,
    'checkbox', 'fixed_price', 160)
  RETURNING id INTO v_svc_td_maint_20_39;

  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_toner_dim, 'Maint. (40-60g incl BW)', 'td_maint_40_60g', true, 6,
    'checkbox', 'fixed_price', 175)
  RETURNING id INTO v_svc_td_maint_40_60;

  -- =========================================================================
  -- 9. EXTRA PRODUCT (1 service, special_extra_product)
  -- =========================================================================
  --
  -- pricePerUnit = 18, gramsPerUnit = 18, minutesPerUnit = 10.

  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type,
    special_extra_config,
    summary_group_override,
    help_text)
  VALUES (v_sec_extra_product, 'Extra product', 'ep_extra_product', true, 1,
    'special_extra_product', 'special_extra_product',
    jsonb_build_object(
      'numberOfRows',             3,
      'maxUnitsPerRow',           5,
      'pricePerUnit',             18,
      'gramsPerUnit',             18,
      'minutesPerUnit',           10,
      'blueSummaryLabelTemplate', '{units} units / {grams} grams or {minutes} mins'
    ),
    'Extra Product',
    'Three rows of 1..5 unit radios rolling up into the quote summary in grams and minutes.')
  RETURNING id INTO v_svc_ep_extra;

  -- =========================================================================
  -- 10. KERATIN (4 services: 2 base + 2 linked extras)
  -- =========================================================================

  -- Cezanne (20g) — 350
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_keratin, 'Cezanne (20g)', 'ker_cezanne_20g', true, 1,
    'checkbox', 'fixed_price', 350)
  RETURNING id INTO v_svc_ker_cezanne;

  -- Cezanne additional — $25 per 10g extra unit
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type,
    extra_unit_config, link_to_base_service_id,
    help_text)
  VALUES (v_sec_keratin, 'Cezanne additional', 'ker_cezanne_additional', true, 2,
    'extra_units', 'extra_unit_price',
    jsonb_build_object(
      'baseIncludedAmountLabel', 'Included with Cezanne (20g)',
      'extraLabel',               'Extra',
      'extraUnitDisplaySuffix',   '10g',
      'pricePerExtraUnit',        25,
      'maxExtras',                5,
      'optionStyle',              'radio_1_to_n',
      'gramsPerExtraUnit',        10
    ),
    v_svc_ker_cezanne,
    'Additional 10g units of Cezanne on top of the base 20g.')
  RETURNING id INTO v_svc_ker_cezanne_extra;

  -- BKT Nanoplasty (20g) — 450
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_keratin, 'BKT Nanoplasty (20g)', 'ker_bkt_nanoplasty_20g', true, 3,
    'checkbox', 'fixed_price', 450)
  RETURNING id INTO v_svc_ker_bkt;

  -- BKT Nanoplasty additional — $35 per 10g extra unit
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type,
    extra_unit_config, link_to_base_service_id,
    help_text)
  VALUES (v_sec_keratin, 'BKT Nanoplasty additional', 'ker_bkt_additional', true, 4,
    'extra_units', 'extra_unit_price',
    jsonb_build_object(
      'baseIncludedAmountLabel', 'Included with BKT Nanoplasty (20g)',
      'extraLabel',               'Extra',
      'extraUnitDisplaySuffix',   '10g',
      'pricePerExtraUnit',        35,
      'maxExtras',                5,
      'optionStyle',              'radio_1_to_n',
      'gramsPerExtraUnit',        10
    ),
    v_svc_ker_bkt,
    'Additional 10g units of BKT Nanoplasty on top of the base 20g.')
  RETURNING id INTO v_svc_ker_bkt_extra;

  -- =========================================================================
  -- 11. TAPE EXTENSIONS (7 services)
  -- =========================================================================
  --
  -- Dropdown services run 10 pcs to 60 pcs in 10 pc steps, scaling linearly
  -- from the product's 10 pcs base price.

  -- J'adore hair 22" — base (10 pcs) = 230
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type)
  VALUES (v_sec_tape, 'J''adore hair 22"', 'tp_jadore_22', true, 1,
    'dropdown', 'option_price')
  RETURNING id INTO v_svc_tp_jadore_22;
  INSERT INTO public.quote_service_options (service_id, label, value_key, display_order, active, price) VALUES
    (v_svc_tp_jadore_22, '10 pcs', 'pcs_10', 1, true,  230),
    (v_svc_tp_jadore_22, '20 pcs', 'pcs_20', 2, true,  460),
    (v_svc_tp_jadore_22, '30 pcs', 'pcs_30', 3, true,  690),
    (v_svc_tp_jadore_22, '40 pcs', 'pcs_40', 4, true,  920),
    (v_svc_tp_jadore_22, '50 pcs', 'pcs_50', 5, true, 1150),
    (v_svc_tp_jadore_22, '60 pcs', 'pcs_60', 6, true, 1380);

  -- J'adore hair 16" Invis. — base (10 pcs) = 180
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type)
  VALUES (v_sec_tape, 'J''adore hair 16" Invis.', 'tp_jadore_16_invis', true, 2,
    'dropdown', 'option_price')
  RETURNING id INTO v_svc_tp_jadore_16_invis;
  INSERT INTO public.quote_service_options (service_id, label, value_key, display_order, active, price) VALUES
    (v_svc_tp_jadore_16_invis, '10 pcs', 'pcs_10', 1, true,  180),
    (v_svc_tp_jadore_16_invis, '20 pcs', 'pcs_20', 2, true,  360),
    (v_svc_tp_jadore_16_invis, '30 pcs', 'pcs_30', 3, true,  540),
    (v_svc_tp_jadore_16_invis, '40 pcs', 'pcs_40', 4, true,  720),
    (v_svc_tp_jadore_16_invis, '50 pcs', 'pcs_50', 5, true,  900),
    (v_svc_tp_jadore_16_invis, '60 pcs', 'pcs_60', 6, true, 1080);

  -- J'adore hair 22" Invis. — base (10 pcs) = 250
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type)
  VALUES (v_sec_tape, 'J''adore hair 22" Invis.', 'tp_jadore_22_invis', true, 3,
    'dropdown', 'option_price')
  RETURNING id INTO v_svc_tp_jadore_22_invis;
  INSERT INTO public.quote_service_options (service_id, label, value_key, display_order, active, price) VALUES
    (v_svc_tp_jadore_22_invis, '10 pcs', 'pcs_10', 1, true,  250),
    (v_svc_tp_jadore_22_invis, '20 pcs', 'pcs_20', 2, true,  500),
    (v_svc_tp_jadore_22_invis, '30 pcs', 'pcs_30', 3, true,  750),
    (v_svc_tp_jadore_22_invis, '40 pcs', 'pcs_40', 4, true, 1000),
    (v_svc_tp_jadore_22_invis, '50 pcs', 'pcs_50', 5, true, 1250),
    (v_svc_tp_jadore_22_invis, '60 pcs', 'pcs_60', 6, true, 1500);

  -- Great Lengths 45cm — base (10 pcs) = 262
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type)
  VALUES (v_sec_tape, 'Great Lengths 45cm', 'tp_great_lengths_45cm', true, 4,
    'dropdown', 'option_price')
  RETURNING id INTO v_svc_tp_great_lengths;
  INSERT INTO public.quote_service_options (service_id, label, value_key, display_order, active, price) VALUES
    (v_svc_tp_great_lengths, '10 pcs', 'pcs_10', 1, true,  262),
    (v_svc_tp_great_lengths, '20 pcs', 'pcs_20', 2, true,  524),
    (v_svc_tp_great_lengths, '30 pcs', 'pcs_30', 3, true,  786),
    (v_svc_tp_great_lengths, '40 pcs', 'pcs_40', 4, true, 1048),
    (v_svc_tp_great_lengths, '50 pcs', 'pcs_50', 5, true, 1310),
    (v_svc_tp_great_lengths, '60 pcs', 'pcs_60', 6, true, 1572);

  -- Install — 150 / 200 / 250
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type)
  VALUES (v_sec_tape, 'Install', 'tp_install', true, 5,
    'option_radio', 'option_price')
  RETURNING id INTO v_svc_tp_install;
  INSERT INTO public.quote_service_options (service_id, label, value_key, display_order, active, price) VALUES
    (v_svc_tp_install, '20 min', 'mins_20', 1, true, 150),
    (v_svc_tp_install, '40 min', 'mins_40', 2, true, 200),
    (v_svc_tp_install, '60 min', 'mins_60', 3, true, 250);

  -- Maintenance — 140 / 210 / 270
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type)
  VALUES (v_sec_tape, 'Maintenance', 'tp_maintenance', true, 6,
    'option_radio', 'option_price')
  RETURNING id INTO v_svc_tp_maintenance;
  INSERT INTO public.quote_service_options (service_id, label, value_key, display_order, active, price) VALUES
    (v_svc_tp_maintenance, '20 min', 'mins_20', 1, true, 140),
    (v_svc_tp_maintenance, '40 min', 'mins_40', 2, true, 210),
    (v_svc_tp_maintenance, '60 min', 'mins_60', 3, true, 270);

  -- Removal — 80 / 90 / 100
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type)
  VALUES (v_sec_tape, 'Removal', 'tp_removal', true, 7,
    'option_radio', 'option_price')
  RETURNING id INTO v_svc_tp_removal;
  INSERT INTO public.quote_service_options (service_id, label, value_key, display_order, active, price) VALUES
    (v_svc_tp_removal, '20 min', 'mins_20', 1, true,  80),
    (v_svc_tp_removal, '40 min', 'mins_40', 2, true,  90),
    (v_svc_tp_removal, '60 min', 'mins_60', 3, true, 100);

  -- =========================================================================
  -- 12. WEFT EXTENSIONS (10 services)
  -- =========================================================================

  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_weft, 'Blonde 60g', 'wft_blonde_60g', true, 1,
    'checkbox', 'fixed_price', 490)
  RETURNING id INTO v_svc_wft_blonde_60;

  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_weft, 'Blonde 120g', 'wft_blonde_120g', true, 2,
    'checkbox', 'fixed_price', 975)
  RETURNING id INTO v_svc_wft_blonde_120;

  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_weft, 'Brunette 60g', 'wft_brunette_60g', true, 3,
    'checkbox', 'fixed_price', 470)
  RETURNING id INTO v_svc_wft_brunette_60;

  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_weft, 'Brunette 120g', 'wft_brunette_120g', true, 4,
    'checkbox', 'fixed_price', 935)
  RETURNING id INTO v_svc_wft_brunette_120;

  -- Install microbead — 175 / 175 / 200
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type)
  VALUES (v_sec_weft, 'Install microbead', 'wft_install_microbead', true, 5,
    'option_radio', 'option_price')
  RETURNING id INTO v_svc_wft_install_mb;
  INSERT INTO public.quote_service_options (service_id, label, value_key, display_order, active, price) VALUES
    (v_svc_wft_install_mb, '1/2',  'half',          1, true, 175),
    (v_svc_wft_install_mb, '3/4',  'three_quarter', 2, true, 175),
    (v_svc_wft_install_mb, 'Full', 'full',          3, true, 200);

  -- Maint. microbead — 85 / 170 / 255
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type)
  VALUES (v_sec_weft, 'Maint. microbead', 'wft_maint_microbead', true, 6,
    'option_radio', 'option_price')
  RETURNING id INTO v_svc_wft_maint_mb;
  INSERT INTO public.quote_service_options (service_id, label, value_key, display_order, active, price) VALUES
    (v_svc_wft_maint_mb, '1 row',  'rows_1', 1, true,  85),
    (v_svc_wft_maint_mb, '2 rows', 'rows_2', 2, true, 170),
    (v_svc_wft_maint_mb, '3 rows', 'rows_3', 3, true, 255);

  -- Removal microbead — 25 / 50 / 75
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type)
  VALUES (v_sec_weft, 'Removal microbead', 'wft_removal_microbead', true, 7,
    'option_radio', 'option_price')
  RETURNING id INTO v_svc_wft_removal_mb;
  INSERT INTO public.quote_service_options (service_id, label, value_key, display_order, active, price) VALUES
    (v_svc_wft_removal_mb, '1 row',  'rows_1', 1, true, 25),
    (v_svc_wft_removal_mb, '2 rows', 'rows_2', 2, true, 50),
    (v_svc_wft_removal_mb, '3 rows', 'rows_3', 3, true, 75);

  -- Install sew-in — 180 / 220 / 250
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type)
  VALUES (v_sec_weft, 'Install sew-in', 'wft_install_sew_in', true, 8,
    'option_radio', 'option_price')
  RETURNING id INTO v_svc_wft_install_si;
  INSERT INTO public.quote_service_options (service_id, label, value_key, display_order, active, price) VALUES
    (v_svc_wft_install_si, '1/2',  'half',          1, true, 180),
    (v_svc_wft_install_si, '3/4',  'three_quarter', 2, true, 220),
    (v_svc_wft_install_si, 'Full', 'full',          3, true, 250);

  -- Maint. sew-in — 105 / 210 / 315
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type)
  VALUES (v_sec_weft, 'Maint. sew-in', 'wft_maint_sew_in', true, 9,
    'option_radio', 'option_price')
  RETURNING id INTO v_svc_wft_maint_si;
  INSERT INTO public.quote_service_options (service_id, label, value_key, display_order, active, price) VALUES
    (v_svc_wft_maint_si, '1 row',  'rows_1', 1, true, 105),
    (v_svc_wft_maint_si, '2 rows', 'rows_2', 2, true, 210),
    (v_svc_wft_maint_si, '3 rows', 'rows_3', 3, true, 315);

  -- Removal sew-in — 25 / 50 / 75
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type)
  VALUES (v_sec_weft, 'Removal sew-in', 'wft_removal_sew_in', true, 10,
    'option_radio', 'option_price')
  RETURNING id INTO v_svc_wft_removal_si;
  INSERT INTO public.quote_service_options (service_id, label, value_key, display_order, active, price) VALUES
    (v_svc_wft_removal_si, '1 row',  'rows_1', 1, true, 25),
    (v_svc_wft_removal_si, '2 rows', 'rows_2', 2, true, 50),
    (v_svc_wft_removal_si, '3 rows', 'rows_3', 3, true, 75);

  -- =========================================================================
  -- 13. BONDED EXTENSIONS (9 services)
  -- =========================================================================

  -- Hair 30cm — $11 per strand
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, numeric_config, help_text)
  VALUES (v_sec_bonded, 'Hair 30cm', 'bnd_hair_30cm', true, 1,
    'numeric_input', 'numeric_multiplier',
    jsonb_build_object(
      'unitLabel',    'strand',
      'pricePerUnit', 11,
      'min',          0,
      'max',          100,               -- PLACEHOLDER: confirm realistic upper bound
      'step',         1,
      'defaultValue', 0,
      'roundTo',      null,
      'minCharge',    null
    ),
    'Charged per 30cm strand fitted.')
  RETURNING id INTO v_svc_bnd_30;

  -- Hair 40cm — $14 per strand
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, numeric_config, help_text)
  VALUES (v_sec_bonded, 'Hair 40cm', 'bnd_hair_40cm', true, 2,
    'numeric_input', 'numeric_multiplier',
    jsonb_build_object(
      'unitLabel',    'strand',
      'pricePerUnit', 14,
      'min',          0,
      'max',          100,               -- PLACEHOLDER
      'step',         1,
      'defaultValue', 0,
      'roundTo',      null,
      'minCharge',    null
    ),
    'Charged per 40cm strand fitted.')
  RETURNING id INTO v_svc_bnd_40;

  -- Hair 50cm — $17 per strand
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, numeric_config, help_text)
  VALUES (v_sec_bonded, 'Hair 50cm', 'bnd_hair_50cm', true, 3,
    'numeric_input', 'numeric_multiplier',
    jsonb_build_object(
      'unitLabel',    'strand',
      'pricePerUnit', 17,
      'min',          0,
      'max',          100,               -- PLACEHOLDER
      'step',         1,
      'defaultValue', 0,
      'roundTo',      null,
      'minCharge',    null
    ),
    'Charged per 50cm strand fitted.')
  RETURNING id INTO v_svc_bnd_50;

  -- Hair 60cm — $23 per strand
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, numeric_config, help_text)
  VALUES (v_sec_bonded, 'Hair 60cm', 'bnd_hair_60cm', true, 4,
    'numeric_input', 'numeric_multiplier',
    jsonb_build_object(
      'unitLabel',    'strand',
      'pricePerUnit', 23,
      'min',          0,
      'max',          100,               -- PLACEHOLDER
      'step',         1,
      'defaultValue', 0,
      'roundTo',      null,
      'minCharge',    null
    ),
    'Charged per 60cm strand fitted.')
  RETURNING id INTO v_svc_bnd_60;

  -- Hair (fash. colours) 40cm — $16 per strand
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, numeric_config, help_text)
  VALUES (v_sec_bonded, 'Hair (fash. colours) 40cm', 'bnd_hair_fashion_40cm', true, 5,
    'numeric_input', 'numeric_multiplier',
    jsonb_build_object(
      'unitLabel',    'strand',
      'pricePerUnit', 16,
      'min',          0,
      'max',          100,               -- PLACEHOLDER
      'step',         1,
      'defaultValue', 0,
      'roundTo',      null,
      'minCharge',    null
    ),
    'Charged per 40cm fashion-colour strand fitted.')
  RETURNING id INTO v_svc_bnd_fash;

  -- Hair (rooted and bronde) 40cm — $21 per strand
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, numeric_config, help_text)
  VALUES (v_sec_bonded, 'Hair (rooted and bronde) 40cm', 'bnd_hair_rooted_40cm', true, 6,
    'numeric_input', 'numeric_multiplier',
    jsonb_build_object(
      'unitLabel',    'strand',
      'pricePerUnit', 21,
      'min',          0,
      'max',          100,               -- PLACEHOLDER
      'step',         1,
      'defaultValue', 0,
      'roundTo',      null,
      'minCharge',    null
    ),
    'Charged per 40cm rooted/bronde strand fitted.')
  RETURNING id INTO v_svc_bnd_rooted;

  -- Hair prep — Sml=60, Med=90, Lrg=120
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type)
  VALUES (v_sec_bonded, 'Hair prep', 'bnd_hair_prep', true, 7,
    'option_radio', 'option_price')
  RETURNING id INTO v_svc_bnd_hair_prep;
  INSERT INTO public.quote_service_options (service_id, label, value_key, display_order, active, price) VALUES
    (v_svc_bnd_hair_prep, 'Sml.', 'sml', 1, true,  60),
    (v_svc_bnd_hair_prep, 'Med.', 'med', 2, true,  90),
    (v_svc_bnd_hair_prep, 'Lrg.', 'lrg', 3, true, 120);

  -- Install — $5.50 per strand
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, numeric_config, help_text)
  VALUES (v_sec_bonded, 'Install', 'bnd_install', true, 8,
    'numeric_input', 'numeric_multiplier',
    jsonb_build_object(
      'unitLabel',    'strand',
      'pricePerUnit', 5.50,
      'min',          0,
      'max',          200,               -- PLACEHOLDER: confirm upper bound
      'step',         1,
      'defaultValue', 0,
      'roundTo',      null,
      'minCharge',    null
    ),
    'Install charge per strand fitted.')
  RETURNING id INTO v_svc_bnd_install;

  -- Removal — Sml=70, Med=70, Lrg=135
  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type)
  VALUES (v_sec_bonded, 'Removal', 'bnd_removal', true, 9,
    'option_radio', 'option_price')
  RETURNING id INTO v_svc_bnd_removal;
  INSERT INTO public.quote_service_options (service_id, label, value_key, display_order, active, price) VALUES
    (v_svc_bnd_removal, 'Sml.', 'sml', 1, true,  70),
    (v_svc_bnd_removal, 'Med.', 'med', 2, true,  70),
    (v_svc_bnd_removal, 'Lrg.', 'lrg', 3, true, 135);

  -- =========================================================================
  -- 14. CREATIVE DIRECTOR (3 services)
  -- =========================================================================

  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_creative_dir, 'Cut and Blow Wave', 'cd_cut_and_blow_wave', true, 1,
    'checkbox', 'fixed_price', 200)
  RETURNING id INTO v_svc_cd_cut_bw;

  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_creative_dir, 'Blow Wave', 'cd_blow_wave', true, 2,
    'checkbox', 'fixed_price', 150)
  RETURNING id INTO v_svc_cd_blow_wave;

  INSERT INTO public.quote_services (section_id, name, internal_key, active, display_order,
    input_type, pricing_type, fixed_price)
  VALUES (v_sec_creative_dir, 'Style Lesson', 'cd_style_lesson', true, 3,
    'checkbox', 'fixed_price', 150)
  RETURNING id INTO v_svc_cd_style_lesson;

END
$seed$;

COMMIT;

-- ---------------------------------------------------------------------------
-- Post-run sanity checks (copy / paste into psql after COMMIT).
-- ---------------------------------------------------------------------------
-- SELECT display_order, name, summary_label FROM public.quote_sections ORDER BY display_order;
--
-- SELECT sec.display_order AS sec_ord, sec.name AS section, s.display_order AS ord,
--        s.name, s.input_type, s.pricing_type, s.fixed_price, s.visible_roles
--   FROM public.quote_services s
--   JOIN public.quote_sections sec ON sec.id = s.section_id
--  ORDER BY sec.display_order, s.display_order;
--
-- SELECT sv.name, o.display_order, o.label, o.value_key, o.price
--   FROM public.quote_service_options o
--   JOIN public.quote_services sv ON sv.id = o.service_id
--  ORDER BY sv.name, o.display_order;
--
-- SELECT sv.name, rp.role, rp.price
--   FROM public.quote_service_role_prices rp
--   JOIN public.quote_services sv ON sv.id = rp.service_id
--  ORDER BY sv.name, rp.role;
