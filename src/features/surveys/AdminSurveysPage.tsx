import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { useAuth } from '@/features/auth/authContext'
import { archiveSurvey, closeSurvey, getAdminSurveys, launchSurvey, type SurveyDefinition, type SurveyDefinitionInput } from './surveyApi'
import { SurveyBuilder } from './SurveyBuilder'
import { SurveyDialog } from './SurveyDialog'
import { SurveyResults } from './SurveyResults'
import { useSurveyClock } from './useSurveyClock'
import { nzDateAfter, SCHEDULE_LABELS, surveyAdminCard as surveyCard, surveyDate, surveyAdminInput as surveyInput, surveyIsOpen, surveyAdminPrimaryButton as surveyPrimaryButton, surveyAdminSecondaryButton as surveySecondaryButton } from './surveyUtils'

export function AdminSurveysPage() {
  const { user } = useAuth()
  const now = useSurveyClock()
  const client = useQueryClient()
  const [tab, setTab] = useState<'surveys' | 'results'>('surveys')
  const [editor, setEditor] = useState<SurveyDefinitionInput | null>(null)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [filterSurvey, setFilterSurvey] = useState('')
  const [showArchived, setShowArchived] = useState(false)
  const [launching, setLaunching] = useState<SurveyDefinition | null>(null)
  const [closing, setClosing] = useState<string | null>(null)
  const [archiving, setArchiving] = useState<SurveyDefinition | null>(null)
  const [closesOn, setClosesOn] = useState(() => nzDateAfter(14))
  const [notice, setNotice] = useState('')
  const query = useQuery({ queryKey: ['surveys', 'admin', 'builder', user?.id], queryFn: getAdminSurveys, refetchInterval: editor ? false : 30_000, refetchOnWindowFocus: !editor })
  const refresh = () => { void client.invalidateQueries({ queryKey: ['surveys'] }) }
  const launch = useMutation({ mutationFn: launchSurvey, onSuccess: id => { setLaunching(null); setSelectedId(id); setFilterSurvey(''); setTab('results'); setNotice('Survey launched. Eligible staff will be invited after login.'); refresh() } })
  const close = useMutation({ mutationFn: closeSurvey, onSuccess: () => { setClosing(null); setNotice('Survey closed. Submitted answers and private drafts are preserved.'); refresh() } })
  const archive = useMutation({ mutationFn: archiveSurvey, onSuccess: () => { setArchiving(null); setNotice('Survey updated. Existing runs and answers are preserved.'); refresh() } })
  if (query.isPending) return <LoadingState message="Loading surveys…" />
  if (query.isError) return <ErrorState error={query.error} onRetry={() => void query.refetch()} />
  const { surveys, rounds } = query.data
  const visibleRounds = rounds.filter(r => !filterSurvey || r.survey_id === filterSurvey)
  const selected = visibleRounds.find(r => r.id === selectedId) ?? visibleRounds[0]
  const previous = selected ? rounds.find(r => r.survey_id === selected.survey_id && r.opens_at < selected.opens_at) : undefined

  function createSurvey() {
    setNotice(''); setEditor({ id: null, updated_at: null, name: '', description: '', questions: [{ id: crypto.randomUUID(), prompt: '', type: 'agreement', required: true }], schedule_kind: 'manual', start_on: null, duration_days: 14, schedule_enabled: false })
  }
  return <div className="w-full pb-6">
    <header className="mb-3 flex flex-wrap items-center gap-2 sm:gap-3">
      <h1 className="mr-2 text-xl font-semibold tracking-tight text-slate-900">{editor ? editor.id ? 'Edit survey' : 'Create survey' : 'Surveys'}</h1>
      {!editor ? <>
        <div className="flex gap-1" role="group" aria-label="Survey sections">
          <button type="button" aria-pressed={tab === 'surveys'} className={tab === 'surveys' ? surveyPrimaryButton : surveySecondaryButton} onClick={() => { setTab('surveys'); setNotice(''); refresh() }}>Survey library</button>
          <button type="button" aria-pressed={tab === 'results'} className={tab === 'results' ? surveyPrimaryButton : surveySecondaryButton} onClick={() => { setTab('results'); setNotice(''); refresh() }}>Runs & results</button>
        </div>
        <div className="ml-auto flex flex-wrap items-center gap-2 sm:gap-3">
          {tab === 'surveys' ? <label className="flex items-center gap-1.5 text-xs text-slate-600"><input type="checkbox" checked={showArchived} onChange={event => setShowArchived(event.target.checked)} className="size-4 accent-violet-700" />Show archived</label> : null}
          <button type="button" className={surveySecondaryButton} disabled={query.isFetching} onClick={refresh}>Refresh</button>
          <button type="button" onClick={createSurvey} className={surveyPrimaryButton}>Create survey</button>
        </div>
      </> : <p className="text-xs text-slate-500">Changes apply to future runs; launched questions stay fixed.</p>}
    </header>
    {notice ? <p role="status" className="mb-3 rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-800">{notice}</p> : null}
    {editor ? <SurveyBuilder initial={editor} onCancel={() => setEditor(null)} onSaved={() => { setEditor(null); setTab('surveys'); setNotice('Survey saved. Existing runs are unchanged.'); refresh() }} /> : <>
      {tab === 'surveys' ? <>
        <div className="space-y-2">
          {surveys.filter(s => showArchived || !s.is_archived).map(s => {
            const open = rounds.some(r => r.survey_id === s.id && surveyIsOpen(r, now))
            return <article key={s.id} className={`${surveyCard} grid items-center gap-x-5 gap-y-2 xl:grid-cols-[minmax(0,1fr)_minmax(10rem,0.6fr)_auto]`}>
              <div className="min-w-0"><div className="flex flex-wrap items-center gap-2"><h2 className="break-words text-sm font-semibold text-slate-900">{s.name}</h2><span className="shrink-0 rounded bg-violet-50 px-1.5 py-0.5 text-[11px] text-violet-800">{s.is_archived ? 'Archived' : s.schedule_enabled ? 'Scheduled' : 'Manual / paused'}</span></div>
              {s.description ? <p className="mt-1 truncate text-xs text-slate-500" title={s.description}>{s.description}</p> : null}
              <p className="mt-1 text-xs text-slate-600">{s.questions.length} questions · {s.duration_days}-day window · Named responses</p></div>
              <div className="text-xs text-slate-600"><p>{SCHEDULE_LABELS[s.schedule_kind]}</p><p className="mt-0.5 text-slate-500">{s.next_run_on ? `Next: ${surveyDate(s.next_run_on)}` : s.schedule_kind !== 'manual' && !s.is_archived ? s.schedule_enabled ? 'No upcoming run' : 'Automatic runs paused' : 'Launch when needed'}</p></div>
              <div className="flex flex-wrap items-center gap-1.5">
                {!s.is_archived ? <><button type="button" className={surveyPrimaryButton} onClick={() => { setNotice(''); setEditor(s) }}>Edit survey</button><button type="button" disabled={open} className={surveySecondaryButton} onClick={() => { launch.reset(); setClosesOn(nzDateAfter(s.duration_days)); setLaunching(s) }}>{open ? 'Run is open' : 'Launch now'}</button></> : null}
                <button type="button" className={surveySecondaryButton} onClick={() => { setNotice(''); setEditor({ ...s, id: null, updated_at: null, name: `${s.name.slice(0, 110)} (copy)`, schedule_kind: 'manual', start_on: null, schedule_enabled: false }) }}>Duplicate</button>
                <button type="button" className={surveySecondaryButton} onClick={() => { setFilterSurvey(s.id); setTab('results') }}>View results</button>
                <button type="button" className="min-h-10 px-1.5 py-1.5 text-xs text-slate-500 underline sm:min-h-8" onClick={() => { archive.reset(); setArchiving(s) }}>{s.is_archived ? 'Restore' : 'Archive'}</button>
              </div>
            </article>
          })}
        </div>
      </> : <>
        <div className="mb-3 flex items-center gap-2"><label htmlFor="results-survey" className="text-xs font-medium text-slate-700">Survey</label><select id="results-survey" className={`${surveyInput} max-w-md`} value={filterSurvey} onChange={event => setFilterSurvey(event.target.value)}><option value="">All surveys</option>{surveys.map(s => <option key={s.id} value={s.id}>{s.name}{s.is_archived ? ' (archived)' : ''}</option>)}</select></div>
        {selected ? <div className="grid items-start gap-5 xl:grid-cols-[15rem_minmax(0,1fr)]"><aside aria-label="Survey runs" className="space-y-2">
          {visibleRounds.map(r => <button type="button" key={r.id} onClick={() => setSelectedId(r.id)} aria-pressed={selected.id === r.id} className={`w-full rounded-lg border p-4 text-left ${selected.id === r.id ? 'border-violet-300 bg-violet-50' : 'border-slate-200 bg-white hover:bg-slate-50'}`}><span className="block text-sm font-semibold text-slate-900">{r.title}</span><span className="mt-1 block text-xs text-slate-500">{surveyDate(r.opens_at)} · {surveyIsOpen(r, now) ? 'Open' : 'Closed'}<br />{r.submitted_count}/{r.participant_count} responses</span></button>)}
        </aside><div className="min-w-0 space-y-4"><SurveyResults key={selected.id} round={selected} previous={previous} rounds={rounds} />{surveyIsOpen(selected, now) ? <div className={surveyCard}><button type="button" className={surveySecondaryButton} onClick={() => { close.reset(); setClosing(selected.id) }}>Close run early</button></div> : null}</div></div>
          : <div className={`${surveyCard} text-sm text-slate-600`}>No runs yet. Launch a survey from the library or enable its schedule.</div>}
      </>}
    </>}
    {launching ? <SurveyDialog title={`Launch ${launching.name}?`} onDismiss={() => { if (!launch.isPending) setLaunching(null) }}>
      <p className="mt-3 text-sm text-slate-600">All active staff with active app access will be invited. Saved questions and answer formats are fixed for this run. You can launch once per day, with no overlapping run of the same survey.</p>
      <label htmlFor="launch-closes-on" className="mb-2 mt-4 block text-sm font-medium text-slate-700">Close at the start of this date (midnight NZ time)</label><input id="launch-closes-on" type="date" min={nzDateAfter(1)} max={nzDateAfter(60)} value={closesOn} onChange={event => setClosesOn(event.target.value)} className={surveyInput} />
      {launch.isError ? <p role="alert" className="mt-3 text-sm text-red-700">{launch.error.message}</p> : null}
      <div className="mt-5 flex gap-3"><button type="button" disabled={launch.isPending || !closesOn} className={surveyPrimaryButton} onClick={() => launch.mutate({ surveyId: launching.id, closesOn })}>{launch.isPending ? 'Launching…' : 'Launch survey'}</button><button type="button" disabled={launch.isPending} autoFocus className={surveySecondaryButton} onClick={() => setLaunching(null)}>Cancel</button></div>
    </SurveyDialog> : null}
    {closing ? <SurveyDialog title="Close this run early?" onDismiss={() => { if (!close.isPending) setClosing(null) }}><p className="mt-3 text-sm text-slate-600">Staff will no longer be able to submit to this run. Submitted answers and private drafts will be kept. Future scheduled runs are unaffected.</p>{close.isError ? <p role="alert" className="mt-3 text-sm text-red-700">{close.error.message}</p> : null}<div className="mt-5 flex gap-3"><button type="button" disabled={close.isPending} className={surveyPrimaryButton} onClick={() => close.mutate(closing)}>Close run</button><button type="button" disabled={close.isPending} autoFocus className={surveySecondaryButton} onClick={() => setClosing(null)}>Cancel</button></div></SurveyDialog> : null}
    {archiving ? <SurveyDialog title={archiving.is_archived ? 'Restore survey?' : 'Archive survey?'} onDismiss={() => { if (!archive.isPending) setArchiving(null) }}><p className="mt-3 text-sm text-slate-600">{archiving.is_archived ? 'Restoring makes this survey available again and resumes its schedule if enabled.' : 'Archiving stops future automatic runs. Existing open runs and all answers are kept.'}</p>{archive.isError ? <p role="alert" className="mt-3 text-sm text-red-700">{archive.error.message}</p> : null}<div className="mt-5 flex gap-3"><button type="button" disabled={archive.isPending} className={surveyPrimaryButton} onClick={() => archive.mutate({ survey: archiving, archived: !archiving.is_archived })}>{archiving.is_archived ? 'Restore survey' : 'Archive survey'}</button><button type="button" autoFocus disabled={archive.isPending} className={surveySecondaryButton} onClick={() => setArchiving(null)}>Cancel</button></div></SurveyDialog> : null}
  </div>
}
