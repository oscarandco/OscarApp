// node scripts/local/survey-browser-check.mjs <playwright/index.mjs> [chromium executable]
// Uses only loopback services; cleans up its own surveys, runs and identities.
import assert from 'node:assert/strict'
import { randomBytes, randomUUID } from 'node:crypto'
import { writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { adminEmail, apiUrl, appUrl, assertLocalDocker, localDir, readRuntime, request, sql } from './runtime.mjs'

const { chromium } = await import(pathToFileURL(process.argv[2]).href)
const runtime = await readRuntime()
assertLocalDocker()
const name = `SURVEY TEST ${randomBytes(4).toString('hex')}`
const password = `${randomBytes(20).toString('base64url')}aA1!`
const fixtures = [0, 1, 2, 3].map(i => ({ staff: randomUUID(), name: `${name} ${i === 0 ? 'Hēmi Māori' : i === 3 ? 'Māia' : `staff ${i}`}`, email: `survey-${randomBytes(5).toString('hex')}@oscarapp.test`, id: null }))
let surveyId, roundId, previousId, adminToken, browser, failure
const created = new Set()
const log = [], errors = []
const pass = message => { log.push(`PASS: ${message}`); console.log(`PASS: ${message}`) }
const rpc = (fn, args = {}, token = adminToken) => request(runtime, `/rest/v1/rpc/${fn}`, { token, method: 'POST', body: JSON.stringify(args) })
const manifest = () => writeFile(join(localDir, 'survey-browser-fixture.json'), JSON.stringify({ name, fixtures, surveys: [...created], roundId, previousId }, null, 2), { mode: 0o600 })
const nextDate = days => {
  const parts = new Intl.DateTimeFormat('en-CA', { year:'numeric',month:'2-digit',day:'2-digit',timeZone:'Pacific/Auckland' }).formatToParts(new Date())
  const part = key => parts.find(p => p.type === key).value
  const date = new Date(`${part('year')}-${part('month')}-${part('day')}T12:00:00Z`)
  date.setUTCDate(date.getUTCDate()+days)
  return date.toISOString().slice(0,10)
}
async function login(page, email, passphrase) {
  await page.goto(`${appUrl}/login`)
  await page.getByLabel('Email', { exact:true }).fill(email)
  await page.getByLabel('Password', { exact:true }).fill(passphrase)
  await page.getByRole('button', { name:'Sign in',exact:true }).click()
  await page.waitForURL('**/app/**')
  await page.getByText('Local development', { exact:false }).first().waitFor()
}
async function context(suppressInvitations = false) {
  const ctx = await browser.newContext({ viewport:{ width:1440,height:1000 } })
  await ctx.route('**/*', route => {
    const url = new URL(route.request().url())
    if (['127.0.0.1','localhost'].includes(url.hostname) || ['data:','blob:'].includes(url.protocol)) return route.continue()
    errors.push(`Nonlocal request: ${url.origin}`); return route.abort()
  })
  ctx.on('page', page => page.on('pageerror', error => errors.push(error.message)))
  if(suppressInvitations) await ctx.route('**/rest/v1/rpc/get_my_staff_surveys',route=>route.fulfill({json:[]}))
  return ctx
}
const card = (page, title) => page.getByRole('article').filter({ has:page.getByRole('heading',{ name:title,exact:true }) })
async function keyboardSelect(locator) { await locator.focus(); await locator.press('Space') }

try {
  assert((await (await fetch(`${appUrl}/src/lib/env.ts`)).text()).includes(apiUrl))
  adminToken = (await request(runtime,'/auth/v1/token?grant_type=password',{ method:'POST',body:JSON.stringify({ email:adminEmail,password:runtime.adminPassword }) })).access_token
  const original = await rpc('get_admin_staff_surveys')
  const defaultPulse = original.surveys.find(s => s.id === '00000000-0000-4000-8000-000000000100')
  assert.equal(defaultPulse.questions[5].prompt,'My work feels manageable within my rostered hours.')
  for (const [i,f] of fixtures.entries()) {
    f.id = (await request(runtime,'/auth/v1/admin/users',{ service:true,method:'POST',body:JSON.stringify({ email:f.email,password,email_confirm:true }) })).id
    await manifest()
    sql(`begin; insert into public.staff_members(id,full_name,display_name) values('${f.staff}','${f.name}','${f.name}');
      insert into public.staff_member_user_access(user_id,staff_member_id,access_role,is_active) values('${f.id}','${f.staff}','${i===2?'manager':'stylist'}',true); commit;`)
  }
  browser = await chromium.launch({ headless:true,...(process.argv[3]?{executablePath:process.argv[3]}:{}) })
  const admin = await (await context(true)).newPage()
  await login(admin,adminEmail,runtime.adminPassword)
  await admin.goto(`${appUrl}/app/admin/surveys`)
  await admin.getByRole('button',{name:'Create survey',exact:true}).click()
  await admin.getByLabel('Survey name',{exact:true}).fill(name)
  await admin.getByLabel('Introduction / purpose',{exact:true}).fill('Help us plan useful workshops for the team.')
  await admin.getByLabel('Frequency',{exact:true}).selectOption('monthly')
  await admin.getByLabel('First run date',{exact:true}).fill(nextDate(10))
  await admin.getByLabel('Enable automatic runs',{exact:false}).check()
  const prompts = ['I feel supported at work.','How useful was training?','Would you attend again?','Preferred workshop time?','Which topics interest you?','Any suggestions?']
  const types = ['agreement','rating','yes_no','single_choice','multi_choice','text']
  for (let i=0;i<6;i++) {
    if(i) await admin.getByRole('button',{name:'+ Add question',exact:true}).click()
    const section = admin.getByRole('region',{name:`Question ${i+1} settings`,exact:true})
    await section.getByLabel('Question text',{exact:true}).fill(prompts[i])
    await section.getByLabel('Answer type',{exact:true}).selectOption(types[i])
    if(i===1) {
      await section.getByLabel('Scale',{exact:true}).selectOption('10')
      await section.getByLabel('Label for 1',{exact:true}).fill('Not useful')
      await section.getByLabel('Label for 10',{exact:true}).fill('Very useful')
    }
    if(i===3 || i===4) {
      await section.getByLabel('Option 1',{exact:true}).fill(i===3?'Morning':'Learning')
      await section.getByLabel('Option 2',{exact:true}).fill(i===3?'Afternoon':'Products')
      await section.getByRole('button',{name:'+ Add option',exact:true}).click()
      await section.getByLabel('Option 3',{exact:true}).fill(i===3?'Evening':'Roster')
    }
    if(i===5) await section.getByLabel('Required',{exact:true}).uncheck()
  }
  await admin.getByRole('button',{name:'+ Add question',exact:true}).click()
  await admin.getByRole('button',{name:'Remove question 7',exact:true}).click()
  await admin.getByRole('button',{name:'Move question 3 up',exact:true}).click()
  await admin.getByRole('button',{name:'Move question 2 down',exact:true}).click()
  await admin.locator('[data-testid="app-shell-main"]').evaluate(main=>{main.scrollTop=0})
  await admin.screenshot({path:join(localDir,'survey-builder.png')})
  await admin.setViewportSize({width:390,height:844})
  assert.equal(await admin.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false)
  await admin.screenshot({path:join(localDir,'survey-builder-mobile.png')})
  await admin.setViewportSize({width:1440,height:1000})
  await admin.getByRole('button',{name:'Preview survey',exact:true}).click()
  const preview = admin.getByRole('dialog')
  await preview.getByText('6 questions · 5 required',{exact:true}).waitFor()
  await keyboardSelect(preview.getByRole('radio',{name:'No',exact:true}))
  await preview.getByRole('button',{name:'Close preview',exact:true}).click()
  assert.equal((await rpc('get_admin_staff_surveys')).surveys.length,original.surveys.length)
  await admin.getByRole('button',{name:'Save survey',exact:true}).click()
  await admin.getByText('Survey saved. Existing runs are unchanged.',{exact:true}).waitFor()
  let definition=(await rpc('get_admin_staff_surveys')).surveys.find(s=>s.name===name)
  surveyId=definition.id;created.add(surveyId);await manifest()
  assert.equal(definition.schedule_kind,'monthly');assert.equal(definition.schedule_enabled,true)
  assert.equal(definition.next_run_on,nextDate(10));assert.deepEqual(definition.questions.map(q=>q.type),types)
  pass('Create a named survey, all six question types, options, required flags, monthly schedule, reorder/remove, preview and mobile builder')
  await card(admin,name).getByRole('button',{name:'Launch now',exact:true}).click()
  await admin.getByRole('dialog').getByRole('button',{name:'Launch survey',exact:true}).click()
  await admin.getByText('Survey launched. Eligible staff will be invited after login.',{exact:true}).waitFor()
  roundId=(await rpc('get_admin_staff_surveys')).rounds.find(r=>r.survey_id===surveyId).id;await manifest()
  await assert.rejects(()=>rpc('launch_configured_staff_survey',{p_survey_id:surveyId}),/overlapping|already/)
  pass('Launch through UI; duplicate and overlapping runs are rejected')
  await admin.getByRole('button',{name:'Survey library',exact:true}).click()
  await card(admin,name).getByRole('button',{name:'Edit survey',exact:true}).click()
  await admin.getByRole('region',{name:'Question 1 settings',exact:true}).getByLabel('Question text',{exact:true}).fill('A future version of question one.')
  await admin.getByRole('button',{name:'Save survey',exact:true}).click()
  await admin.getByText('Survey saved. Existing runs are unchanged.',{exact:true}).waitFor()
  assert.equal((await rpc('get_admin_staff_surveys')).rounds.find(r=>r.id===roundId).question_schema[0].prompt,prompts[0])
  pass('Editing future questions preserves launched wording and formats')
  previousId=sql(`select private.create_configured_survey_run('${surveyId}',(now() at time zone 'Pacific/Auckland')::date-30,now()-interval '30 days',now()-interval '16 days','automatic');`)
  await manifest()
  const ids=definition.questions.map(q=>q.id)
  const previousAnswers=Object.fromEntries(ids.map((id,i)=>[id,[3,7,true,'Morning',['Learning'],'Previous feedback'][i]]))
  sql(`insert into public.staff_survey_responses(round_id,user_id,answers,submitted_at) values('${previousId}','${fixtures[0].id}','${JSON.stringify(previousAnswers)}',now()-interval '29 days');`)

  const employee=await(await context()).newPage()
  await login(employee,fixtures[0].email,password)
  await employee.getByRole('dialog',{name:'You have a survey to answer'}).waitFor()
  await employee.getByRole('button',{name:'Remind me later',exact:true}).click()
  await employee.getByRole('dialog').waitFor({state:'hidden'})
  await employee.reload();await employee.getByRole('link',{name:'Surveys',exact:true}).waitFor()
  assert.equal(await employee.getByRole('dialog').count(),0)
  await employee.clock.install({time:new Date(Date.now()+25*3600_000)});await employee.clock.runFor(15001)
  await employee.getByRole('dialog',{name:'You have a survey to answer'}).waitFor()
  await employee.clock.setSystemTime(new Date());await employee.clock.runFor(15001)
  await employee.getByRole('dialog').waitFor({state:'hidden'})
  pass('Login invitation and reminder persistence/expiry work for a custom survey')
  await employee.goto(`${appUrl}/app/surveys/${roundId}`)
  await employee.getByRole('heading',{name:'Your answers',exact:true}).waitFor()
  await employee.setViewportSize({width:390,height:844})
  await employee.getByRole('button',{name:'Submit answers',exact:true}).click()
  await employee.getByRole('dialog',{name:'Some required answers are missing',exact:true}).waitFor()
  assert.equal((await rpc('get_staff_survey_results',{p_round_id:roundId})).find(p=>p.user_id===fixtures[0].id).response,null)
  await employee.screenshot({path:join(localDir,'survey-mobile-outstanding.png')})
  await employee.getByRole('button',{name:'Go to first unanswered',exact:true}).click()
  await employee.waitForFunction(id=>document.activeElement?.closest('[id^="survey-question-"]')?.id===`survey-question-${id}`,ids[0])
  await employee.setViewportSize({width:1440,height:1000})
  pass('Incomplete Submit opens a missing-question dialog, keeps answers private and focuses the first required answer')
  await keyboardSelect(employee.getByRole('radio',{name:'No',exact:true}))
  await employee.getByText('1 of 5 required answered',{exact:true}).waitFor()
  await employee.getByText('Draft saved automatically. Only you can see it until you submit.',{exact:true}).waitFor()
  await employee.reload();await employee.getByRole('heading',{name:'Your answers',exact:true}).waitFor()
  assert(await employee.getByRole('radio',{name:'No',exact:true}).isChecked())
  assert.equal((await rpc('get_staff_survey_results',{p_round_id:roundId})).find(p=>p.user_id===fixtures[0].id).response,null)
  pass('No counts as answered, survives draft recovery, and the draft remains hidden from admins')
  await keyboardSelect(employee.getByRole('radio',{name:'4 - Agree',exact:true}))
  await keyboardSelect(employee.getByRole('group',{name:/2\. How useful was training/}).getByRole('radio',{name:'8',exact:true}))
  await keyboardSelect(employee.getByRole('radio',{name:'Afternoon',exact:true}))
  await keyboardSelect(employee.getByRole('checkbox',{name:'Learning',exact:true}))
  await keyboardSelect(employee.getByRole('checkbox',{name:'Products',exact:true}))
  await employee.getByLabel(/6\. Any suggestions/).fill('More hands-on practice.')
  await employee.getByText('5 of 5 required answered',{exact:true}).waitFor()
  await employee.getByText('Draft saved automatically. Only you can see it until you submit.',{exact:true}).waitFor()
  await employee.setViewportSize({width:390,height:844})
  for(const width of [320,360,390,430]) {
    await employee.setViewportSize({width,height:844})
    assert.equal(await employee.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,`No horizontal overflow at ${width}px`)
    const targets=await employee.getByRole('group',{name:/1\. I feel supported/}).locator('label').evaluateAll(labels=>labels.map(l=>l.getBoundingClientRect().width))
    assert(targets.every(w=>w>=44),`Agreement tap targets at least 44px wide at ${width}px`)
  }
  await employee.setViewportSize({width:390,height:844})
  assert.equal(await employee.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false)
  await employee.screenshot({path:join(localDir,'survey-mixed-form.png'),fullPage:true})
  await employee.getByRole('button',{name:'Submit answers',exact:true}).click()
  await employee.getByRole('dialog').getByRole('button',{name:'Submit answers',exact:true}).click()
  await employee.getByRole('heading',{name:'Your submitted answers',exact:true}).waitFor()
  await employee.getByText('Previous: 7 · Change: +1',{exact:true}).waitFor()
  assert.equal(await employee.getByText('Previous: 3 · Change: +1',{exact:true}).count(),0)
  const results=await rpc('get_staff_survey_results',{p_round_id:roundId})
  const response=results.find(p=>p.user_id===fixtures[0].id).response
  assert.deepEqual(response.answers,Object.fromEntries(ids.map((id,i)=>[id,[4,8,false,'Afternoon',['Learning','Products'],'More hands-on practice.'][i]])))
  const employeeToken=(await request(runtime,'/auth/v1/token?grant_type=password',{method:'POST',body:JSON.stringify({email:fixtures[0].email,password})})).access_token
  await assert.rejects(()=>rpc('save_configured_staff_survey_response',{p_round_id:roundId,p_answers:response.answers,p_submit:true,p_revision:response.revision},employeeToken),/already been submitted/)
  await employee.goto(`${appUrl}/app/surveys`)
  await employee.getByRole('link',{name:'View my answers',exact:true}).first().waitFor()
  assert.equal(await employee.getByRole('link',{name:'View my answers',exact:true}).count(),2)
  pass('All typed answers submit, remain final, appear in personal history and compare only unchanged scales/questions')
  const otherToken=(await request(runtime,'/auth/v1/token?grant_type=password',{method:'POST',body:JSON.stringify({email:fixtures[1].email,password})})).access_token
  assert((await rpc('get_my_staff_surveys',{},otherToken)).every(r=>r.response===null))
  await assert.rejects(()=>rpc('get_staff_survey_results',{p_round_id:roundId},otherToken),/Admin access required/)
  const managerToken=(await request(runtime,'/auth/v1/token?grant_type=password',{method:'POST',body:JSON.stringify({email:fixtures[2].email,password})})).access_token
  await assert.rejects(()=>rpc('get_admin_staff_surveys',{},managerToken),/Admin access required/)
  pass('Other employees and managers cannot access named results')
  await admin.getByRole('button',{name:'Runs & results',exact:true}).click()
  await admin.getByLabel('Survey',{exact:true}).selectOption(surveyId)
  await admin.getByLabel('Analysis view',{exact:true}).selectOption('questions')
  await admin.getByText('8.0 / 10',{exact:true}).waitFor()
  await admin.getByText('Change: +1.0',{exact:false}).waitFor()
  await admin.getByText('Read written answers (1)',{exact:true}).click()
  await admin.getByText('More hands-on practice.',{exact:true}).waitFor()
  await admin.getByRole('button',{name:'View response',exact:true}).click()
  await admin.getByRole('dialog').getByText('No',{exact:true}).waitFor()
  await admin.getByRole('dialog').getByText('Learning, Products',{exact:true}).waitFor()
  await admin.getByRole('dialog').evaluate(d=>{d.scrollTop=0})
  await admin.screenshot({path:join(localDir,'survey-typed-response.png')})
  await admin.getByRole('button',{name:'Close response',exact:true}).click()
  await admin.locator('[data-testid="app-shell-main"]').evaluate(main=>{main.scrollTop=0})
  await admin.screenshot({path:join(localDir,'survey-typed-results.png')})
  pass('Admin sees type-aware distributions, numeric means, named written feedback and valid previous-run comparisons')
  const extraToken=(await request(runtime,'/auth/v1/token?grant_type=password',{method:'POST',body:JSON.stringify({email:fixtures[3].email,password})})).access_token
  const extraAnswers=Object.fromEntries(ids.map((id,i)=>[id,[2,6,true,'Morning',['Roster'],'=HYPERLINK("https://example.test","literal text")\nKia ora, whānau. More practical learning.'][i]]))
  await rpc('save_configured_staff_survey_response',{p_round_id:roundId,p_answers:extraAnswers,p_submit:true,p_revision:0},extraToken)
  await admin.getByRole('button',{name:'Refresh',exact:true}).click()
  await admin.getByText('7.0 / 10',{exact:true}).waitFor()
  await admin.getByLabel('Analysis view',{exact:true}).selectOption('overview')
  await admin.getByText('50% agree',{exact:true}).waitFor()
  await admin.getByLabel('Analysis view',{exact:true}).selectOption('trends')
  await admin.getByLabel('Trend question',{exact:true}).selectOption(ids[1])
  await admin.getByRole('img',{name:/Mean rating trend for How useful was training/}).waitFor()
  await admin.getByRole('cell',{name:'7.00 / 10',exact:true}).first().waitFor()
  await admin.setViewportSize({width:390,height:844})
  assert.equal(await admin.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false)
  await admin.screenshot({path:join(localDir,'survey-mobile-trends.png'),fullPage:true})
  await admin.setViewportSize({width:1440,height:1000})
  pass('Agreement chart uses a 50% favourable rate and trends show correct per-run means and counts')
  await admin.getByRole('button',{name:'Export results',exact:true}).click()
  for(const identity of ['named','randomised']) {
    await admin.getByLabel('Respondent identities',{exact:true}).selectOption(identity)
    assert.equal(await admin.getByLabel('Include written answers',{exact:true}).isChecked(),identity==='named')
    for(const format of ['xlsx','pdf']) {
      await admin.getByLabel('File format',{exact:true}).selectOption(format)
      const waiting=admin.waitForEvent('download',{timeout:60000})
      await admin.getByRole('button',{name:'Download results',exact:true}).click()
      const download=await waiting
      await download.saveAs(join(localDir,`survey-export-${identity}.${format}`))
      await admin.getByRole('status').filter({hasText:`${format.toUpperCase()} ready.`}).waitFor()
    }
  }
  await admin.getByRole('dialog').getByRole('button',{name:'Close',exact:true}).click()
  await writeFile(join(localDir,'survey-export-test-expectations.json'),JSON.stringify({names:[fixtures[0].name,fixtures[3].name],emails:[fixtures[0].email,fixtures[3].email],ids:fixtures.map(f=>f.id),extraAnswers,questionIds:ids},null,2),{mode:0o600})
  pass('Named and randomised XLSX/PDF files download, with written answers excluded by default for randomised IDs')
  await admin.getByRole('button',{name:'Close run early',exact:true}).click()
  await admin.getByRole('dialog').getByRole('button',{name:'Close run',exact:true}).click()
  await admin.getByText('Survey closed. Submitted answers and private drafts are preserved.',{exact:true}).waitFor()
  await assert.rejects(()=>rpc('save_configured_staff_survey_response',{p_round_id:roundId,p_answers:response.answers,p_submit:true,p_revision:0},otherToken),/closed/)
  await admin.getByRole('button',{name:'Survey library',exact:true}).click()
  await card(admin,name).getByRole('button',{name:'Duplicate',exact:true}).click()
  assert.equal(await admin.getByLabel('Frequency',{exact:true}).inputValue(),'manual')
  await admin.getByRole('button',{name:'Save survey',exact:true}).click()
  await admin.getByText('Survey saved. Existing runs are unchanged.',{exact:true}).waitFor()
  const copy=(await rpc('get_admin_staff_surveys')).surveys.find(s=>s.name===`${name} (copy)`)
  created.add(copy.id);await manifest();assert.equal(copy.schedule_enabled,false)
  await card(admin,name).getByRole('button',{name:'Archive',exact:true}).click()
  await admin.getByRole('dialog').getByRole('button',{name:'Archive survey',exact:true}).click()
  await admin.getByText('Survey updated. Existing runs and answers are preserved.',{exact:true}).waitFor()
  await admin.getByLabel('Show archived',{exact:true}).check()
  await card(admin,name).getByRole('button',{name:'Restore',exact:true}).click()
  await admin.getByRole('dialog').getByRole('button',{name:'Restore survey',exact:true}).click()
  await admin.getByRole('dialog').waitFor({state:'hidden'})
  await admin.locator('[data-testid="app-shell-main"]').evaluate(main=>{main.scrollTop=0})
  await admin.screenshot({path:join(localDir,'survey-library.png')})
  assert.deepEqual((await rpc('get_admin_staff_surveys')).surveys.find(s=>s.id===defaultPulse.id),defaultPulse)
  pass('Close run, duplicate without enabling a schedule, archive/restore without losing answers; default pulse unchanged')
  assert.deepEqual(errors,[])
} catch(error) {
  failure=error;console.error(error.stack);if(errors.length) console.error(errors.join('\n'));process.exitCode=1
} finally {
  await browser?.close()
  try {
    if(adminToken) for(const s of (await rpc('get_admin_staff_surveys')).surveys.filter(s=>s.name===name||s.name===`${name} (copy)`)) created.add(s.id)
    for(const id of created) sql(`begin;
      do $guard$ begin if exists(select 1 from public.staff_survey_responses s join public.staff_survey_rounds r on r.id=s.round_id
        where r.survey_id='${id}' and s.user_id not in(${fixtures.filter(f=>f.id).map(f=>`'${f.id}'`).join(',')})) then raise exception 'Unexpected response; fixture cleanup refused'; end if; end $guard$;
      delete from public.staff_survey_rounds where survey_id='${id}'; delete from public.staff_surveys where id='${id}' and name like '${name}%'; commit;`)
    for(const f of fixtures.filter(f=>f.id)) {
      sql(`begin;delete from public.staff_member_user_access where user_id='${f.id}' and staff_member_id='${f.staff}';delete from public.staff_members where id='${f.staff}' and full_name='${f.name}';commit;`)
      await request(runtime,`/auth/v1/admin/users/${f.id}`,{service:true,method:'DELETE'})
    }
    pass('Temporary custom surveys, runs, staff and Auth accounts removed')
  } catch(error) {failure??=error;console.error(`Cleanup needs attention: ${error.message}. See local-db.local/survey-browser-fixture.json`);process.exitCode=1}
  await writeFile(join(localDir,'survey-browser-check.log'),`${log.join('\n')}\n${failure?`FAILED: ${failure.stack}`:'PASSED'}\n`,{mode:0o600})
}
