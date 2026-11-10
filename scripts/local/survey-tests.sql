-- Configurable survey integration tests. Every fixture rolls back.
BEGIN;
CREATE FUNCTION pg_temp.survey_denied(p_sql text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE denied boolean:=false;
BEGIN
  BEGIN EXECUTE p_sql; EXCEPTION WHEN insufficient_privilege OR raise_exception OR check_violation THEN denied:=true; END;
  IF NOT denied THEN RAISE EXCEPTION 'Expected denial: %',p_sql; END IF;
END $$;
UPDATE public.staff_surveys SET schedule_enabled=false;
INSERT INTO auth.users(id,email) VALUES
  ('ca710000-0000-4000-8000-000000000001','survey-employee-a@oscarapp.test'),
  ('ca710000-0000-4000-8000-000000000002','survey-employee-b@oscarapp.test'),
  ('ca710000-0000-4000-8000-000000000003','survey-manager@oscarapp.test'),
  ('ca710000-0000-4000-8000-000000000004','survey-inactive@oscarapp.test'),
  ('ca710000-0000-4000-8000-000000000005','survey-unassigned@oscarapp.test');
INSERT INTO public.staff_members(id,full_name) VALUES
  ('ca710000-0000-4000-8000-000000000011','Survey fixture A'),
  ('ca710000-0000-4000-8000-000000000012','Survey fixture B');
INSERT INTO public.staff_member_user_access(user_id,staff_member_id,access_role,is_active) VALUES
  ('ca710000-0000-4000-8000-000000000001','ca710000-0000-4000-8000-000000000011','stylist',true),
  ('ca710000-0000-4000-8000-000000000002','ca710000-0000-4000-8000-000000000012','reception',true),
  ('ca710000-0000-4000-8000-000000000003','ca710000-0000-4000-8000-000000000012','manager',true),
  ('ca710000-0000-4000-8000-000000000004','ca710000-0000-4000-8000-000000000011','stylist',false),
  ('ca710000-0000-4000-8000-000000000005',null,'stylist',true);
SELECT set_config('survey_test.schema','[
 {"id":"agree","prompt":"I feel supported.","type":"agreement","required":true},
 {"id":"rating","prompt":"How useful was training?","type":"rating","required":true,"scale_max":10,"low_label":"Not useful","high_label":"Very useful"},
 {"id":"yes","prompt":"Would you attend again?","type":"yes_no","required":true},
 {"id":"one","prompt":"Preferred time?","type":"single_choice","required":true,"options":["Morning","Afternoon"]},
 {"id":"many","prompt":"Which topics?","type":"multi_choice","required":true,"options":["Learning","Roster","Products"]},
 {"id":"written","prompt":"Any suggestions?","type":"text","required":false}
]',true);
SELECT set_config('survey_test.answers','{"agree":4,"rating":8,"yes":false,"one":"Morning","many":["Learning","Roster"],"written":""}',true);
SELECT set_config('request.jwt.claim.sub',id::text,true),set_config('request.jwt.claims',jsonb_build_object('sub',id,'role','authenticated')::text,true)
FROM auth.users WHERE email='local-admin@oscarapp.test';
SET LOCAL ROLE authenticated;
SELECT set_config('survey_test.survey',public.save_staff_survey_definition(null,'TEST configurable survey','Test purpose',current_setting('survey_test.schema')::jsonb,'manual',null,14,false,null)::text,true);
SELECT set_config('survey_test.round',public.launch_configured_staff_survey(current_setting('survey_test.survey')::uuid)::text,true);
DO $$ DECLARE sid uuid:=current_setting('survey_test.survey')::uuid; rid uuid:=current_setting('survey_test.round')::uuid; s public.staff_surveys; changed jsonb;
BEGIN
  ASSERT (SELECT jsonb_array_length(question_schema) FROM public.staff_survey_rounds WHERE id=rid)=6;
  ASSERT NOT EXISTS(SELECT 1 FROM public.staff_survey_participants WHERE round_id=rid AND user_id IN('ca710000-0000-4000-8000-000000000004','ca710000-0000-4000-8000-000000000005'));
  PERFORM pg_temp.survey_denied(format('select public.launch_configured_staff_survey(%L)',sid));
  SELECT * INTO s FROM public.staff_surveys WHERE id=sid;
  changed:=jsonb_set(s.questions,'{0,prompt}','"Future question wording."');
  PERFORM public.save_staff_survey_definition(sid,'Updated future title','Future purpose',changed,'manual',null,14,false,s.updated_at);
  ASSERT (SELECT question_schema->0->>'prompt' FROM public.staff_survey_rounds WHERE id=rid)='I feel supported.';
  ASSERT (SELECT title FROM public.staff_survey_rounds WHERE id=rid)='TEST configurable survey';
  PERFORM pg_temp.survey_denied(format('select public.save_staff_survey_definition(%L,''Stale'','''',%L::jsonb,''manual'',null,14,false,%L)',sid,s.questions,s.updated_at));
  PERFORM pg_temp.survey_denied(format('select public.save_staff_survey_definition(null,''Invalid'','''',%L::jsonb,''weekly'',current_date+1,14,true,null)',s.questions));
  PERFORM pg_temp.survey_denied($q$select public.save_staff_survey_definition(null,'Empty','','[]','manual',null,14,false,null)$q$);
  PERFORM pg_temp.survey_denied($q$select public.save_staff_survey_definition(null,'Duplicate options','','[{"id":"x","prompt":"Q?","type":"single_choice","required":true,"options":["Yes"," yes "]}]','manual',null,14,false,null)$q$);
  PERFORM pg_temp.survey_denied($q$select public.save_staff_survey_definition(null,'Null type','','[{"id":"x","prompt":"Q?","type":null,"required":true}]','manual',null,14,false,null)$q$);
  PERFORM pg_temp.survey_denied($q$select public.update_role_page_permission('admin_surveys','manager','full')$q$);
END $$;

SELECT set_config('request.jwt.claim.sub','ca710000-0000-4000-8000-000000000001',true);
SELECT set_config('request.jwt.claims','{"sub":"ca710000-0000-4000-8000-000000000001","role":"authenticated"}',true);
DO $$ DECLARE rid uuid:=current_setting('survey_test.round')::uuid; a jsonb:=current_setting('survey_test.answers')::jsonb; r jsonb;
BEGIN
  ASSERT (SELECT count(*) FROM public.staff_surveys)=0,'Staff must not read definition settings';
  ASSERT (SELECT count(*) FROM public.staff_survey_participants)=1,'Staff see only their own participation';
  PERFORM pg_temp.survey_denied('select public.get_admin_staff_surveys()');
  PERFORM pg_temp.survey_denied(format('select public.get_staff_survey_results(%L)',rid));
  PERFORM pg_temp.survey_denied(format('select public.launch_configured_staff_survey(%L)',current_setting('survey_test.survey')));
  PERFORM pg_temp.survey_denied('select private.launch_due_staff_survey()');
  PERFORM pg_temp.survey_denied('update public.staff_survey_rounds set title=''Tampered''');
  ASSERT public.remind_staff_survey_later(rid)>now()+interval '23 hours';
  PERFORM pg_temp.survey_denied(format('select public.save_configured_staff_survey_response(%L,''{}'',true,0)',rid));
  PERFORM pg_temp.survey_denied(format('select public.save_configured_staff_survey_response(%L,%L,true,0)',rid,a-'yes'));
  PERFORM pg_temp.survey_denied(format('select public.save_configured_staff_survey_response(%L,%L,false,0)',rid,jsonb_set(a,'{rating}','11')));
  PERFORM pg_temp.survey_denied(format('select public.save_configured_staff_survey_response(%L,%L,false,0)',rid,jsonb_set(a,'{agree}','1.5')));
  PERFORM pg_temp.survey_denied(format('select public.save_configured_staff_survey_response(%L,%L,false,0)',rid,jsonb_set(a,'{yes}','"No"')));
  PERFORM pg_temp.survey_denied(format('select public.save_configured_staff_survey_response(%L,%L,false,0)',rid,jsonb_set(a,'{one}','"Evening"')));
  PERFORM pg_temp.survey_denied(format('select public.save_configured_staff_survey_response(%L,%L,false,0)',rid,jsonb_set(a,'{many}','["Learning","Learning"]')));
  PERFORM pg_temp.survey_denied(format('select public.save_configured_staff_survey_response(%L,%L,false,0)',rid,jsonb_set(a,'{many}','["Unknown"]')));
  PERFORM pg_temp.survey_denied(format('select public.save_configured_staff_survey_response(%L,%L,true,0)',rid,jsonb_set(a,'{many}','[]')));
  PERFORM pg_temp.survey_denied(format('select public.save_configured_staff_survey_response(%L,%L,false,0)',rid,jsonb_set(a,'{written}',to_jsonb(repeat('x',2001)))));
  PERFORM pg_temp.survey_denied(format('select public.save_configured_staff_survey_response(%L,%L,false,0)',rid,a||'{"unknown":1}'));
  r:=public.save_configured_staff_survey_response(rid,'{"yes":false}',false,0);
  ASSERT r->'answers'->'yes'='false'::jsonb AND r->>'submitted_at' IS NULL;
  PERFORM pg_temp.survey_denied(format('select public.save_configured_staff_survey_response(%L,%L,false,0)',rid,a));
END $$;

RESET ROLE;
SELECT set_config('request.jwt.claim.sub',id::text,true),set_config('request.jwt.claims',jsonb_build_object('sub',id,'role','authenticated')::text,true)
FROM auth.users WHERE email='local-admin@oscarapp.test';
SET LOCAL ROLE authenticated;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.staff_survey_responses WHERE round_id=current_setting('survey_test.round')::uuid)=0,'Admin must not read employee drafts';
  ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.get_staff_survey_results(current_setting('survey_test.round')::uuid)) p WHERE p->'response'<>'null'::jsonb);
