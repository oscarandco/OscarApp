import { useMutation } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useBeforeUnload, useNavigate } from 'react-router-dom'
import { saveSurveyResponse, type MySurvey, type SurveyAnswerMap } from './surveyApi'
import { SurveyDialog } from './SurveyDialog'
import { SurveyQuestionInput } from './SurveyQuestionInput'
import { useSurveyClock } from './useSurveyClock'
import { questionHasAnswer, surveyCard, surveyIsOpen, surveyPrimaryButton, surveySecondaryButton } from './surveyUtils'

type Answers = { answers: SurveyAnswerMap; submit: boolean }

export function SurveyResponseForm({ survey, onSubmitted }: { survey: MySurvey; onSubmitted: () => void }) {
  const navigate = useNavigate()
  const now = useSurveyClock()
  const [answers, setAnswers] = useState<SurveyAnswerMap>(() => survey.response?.answers ?? {})
  const [revision, setRevision] = useState(survey.response?.revision ?? 0)
  const [saved, setSaved] = useState(() => JSON.stringify(answers))
  const [confirmSubmit, setConfirmSubmit] = useState(false)
  const [showMissing, setShowMissing] = useState(false)
  const [attempted, setAttempted] = useState(false)
  const [submitted, setSubmitted] = useState(false)
  const dirty = JSON.stringify(answers) !== saved
  const required = survey.question_schema.filter(q => q.required)
  const answered = required.filter(q => questionHasAnswer(answers[q.id])).length
  const missing = survey.question_schema.map((q, i) => ({ question: q, number: i + 1 })).filter(({ question }) => question.required && !questionHasAnswer(answers[question.id]))
  const optionalSkipped = survey.question_schema.filter(q => !q.required && !questionHasAnswer(answers[q.id])).length
  const save = useMutation({
    mutationFn: (value: Answers) => saveSurveyResponse(survey.id, value.answers, value.submit, revision),
    onSuccess: (response, value) => {
      setRevision(response.revision); setSaved(JSON.stringify(value.answers))
      if (response.submitted_at) { setSubmitted(true); onSubmitted() }
    },
  })
  const { mutate, isPending, isError } = save
  useEffect(() => {
    if (!dirty || isPending || isError || confirmSubmit || showMissing || submitted || !surveyIsOpen(survey, now)) return
    const timer = window.setTimeout(() => mutate({ answers, submit: false }), 650)
    return () => window.clearTimeout(timer)
  }, [answers, dirty, isPending, isError, confirmSubmit, showMissing, submitted, survey, now, mutate])
  useBeforeUnload(event => { if (dirty && !submitted) { event.preventDefault(); event.returnValue = '' } })
  async function saveAndReturn() {
    try { if (dirty) await save.mutateAsync({ answers, submit: false }); navigate('/app/surveys') } catch { /* Keep answers and show the mutation error. */ }
  }
  const disabled = submitted || (isPending && save.variables?.submit)
  function goToQuestion(id: string) {
    setShowMissing(false)
    window.setTimeout(() => {
      const element = document.getElementById(`survey-question-${id}`)
      element?.scrollIntoView({ behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth', block: 'center' })
      const control = element?.querySelector<HTMLElement>('input, textarea, select')
      ;(control ?? element)?.focus({ preventScroll: true })
    }, 50)
  }
  return <form onSubmit={event => { event.preventDefault(); setAttempted(true); if (missing.length) setShowMissing(true); else setConfirmSubmit(true) }} className="space-y-3">
    <div className="sticky top-0 z-10 rounded-lg border border-slate-200 bg-white/95 px-3 py-2 shadow-sm backdrop-blur-sm" aria-label="Survey progress">
      <div className="flex items-center justify-between gap-2 text-xs"><span className="font-medium text-slate-700">{answered} of {required.length} required answered</span><span className={missing.length ? 'font-medium text-red-700' : 'font-medium text-emerald-700'}>{missing.length ? `${missing.length} still to answer` : 'Ready to submit'}</span></div>
      <div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-slate-100" role="progressbar" aria-label="Required questions answered" aria-valuemin={0} aria-valuemax={required.length || 1} aria-valuenow={required.length ? answered : 1}><div className="h-full rounded-full bg-violet-600 transition-[width]" style={{ width: `${required.length ? answered / required.length * 100 : 100}%` }} /></div>
    </div>
    <div className={surveyCard}>
      <h2 className="font-semibold text-slate-900">Your answers</h2>
      <div className="mt-1 divide-y divide-slate-100">{survey.question_schema.map((q, i) => <div key={q.id} id={`survey-question-${q.id}`} tabIndex={-1} className={`scroll-mt-20 rounded-lg outline-none ${attempted && q.required && !questionHasAnswer(answers[q.id]) ? 'bg-red-50/60 px-2 ring-1 ring-inset ring-red-200' : ''}`}>
        <SurveyQuestionInput number={i + 1} question={q} value={answers[q.id]} disabled={disabled} invalid={attempted && q.required && !questionHasAnswer(answers[q.id])}
          onChange={value => setAnswers(old => ({ ...old, [q.id]: value }))} />
      </div>)}</div>
    </div>
    <div className={`${surveyCard} space-y-3`}>
      <p role="status" aria-live="polite" className="text-sm text-slate-600">{submitted ? 'Thank you. Your answers have been submitted.' : isPending ? 'Saving…' : isError ? 'Your latest changes have not been saved.' : dirty ? 'Unsaved changes…' : revision > 0 ? 'Draft saved automatically. Only you can see it until you submit.' : 'Your progress will save automatically as you answer.'}</p>
      {save.isError ? <div role="alert" className="space-y-2 text-sm text-red-700"><p>{save.error.message}</p><button type="button" className={surveySecondaryButton} onClick={() => save.mutate({ answers, submit: false })}>Retry save</button><p>If another session changed your answers, reload this page to load that version.</p></div> : null}
      <div className="grid gap-2 sm:flex sm:flex-wrap"><button type="submit" disabled={disabled || !surveyIsOpen(survey, now)} className={`${surveyPrimaryButton} min-h-12`}>Submit answers</button><button type="button" disabled={isPending || submitted} onClick={() => void saveAndReturn()} className={`${surveySecondaryButton} min-h-12`}>Save and return later</button></div>
    </div>
    {showMissing ? <SurveyDialog title="Some required answers are missing" onDismiss={() => setShowMissing(false)}><p className="mt-3 text-sm text-slate-600">Please answer the {missing.length} question{missing.length === 1 ? '' : 's'} below before submitting. Your current answers are kept.</p><ul className="mt-3 max-h-52 overflow-y-auto rounded-lg bg-red-50 p-2">{missing.map(({ question, number }) => <li key={question.id}><button type="button" onClick={() => goToQuestion(question.id)} className="min-h-11 w-full px-2 py-2 text-left text-sm text-red-800 underline">Q{number}. {question.prompt}</button></li>)}</ul>{optionalSkipped ? <p className="mt-2 text-xs text-slate-500">{optionalSkipped} optional question{optionalSkipped === 1 ? '' : 's'} left blank. These do not prevent submission.</p> : null}<div className="mt-4 grid gap-2 sm:flex"><button type="button" autoFocus className={`${surveyPrimaryButton} min-h-12`} onClick={() => { if (missing[0]) goToQuestion(missing[0].question.id) }}>Go to first unanswered</button><button type="button" className={surveySecondaryButton} onClick={() => setShowMissing(false)}>Keep reviewing</button></div></SurveyDialog> : null}
    {confirmSubmit ? <SurveyDialog title="Submit your answers?" onDismiss={() => setConfirmSubmit(false)}><p className="mt-3 text-sm text-slate-600">Authorised admins will be able to read your answers by name. Submitted answers are final, and you can view them any time in Surveys.</p>{optionalSkipped ? <p className="mt-2 text-sm text-slate-500">{optionalSkipped} optional question{optionalSkipped === 1 ? '' : 's'} will be left blank.</p> : null}<div className="mt-5 grid gap-2 sm:flex"><button type="button" disabled={isPending} className={`${surveyPrimaryButton} min-h-12`} onClick={() => { setConfirmSubmit(false); save.mutate({ answers, submit: true }) }}>Submit answers</button><button type="button" autoFocus className={surveySecondaryButton} onClick={() => setConfirmSubmit(false)}>Keep editing</button></div></SurveyDialog> : null}
  </form>
}
