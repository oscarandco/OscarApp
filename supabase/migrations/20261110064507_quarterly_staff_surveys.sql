-- Quarterly staff pulse surveys. Apply only to the intended environment.
-- Named submitted responses are admin-only; employee drafts remain private.
BEGIN;

ALTER TABLE public.role_page_permissions DROP CONSTRAINT role_page_permissions_page_id_check;
ALTER TABLE public.role_page_permissions ADD CONSTRAINT role_page_permissions_page_id_check CHECK (page_id IN (
  'my_payroll','guest_quote','previous_quotes','kpi_dashboard','weekly_payroll','commission_breakdown','staff_trends',
  'imports','staff','products','quotes','remuneration','access','role_permissions','contractor_invoices',
  'business_settings','commission_guide','service_product_costs','surveys','admin_surveys'
));
ALTER TABLE public.role_page_permissions ADD CONSTRAINT staff_survey_role_privacy CHECK (
  (page_id <> 'admin_surveys' OR access_level = CASE WHEN role_key = 'admin' THEN 'full' ELSE 'none' END)
  AND (page_id <> 'surveys' OR access_level = 'full')
);
INSERT INTO public.role_page_permissions(page_id, role_key, access_level)
SELECT p, r, CASE WHEN p = 'surveys' OR r = 'admin' THEN 'full' ELSE 'none' END
FROM unnest(ARRAY['surveys','admin_surveys']) p CROSS JOIN unnest(ARRAY[
  'assistant','stylist','reception','manager','assistant_uat','stylist_uat','reception_uat','manager_uat','admin'
]) r;

CREATE OR REPLACE FUNCTION public.update_role_page_permission(p_page_id text, p_role_key text, p_access_level text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_page text := lower(btrim(coalesce(p_page_id, '')));
  v_role text := lower(btrim(coalesce(p_role_key, '')));
  v_level text := lower(btrim(coalesce(p_access_level, ''))); v_row public.role_page_permissions;
BEGIN
  IF auth.uid() IS NULL OR NOT private.user_can_manage_access_mappings() THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
  END IF;
  IF v_role NOT IN ('assistant','stylist','reception','manager','assistant_uat','stylist_uat','reception_uat','manager_uat','admin')
    OR v_level NOT IN ('none','view','full') THEN RAISE EXCEPTION 'Invalid role or access level'; END IF;
  IF v_page NOT IN ('my_payroll','guest_quote','previous_quotes','kpi_dashboard','weekly_payroll','commission_breakdown',
    'staff_trends','imports','staff','products','quotes','remuneration','access','role_permissions','contractor_invoices',
    'business_settings','commission_guide','service_product_costs','surveys','admin_surveys') THEN RAISE EXCEPTION 'Invalid page'; END IF;
  IF v_page = 'role_permissions' AND v_role = 'admin' AND v_level <> 'full' THEN
    RAISE EXCEPTION 'Admin must retain Full access to Role permissions'; END IF;
  IF v_page = 'access' AND v_role = 'admin' AND v_level = 'none' THEN
    RAISE EXCEPTION 'Admin must retain at least View access to Access'; END IF;
  INSERT INTO public.role_page_permissions(page_id, role_key, access_level) VALUES(v_page, v_role, v_level)
  ON CONFLICT (page_id, role_key) DO UPDATE SET access_level = excluded.access_level, updated_at = now() RETURNING * INTO v_row;
  RETURN to_jsonb(v_row);
END;
$$;

CREATE FUNCTION private.survey_active_user() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT auth.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.staff_member_user_access a
    WHERE a.user_id = auth.uid() AND a.is_active
  );
$$;

CREATE FUNCTION private.survey_admin() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT auth.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.staff_member_user_access a
    WHERE a.user_id = auth.uid() AND a.is_active AND a.access_role IN ('admin', 'superadmin')
  );
$$;