END $$;
SELECT set_config('request.jwt.claim.sub','ca710000-0000-4000-8000-000000000002',true);
SELECT set_config('request.jwt.claims','{"sub":"ca710000-0000-4000-8000-000000000002","role":"authenticated"}',true);
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.staff_survey_responses)=0; END $$;
SELECT set_config('request.jwt.claim.sub','ca710000-0000-4000-8000-000000000001',true);
SELECT set_config('request.jwt.claims','{"sub":"ca710000-0000-4000-8000-000000000001","role":"authenticated"}',true);
SELECT public.save_configured_staff_survey_response(current_setting('survey_test.round')::uuid,current_setting('survey_test.answers')::jsonb,true,1);
SELECT pg_temp.survey_denied(format('select public.save_configured_staff_survey_response(%L,%L,true,2)',current_setting('survey_test.round'),current_setting('survey_test.answers')));
SELECT pg_temp.survey_denied(format('select public.remind_staff_survey_later(%L)',current_setting('survey_test.round')));
SELECT set_config('request.jwt.claim.sub','ca710000-0000-4000-8000-000000000003',true);
SELECT set_config('request.jwt.claims','{"sub":"ca710000-0000-4000-8000-000000000003","role":"authenticated"}',true);
SELECT pg_temp.survey_denied('select public.get_admin_staff_surveys()');
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.staff_survey_responses)=0,'Managers cannot read other submitted responses'; END $$;
SELECT set_config('request.jwt.claim.sub','ca710000-0000-4000-8000-000000000004',true);
SELECT set_config('request.jwt.claims','{"sub":"ca710000-0000-4000-8000-000000000004","role":"authenticated"}',true);
DO $$ BEGIN ASSERT public.get_my_staff_surveys()='[]'::jsonb; END $$;
SELECT set_config('request.jwt.claim.sub','ca710000-0000-4000-8000-000000000005',true);
SELECT set_config('request.jwt.claims','{"sub":"ca710000-0000-4000-8000-000000000005","role":"authenticated"}',true);
SELECT pg_temp.survey_denied(format('select public.save_configured_staff_survey_response(%L,%L,true,0)',current_setting('survey_test.round'),current_setting('survey_test.answers')));

