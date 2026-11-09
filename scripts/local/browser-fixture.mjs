import { access, writeFile, unlink } from 'node:fs/promises'
import { join } from 'node:path'
import { assertLocalDocker, localDir, sql } from './runtime.mjs'

const ids = {
  staff: 'b7010000-0000-4000-8000-000000000001',
  plan: 'b7010000-0000-4000-8000-000000000002',
  service: 'b7010000-0000-4000-8000-000000000003',
  sale: 'b7010000-0000-4000-8000-000000000004',
  assignment: 'b7010000-0000-4000-8000-000000000005',
}
const names = {
  staff: 'OSCAR TEST Cost Stylist b701', plan: 'OSCAR TEST Cost Plan b701',
  service: 'OSCAR TEST Cost Service b701', invoice: 'OSCAR TEST INVOICE b701',
}
const manifestPath = join(localDir, 'browser-fixture.json')
const claims = `select set_config('request.jwt.claim.sub',id::text,true),set_config('request.jwt.claims',jsonb_build_object('sub',id,'role','authenticated')::text,true) from auth.users where email='local-admin@oscarapp.test';`

try {
  assertLocalDocker()
  const action = process.argv[2]
  if (action === 'setup') {
    try {
      await access(manifestPath)
      throw new Error('A browser-fixture manifest already exists. Inspect or cleanup it before setup.')
    } catch (error) {
      if (error.code !== 'ENOENT') throw error
    }
    sql(`begin;
      ${claims}
      do $fixture$
      declare sample public.sales_transactions; test_sale public.sales_transactions;
      begin
        if exists(select 1 from public.staff_members where id='${ids.staff}')
          or exists(select 1 from public.remuneration_plans where id='${ids.plan}')
          or exists(select 1 from public.service_product_cost_services where id='${ids.service}')
          or exists(select 1 from public.sales_transactions where id='${ids.sale}') then
          raise exception 'Browser fixture IDs already exist. Inspect or cleanup the previous fixture; setup will not overwrite them.';
        end if;
        select * into strict sample from public.sales_transactions where id=(
          select id from public.v_commission_calculations_core where invoice='INV98610' and product_service_name='Colour Root Retouch Emerging Colourist' limit 1);
        insert into public.remuneration_plans(id,plan_name,can_use_assistants,is_active,deduct_service_product_costs,conditions_text)
          values('${ids.plan}','${names.plan}',false,true,true,'Disposable local browser fixture');
        insert into public.remuneration_plan_rates(remuneration_plan_id,commission_category,rate)
          select '${ids.plan}',category,case when category in('service','extensions_service') then 0.35 else 0.1 end
          from unnest(array['retail_product','professional_product','service','toner_with_other_service','extensions_product','extensions_service']) category;
        insert into public.staff_members(id,full_name,display_name,primary_role,remuneration_plan,remuneration_plan_id,
          employment_type,primary_location_id,fte,employment_start_date,is_active,notes)
          values('${ids.staff}','${names.staff}','${names.staff}','Senior Stylist','${names.plan}','${ids.plan}',
          'Employee',sample.location_id,1,'2026-11-01',true,'Disposable local browser fixture');
        insert into public.staff_role_assignments(id,staff_member_id,effective_start_date,primary_role,remuneration_plan,
          remuneration_plan_id,employment_type,primary_location_id,fte,reason)
          values('${ids.assignment}','${ids.staff}','2026-11-01','Senior Stylist','${names.plan}','${ids.plan}',
          'Employee',sample.location_id,1,'Disposable local browser fixture');
        insert into public.service_product_cost_services(id,service_name) values('${ids.service}','${names.service}');
        insert into public.service_product_cost_aliases(description_key,service_id) values(lower('${names.service}'),'${ids.service}');
        test_sale:=sample;test_sale.id:='${ids.sale}';test_sale.raw_row_id:=null;
        test_sale.invoice:='${names.invoice}';test_sale.customer_name:='OSCAR TEST Client';
        test_sale.sale_date:='2026-11-02';test_sale.sale_datetime:='2026-11-02 12:00:00+13';
        test_sale.month_start:='2026-11-01';test_sale.month_num:=11;test_sale.day_name:='Monday';
        test_sale.product_service_name:='${names.service}';test_sale.product_master_id:=null;
        test_sale.raw_product_type:='Service';test_sale.product_type_actual:='Service';test_sale.product_type_short:='Services';
        test_sale.quantity:=1;test_sale.price_ex_gst:=149.57;test_sale.price_incl_gst:=172.0055;test_sale.price_gst_component:=22.4355;
        test_sale.staff_commission_name:='${names.staff}';test_sale.staff_work_name:='${names.staff}';test_sale.staff_paid_name:='${names.staff}';
        test_sale.staff_commission_id:='${ids.staff}';test_sale.staff_work_id:='${ids.staff}';test_sale.staff_paid_id:='${ids.staff}';
        test_sale.staff_commission_type:='Stylist';test_sale.staff_work_type:='Stylist';test_sale.staff_paid_type:='Stylist';
        test_sale.staff_work_is_staff_paid:='Yes';test_sale.assistant_usage_alert:=null;
        insert into public.sales_transactions select(test_sale).*;
        assert exists(select 1 from public.get_payroll_cost_readiness('2026-11-02') where service_id='${ids.service}' and reason='missing_cost'),
          'Browser fixture must produce the missing-cost modal requirement';
      end;$fixture$;
      commit;`)
    await writeFile(manifestPath, `${JSON.stringify({ ids, names, week:'2026-11-02', effectiveFrom:'2026-11-01', unitCost:30, expectedActualCommission:41.85,
      note:'Synthetic staff/plan/service/sale only; original staff assignments and theoretical benchmark are unchanged.' }, null, 2)}\n`, { flag:'wx', mode:0o600 })
    console.log('Browser fixture created for week 2 November 2026. Enter $30 ex GST from 1 November to resolve it.')
    console.log('Manifest: local-db.local/browser-fixture.json. Cleanup: node scripts/local/browser-fixture.mjs cleanup')
  } else if (action === 'cleanup') {
    sql(`begin;
      ${claims}
      do $guard$ begin
        if exists(select 1 from public.staff_members where id='${ids.staff}' and full_name<>'${names.staff}')
          or exists(select 1 from public.remuneration_plans where id='${ids.plan}' and plan_name<>'${names.plan}')
          or exists(select 1 from public.service_product_cost_services where id='${ids.service}' and service_name<>'${names.service}')
          or exists(select 1 from public.sales_transactions where id='${ids.sale}' and invoice<>'${names.invoice}') then
          raise exception 'Fixture identity mismatch; cleanup refused';
        end if;
      end;$guard$;
      delete from public.sales_transactions where id='${ids.sale}';
      delete from public.staff_role_assignments where staff_member_id='${ids.staff}';
      delete from public.staff_members where id='${ids.staff}';
      delete from public.remuneration_plan_rates where remuneration_plan_id='${ids.plan}';
      delete from public.remuneration_plans where id='${ids.plan}';
      delete from public.service_product_cost_versions where service_id='${ids.service}';
      delete from public.service_product_source_mappings where service_id='${ids.service}';
      delete from public.service_product_cost_aliases where service_id='${ids.service}';
      delete from public.service_product_cost_services where id='${ids.service}';
      commit;`)
    try { await unlink(manifestPath) } catch(error) { if(error.code!=='ENOENT') throw error }
    console.log('Only the known synthetic browser-fixture identities were removed. Run npm run local:check to reconfirm the source baseline.')
  } else throw new Error('Use setup or cleanup. This script acts only on the fixed local Docker database.')
} catch(error) {
  console.error(error.message)
  process.exitCode=1
}
