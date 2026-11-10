import type { SurveyAnswer, SurveyQuestion } from './surveyApi'
import { questionOptions, surveyInput } from './surveyUtils'
import { AgreementFace } from './AgreementFace'

export function SurveyQuestionInput({ question, value, onChange, number, disabled = false, invalid = false }: {
  question: SurveyQuestion; value: SurveyAnswer | undefined; onChange: (value: SurveyAnswer) => void; number: number; disabled?: boolean; invalid?: boolean
}) {
  const fieldId = `survey-answer-${question.id}`
  const errorId = `${fieldId}-error`
  if (question.type === 'text') return <div className="py-4 sm:py-5">
    <label htmlFor={fieldId} className="mb-3 block text-sm font-medium text-slate-800">{number}. {question.prompt} <span className={question.required ? 'font-normal text-red-600' : 'font-normal text-slate-500'}>({question.required ? 'Required' : 'Optional'})</span></label>
    <textarea id={fieldId} rows={3} maxLength={2000} disabled={disabled} aria-invalid={invalid || undefined} aria-describedby={invalid ? errorId : undefined} value={typeof value === 'string' ? value : ''} onChange={event => onChange(event.target.value)} className={`${surveyInput} ${invalid ? 'border-red-500' : ''}`} />
    {invalid ? <p id={errorId} className="mt-2 text-xs font-medium text-red-700">Please answer this required question.</p> : null}
    <p className="mt-1 text-right text-xs text-slate-500">{typeof value === 'string' ? value.length : 0}/2,000</p>
  </div>
  const numeric = question.type === 'agreement' || question.type === 'rating'
  const options = questionOptions(question)
  return <fieldset disabled={disabled} aria-invalid={invalid || undefined} aria-describedby={invalid ? errorId : undefined} className="py-4 sm:py-5">
    <legend className="float-left mb-3 w-full text-sm font-medium text-slate-800">{number}. {question.prompt} <span className={question.required ? 'font-normal text-red-600' : 'font-normal text-slate-500'}>({question.required ? 'Required' : 'Optional'})</span></legend>
    <div className={`clear-both grid gap-1 sm:gap-2 ${numeric ? 'grid-cols-5' : 'grid-cols-1 sm:grid-cols-2'}`}>
      {options.map(option => <label key={String(option.value)} className="relative cursor-pointer">
        <input className="peer sr-only" type={question.type === 'multi_choice' ? 'checkbox' : 'radio'} name={fieldId} disabled={disabled}
          aria-label={option.label} aria-invalid={invalid || undefined} aria-describedby={invalid ? errorId : undefined} checked={question.type === 'multi_choice' ? Array.isArray(value) && value.includes(String(option.value)) : value === option.value}
          onChange={event => onChange(question.type === 'multi_choice'
            ? event.target.checked ? [...(Array.isArray(value) ? value : []), String(option.value)] : (Array.isArray(value) ? value : []).filter(v => v !== option.value)
            : option.value)} />
        <span className={`flex h-full min-h-12 flex-col items-center justify-center rounded-xl border border-slate-200 px-1 py-2.5 text-center text-sm text-slate-600 transition-colors peer-checked:border-violet-600 peer-checked:bg-violet-50 peer-checked:text-violet-900 peer-checked:shadow-[inset_0_0_0_1px_#7c3aed] peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-violet-600 ${question.type === 'agreement' ? 'min-h-[104px]' : numeric ? 'min-h-16' : ''}`}>
          {question.type === 'agreement' ? <AgreementFace value={option.value as number} /> : null}
          {numeric ? <><span className="mt-1 text-sm font-semibold">{String(option.value)}</span><span className="mt-1 text-[10px] leading-tight sm:text-xs">{option.label.split(' - ').slice(1).join(' - ')}</span></> : option.label}
        </span>
      </label>)}
    </div>
    {invalid ? <p id={errorId} className="mt-2 text-xs font-medium text-red-700">Please answer this required question.</p> : null}
    {question.type === 'multi_choice' ? <p className="mt-2 text-xs text-slate-500">Select all that apply.</p> : null}
    {!question.required && value != null ? <button type="button" disabled={disabled} onClick={() => onChange(null)} className="mt-2 text-xs text-violet-700 underline">Clear answer</button> : null}
  </fieldset>
}
