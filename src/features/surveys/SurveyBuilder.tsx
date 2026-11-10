import { useMutation } from '@tanstack/react-query'
import { useState } from 'react'
import { useBeforeUnload } from 'react-router-dom'
import { saveSurveyDefinition, type QuestionType, type SurveyAnswerMap, type SurveyDefinitionInput, type SurveyQuestion, type SurveySchedule } from './surveyApi'
import { SurveyDialog } from './SurveyDialog'
import { SurveyIntroduction } from './SurveyIntroduction'
import { SurveyQuestionInput } from './SurveyQuestionInput'
import { nzDateAfter, QUESTION_TYPE_LABELS, SCHEDULE_LABELS, surveyAdminCard as surveyCard, surveyAdminInput as surveyInput, surveyAdminPrimaryButton as surveyPrimaryButton, surveyAdminSecondaryButton as surveySecondaryButton } from './surveyUtils'

function newQuestion(type: QuestionType = 'agreement'): SurveyQuestion {
  return { id: crypto.randomUUID(), prompt: '', type, required: type !== 'text',
    ...(type === 'rating' ? { scale_max: 5, low_label: 'Not at all', high_label: 'Very much' } : {}),
    ...(['single_choice', 'multi_choice'].includes(type) ? { options: ['Option 1', 'Option 2'] } : {}),
  }
}