CREATE FUNCTION private.valid_survey_questions(p_questions jsonb, p_count integer) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN jsonb_typeof(p_questions) = 'array' THEN
    jsonb_array_length(p_questions) = p_count AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_questions) q
      WHERE jsonb_typeof(q) <> 'string' OR length(btrim(q #>> '{}')) NOT BETWEEN 1 AND 300
    ) ELSE false END;
$$;

CREATE TABLE public.staff_survey_settings (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  questions jsonb NOT NULL CHECK (private.valid_survey_questions(questions, 10)),
  written_questions jsonb NOT NULL CHECK (private.valid_survey_questions(written_questions, 2)),
  automatic_enabled boolean NOT NULL DEFAULT true,
  automatic_from date NOT NULL DEFAULT ((date_trunc('quarter', now() AT TIME ZONE 'Pacific/Auckland') + interval '3 months')::date),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.staff_survey_settings (questions, written_questions) VALUES (
  '["I enjoy coming to work at Oscar&Co.","I feel valued and respected as a member of the team.","The people I work with support one another.","I feel comfortable raising concerns, sharing ideas or asking for help.","I understand what is expected of me in my role.","My work feels manageable within my rostered hours.","I receive useful feedback and recognition for the work I do.","I have opportunities to learn, develop and progress.","I feel proud to be part of Oscar&Co.","I would recommend Oscar&Co as a great place to work."]',
  '["What is one thing we should keep doing?","What is one thing we could change to make Oscar&Co a better place to work?"]'
);

CREATE TABLE public.staff_survey_rounds (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quarter_start date NOT NULL UNIQUE CHECK (quarter_start = date_trunc('quarter', quarter_start::timestamp)::date),
  title text NOT NULL,
  questions jsonb NOT NULL CHECK (private.valid_survey_questions(questions, 10)),
  written_questions jsonb NOT NULL CHECK (private.valid_survey_questions(written_questions, 2)),
  opens_at timestamptz NOT NULL,
  closes_at timestamptz NOT NULL CHECK (closes_at > opens_at),
  closed_at timestamptz,
  launch_source text NOT NULL CHECK (launch_source IN ('automatic', 'admin')),
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.staff_survey_participants (
  round_id uuid NOT NULL REFERENCES public.staff_survey_rounds(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  staff_member_id uuid REFERENCES public.staff_members(id) ON DELETE SET NULL,
  staff_name text NOT NULL,
  email text NOT NULL,
  remind_after timestamptz,
  PRIMARY KEY (round_id, user_id)
);
CREATE INDEX staff_survey_participant_user_idx ON public.staff_survey_participants(user_id, round_id);

CREATE TABLE public.staff_survey_responses (
  round_id uuid NOT NULL,
  user_id uuid NOT NULL,
  scores jsonb NOT NULL CHECK (jsonb_typeof(scores) = 'array' AND jsonb_array_length(scores) = 10),
  comments text[] NOT NULL DEFAULT ARRAY['',''] CHECK (array_length(comments, 1) = 2),
  revision integer NOT NULL DEFAULT 1,
  updated_at timestamptz NOT NULL DEFAULT now(),
  submitted_at timestamptz,
  PRIMARY KEY (round_id, user_id),
  FOREIGN KEY (round_id, user_id) REFERENCES public.staff_survey_participants(round_id, user_id) ON DELETE CASCADE
);

ALTER TABLE public.staff_survey_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff_survey_rounds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff_survey_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff_survey_responses ENABLE ROW LEVEL SECURITY;
CREATE POLICY survey_settings_admin_read ON public.staff_survey_settings FOR SELECT TO authenticated
  USING ((SELECT private.survey_admin()));
CREATE POLICY survey_participant_read ON public.staff_survey_participants FOR SELECT TO authenticated
  USING ((SELECT private.survey_active_user()) AND (user_id = (SELECT auth.uid()) OR (SELECT private.survey_admin())));
CREATE POLICY survey_round_read ON public.staff_survey_rounds FOR SELECT TO authenticated
  USING ((SELECT private.survey_active_user()) AND ((SELECT private.survey_admin()) OR EXISTS (
    SELECT 1 FROM public.staff_survey_participants p WHERE p.round_id = staff_survey_rounds.id AND p.user_id = (SELECT auth.uid())
  )));
CREATE POLICY survey_response_read ON public.staff_survey_responses FOR SELECT TO authenticated
  USING ((SELECT private.survey_active_user()) AND (user_id = (SELECT auth.uid()) OR
    (submitted_at IS NOT NULL AND (SELECT private.survey_admin()))));

-- No direct client writes, including admins: validated functions preserve snapshots,
-- ownership, one response per round, deadlines and immutable submitted answers.
REVOKE ALL ON public.staff_survey_settings, public.staff_survey_rounds,
  public.staff_survey_participants, public.staff_survey_responses FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.staff_survey_settings, public.staff_survey_rounds,
  public.staff_survey_participants, public.staff_survey_responses TO authenticated;

CREATE FUNCTION private.create_staff_survey_round(p_now timestamptz, p_source text, p_closes_at timestamptz)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid; v_quarter date := date_trunc('quarter', p_now AT TIME ZONE 'Pacific/Auckland')::date;
BEGIN
  -- Internal only: no client execute grant. The caller must authenticate or be cron.
  INSERT INTO public.staff_survey_rounds(quarter_start, title, questions, written_questions, opens_at, closes_at, launch_source, created_by)
  SELECT v_quarter, 'Q' || extract(quarter FROM v_quarter)::text || ' ' || extract(year FROM v_quarter)::text || ' team pulse',
    questions, written_questions, p_now, p_closes_at, p_source,
    CASE WHEN p_source = 'admin' THEN auth.uid() ELSE NULL END
  FROM public.staff_survey_settings WHERE id
  ON CONFLICT (quarter_start) DO NOTHING RETURNING id INTO v_id;
  IF v_id IS NULL THEN RETURN NULL; END IF;
  INSERT INTO public.staff_survey_participants(round_id, user_id, staff_member_id, staff_name, email)
  SELECT DISTINCT ON (a.user_id) v_id, a.user_id, s.id, coalesce(nullif(s.display_name, ''), s.full_name), coalesce(u.email, '')
  FROM public.staff_member_user_access a
  JOIN public.staff_members s ON s.id = a.staff_member_id AND s.is_active
  JOIN auth.users u ON u.id = a.user_id
  WHERE a.is_active ORDER BY a.user_id, a.created_at, a.id;
  RETURN v_id;
END;
$$;

CREATE FUNCTION private.launch_due_staff_survey(p_now timestamptz DEFAULT now()) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_day date := (p_now AT TIME ZONE 'Pacific/Auckland')::date;
  v_quarter date := date_trunc('quarter', p_now AT TIME ZONE 'Pacific/Auckland')::date;
BEGIN
  IF v_day >= v_quarter + 7 OR NOT EXISTS (
    SELECT 1 FROM public.staff_survey_settings WHERE id AND automatic_enabled AND v_quarter >= automatic_from
  ) THEN RETURN NULL; END IF;
  RETURN private.create_staff_survey_round(p_now, 'automatic', (v_quarter + 14)::timestamp AT TIME ZONE 'Pacific/Auckland');
END;
$$;

CREATE FUNCTION private.launch_staff_survey(p_closes_on date DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid; v_day date := (now() AT TIME ZONE 'Pacific/Auckland')::date;
BEGIN
  IF NOT private.survey_admin() THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501'; END IF;
  IF p_closes_on IS NOT NULL AND (p_closes_on <= v_day OR p_closes_on > v_day + 60) THEN
    RAISE EXCEPTION 'Choose a closing date within the next 60 days';
  END IF;
  v_id := private.create_staff_survey_round(now(), 'admin', coalesce(p_closes_on, v_day + 14)::timestamp AT TIME ZONE 'Pacific/Auckland');
  IF v_id IS NULL THEN RAISE EXCEPTION 'A survey already exists for this quarter'; END IF;
  RETURN v_id;
END;
$$;

CREATE FUNCTION private.save_staff_survey_settings(p_questions jsonb, p_written_questions jsonb, p_automatic_enabled boolean, p_updated_at timestamptz)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT private.survey_admin() THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501'; END IF;
  IF p_automatic_enabled IS NULL OR NOT coalesce(private.valid_survey_questions(p_questions, 10), false)
    OR NOT coalesce(private.valid_survey_questions(p_written_questions, 2), false) THEN
    RAISE EXCEPTION 'Provide 10 rating questions and 2 written questions (1–300 characters each)';
  END IF;
  UPDATE public.staff_survey_settings SET questions = p_questions, written_questions = p_written_questions,
    automatic_enabled = p_automatic_enabled, updated_at = clock_timestamp()
  WHERE id AND updated_at = p_updated_at;
  IF NOT FOUND THEN RAISE EXCEPTION 'Settings changed elsewhere. Reload before saving.'; END IF;
END;
$$;

CREATE FUNCTION private.save_staff_survey_response(p_round_id uuid, p_scores jsonb, p_comments text[], p_submit boolean, p_revision integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_round public.staff_survey_rounds; v_response public.staff_survey_responses; v_existing public.staff_survey_responses;
BEGIN
  IF NOT private.survey_active_user() THEN RAISE EXCEPTION 'Active staff access required' USING ERRCODE = '42501'; END IF;
  SELECT * INTO v_round FROM public.staff_survey_rounds WHERE id = p_round_id FOR SHARE;
  IF NOT FOUND OR now() < v_round.opens_at OR now() >= v_round.closes_at OR v_round.closed_at IS NOT NULL THEN
    RAISE EXCEPTION 'This survey is closed';
  END IF;
  PERFORM 1 FROM public.staff_survey_participants WHERE round_id = p_round_id AND user_id = auth.uid() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'You are not a participant in this survey' USING ERRCODE = '42501'; END IF;
  SELECT * INTO v_existing FROM public.staff_survey_responses WHERE round_id = p_round_id AND user_id = auth.uid();
  IF v_existing.submitted_at IS NOT NULL THEN RAISE EXCEPTION 'Your response has already been submitted'; END IF;
  IF p_revision IS DISTINCT FROM coalesce(v_existing.revision, 0) THEN
    RAISE EXCEPTION 'Your response changed in another session. Reload before continuing.';
  END IF;
  IF p_submit IS NULL OR p_scores IS NULL OR jsonb_typeof(p_scores) <> 'array' THEN RAISE EXCEPTION 'Invalid answers'; END IF;
  IF jsonb_array_length(p_scores) <> 10 THEN RAISE EXCEPTION 'Provide exactly 10 ratings'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_scores) s WHERE s <> 'null'::jsonb
    AND (jsonb_typeof(s) <> 'number' OR s::text !~ '^[1-5]$')) THEN
    RAISE EXCEPTION 'Ratings must be whole numbers from 1 to 5';
  END IF;
  IF p_submit AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_scores) s WHERE s = 'null'::jsonb) THEN
    RAISE EXCEPTION 'Answer all 10 rating questions before submitting';
  END IF;
  IF p_comments IS NULL OR coalesce(array_length(p_comments, 1), 0) <> 2 OR array_ndims(p_comments) <> 1
    OR EXISTS (SELECT 1 FROM unnest(p_comments) c WHERE c IS NULL OR length(c) > 2000) THEN
    RAISE EXCEPTION 'Written answers must be at most 2,000 characters each';
  END IF;
  INSERT INTO public.staff_survey_responses(round_id, user_id, scores, comments, revision, submitted_at)
  VALUES(p_round_id, auth.uid(), p_scores, p_comments, p_revision + 1, CASE WHEN p_submit THEN now() END)
  ON CONFLICT (round_id, user_id) DO UPDATE SET scores = excluded.scores, comments = excluded.comments,
    revision = excluded.revision, updated_at = clock_timestamp(), submitted_at = excluded.submitted_at
  RETURNING * INTO v_response;
  RETURN to_jsonb(v_response);
END;
$$;

CREATE FUNCTION private.remind_staff_survey_later(p_round_id uuid) RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_until timestamptz := now() + interval '24 hours';
BEGIN
  IF NOT private.survey_active_user() THEN RAISE EXCEPTION 'Active staff access required' USING ERRCODE = '42501'; END IF;
  UPDATE public.staff_survey_participants p SET remind_after = v_until
  FROM public.staff_survey_rounds r WHERE p.round_id = p_round_id AND p.user_id = auth.uid() AND r.id = p.round_id
    AND now() >= r.opens_at AND now() < r.closes_at AND r.closed_at IS NULL
    AND NOT EXISTS (SELECT 1 FROM public.staff_survey_responses s WHERE s.round_id = p.round_id AND s.user_id = p.user_id AND s.submitted_at IS NOT NULL);
  IF NOT FOUND THEN RAISE EXCEPTION 'No unanswered open survey found'; END IF;
  RETURN v_until;
END;
$$;

CREATE FUNCTION private.close_staff_survey(p_round_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT private.survey_admin() THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501'; END IF;
  UPDATE public.staff_survey_rounds SET closed_at = now() WHERE id = p_round_id AND closed_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Survey not found or already closed'; END IF;
END;
$$;

-- Public wrappers run as the caller. Privileged implementations live in the
-- non-exposed private schema, authenticate every request, and accept no user ID.
CREATE FUNCTION public.get_my_staff_surveys() RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object('remind_after', p.remind_after, 'response', to_jsonb(s))
    ORDER BY r.opens_at DESC), '[]'::jsonb)
  FROM public.staff_survey_rounds r JOIN public.staff_survey_participants p ON p.round_id = r.id AND p.user_id = auth.uid()
  LEFT JOIN public.staff_survey_responses s ON s.round_id = r.id AND s.user_id = auth.uid();
$$;

CREATE FUNCTION public.get_admin_staff_surveys() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  IF NOT private.survey_admin() THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501'; END IF;
  RETURN jsonb_build_object('settings', (SELECT to_jsonb(s) FROM public.staff_survey_settings s WHERE id),
    'rounds', (SELECT coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object(
      'participant_count', (SELECT count(*) FROM public.staff_survey_participants p WHERE p.round_id = r.id),
      'submitted_count', (SELECT count(*) FROM public.staff_survey_responses s WHERE s.round_id = r.id AND s.submitted_at IS NOT NULL)
    ) ORDER BY r.opens_at DESC), '[]'::jsonb) FROM public.staff_survey_rounds r));
