-- Archive metadata fixtures are local and rolled back.
BEGIN;
SET LOCAL plpgsql.check_asserts=on;
SELECT set_config('request.jwt.claim.sub',id::text,true),
 set_config('request.jwt.claims',jsonb_build_object('sub',id,'role','authenticated')::text,true)
FROM auth.users WHERE email='local-admin@oscarapp.test';
DO $$
DECLARE sid uuid; legacy uuid; first_archive timestamptz; stamp timestamptz; row_data record;
BEGIN
 sid:=public.create_service_product_cost_service('__ARCHIVE_TEST_'||gen_random_uuid()::text);
 ASSERT (SELECT archived_at IS NULL FROM public.service_product_cost_services WHERE id=sid),'Active services have no archive date';
 PERFORM public.set_service_product_cost_service_active(sid,false);
 SELECT archived_at INTO first_archive FROM public.service_product_cost_services WHERE id=sid;
 ASSERT first_archive=statement_timestamp(),'Archive date must be recorded by the server';
 SELECT * INTO row_data FROM public.get_service_product_costs() WHERE service_id=sid;
 ASSERT NOT row_data.is_active AND row_data.archived_at=first_archive,'Catalogue RPC exposes the recorded archive timestamp';
 PERFORM public.set_service_product_cost_service_active(sid,false);
 ASSERT (SELECT archived_at=first_archive FROM public.service_product_cost_services WHERE id=sid),'Repeated archive must retain its date';
 UPDATE public.service_product_cost_services SET archived_at='2000-01-01' WHERE id=sid;
 ASSERT (SELECT archived_at=first_archive FROM public.service_product_cost_services WHERE id=sid),'Updates cannot invent or replace an archive date';
 PERFORM public.set_service_product_cost_service_active(sid,true);
 ASSERT (SELECT archived_at IS NULL AND is_active FROM public.service_product_cost_services WHERE id=sid),'Reactivation clears the current archive date';
 PERFORM public.set_service_product_cost_service_active(sid,false);
 ASSERT (SELECT archived_at IS NOT NULL FROM public.service_product_cost_services WHERE id=sid),'Rearchiving records a new archive event';
 INSERT INTO public.service_product_cost_services(service_name,is_active)
 VALUES('__LEGACY_ARCHIVE_TEST_'||gen_random_uuid()::text,false) RETURNING id INTO legacy;
 PERFORM public.set_service_product_cost_service_active(legacy,false);
 ASSERT (SELECT archived_at IS NULL FROM public.service_product_cost_services WHERE id=legacy),'Legacy archives with unknown dates stay unknown';
 ASSERT NOT has_function_privilege('authenticated','private.get_service_product_costs_without_archive_date(date)','EXECUTE'),'Private catalogue implementation is not directly executable';
 ASSERT NOT has_function_privilege('anon','public.get_service_product_costs(date)','EXECUTE'),'Anon cannot read the catalogue';
END $$;
ROLLBACK;