export function SurveyBuilder({ initial, onSaved, onCancel }: { initial: SurveyDefinitionInput; onSaved: (id: string) => void; onCancel: () => void }) {
  const [survey, setSurvey] = useState(initial)
  const [preview, setPreview] = useState(false)
  const [previewAnswers, setPreviewAnswers] = useState<SurveyAnswerMap>({})
  const [discard, setDiscard] = useState(false)
  const dirty = JSON.stringify(survey) !== JSON.stringify(initial)
  const save = useMutation({ mutationFn: saveSurveyDefinition, onSuccess: onSaved })
  useBeforeUnload(event => { if (dirty && !save.isSuccess) { event.preventDefault(); event.returnValue = '' } })
  function updateQuestion(id: string, changes: Partial<SurveyQuestion>) {
    setSurvey(old => ({ ...old, questions: old.questions.map(q => q.id === id ? { ...q, ...changes } : q) }))
  }
  function moveQuestion(index: number, direction: number) {
    setSurvey(old => {
      const questions = [...old.questions]
      ;[questions[index], questions[index + direction]] = [questions[index + direction], questions[index]]
      return { ...old, questions }
    })
  }
  function changeSchedule(kind: SurveySchedule) {
    setSurvey(old => ({ ...old, schedule_kind: kind, start_on: kind === 'manual' ? null : old.start_on ?? nzDateAfter(1),
      schedule_enabled: kind === 'manual' ? false : old.schedule_enabled,
      duration_days: Math.min(old.duration_days, kind === 'weekly' ? 7 : kind === 'monthly' ? 28 : 60),
    }))
  }
  return <form onSubmit={event => { event.preventDefault(); if (!preview && !discard) save.mutate(survey) }} className="space-y-2">
    <div className="grid gap-2 lg:grid-cols-2">
    <div className={surveyCard}>
      <label htmlFor="survey-name" className="mb-1 block text-xs font-medium text-slate-700">Survey name</label>
      <input id="survey-name" required maxLength={120} className={surveyInput} value={survey.name} onChange={event => setSurvey(old => ({ ...old, name: event.target.value }))} />
      <label htmlFor="survey-description" className="mb-1 mt-2 block text-xs font-medium text-slate-700">Introduction / purpose</label>
      <textarea id="survey-description" rows={2} maxLength={2000} className={surveyInput} value={survey.description} onChange={event => setSurvey(old => ({ ...old, description: event.target.value }))} />
    </div>
    <div className={surveyCard}>
      <div className="mb-2 flex flex-wrap items-center justify-between gap-1"><h2 className="text-sm font-semibold text-slate-900">Run schedule</h2><span className="text-xs text-slate-500">NZ time · checked hourly</span></div>
      <div className="grid gap-2 sm:grid-cols-3">
        <div><label htmlFor="survey-frequency" className="mb-1 block text-xs font-medium text-slate-700">Frequency</label>
          <select id="survey-frequency" value={survey.schedule_kind} onChange={event => changeSchedule(event.target.value as SurveySchedule)} className={surveyInput}>
            {Object.entries(SCHEDULE_LABELS).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
          </select></div>
        {survey.schedule_kind !== 'manual' ? <div><label htmlFor="survey-first-run" className="mb-1 block text-xs font-medium text-slate-700">First run date</label><input id="survey-first-run" type="date" required className={surveyInput} value={survey.start_on ?? ''} onChange={event => setSurvey(old => ({ ...old, start_on: event.target.value }))} /></div> : null}
        <div><label htmlFor="survey-duration" className="mb-1 block text-xs font-medium text-slate-700">Response window (days)</label><input id="survey-duration" type="number" min={1} max={survey.schedule_kind === 'weekly' ? 7 : survey.schedule_kind === 'monthly' ? 28 : 60} required className={surveyInput} value={survey.duration_days} onChange={event => setSurvey(old => ({ ...old, duration_days: Number(event.target.value) }))} /></div>
      </div>
      <div className="mt-2 flex flex-wrap items-start gap-x-4 gap-y-1">
        {survey.schedule_kind !== 'manual' ? <label className="flex min-h-8 items-center gap-2 text-xs text-slate-700"><input type="checkbox" className="size-4 accent-violet-700" checked={survey.schedule_enabled} onChange={event => setSurvey(old => ({ ...old, schedule_enabled: event.target.checked }))} />Enable automatic runs</label> : null}
        <details className="py-1.5 text-xs text-slate-500"><summary className="cursor-pointer text-violet-700">Schedule details</summary><p className="mt-1">Scheduled runs open at midnight; offline launches retry for up to 7 days while the response window remains open. Short months use their last day. Manual launch is always available. Employees also see the standard explanation about named admin access and private drafts.</p></details>
      </div>
    </div>
    </div>
    <div className="flex flex-wrap items-center justify-between gap-2 px-1 py-1"><h2 className="text-sm font-semibold text-slate-900">Questions <span className="text-xs font-normal text-slate-500">{survey.questions.length}/50</span></h2><button type="button" className={surveySecondaryButton} onClick={() => { setPreviewAnswers({}); setPreview(true) }}>Preview survey</button></div>
    {survey.questions.map((question, index) => <section key={question.id} className={`${surveyCard} scroll-mb-20 py-2`} aria-label={`Question ${index + 1} settings`}>
      <div className="mb-1.5 flex flex-wrap items-center justify-between gap-2"><h3 className="text-xs font-semibold text-slate-800">Question {index + 1}</h3><div className="flex gap-3 text-xs text-violet-700">
        <button type="button" disabled={index === 0} onClick={() => moveQuestion(index, -1)} className="disabled:text-slate-300" aria-label={`Move question ${index + 1} up`}>Move up</button>
        <button type="button" disabled={index === survey.questions.length - 1} onClick={() => moveQuestion(index, 1)} className="disabled:text-slate-300" aria-label={`Move question ${index + 1} down`}>Move down</button>
        <button type="button" disabled={survey.questions.length === 1} onClick={() => setSurvey(old => ({ ...old, questions: old.questions.filter(q => q.id !== question.id) }))} className="text-rose-700 disabled:text-slate-300" aria-label={`Remove question ${index + 1}`}>Remove</button>
      </div></div>
      <div className="grid items-end gap-2 md:grid-cols-[minmax(0,1fr)_15rem_auto]">
      <div><label htmlFor={`builder-prompt-${question.id}`} className="mb-1 block text-xs font-medium text-slate-700 md:sr-only">Question text</label>
      <input id={`builder-prompt-${question.id}`} required maxLength={500} value={question.prompt} onChange={event => updateQuestion(question.id, { prompt: event.target.value })} className={surveyInput} />
      </div><div className="min-w-0"><label htmlFor={`builder-type-${question.id}`} className="mb-1 block text-xs font-medium text-slate-700 md:sr-only">Answer type</label>
        <select id={`builder-type-${question.id}`} value={question.type} onChange={event => {
          const next = newQuestion(event.target.value as QuestionType)
          setSurvey(old => ({ ...old, questions: old.questions.map(q => q.id === question.id ? { ...next, id: q.id, prompt: q.prompt, required: q.required } : q) }))
        }} className={surveyInput}>{Object.entries(QUESTION_TYPE_LABELS).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select>
      </div><label className={`flex min-h-8 items-center gap-2 text-xs ${question.required ? 'text-red-600' : 'text-slate-500'}`}><input type="checkbox" checked={question.required} onChange={event => updateQuestion(question.id, { required: event.target.checked })} className="size-4 accent-violet-700" />Required</label></div>
      {question.type === 'rating' ? <div className="mt-2 grid gap-2 sm:grid-cols-3">
        <div><label htmlFor={`scale-${question.id}`} className="mb-2 block text-xs font-medium text-slate-600">Scale</label><select id={`scale-${question.id}`} className={surveyInput} value={question.scale_max} onChange={event => updateQuestion(question.id, { scale_max: Number(event.target.value) })}><option value={5}>1–5</option><option value={10}>1–10</option></select></div>
        <div><label htmlFor={`low-${question.id}`} className="mb-2 block text-xs font-medium text-slate-600">Label for 1</label><input id={`low-${question.id}`} required maxLength={80} className={surveyInput} value={question.low_label} onChange={event => updateQuestion(question.id, { low_label: event.target.value })} /></div>
        <div><label htmlFor={`high-${question.id}`} className="mb-2 block text-xs font-medium text-slate-600">Label for {question.scale_max}</label><input id={`high-${question.id}`} required maxLength={80} className={surveyInput} value={question.high_label} onChange={event => updateQuestion(question.id, { high_label: event.target.value })} /></div>
      </div> : null}
      {question.type === 'single_choice' || question.type === 'multi_choice' ? <div className="mt-2 space-y-1.5">
        <p className="text-xs font-medium text-slate-600">Answer options (2–10, each different)</p>
        <div className="grid gap-x-4 gap-y-1.5 sm:grid-cols-2">{question.options?.map((option, i) => <div key={i} className="flex items-center gap-2"><label htmlFor={`option-${question.id}-${i}`} className="sr-only">Option {i + 1}</label><input id={`option-${question.id}-${i}`} required maxLength={120} value={option} onChange={event => updateQuestion(question.id, { options: question.options!.map((o, j) => j === i ? event.target.value : o) })} className={surveyInput} /><button type="button" aria-label={`Remove option ${i + 1}`} disabled={question.options!.length <= 2} onClick={() => updateQuestion(question.id, { options: question.options!.filter((_, j) => i !== j) })} className="text-xs text-rose-700 disabled:text-slate-300">Remove</button></div>)}</div>
        <button type="button" disabled={question.options!.length >= 10} onClick={() => updateQuestion(question.id, { options: [...question.options!, `Option ${question.options!.length + 1}`] })} className="text-sm text-violet-700 disabled:text-slate-400">+ Add option</button>
      </div> : null}
    </section>)}
    <button type="button" disabled={survey.questions.length >= 50} className={surveySecondaryButton} onClick={() => setSurvey(old => ({ ...old, questions: [...old.questions, newQuestion()] }))}>+ Add question</button>
    <div className={`${surveyCard} sticky bottom-0 z-10 space-y-2 shadow-[0_-3px_8px_rgb(15_23_42_/_0.05)]`}>
      {save.isError ? <p role="alert" className="text-sm text-red-700">{save.error.message}</p> : null}
      <div className="flex flex-wrap gap-3"><button type="submit" disabled={save.isPending} className={surveyPrimaryButton}>{save.isPending ? 'Saving…' : 'Save survey'}</button><button type="button" disabled={save.isPending} className={surveySecondaryButton} onClick={() => dirty ? setDiscard(true) : onCancel()}>Cancel</button></div>
    </div>
    {preview ? <SurveyDialog title={survey.name || 'Survey preview'} wide onDismiss={() => setPreview(false)}>
      <div className="my-3 flex items-center justify-between gap-3"><p className="text-xs font-medium text-violet-700">Preview only · no answers are saved</p><button type="button" autoFocus className={surveySecondaryButton} onClick={() => setPreview(false)}>Close preview</button></div><SurveyIntroduction questions={survey.questions} description={survey.description} />
      <div className="divide-y divide-slate-100">{survey.questions.map((q, i) => <SurveyQuestionInput key={q.id} question={q} number={i + 1} value={previewAnswers[q.id]} onChange={value => setPreviewAnswers(old => ({ ...old, [q.id]: value }))} />)}</div>
    </SurveyDialog> : null}
    {discard ? <SurveyDialog title="Discard unsaved changes?" onDismiss={() => setDiscard(false)}><p className="mt-3 text-sm text-slate-600">Your saved surveys and launched runs will be kept.</p><div className="mt-5 flex gap-3"><button type="button" className={surveyPrimaryButton} onClick={onCancel}>Discard changes</button><button type="button" autoFocus className={surveySecondaryButton} onClick={() => setDiscard(false)}>Keep editing</button></div></SurveyDialog> : null}
  </form>
}