END;
$$;

CREATE FUNCTION public.get_staff_survey_results(p_round_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  IF NOT private.survey_admin() THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501'; END IF;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(p) || jsonb_build_object('response', to_jsonb(s)) ORDER BY p.staff_name, p.email)
    FROM public.staff_survey_participants p LEFT JOIN public.staff_survey_responses s
    ON s.round_id = p.round_id AND s.user_id = p.user_id AND s.submitted_at IS NOT NULL
    WHERE p.round_id = p_round_id), '[]'::jsonb);
END;
$$;

CREATE FUNCTION public.launch_staff_survey(p_closes_on date DEFAULT NULL) RETURNS uuid
LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT private.launch_staff_survey(p_closes_on); $$;
CREATE FUNCTION public.save_staff_survey_settings(p_questions jsonb, p_written_questions jsonb, p_automatic_enabled boolean, p_updated_at timestamptz) RETURNS void
LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT private.save_staff_survey_settings(p_questions, p_written_questions, p_automatic_enabled, p_updated_at); $$;
CREATE FUNCTION public.save_staff_survey_response(p_round_id uuid, p_scores jsonb, p_comments text[], p_submit boolean, p_revision integer) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT private.save_staff_survey_response(p_round_id, p_scores, p_comments, p_submit, p_revision); $$;
CREATE FUNCTION public.remind_staff_survey_later(p_round_id uuid) RETURNS timestamptz
LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT private.remind_staff_survey_later(p_round_id); $$;
CREATE FUNCTION public.close_staff_survey(p_round_id uuid) RETURNS void
LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT private.close_staff_survey(p_round_id); $$;

-- Explicitly remove the PostgreSQL default PUBLIC execute grant, also in private.
DO $$ DECLARE f record; BEGIN
  FOR f IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public','private') AND p.proname IN (
      'survey_active_user','survey_admin','valid_survey_questions','create_staff_survey_round','launch_due_staff_survey',
      'get_my_staff_surveys','get_admin_staff_surveys','get_staff_survey_results','launch_staff_survey',
      'save_staff_survey_settings','save_staff_survey_response','remind_staff_survey_later','close_staff_survey')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.signature);
    IF f.signature::text NOT LIKE '%create_staff_survey_round(%' AND f.signature::text NOT LIKE '%launch_due_staff_survey(%' THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.signature);
    END IF;
  END LOOP;
END $$;

-- Poll at NZ midnight (11:00/12:00 UTC depending on daylight saving), with hourly
-- first-week retries. UNIQUE quarter_start makes manual/automatic races harmless.
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('oscar-quarterly-staff-survey', '0 * * * *', 'select private.launch_due_staff_survey();');

NOTIFY pgrst, 'reload schema';
COMMIT;
