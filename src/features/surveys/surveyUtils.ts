import type { SurveyAnswer, SurveyAnswerMap, SurveyQuestion, SurveyRound, SurveySchedule } from './surveyApi'

export const SURVEY_SCALE = ['Strongly disagree', 'Disagree', 'Neutral', 'Agree', 'Strongly agree']
export const QUESTION_TYPE_LABELS = {
  agreement: 'Agreement scale (1–5)', rating: 'Number rating (1–5 or 1–10)', yes_no: 'Yes / No',
  single_choice: 'Multiple choice (pick one)', multi_choice: 'Checkboxes (pick several)', text: 'Written answer',
}
export const SCHEDULE_LABELS: Record<SurveySchedule, string> = {
  manual: 'Manual launch only', once: 'Once on a date', weekly: 'Every week', monthly: 'Every month', quarterly: 'Every 3 months', yearly: 'Every year',
}
export const surveyPrimaryButton = 'rounded-md bg-violet-700 px-4 py-2 text-sm font-medium text-white hover:bg-violet-800 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-violet-600 disabled:cursor-not-allowed disabled:opacity-50'
export const surveySecondaryButton = 'rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-violet-600 disabled:opacity-50'
export const surveyInput = 'w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500'
export const surveyCard = 'rounded-xl border border-slate-200 bg-white p-4 sm:p-6'
// Denser administration controls; employee answer controls retain their spacing.
export const surveyAdminCard = 'rounded-lg border border-slate-200 bg-white p-3'
export const surveyAdminInput = 'min-h-10 w-full rounded-md border border-slate-300 bg-white px-2.5 py-1.5 text-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500 sm:min-h-8'
export const surveyAdminPrimaryButton = surveyPrimaryButton.replace('px-4 py-2', 'min-h-10 px-3 py-1.5 sm:min-h-8')
export const surveyAdminSecondaryButton = surveySecondaryButton.replace('px-4 py-2', 'min-h-10 px-3 py-1.5 sm:min-h-8')

export function surveyIsOpen(round: SurveyRound, now: number) {
  return !round.closed_at && new Date(round.opens_at).getTime() <= now && now < new Date(round.closes_at).getTime()
}

export function surveyDate(value: string) {
  // A date-only value is a NZ calendar date, not a UTC instant.
  const date = new Date(value.length === 10 ? `${value}T12:00:00+13:00` : value)
  return new Intl.DateTimeFormat('en-NZ', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'Pacific/Auckland' }).format(date)
}

export function nzDateAfter(days: number) {
  const parts = new Intl.DateTimeFormat('en-CA', {
    year: 'numeric', month: '2-digit', day: '2-digit', timeZone: 'Pacific/Auckland',
  }).formatToParts(new Date())
  const part = (type: string) => parts.find(p => p.type === type)?.value ?? ''
  const date = new Date(`${part('year')}-${part('month')}-${part('day')}T12:00:00Z`)
  date.setUTCDate(date.getUTCDate() + days)
  return date.toISOString().slice(0, 10)
}

export function surveyAverage(scores: (number | null)[]) {
  const answered = scores.filter((score): score is number => score != null)
  return answered.length ? answered.reduce((sum, score) => sum + score, 0) / answered.length : null
}

export function questionHasAnswer(value: SurveyAnswer | undefined) {
  if (value == null) return false
  if (typeof value === 'string') return value.trim().length > 0
  if (Array.isArray(value)) return value.length > 0
  return true // A deliberate No (false) is an answered question.
}

export function questionOptions(question: SurveyQuestion): { label: string; value: SurveyAnswer }[] {
  if (question.type === 'agreement') return SURVEY_SCALE.map((label, i) => ({ label: `${i + 1} - ${label}`, value: i + 1 }))
  if (question.type === 'rating') return Array.from({ length: question.scale_max ?? 5 }, (_, i) => ({
    label: `${i + 1}${i === 0 ? ` - ${question.low_label}` : i + 1 === question.scale_max ? ` - ${question.high_label}` : ''}`, value: i + 1,
  }))
  if (question.type === 'yes_no') return [{ label: 'Yes', value: true }, { label: 'No', value: false }]
  return (question.options ?? []).map(option => ({ label: option, value: option }))
}

export function formatSurveyAnswer(question: SurveyQuestion, answer: SurveyAnswer | undefined) {
  if (!questionHasAnswer(answer)) return 'No answer provided.'
  if (Array.isArray(answer)) return answer.join(', ')
  return questionOptions(question).find(option => option.value === answer)?.label ?? String(answer)
}

export function comparableQuestion(question: SurveyQuestion, previous: SurveyQuestion) {
  return question.id === previous.id && question.prompt === previous.prompt && question.type === previous.type &&
    question.scale_max === previous.scale_max && question.low_label === previous.low_label && question.high_label === previous.high_label &&
    JSON.stringify(question.options ?? []) === JSON.stringify(previous.options ?? [])
}

export function responseRatingSummary(questions: SurveyQuestion[], answers: SurveyAnswerMap) {
  // Mixed question types and scale lengths cannot form one meaningful average.
  const rated = questions.filter(q => q.type === 'agreement' || q.type === 'rating')
  const scales = new Set(rated.map(q => q.type === 'agreement' ? 5 : q.scale_max ?? 5))
  if (!rated.length || scales.size !== 1) return null
  const average = surveyAverage(rated.map(q => typeof answers[q.id] === 'number' ? answers[q.id] as number : null))
  return average == null ? null : `${average.toFixed(1)} / ${[...scales][0]}`
}
