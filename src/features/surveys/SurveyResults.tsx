import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { useAuth } from '@/features/auth/authContext'
import { getSurveyResults, type AdminSurveyRound, type AdminSurveys } from './surveyApi'
import { SurveyAnswers } from './SurveyAnswers'
import { SurveyDialog } from './SurveyDialog'
import { SurveyAnalysis } from './SurveyAnalysis'
import { SurveyExportDialog } from './SurveyExportDialog'
import { comparableQuestion, questionHasAnswer, questionOptions, surveyAverage, surveyAdminCard as surveyCard, surveyDate, surveyAdminInput, surveyAdminSecondaryButton } from './surveyUtils'

export function SurveyResults({ round, previous, rounds = [round] }: { round: AdminSurveyRound; previous?: AdminSurveyRound; rounds?: AdminSurveyRound[] }) {
  const { user } = useAuth()
  const client = useQueryClient()
  const [selectedUser, setSelectedUser] = useState<string | null>(null)
  const [filter, setFilter] = useState('')
  const [view, setView] = useState<'overview' | 'questions' | 'trends'>('overview')
  const [exportOpen, setExportOpen] = useState(false)
  const query = useQuery({ queryKey: ['surveys', 'results', 'builder', user?.id, round.id], queryFn: () => getSurveyResults(round.id), refetchInterval: 30_000 })
  const previousQuery = useQuery({ queryKey: ['surveys', 'results', 'builder', user?.id, previous?.id], queryFn: () => getSurveyResults(previous!.id), enabled: !!previous })
  useEffect(() => {
    if (!query.data) return
    const count = query.data.filter(p => p.response?.submitted_at).length
    const total = query.data.length
    client.setQueryData<AdminSurveys>(['surveys', 'admin', 'builder', user?.id], old => {
      if (!old || old.rounds.every(r => r.id !== round.id || (r.submitted_count === count && r.participant_count === total))) return old
      return { ...old, rounds: old.rounds.map(r => r.id === round.id ? { ...r, submitted_count: count, participant_count: total } : r) }
    })
  }, [client, query.data, round.id, user?.id])
  if (query.isPending) return <LoadingState message="Loading survey results…" />
  if (query.isError) return <ErrorState error={query.error} onRetry={() => void query.refetch()} />
  const participants = query.data
  const submitted = participants.flatMap(p => p.response?.submitted_at ? [p.response] : [])
  const previousSubmitted = previousQuery.data?.flatMap(p => p.response?.submitted_at ? [p.response] : []) ?? []
  const selected = participants.find(p => p.user_id === selectedUser)

  return <div className="space-y-4">
    <div className={surveyCard}>
      <div className="flex flex-wrap items-start justify-between gap-2"><div><p className="text-xs font-semibold uppercase tracking-wide text-violet-700">{round.launch_source === 'admin' ? 'Launched by admin' : 'Scheduled survey'}</p>
      <h2 className="mt-1 break-words text-lg font-semibold text-slate-900">{round.title}</h2></div><button type="button" className={surveyAdminSecondaryButton} disabled={submitted.length === 0} onClick={() => setExportOpen(true)}>Export results</button></div>
      <p className="mt-1 text-sm text-slate-500">{surveyDate(round.opens_at)} – {surveyDate(round.closes_at)} · New Zealand time{round.closed_at ? ' · Closed early by admin' : ''}</p>
      <div className="mt-3 grid grid-cols-3 gap-2 sm:gap-3">
        {[
          ['Responses', `${submitted.length} / ${participants.length}`],
          ['Participation', `${participants.length ? Math.round(100 * submitted.length / participants.length) : 0}%`],
          ['Questions', String(round.question_schema.length)],
        ].map(([label, value]) => <div key={label} className="rounded-lg bg-slate-50 px-2 py-2 sm:px-3"><p className="text-xs text-slate-500">{label}</p><p className="mt-1 text-lg font-semibold text-slate-900">{value}</p></div>)}
      </div>
      <p className="mt-2 text-xs text-slate-500">Eligible staff are captured at launch. Submitted answers only; drafts stay private.</p>
    </div>
    <div className="flex flex-wrap items-center gap-2"><label htmlFor="survey-analysis-view" className="text-xs font-medium text-slate-600">Analysis view</label><select id="survey-analysis-view" className={`${surveyAdminInput} max-w-xs`} value={view} onChange={e => setView(e.target.value as typeof view)}><option value="overview">Summary charts</option><option value="questions">Question breakdown</option><option value="trends">Trends across runs</option></select></div>
    {view === 'overview' || view === 'trends' ? <SurveyAnalysis round={round} participants={participants} rounds={rounds} view={view} /> : <div className={surveyCard}>
      <h3 className="font-semibold text-slate-900">Question results</h3>
      <p className="mt-1 text-xs text-slate-500">Results use each question’s answer format. Optional unanswered questions are excluded from averages and percentages.</p>
      {submitted.length === 0 ? <p className="mt-5 text-sm text-slate-600">No answers have been submitted yet.</p> : <ol className="mt-2 divide-y divide-slate-100">
        {round.question_schema.map((question, i) => {
          const answers = submitted.map(response => response.answers[question.id]).filter(questionHasAnswer)
          const numeric = question.type === 'agreement' || question.type === 'rating'
          const avg = numeric ? surveyAverage(answers.filter((a): a is number => typeof a === 'number')) : null
          const previousQuestion = previous?.question_schema.find(q => comparableQuestion(question, q))
          const previousAverage = numeric && previousQuestion ? surveyAverage(previousSubmitted.map(r => r.answers[previousQuestion.id]).filter((a): a is number => typeof a === 'number')) : null
          const maximum = question.type === 'agreement' ? 5 : question.scale_max
          return <li key={question.id} className="py-4">
            <div className="flex items-start justify-between gap-4"><p className="text-sm font-medium text-slate-700">{i + 1}. {question.prompt}</p>{avg != null ? <strong className="shrink-0 text-sm text-violet-900">{avg.toFixed(1)} / {maximum}</strong> : null}</div>
            <p className="mt-1 text-xs text-slate-500">{answers.length} answered · {submitted.length - answers.length} skipped</p>
            {question.type === 'text' ? <details className="mt-3"><summary className="cursor-pointer text-sm text-violet-700">Read written answers ({answers.length})</summary><ul className="mt-3 space-y-3">{participants.filter(p => p.response && questionHasAnswer(p.response.answers[question.id])).map(p => <li key={p.user_id} className="rounded-lg bg-slate-50 p-3 text-sm"><p className="font-medium text-slate-800">{p.staff_name}</p><p className="mt-1 whitespace-pre-wrap break-words text-slate-600">{String(p.response!.answers[question.id])}</p></li>)}</ul></details>
              : <div className="mt-3 space-y-2">{questionOptions(question).map(option => {
                const count = answers.filter(a => Array.isArray(a) ? a.includes(String(option.value)) : a === option.value).length
                const percentage = answers.length ? Math.round(100 * count / answers.length) : 0
                return <div key={String(option.value)}><div className="mb-1 flex justify-between gap-3 text-xs text-slate-600"><span>{option.label}</span><span>{count} ({percentage}%)</span></div><div className="h-1.5 rounded-full bg-slate-100" aria-hidden="true"><div className="h-1.5 rounded-full bg-violet-500" style={{ width: `${percentage}%` }} /></div></div>
              })}{question.type === 'multi_choice' ? <p className="text-xs text-slate-500">Multiple selections allowed; percentages can add up to more than 100%.</p> : null}</div>}
            {previousAverage != null && avg != null ? <p className="mt-2 text-xs text-slate-600">Previous run ({surveyDate(previous!.opens_at)}): {previousAverage.toFixed(1)} · Change: {avg - previousAverage > 0 ? '+' : ''}{(avg - previousAverage).toFixed(1)}</p> : null}
          </li>
        })}
      </ol>}
      {previousQuery.isError ? <p className="mt-3 text-xs text-red-700">Previous round comparison could not load. <button className="underline" onClick={() => void previousQuery.refetch()}>Retry comparison</button></p> : null}
      <p className="mt-3 text-xs text-slate-500">Rating comparisons use the previous run of this survey and appear only when the question wording, type and scale are unchanged.</p>
    </div>}
    <div className={surveyCard}>
      <h3 className="font-semibold text-slate-900">Named individual responses</h3>
      <p className="mt-1 text-sm text-slate-500">Select a submitted response to read all ratings and written feedback.</p>
      <label htmlFor="survey-staff-filter" className="sr-only">Search survey participants</label>
      <input id="survey-staff-filter" type="search" placeholder="Search by name or email" value={filter} onChange={event => setFilter(event.target.value)} className="mt-4 w-full rounded-md border border-slate-300 px-3 py-2 text-sm" />
      <ul className="mt-3 max-h-96 divide-y divide-slate-100 overflow-y-auto" tabIndex={0} aria-label="Eligible staff and response status">
        {participants.filter(p => `${p.staff_name} ${p.email}`.toLowerCase().includes(filter.toLowerCase())).sort((a, b) => Number(Boolean(b.response)) - Number(Boolean(a.response))).map(p => <li key={p.user_id} className="flex flex-wrap items-center justify-between gap-2 py-3">
          <div className="min-w-0"><p className="text-sm font-medium text-slate-800">{p.staff_name}</p><p className="break-all text-xs text-slate-500">{p.email}</p></div>
          {p.response ? <button type="button" onClick={() => setSelectedUser(p.user_id)} aria-pressed={selectedUser === p.user_id} className="rounded-md border border-violet-200 bg-violet-50 px-3 py-2 text-sm font-medium text-violet-800 hover:bg-violet-100">View response</button> : <span className="text-xs text-slate-500">Not submitted</span>}
        </li>)}
        {participants.length === 0 ? <li className="py-4 text-sm text-slate-500">No active staff accounts were eligible when this round launched.</li> : null}
      </ul>
    </div>
    {selected?.response ? <SurveyDialog title={selected.staff_name} wide onDismiss={() => setSelectedUser(null)}>
      <section aria-label={`Response from ${selected.staff_name}`}>
        <div className="mt-2 flex items-center justify-between gap-3"><p className="text-sm text-slate-500">Submitted {surveyDate(selected.response.submitted_at!)}</p>
          <button type="button" autoFocus onClick={() => setSelectedUser(null)} className="rounded-md border border-slate-300 px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50">Close response</button>
        </div>
        <SurveyAnswers round={round} response={selected.response} />
      </section>
    </SurveyDialog> : null}
    {exportOpen ? <SurveyExportDialog round={round} participants={participants} onClose={() => setExportOpen(false)} /> : null}
  </div>
}
