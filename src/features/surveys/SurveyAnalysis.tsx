import { useQueries } from '@tanstack/react-query'
import { useState } from 'react'
import { useAuth } from '@/features/auth/authContext'
import { getSurveyResults, type AdminSurveyRound, type SurveyParticipant } from './surveyApi'
import { analyseQuestion, comparableHistoryQuestion } from './surveyStatistics'
import { surveyAdminCard, surveyAdminInput, surveyDate } from './surveyUtils'

export function SurveyAnalysis({ round, participants, rounds, view }: { round: AdminSurveyRound; participants: SurveyParticipant[]; rounds: AdminSurveyRound[]; view: 'overview' | 'trends' }) {
  if (view === 'trends') return <SurveyTrends round={round} rounds={rounds} />
  const stats = round.question_schema.map(q => analyseQuestion(q, participants))
  const agreement = stats.filter(s => s.question.type === 'agreement')
  const rated = stats.filter(s => s.mean != null)
  const submitted = participants.filter(p => p.response?.submitted_at).length
  return <section className={`${surveyAdminCard} space-y-4`} aria-label="Survey analysis">
    <div><h3 className="font-semibold text-slate-900">At a glance</h3><p className="mt-1 text-xs text-slate-500">Submitted responses only. Each question uses its own scale and answer count.</p></div>
    {submitted === 0 ? <p className="text-sm text-slate-500">Charts will appear when staff submit answers.</p> : <>
      {agreement.length ? <div>
        <div className="mb-3 flex flex-wrap items-center justify-between gap-2"><h4 className="text-sm font-medium text-slate-800">Agreement profile</h4><div className="flex flex-wrap gap-3 text-[11px] text-slate-500"><span><i className="mr-1 inline-block size-2 rounded bg-rose-400" />Disagree (1-2)</span><span><i className="mr-1 inline-block size-2 rounded bg-slate-300" />Neutral (3)</span><span><i className="mr-1 inline-block size-2 rounded bg-emerald-500" />Agree (4-5)</span></div></div>
        <div className="space-y-3">{agreement.map(s => <div key={s.question.id}>
          <div className="mb-1 flex items-start justify-between gap-3 text-xs"><span className="min-w-0 text-slate-700">Q{round.question_schema.indexOf(s.question) + 1}. {s.question.prompt}</span><span className="shrink-0 font-semibold text-emerald-800">{s.favourable == null ? 'No answers' : `${Math.round(s.favourable)}% agree`}</span></div>
          <div className="flex h-5 overflow-hidden rounded bg-slate-100" role="img" aria-label={`${s.disagree} disagree, ${s.neutral} neutral, ${s.agree} agree. ${s.answered} answered.`}>
            {[{ count: s.disagree!, colour: 'bg-rose-400' }, { count: s.neutral!, colour: 'bg-slate-300' }, { count: s.agree!, colour: 'bg-emerald-500' }].map((segment, i) => <span key={i} className={segment.colour} style={{ width: `${s.answered ? segment.count / s.answered * 100 : 0}%` }} />)}
          </div><p className="mt-1 text-[11px] text-slate-500">{s.answered} answered · {s.skipped} skipped</p>
        </div>)}</div>
      </div> : null}
      {rated.length ? <details><summary className="cursor-pointer text-sm font-medium text-violet-700">Rating summary table</summary><div className="mt-2 overflow-x-auto"><table className="w-full text-left text-xs"><caption className="sr-only">Rating means, medians and answer counts</caption><thead><tr className="border-b text-slate-500"><th className="py-2 pr-3">Question</th><th className="pr-3">Mean</th><th className="pr-3">Median</th><th>Answers</th></tr></thead><tbody>{rated.map(s => <tr key={s.question.id} className="border-b border-slate-100"><td className="py-2 pr-3">{s.question.prompt}</td><td className="whitespace-nowrap pr-3">{s.mean!.toFixed(2)} / {s.question.type === 'agreement' ? 5 : s.question.scale_max}</td><td className="pr-3">{s.median}</td><td>{s.answered}</td></tr>)}</tbody></table></div></details> : null}
      {!agreement.length ? <div className="space-y-4">{stats.filter(s => s.question.type !== 'text').map(s => <div key={s.question.id}><h4 className="text-sm font-medium text-slate-800">{s.question.prompt}</h4><div className="mt-2 space-y-1.5">{s.distribution.map(option => <div key={String(option.value)}><div className="flex justify-between gap-2 text-xs text-slate-600"><span>{option.label}</span><span>{option.count} ({Math.round(option.percentage)}%)</span></div><div className="mt-1 h-2 rounded bg-slate-100"><div className="h-2 rounded bg-violet-500" style={{ width: `${option.percentage}%` }} /></div></div>)}</div>{s.question.type === 'multi_choice' ? <p className="mt-2 text-xs text-slate-500">Multiple selections allowed. Percentages can exceed 100% in total.</p> : null}</div>)}</div> : null}
      {agreement.length ? <p className="text-xs text-slate-500">Agreement combines scores 4 and 5. Neutral answers are included in the denominator. Skipped answers are excluded.</p> : null}
    </>}
  </section>
}

