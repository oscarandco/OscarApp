-- Configurable survey definitions, NZ schedules and typed answer snapshots.
BEGIN;

CREATE FUNCTION private.valid_staff_survey_schema(p_questions jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE q jsonb; v_ids text[] := '{}'; o jsonb; v_options text[];
BEGIN
  IF p_questions IS NULL OR jsonb_typeof(p_questions) <> 'array' THEN RETURN false; END IF;
  IF jsonb_array_length(p_questions) NOT BETWEEN 1 AND 50 THEN RETURN false; END IF;
  FOR q IN SELECT value FROM jsonb_array_elements(p_questions) LOOP
    IF jsonb_typeof(q) <> 'object' OR NOT (q ?& ARRAY['id','prompt','type','required'])
      OR jsonb_typeof(q->'id') <> 'string' OR (q->>'id') !~ '^[a-zA-Z0-9_-]{1,80}$'
      OR (q->>'id') = ANY(v_ids) OR jsonb_typeof(q->'prompt') <> 'string'
      OR length(btrim(q->>'prompt')) NOT BETWEEN 1 AND 500 OR jsonb_typeof(q->'required') <> 'boolean'
      OR jsonb_typeof(q->'type') <> 'string' OR (q->>'type') NOT IN ('agreement','rating','yes_no','single_choice','multi_choice','text') THEN RETURN false; END IF;
    v_ids := array_append(v_ids, q->>'id');
    IF q->>'type' = 'rating' THEN
      IF NOT (q ?& ARRAY['scale_max','low_label','high_label']) OR jsonb_typeof(q->'scale_max') <> 'number'
        OR (q->>'scale_max') NOT IN ('5','10') OR jsonb_typeof(q->'low_label') <> 'string'
        OR jsonb_typeof(q->'high_label') <> 'string' OR length(btrim(q->>'low_label')) NOT BETWEEN 1 AND 80
        OR length(btrim(q->>'high_label')) NOT BETWEEN 1 AND 80 THEN RETURN false; END IF;
    END IF;
    IF q->>'type' IN ('single_choice','multi_choice') THEN
      IF NOT q ? 'options' OR jsonb_typeof(q->'options') <> 'array' THEN RETURN false; END IF;
      IF jsonb_array_length(q->'options') NOT BETWEEN 2 AND 10 THEN RETURN false; END IF;
      v_options := '{}';
      FOR o IN SELECT value FROM jsonb_array_elements(q->'options') LOOP
        IF jsonb_typeof(o) <> 'string' OR length(btrim(o #>> '{}')) NOT BETWEEN 1 AND 120
          OR lower(btrim(o #>> '{}')) = ANY(v_options) THEN RETURN false; END IF;
        v_options := array_append(v_options, lower(btrim(o #>> '{}')));
      END LOOP;
    END IF;
  END LOOP;
  RETURN true;
END;
$$;

CREATE FUNCTION private.legacy_staff_survey_schema(p_ratings jsonb, p_written jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT coalesce(jsonb_agg(q ORDER BY sort), '[]'::jsonb) FROM (
    SELECT n AS sort, jsonb_build_object('id','pulse-rating-'||n,'prompt',t,'type','agreement','required',true) q
      FROM jsonb_array_elements_text(p_ratings) WITH ORDINALITY r(t,n)
    UNION ALL SELECT 100 + n, jsonb_build_object('id','pulse-text-'||n,'prompt',t,'type','text','required',false)
      FROM jsonb_array_elements_text(p_written) WITH ORDINALITY r(t,n)
  ) questions;
$$;

CREATE TABLE public.staff_surveys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  description text NOT NULL DEFAULT '' CHECK (length(description) <= 2000),
  questions jsonb NOT NULL CHECK (private.valid_staff_survey_schema(questions)),
  schedule_kind text NOT NULL DEFAULT 'manual' CHECK (schedule_kind IN ('manual','once','weekly','monthly','quarterly','yearly')),
  start_on date,
  duration_days integer NOT NULL DEFAULT 14 CHECK (duration_days BETWEEN 1 AND 60),
  schedule_enabled boolean NOT NULL DEFAULT false,
  is_archived boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((schedule_kind = 'manual' AND start_on IS NULL AND NOT schedule_enabled) OR (schedule_kind <> 'manual' AND start_on IS NOT NULL)),
  CHECK ((schedule_kind <> 'weekly' OR duration_days <= 7) AND (schedule_kind <> 'monthly' OR duration_days <= 28))
);
ALTER TABLE public.staff_surveys ENABLE ROW LEVEL SECURITY;
CREATE POLICY staff_survey_definition_admin_read ON public.staff_surveys FOR SELECT TO authenticated USING ((SELECT private.survey_admin()));
REVOKE ALL ON public.staff_surveys FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.staff_surveys TO authenticated;

-- Preserve the pulse as an editable definition and migrate historical answers.
INSERT INTO public.staff_surveys(id,name,description,questions,schedule_kind,start_on,duration_days,schedule_enabled)
SELECT '00000000-0000-4000-8000-000000000100', 'Quarterly team pulse',
  'Help us understand your experience at Oscar&Co and identify opportunities to improve our workplace.',
  private.legacy_staff_survey_schema(questions,written_questions),'quarterly',automatic_from,14,automatic_enabled
FROM public.staff_survey_settings WHERE id;

ALTER TABLE public.staff_survey_rounds DROP CONSTRAINT staff_survey_rounds_quarter_start_key;
ALTER TABLE public.staff_survey_rounds DROP CONSTRAINT staff_survey_rounds_questions_check;
ALTER TABLE public.staff_survey_rounds DROP CONSTRAINT staff_survey_rounds_written_questions_check;
ALTER TABLE public.staff_survey_rounds ADD COLUMN survey_id uuid REFERENCES public.staff_surveys(id);
ALTER TABLE public.staff_survey_rounds ADD COLUMN run_on date;
ALTER TABLE public.staff_survey_rounds ADD COLUMN description text NOT NULL DEFAULT '';
ALTER TABLE public.staff_survey_rounds ADD COLUMN question_schema jsonb;
UPDATE public.staff_survey_rounds SET survey_id='00000000-0000-4000-8000-000000000100',run_on=quarter_start,
  question_schema=private.legacy_staff_survey_schema(questions,written_questions);
ALTER TABLE public.staff_survey_rounds ALTER COLUMN survey_id SET NOT NULL;
ALTER TABLE public.staff_survey_rounds ALTER COLUMN run_on SET NOT NULL;
ALTER TABLE public.staff_survey_rounds ALTER COLUMN question_schema SET NOT NULL;
ALTER TABLE public.staff_survey_rounds ADD CONSTRAINT staff_survey_round_schema_check CHECK (private.valid_staff_survey_schema(question_schema));
ALTER TABLE public.staff_survey_rounds ADD CONSTRAINT staff_survey_occurrence_unique UNIQUE(survey_id,run_on);

ALTER TABLE public.staff_survey_responses DROP CONSTRAINT staff_survey_responses_scores_check;
ALTER TABLE public.staff_survey_responses DROP CONSTRAINT staff_survey_responses_comments_check;
ALTER TABLE public.staff_survey_responses ALTER COLUMN scores SET DEFAULT '[]';
ALTER TABLE public.staff_survey_responses ADD COLUMN answers jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(answers) = 'object');
UPDATE public.staff_survey_responses s SET answers = coalesce((
  SELECT jsonb_object_agg(q->>'id', CASE WHEN q->>'type'='text' THEN to_jsonb(s.comments[(split_part(q->>'id','-',3))::int])
    ELSE s.scores->((split_part(q->>'id','-',3))::int - 1) END)
  FROM public.staff_survey_rounds r CROSS JOIN LATERAL jsonb_array_elements(r.question_schema) q WHERE r.id=s.round_id
),'{}'::jsonb);

CREATE FUNCTION private.staff_survey_occurrence(p_kind text,p_start date,p_day date) RETURNS date
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE v_step integer; v_offset integer; v_month date; v_date date;
BEGIN
  IF p_start IS NULL OR p_day < p_start OR p_kind='manual' THEN RETURN NULL; END IF;
  IF p_kind='once' THEN RETURN p_start; END IF;
  IF p_kind='weekly' THEN RETURN p_start + ((p_day-p_start)/7)*7; END IF;
  v_step := CASE p_kind WHEN 'monthly' THEN 1 WHEN 'quarterly' THEN 3 WHEN 'yearly' THEN 12 ELSE NULL END;
  IF v_step IS NULL THEN RETURN NULL; END IF;
  v_offset := (extract(year FROM p_day)::int-extract(year FROM p_start)::int)*12 + extract(month FROM p_day)::int-extract(month FROM p_start)::int;
  v_month := (date_trunc('month',p_start::timestamp) + make_interval(months => (v_offset/v_step)*v_step))::date;
  v_date := v_month + least(extract(day FROM p_start)::int,extract(day FROM (v_month+interval '1 month - 1 day'))::int)-1;
  IF v_date > p_day THEN
    v_month := (v_month-make_interval(months=>v_step))::date;
    v_date := v_month + least(extract(day FROM p_start)::int,extract(day FROM (v_month+interval '1 month - 1 day'))::int)-1;
  END IF;
  RETURN CASE WHEN v_date >= p_start THEN v_date END;
END;
$$;

CREATE FUNCTION private.staff_survey_next_occurrence(p_kind text,p_start date,p_day date) RETURNS date
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE v_due date; v_month date; v_step integer;
BEGIN
  IF p_start IS NULL OR p_kind='manual' THEN RETURN NULL; END IF;
  IF p_start > p_day THEN RETURN p_start; END IF;
  v_due := private.staff_survey_occurrence(p_kind,p_start,p_day);
  IF p_kind='once' THEN RETURN NULL; END IF;
  IF p_kind='weekly' THEN RETURN v_due+7; END IF;
  v_step := CASE p_kind WHEN 'monthly' THEN 1 WHEN 'quarterly' THEN 3 WHEN 'yearly' THEN 12 END;
  v_month := (date_trunc('month',v_due::timestamp)+make_interval(months=>v_step))::date;
  RETURN v_month + least(extract(day FROM p_start)::int,extract(day FROM (v_month+interval '1 month - 1 day'))::int)-1;
END;
$$;

CREATE FUNCTION private.create_configured_survey_run(p_survey_id uuid,p_run_on date,p_opens_at timestamptz,p_closes_at timestamptz,p_source text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_survey public.staff_surveys; v_id uuid;
BEGIN
  SELECT * INTO v_survey FROM public.staff_surveys WHERE id=p_survey_id FOR UPDATE;
  IF NOT FOUND OR v_survey.is_archived THEN RETURN NULL; END IF;
  -- Definition row lock serialises manual/scheduled launches and question edits.
  IF EXISTS(SELECT 1 FROM public.staff_survey_rounds WHERE survey_id=p_survey_id AND closed_at IS NULL
    AND opens_at < p_closes_at AND closes_at > p_opens_at) THEN RETURN NULL; END IF;
  INSERT INTO public.staff_survey_rounds(survey_id,run_on,quarter_start,title,description,question_schema,questions,written_questions,opens_at,closes_at,launch_source,created_by)
  VALUES(p_survey_id,p_run_on,date_trunc('quarter',p_run_on::timestamp)::date,v_survey.name,v_survey.description,v_survey.questions,'[]','[]',p_opens_at,p_closes_at,p_source,
    CASE WHEN p_source='admin' THEN auth.uid() END)
  ON CONFLICT(survey_id,run_on) DO NOTHING RETURNING id INTO v_id;
  IF v_id IS NULL THEN RETURN NULL; END IF;
  INSERT INTO public.staff_survey_participants(round_id,user_id,staff_member_id,staff_name,email)
  SELECT DISTINCT ON(a.user_id) v_id,a.user_id,s.id,coalesce(nullif(s.display_name,''),s.full_name),coalesce(u.email,'')
  FROM public.staff_member_user_access a JOIN public.staff_members s ON s.id=a.staff_member_id AND s.is_active JOIN auth.users u ON u.id=a.user_id
  WHERE a.is_active ORDER BY a.user_id,a.created_at,a.id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION private.launch_due_staff_survey(p_now timestamptz DEFAULT now()) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.staff_surveys; v_day date := (p_now AT TIME ZONE 'Pacific/Auckland')::date; v_due date; v_id uuid; v_last uuid;
BEGIN
  FOR s IN SELECT * FROM public.staff_surveys WHERE schedule_enabled AND NOT is_archived ORDER BY id FOR UPDATE LOOP
    v_due := private.staff_survey_occurrence(s.schedule_kind,s.start_on,v_day);
    IF v_due IS NULL OR v_day >= v_due+least(7,s.duration_days) THEN CONTINUE; END IF;
    v_id := private.create_configured_survey_run(s.id,v_due,v_due::timestamp AT TIME ZONE 'Pacific/Auckland',
      (v_due+s.duration_days)::timestamp AT TIME ZONE 'Pacific/Auckland','automatic');
    IF v_id IS NOT NULL THEN v_last := v_id; END IF;
  END LOOP;
  RETURN v_last;
END;
$$;

CREATE FUNCTION private.save_staff_survey_definition(p_id uuid,p_name text,p_description text,p_questions jsonb,p_schedule_kind text,p_start_on date,p_duration_days integer,p_schedule_enabled boolean,p_updated_at timestamptz) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid; v_old public.staff_surveys;
BEGIN
  IF NOT private.survey_admin() THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE='42501'; END IF;
  IF p_name IS NULL OR length(btrim(p_name)) NOT BETWEEN 1 AND 120 OR p_description IS NULL OR length(p_description)>2000
    OR NOT private.valid_staff_survey_schema(p_questions) THEN RAISE EXCEPTION 'Provide a survey name and 1–50 valid questions. Choice options must be unique.'; END IF;
  IF p_schedule_kind IS NULL OR p_schedule_kind NOT IN('manual','once','weekly','monthly','quarterly','yearly') OR p_duration_days IS NULL
    OR p_duration_days NOT BETWEEN 1 AND 60 OR p_schedule_enabled IS NULL
    OR (p_schedule_kind='manual' AND (p_start_on IS NOT NULL OR p_schedule_enabled))
    OR (p_schedule_kind<>'manual' AND p_start_on IS NULL)
    OR (p_schedule_kind='weekly' AND p_duration_days>7) OR (p_schedule_kind='monthly' AND p_duration_days>28) THEN
    RAISE EXCEPTION 'Invalid schedule. Weekly response windows must be at most 7 days; monthly windows at most 28 days.';
  END IF;
  IF p_id IS NULL THEN
    IF p_start_on < (now() AT TIME ZONE 'Pacific/Auckland')::date THEN RAISE EXCEPTION 'The first scheduled run must be today or later'; END IF;
    INSERT INTO public.staff_surveys(name,description,questions,schedule_kind,start_on,duration_days,schedule_enabled)
      VALUES(btrim(p_name),p_description,p_questions,p_schedule_kind,p_start_on,p_duration_days,p_schedule_enabled) RETURNING id INTO v_id;
  ELSE
    SELECT * INTO v_old FROM public.staff_surveys WHERE id=p_id FOR UPDATE;
    IF NOT FOUND OR v_old.is_archived THEN RAISE EXCEPTION 'Survey not found or archived'; END IF;
    IF v_old.updated_at IS DISTINCT FROM p_updated_at THEN RAISE EXCEPTION 'This survey changed elsewhere. Reload before saving.'; END IF;
    IF (v_old.start_on IS DISTINCT FROM p_start_on OR v_old.schedule_kind IS DISTINCT FROM p_schedule_kind)
      AND p_start_on < (now() AT TIME ZONE 'Pacific/Auckland')::date THEN RAISE EXCEPTION 'Choose today or a future first run date when changing the schedule'; END IF;
    UPDATE public.staff_surveys SET name=btrim(p_name),description=p_description,questions=p_questions,schedule_kind=p_schedule_kind,start_on=p_start_on,
      duration_days=p_duration_days,schedule_enabled=p_schedule_enabled,updated_at=clock_timestamp() WHERE id=p_id RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END;
$$;

CREATE FUNCTION private.launch_configured_staff_survey(p_survey_id uuid,p_closes_on date DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.staff_surveys; v_day date := (now() AT TIME ZONE 'Pacific/Auckland')::date; v_id uuid;
BEGIN
  IF NOT private.survey_admin() THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE='42501'; END IF;
  SELECT * INTO s FROM public.staff_surveys WHERE id=p_survey_id FOR UPDATE;
  IF NOT FOUND OR s.is_archived THEN RAISE EXCEPTION 'Survey not found or archived'; END IF;
  IF p_closes_on IS NOT NULL AND (p_closes_on<=v_day OR p_closes_on>v_day+60) THEN RAISE EXCEPTION 'Choose a closing date within the next 60 days'; END IF;
  v_id := private.create_configured_survey_run(s.id,v_day,now(),coalesce(p_closes_on,v_day+s.duration_days)::timestamp AT TIME ZONE 'Pacific/Auckland','admin');
  IF v_id IS NULL THEN RAISE EXCEPTION 'This survey has an overlapping open run or has already run today'; END IF;
  RETURN v_id;
END;
$$;

CREATE FUNCTION private.archive_staff_survey(p_survey_id uuid,p_archived boolean,p_updated_at timestamptz) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT private.survey_admin() THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE='42501'; END IF;
  IF p_archived IS NULL THEN RAISE EXCEPTION 'Archive status is required'; END IF;
  UPDATE public.staff_surveys SET is_archived=p_archived,updated_at=clock_timestamp() WHERE id=p_survey_id AND updated_at=p_updated_at;
  IF NOT FOUND THEN RAISE EXCEPTION 'Survey changed elsewhere. Reload before continuing.'; END IF;
END;
$$;

CREATE FUNCTION private.save_configured_staff_survey_response(p_round_id uuid,p_answers jsonb,p_submit boolean,p_revision integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.staff_survey_rounds; existing public.staff_survey_responses; result public.staff_survey_responses; q jsonb; a jsonb; v_empty boolean; v_count integer;
BEGIN
  IF NOT private.survey_active_user() THEN RAISE EXCEPTION 'Active staff access required' USING ERRCODE='42501'; END IF;
  SELECT * INTO r FROM public.staff_survey_rounds WHERE id=p_round_id FOR SHARE;
  IF NOT FOUND OR now()<r.opens_at OR now()>=r.closes_at OR r.closed_at IS NOT NULL THEN RAISE EXCEPTION 'This survey is closed'; END IF;
  PERFORM 1 FROM public.staff_survey_participants WHERE round_id=p_round_id AND user_id=auth.uid() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'You are not a participant in this survey' USING ERRCODE='42501'; END IF;
  SELECT * INTO existing FROM public.staff_survey_responses WHERE round_id=p_round_id AND user_id=auth.uid();
  IF existing.submitted_at IS NOT NULL THEN RAISE EXCEPTION 'Your response has already been submitted'; END IF;
  IF p_revision IS DISTINCT FROM coalesce(existing.revision,0) THEN RAISE EXCEPTION 'Your response changed in another session. Reload before continuing.'; END IF;
  IF p_submit IS NULL OR p_answers IS NULL OR jsonb_typeof(p_answers)<>'object' THEN RAISE EXCEPTION 'Invalid answers'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_answers) k WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements(r.question_schema) field(value) WHERE field.value->>'id'=k)) THEN
    RAISE EXCEPTION 'Answers include a question that is not in this survey'; END IF;
  FOR q IN SELECT value FROM jsonb_array_elements(r.question_schema) LOOP
    a := p_answers->(q->>'id');
    v_empty := a IS NULL OR a='null'::jsonb OR a='""'::jsonb OR a='[]'::jsonb;
    IF q->>'type'='text' AND jsonb_typeof(a)='string' THEN v_empty := btrim(a #>> '{}')=''; END IF;
    IF v_empty THEN
      IF p_submit AND (q->>'required')::boolean THEN RAISE EXCEPTION 'Please answer every required question'; END IF;
      CONTINUE;
    END IF;
    IF q->>'type' IN ('agreement','rating') THEN
      IF jsonb_typeof(a)<>'number' OR a::text !~ '^[0-9]+$' THEN RAISE EXCEPTION 'Ratings must be whole numbers'; END IF;
      IF (a::text)::numeric NOT BETWEEN 1 AND (CASE WHEN q->>'type'='agreement' THEN 5 ELSE (q->>'scale_max')::int END) THEN
        RAISE EXCEPTION 'Rating is outside the configured scale'; END IF;
    ELSIF q->>'type'='yes_no' THEN
      IF jsonb_typeof(a)<>'boolean' THEN RAISE EXCEPTION 'Yes/no answers must be yes or no'; END IF;
    ELSIF q->>'type'='single_choice' THEN
      IF jsonb_typeof(a)<>'string' OR NOT (q->'options') @> jsonb_build_array(a) THEN RAISE EXCEPTION 'Choose an option from this question'; END IF;
    ELSIF q->>'type'='multi_choice' THEN
      IF jsonb_typeof(a)<>'array' THEN RAISE EXCEPTION 'Choose one or more listed options'; END IF;
      SELECT count(DISTINCT v) INTO v_count FROM jsonb_array_elements(a) v;
      IF jsonb_array_length(a)<>v_count OR NOT (q->'options') @> a THEN RAISE EXCEPTION 'Choose unique options from this question'; END IF;
    ELSIF q->>'type'='text' THEN
      IF jsonb_typeof(a)<>'string' OR length(a #>> '{}')>2000 THEN RAISE EXCEPTION 'Written answers must be at most 2,000 characters'; END IF;
    END IF;
  END LOOP;
  INSERT INTO public.staff_survey_responses(round_id,user_id,answers,scores,comments,revision,submitted_at)
  VALUES(p_round_id,auth.uid(),p_answers,'[]',ARRAY['',''],p_revision+1,CASE WHEN p_submit THEN now() END)
  ON CONFLICT(round_id,user_id) DO UPDATE SET answers=excluded.answers,revision=excluded.revision,updated_at=clock_timestamp(),submitted_at=excluded.submitted_at
  RETURNING * INTO result;
  RETURN to_jsonb(result);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_admin_staff_surveys() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_day date := (now() AT TIME ZONE 'Pacific/Auckland')::date;
BEGIN
  IF NOT private.survey_admin() THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE='42501'; END IF;
  RETURN jsonb_build_object('surveys',(SELECT coalesce(jsonb_agg(to_jsonb(s) || jsonb_build_object('next_run_on',
    CASE WHEN NOT s.schedule_enabled OR s.is_archived THEN NULL
      WHEN d.due IS NOT NULL AND v_day < d.due+least(7,s.duration_days) AND NOT EXISTS(SELECT 1 FROM public.staff_survey_rounds r WHERE r.survey_id=s.id AND r.run_on=d.due) THEN d.due
      ELSE private.staff_survey_next_occurrence(s.schedule_kind,s.start_on,v_day) END) ORDER BY s.is_archived,s.created_at),'[]'::jsonb)
    FROM public.staff_surveys s CROSS JOIN LATERAL (SELECT private.staff_survey_occurrence(s.schedule_kind,s.start_on,v_day) due) d),
    'rounds',(SELECT coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object(
      'participant_count',(SELECT count(*) FROM public.staff_survey_participants p WHERE p.round_id=r.id),
      'submitted_count',(SELECT count(*) FROM public.staff_survey_responses s WHERE s.round_id=r.id AND s.submitted_at IS NOT NULL)) ORDER BY r.opens_at DESC),'[]'::jsonb) FROM public.staff_survey_rounds r));
END;
$$;

CREATE FUNCTION public.save_staff_survey_definition(p_id uuid,p_name text,p_description text,p_questions jsonb,p_schedule_kind text,p_start_on date,p_duration_days integer,p_schedule_enabled boolean,p_updated_at timestamptz) RETURNS uuid
LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT private.save_staff_survey_definition(p_id,p_name,p_description,p_questions,p_schedule_kind,p_start_on,p_duration_days,p_schedule_enabled,p_updated_at); $$;
CREATE FUNCTION public.launch_configured_staff_survey(p_survey_id uuid,p_closes_on date DEFAULT NULL) RETURNS uuid
LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT private.launch_configured_staff_survey(p_survey_id,p_closes_on); $$;
CREATE FUNCTION public.archive_staff_survey(p_survey_id uuid,p_archived boolean,p_updated_at timestamptz) RETURNS void
LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT private.archive_staff_survey(p_survey_id,p_archived,p_updated_at); $$;
CREATE FUNCTION public.save_configured_staff_survey_response(p_round_id uuid,p_answers jsonb,p_submit boolean,p_revision integer) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT private.save_configured_staff_survey_response(p_round_id,p_answers,p_submit,p_revision); $$;

-- Retire fixed-size mutation entry points so they cannot bypass typed validation.
DROP FUNCTION public.launch_staff_survey(date);
DROP FUNCTION private.launch_staff_survey(date);
DROP FUNCTION public.save_staff_survey_settings(jsonb,jsonb,boolean,timestamptz);
DROP FUNCTION private.save_staff_survey_settings(jsonb,jsonb,boolean,timestamptz);
DROP FUNCTION public.save_staff_survey_response(uuid,jsonb,text[],boolean,integer);
DROP FUNCTION private.save_staff_survey_response(uuid,jsonb,text[],boolean,integer);
DROP FUNCTION private.create_staff_survey_round(timestamptz,text,timestamptz);

DO $$ DECLARE f record; BEGIN
  FOR f IN SELECT p.oid::regprocedure signature,p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname IN('public','private') AND p.proname IN('valid_staff_survey_schema','legacy_staff_survey_schema','staff_survey_occurrence',
      'staff_survey_next_occurrence','create_configured_survey_run','save_staff_survey_definition','launch_configured_staff_survey',
      'archive_staff_survey','save_configured_staff_survey_response') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated',f.signature);
    IF f.proname NOT IN('legacy_staff_survey_schema','create_configured_survey_run') THEN EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated',f.signature); END IF;
  END LOOP;
END $$;
-- Existing hourly cron job now services all enabled definitions, not just pulse.
NOTIFY pgrst,'reload schema';
COMMIT;
