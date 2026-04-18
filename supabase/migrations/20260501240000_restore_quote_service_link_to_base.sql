-- =============================================================================
-- Restore link_to_base_service_id for seeded extra-unit services that may
-- have been NULL'd by the earlier admin-drawer round-trip bug.
--
-- Root cause (fixed in src/lib/quoteConfigurationApi.ts): the admin config
-- `mapService` hydrated `extraUnit.linkToBaseServiceId` only from the nested
-- `extra_unit_config` JSONB column, never from the authoritative top-level
-- `link_to_base_service_id` column. Seeds write only the top-level column,
-- so the drawer opened these services with an empty link field; the next
-- save sent `link_to_base_service_id = NULL` back, stamping over the link.
-- The Guest Quote "linked extra rolls into parent" display rule uses that
-- top-level column to identify children, so the child row silently stopped
-- rolling up.
--
-- This migration is narrow on purpose:
--   * Only touches rows where the link is currently NULL (never overwrites
--     a value an admin has since restored or changed).
--   * Matches by `internal_key` pairs from the canonical seed
--     (`supabase/seeds/quote_config_real_data.sql`) — no name matching,
--     no heuristics, no cross-section guesses.
--   * Self-healing: if the parent row has been archived or deleted, no
--     match is found and the row stays NULL (Guest Quote still renders
--     it as a standalone extra, and the dev console warns about it).
--
-- Pairs restored (child → base):
--   fl_individual_extras      → fl_individual_col
--   ker_cezanne_additional    → ker_cezanne_20g
--   ker_bkt_additional        → ker_bkt_nanoplasty_20g
-- =============================================================================

DO $$
DECLARE
  pair RECORD;
  v_parent_id uuid;
  v_updated   int;
BEGIN
  FOR pair IN
    SELECT child_key, parent_key FROM (
      VALUES
        ('fl_individual_extras',   'fl_individual_col'),
        ('ker_cezanne_additional', 'ker_cezanne_20g'),
        ('ker_bkt_additional',     'ker_bkt_nanoplasty_20g')
    ) AS t(child_key, parent_key)
  LOOP
    SELECT id
      INTO v_parent_id
      FROM public.quote_services
      WHERE internal_key = pair.parent_key
      LIMIT 1;

    IF v_parent_id IS NULL THEN
      RAISE NOTICE
        'restore link_to_base_service_id: parent with internal_key=% not found; skipping child=%',
        pair.parent_key, pair.child_key;
      CONTINUE;
    END IF;

    UPDATE public.quote_services
       SET link_to_base_service_id = v_parent_id
     WHERE internal_key = pair.child_key
       AND link_to_base_service_id IS NULL;

    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated > 0 THEN
      RAISE NOTICE
        'restore link_to_base_service_id: linked % -> % (% row)',
        pair.child_key, pair.parent_key, v_updated;
    END IF;
  END LOOP;
END
$$;