RESET ROLE;
SELECT set_config('request.jwt.claim.sub',id::text,true),set_config('request.jwt.claims',jsonb_build_object('sub',id,'role','authenticated')::text,true)
FROM auth.users WHERE email='local-admin@oscarapp.test';
SET LOCAL ROLE authenticated;
DO $$ DECLARE sid uuid:=current_setting('survey_test.survey')::uuid; r jsonb; stamp timestamptz;
BEGIN
  SELECT p INTO STRICT r FROM jsonb_array_elements(public.get_staff_survey_results(current_setting('survey_test.round')::uuid)) p WHERE p->>'user_id'='ca710000-0000-4000-8000-000000000001';
  ASSERT r->>'staff_name'='Survey fixture A';
  ASSERT r->'response'->'answers'->'yes'='false'::jsonb;
  PERFORM public.close_staff_survey(current_setting('survey_test.round')::uuid);
  SELECT updated_at INTO stamp FROM public.staff_surveys WHERE id=sid;
  PERFORM public.archive_staff_survey(sid,true,stamp);
  PERFORM pg_temp.survey_denied(format('select public.launch_configured_staff_survey(%L)',sid));
  SELECT updated_at INTO stamp FROM public.staff_surveys WHERE id=sid;
  PERFORM public.archive_staff_survey(sid,false,stamp);
  ASSERT (SELECT count(*) FROM public.staff_survey_responses WHERE round_id=current_setting('survey_test.round')::uuid)=1,'Archiving/restoring must preserve submissions';
