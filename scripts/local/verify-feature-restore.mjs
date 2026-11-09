import assert from 'node:assert/strict'
import {randomBytes} from 'node:crypto'
import {mkdir,readFile,writeFile} from 'node:fs/promises'
import {join} from 'node:path'
import {assertLocalDocker,docker,localDir,root} from './runtime.mjs'

// Proves the checked-in migration applies to the unmodified source snapshot.
// No migration-history repair/replay or working-database reset is performed.
const database=`oscarapp_feature_verify_${randomBytes(6).toString('hex')}`
const containerDump=`/tmp/${database}.dump`
const query=(input)=>docker(['exec','-i','oscarapp-db','psql','-U','supabase_admin','-d',database,'-X','-At','-v','ON_ERROR_STOP=1'],{input})
const clusterQuery=(input)=>docker(['exec','-i','oscarapp-db','psql','-U','supabase_admin','-d','postgres','-X','-At','-v','ON_ERROR_STOP=1'],{input})
try {
  assertLocalDocker()
  docker(['cp',join(localDir,'checkpoints/2026-11-09T08-36-47-986Z/database.dump'),`oscarapp-db:${containerDump}`])
  clusterQuery(`create database ${database} template template0;`)
  docker(['exec','oscarapp-db','pg_restore','-U','supabase_admin','--dbname',database,'--exit-on-error',containerDump])
  const metadataQuery=`select jsonb_build_object(
    'staff',(select md5(string_agg((to_jsonb(s)-array['remuneration_plan_id','remuneration_plan_fallback_id'])::text,'' order by id)) from public.staff_members s),
    'history',(select md5(string_agg((to_jsonb(a)-'remuneration_plan_id')::text,'' order by id)) from public.staff_role_assignments a),
    'invoices',(select md5(string_agg(to_jsonb(i)::text,'' order by id)) from public.contractor_invoices i),
    'invoice_lines',(select md5(string_agg(to_jsonb(i)::text,'' order by id)) from public.contractor_invoice_lines i),
    'timestamp_triggers',(select jsonb_object_agg(tgname,tgenabled::text) from pg_trigger where tgrelid in ('public.staff_members'::regclass,'public.staff_role_assignments'::regclass) and tgname in ('trg_staff_members_updated_at','trg_staff_role_assignments_updated_at')));`
  const metadataBefore=JSON.parse(query(metadataQuery))
  const migrations=['20261109090656_service_product_costs.sql','20261109100957_service_cost_archive_dates.sql']
  for(const migration of migrations) query(await readFile(join(root,'supabase/migrations',migration),'utf8'))
  assert.deepEqual(JSON.parse(query(metadataQuery)),metadataBefore,'Migration changed existing staff/history metadata, invoices or timestamp trigger states')
  console.log('PASS: complete additive migrations apply to a fresh restore of the pre-feature checkpoint.')
  console.log('PASS: existing staff/history timestamps, invoice snapshots and trigger states remain unchanged.')
  const evidence=[]
  for(const file of ['service-cost-plan-tests.sql','service-cost-tests.sql','service-cost-permission-tests.sql','service-cost-archive-tests.sql']) {
    query(await readFile(join(root,'scripts/local',file),'utf8'))
    evidence.push(file)
    console.log(`PASS: ${file} on freshly migrated restore.`)
  }
  const baseline=JSON.parse(await readFile(join(localDir,'payroll-baseline.json'),'utf8'))
  const fields=Object.keys(baseline.lines[0])
  assert.ok(fields.every((field)=>/^[a-z_]+$/.test(field)))
  const lines=JSON.parse(query(`select jsonb_agg(to_jsonb(r) order by id) from (select ${fields.map((field)=>`"${field}"`).join(',')} from public.v_commission_calculations_core) r;`))
  const canonical=(rows)=>rows.map((row)=>JSON.stringify(Object.fromEntries(Object.entries(row).sort()))).sort().join('\n')
  assert.equal(lines.length,baseline.lines.length)
  assert.ok(canonical(lines)===canonical(baseline.lines),'Fresh migration changed original commission results')
  const report={verifiedAt:new Date().toISOString(),migrations,freshRestore:true,harnesses:evidence,unchangedHistoricalLines:lines.length,unchangedStaffHistoryAndInvoices:true,unchangedTimestampTriggers:true}
  await mkdir(join(localDir,'feature-checks'),{recursive:true})
  await writeFile(join(localDir,'feature-checks/fresh-restore.json'),JSON.stringify(report,null,2)+'\n')
  clusterQuery(`drop database ${database};`)
  console.log(`PASS: all ${lines.length} historical lines match; scratch database removed.`)
}catch(error){
  console.error(error.message)
  console.error(`Inspect local scratch database ${database}; working database was not reset.`)
  process.exitCode=1
}