function SurveyTrends({ round, rounds }: { round: AdminSurveyRound; rounds: AdminSurveyRound[] }) {
  const { user } = useAuth()
  const numeric = round.question_schema.filter(q => q.type === 'agreement' || q.type === 'rating')
  const [questionId, setQuestionId] = useState(numeric[0]?.id ?? '')
  const question = numeric.find(q => q.id === questionId) ?? numeric[0]
  const history = rounds.filter(r => r.survey_id === round.survey_id && r.opens_at <= round.opens_at).slice(0, 8).reverse()
  const queries = useQueries({ queries: history.map(r => ({ queryKey: ['surveys', 'results', 'builder', user?.id, r.id], queryFn: () => getSurveyResults(r.id), enabled: !!question })) })
  if (!question) return <div className={surveyAdminCard}><p className="text-sm text-slate-600">Trends are available for rating and agreement questions. Use Question breakdown for other answer types.</p></div>
  const max = question.type === 'agreement' ? 5 : question.scale_max ?? 5
  const points = history.map((r, i) => {
    const matched = comparableHistoryQuestion(question, r.question_schema)
    const stat = matched && queries[i].data ? analyseQuestion(matched, queries[i].data!) : null
    return { round: r, mean: stat?.mean ?? null, count: stat?.answered ?? 0 }
  })
  const x = (i: number) => points.length < 2 ? 320 : 45 + i * 550 / (points.length - 1)
  const y = (mean: number) => 175 - (mean - 1) / (max - 1) * 140
  return <section className={`${surveyAdminCard} space-y-3`} aria-label="Survey trends">
    <div className="flex flex-wrap items-center justify-between gap-2"><h3 className="font-semibold text-slate-900">Trends across runs</h3><span className="text-xs text-slate-500">Up to 8 runs, ending with this run</span></div>
    <label htmlFor="trend-question" className="sr-only">Trend question</label><select id="trend-question" className={surveyAdminInput} value={question.id} onChange={event => setQuestionId(event.target.value)}>{numeric.map(q => <option key={q.id} value={q.id}>{q.prompt}</option>)}</select>
    {queries.some(q => q.isPending) ? <p role="status" className="text-sm text-slate-500">Loading run history...</p> : null}
    {queries.some(q => q.isError) ? <p role="alert" className="text-sm text-red-700">Some history could not load. <button type="button" className="underline" onClick={() => queries.filter(q => q.isError).forEach(q => { void q.refetch() })}>Retry history</button></p> : null}
    <svg viewBox="0 0 640 220" className="w-full rounded-lg bg-slate-50" role="img" aria-label={`Mean rating trend for ${question.prompt}. Data is listed in the table below.`}>
      {[1, Math.ceil(max / 2), max].map(tick => <g key={tick}><line x1="45" x2="595" y1={y(tick)} y2={y(tick)} stroke="#e2e8f0" /><text x="30" y={y(tick) + 4} textAnchor="end" className="text-[20px] sm:text-[12px]" fill="#64748b">{tick}</text></g>)}
      {points.map((point, i) => <g key={point.round.id}>
        {point.mean != null && i > 0 && points[i - 1].mean != null ? <line x1={x(i - 1)} y1={y(points[i - 1].mean!)} x2={x(i)} y2={y(point.mean)} stroke="#7c3aed" strokeWidth="3" /> : null}
        {point.mean != null ? <><circle cx={x(i)} cy={y(point.mean)} r="5" fill="#7c3aed"><title>{surveyDate(point.round.opens_at)}: {point.mean.toFixed(2)} from {point.count} answers</title></circle><text x={x(i)} y={y(point.mean) - 14} textAnchor="middle" className="text-[20px] sm:text-[12px]" fill="#5b21b6">{point.mean.toFixed(1)}</text></> : null}
        <text x={x(i)} y="203" textAnchor="middle" className="text-[20px] sm:text-[11px]" fill="#64748b">{i + 1}</text>
      </g>)}
    </svg>
    <p className="text-xs text-slate-500">Question wording, type and scale must match. Missing or changed questions leave gaps. Answer counts may differ between runs.</p>
    <table className="w-full text-left text-xs"><thead><tr className="border-b text-slate-500"><th className="py-2">Run</th><th>Date</th><th>Mean</th><th>Answers</th></tr></thead><tbody>{points.map((p, i) => <tr key={p.round.id} className="border-b border-slate-100"><td className="py-2">{i + 1}</td><td>{surveyDate(p.round.opens_at)}</td><td>{p.mean == null ? 'Not available' : `${p.mean.toFixed(2)} / ${max}`}</td><td>{p.count}</td></tr>)}</tbody></table>
  </section>
}