END $$;
SELECT set_config('request.jwt.claim.sub','ca710000-0000-4000-8000-000000000002',true);
SELECT set_config('request.jwt.claims','{"sub":"ca710000-0000-4000-8000-000000000002","role":"authenticated"}',true);
SELECT pg_temp.survey_denied(format('select public.save_configured_staff_survey_response(%L,%L,true,0)',current_setting('survey_test.round'),current_setting('survey_test.answers')));
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.survey_denied('select public.get_my_staff_surveys()');
SELECT pg_temp.survey_denied('select public.get_admin_staff_surveys()');
SELECT pg_temp.survey_denied('select * from public.staff_surveys');
RESET ROLE;

DO $$ DECLARE sid uuid; rid uuid; q jsonb:=current_setting('survey_test.schema')::jsonb;
BEGIN
  ASSERT private.staff_survey_occurrence('monthly','2095-01-31','2095-02-28')='2095-02-28'::date;
  ASSERT private.staff_survey_next_occurrence('monthly','2095-01-31','2095-02-28')='2095-03-31'::date;
  ASSERT private.staff_survey_occurrence('yearly','2096-02-29','2097-02-28')='2097-02-28'::date;
  ASSERT private.staff_survey_next_occurrence('yearly','2096-02-29','2099-02-28')='2100-02-28'::date;
  ASSERT private.staff_survey_occurrence('quarterly','2095-10-31','2096-04-30')='2096-04-30'::date;
  ASSERT private.staff_survey_occurrence('weekly','2096-01-01','2096-01-08')='2096-01-08'::date;
  ASSERT private.staff_survey_occurrence('once','2096-01-01','2095-12-31') IS NULL;
  ASSERT NOT has_function_privilege('authenticated','private.create_configured_survey_run(uuid,date,timestamptz,timestamptz,text)','EXECUTE');
  ASSERT NOT has_function_privilege('authenticated','private.launch_due_staff_survey(timestamptz)','EXECUTE');
  INSERT INTO public.staff_surveys(name,questions,schedule_kind,start_on,duration_days,schedule_enabled)
    VALUES('Scheduled test',q,'monthly','2096-01-31',14,true) RETURNING id INTO sid;
  PERFORM private.launch_due_staff_survey('2096-01-31 00:00:00+13');
  SELECT id INTO STRICT rid FROM public.staff_survey_rounds WHERE survey_id=sid AND run_on='2096-01-31';
  ASSERT (SELECT opens_at FROM public.staff_survey_rounds WHERE id=rid)='2096-01-31 00:00:00+13'::timestamptz;
  PERFORM private.launch_due_staff_survey('2096-02-01 12:00:00+13');
  ASSERT (SELECT count(*) FROM public.staff_survey_rounds WHERE survey_id=sid)=1;
  PERFORM private.launch_due_staff_survey('2096-03-06 00:00:00+13');
  ASSERT EXISTS(SELECT 1 FROM public.staff_survey_rounds WHERE survey_id=sid AND run_on='2096-02-29'),'First-week catch-up in leap month';
  PERFORM private.launch_due_staff_survey('2096-04-08 00:00:00+12');
  ASSERT NOT EXISTS(SELECT 1 FROM public.staff_survey_rounds WHERE survey_id=sid AND run_on='2096-03-31'),'Do not start a missed occurrence after the retry window';
  UPDATE public.staff_surveys SET is_archived=true WHERE id=sid;
  PERFORM private.launch_due_staff_survey('2096-05-31 00:00:00+12');
  ASSERT (SELECT count(*) FROM public.staff_survey_rounds WHERE survey_id=sid)=2;
END $$;
SELECT 'PASS: all six question types, No as an answer, required/optional validation, snapshots, revision conflicts, private drafts, admin-only named results, closing/archive, NZ schedules, short months, leap years and duplicate prevention';
ROLLBACK;
