// Verify the additive builder migration against legacy answers in an isolated
// restore. Never restore over postgres or run scheduled jobs in the scratch DB.
import assert from 'node:assert/strict'
import { createHash, randomBytes } from 'node:crypto'
import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { assertLocalDocker, docker, localDir, root } from './runtime.mjs'

const scratch = `oscarapp_survey_migration_${randomBytes(6).toString('hex')}`
const backup = process.argv[2] ?? join(localDir,'checkpoints/2026-11-10T04-45-23-938Z')
const query = source => docker(['exec','-i','oscarapp-db','psql','-U','postgres','-d',scratch,'-X','-At','-v','ON_ERROR_STOP=1'],{input:source})
try {
  assertLocalDocker()
  const verification = JSON.parse(await readFile(join(backup,'verification.json'),'utf8'))
  assert.equal(verification.restoreVerified,true)
  const file=join(backup,'database.dump')
  assert.equal(createHash('sha256').update(await readFile(file)).digest('hex'),verification.sha256)
  docker(['cp',file,`oscarapp-db:/tmp/${scratch}.dump`])
  docker(['cp',join(backup,'scratch-restore.list'),`oscarapp-db:/tmp/${scratch}.list`])
  docker(['exec','oscarapp-db','psql','-U','supabase_admin','-d','postgres','-X','-v','ON_ERROR_STOP=1','-c',`create database ${scratch} owner postgres template template0;`])
  docker(['exec','oscarapp-db','pg_restore','-U','supabase_admin','--dbname',scratch,'--exit-on-error','--use-list',`/tmp/${scratch}.list`,`/tmp/${scratch}.dump`])
  assert.equal(query("select to_regclass('public.staff_surveys') is null;"),'t','Checkpoint must predate the builder migration')
  const before=query("select md5(string_agg(to_jsonb(c)::text,'' order by c.id)) from public.v_commission_calculations_core c;")
  const rid=query(`begin;
    insert into auth.users(id,email) values('ca720000-0000-4000-8000-000000000001','migration-fixture@oscarapp.test');
    insert into public.staff_members(id,full_name) values('ca720000-0000-4000-8000-000000000011','Migration fixture');
    insert into public.staff_member_user_access(user_id,staff_member_id,access_role,is_active)
      values('ca720000-0000-4000-8000-000000000001','ca720000-0000-4000-8000-000000000011','stylist',true);
    select private.create_staff_survey_round(now()-interval '3 months','automatic',now()-interval '3 months'+interval '14 days');
    commit;`).split('\n').find(line=>/^[0-9a-f-]{36}$/.test(line))
  assert(rid)
  query(`insert into public.staff_survey_responses(round_id,user_id,scores,comments,revision,submitted_at)
    values('${rid}','ca720000-0000-4000-8000-000000000001','[1,2,3,4,5,1,2,3,4,5]',array['Keep learning','More practice'],2,now()-interval '2 months');`)
  query(await readFile(join(root,'supabase/migrations/20261110071543_configurable_staff_surveys.sql'),'utf8'))
  const migrated=JSON.parse(query(`select jsonb_build_object('schema',r.question_schema,'answers',s.answers,'revision',s.revision,'submitted',s.submitted_at is not null)
    from public.staff_survey_rounds r join public.staff_survey_responses s on s.round_id=r.id where r.id='${rid}';`))
  assert.equal(migrated.schema.length,12)
  assert.equal(migrated.schema[5].prompt,'My work feels manageable within my rostered hours.')
  assert.equal(migrated.answers['pulse-rating-10'],5)
  assert.equal(migrated.answers['pulse-text-1'],'Keep learning')
  assert.equal(migrated.answers['pulse-text-2'],'More practice')
  assert.equal(migrated.revision,2);assert.equal(migrated.submitted,true)
  assert.equal(query("select md5(string_agg(to_jsonb(c)::text,'' order by c.id)) from public.v_commission_calculations_core c;"),before)
  await writeFile(join(localDir,'survey-migration-check.log'),'PASS: fresh pre-builder restore, legacy 12-question snapshots and submitted ratings/comments/revision preserved, payroll digest unchanged.\n',{mode:0o600})
  docker(['exec','oscarapp-db','psql','-U','supabase_admin','-d','postgres','-X','-v','ON_ERROR_STOP=1','-c',`drop database ${scratch};`])
  console.log('PASS: builder migration preserves legacy questions, named answers, revision and payroll digest in an isolated restore. Scratch database removed.')
} catch(error) {console.error(error.message);console.error(`Inspect scratch database ${scratch}; working database was not restored or reset.`);process.exitCode=1}
