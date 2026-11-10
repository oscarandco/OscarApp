import type { SurveyAnswerMap, SurveyParticipant, SurveyRound } from './surveyApi'
import { analyseQuestion } from './surveyStatistics'
import { formatSurveyAnswer, QUESTION_TYPE_LABELS, surveyDate } from './surveyUtils'

export type ExportIdentity = 'named' | 'randomised'
export type ExportPerson = { label: string; email?: string; submitted?: string; answers: SurveyAnswerMap }
export type SurveyExportData = ReturnType<typeof prepareSurveyExport>
export const exportText = (value: string) => value.replace(/[\u2013\u2014]/g, '-').replace(/\u00a0/g, ' ')

export function prepareSurveyExport(round: SurveyRound, participants: SurveyParticipant[], identity: ExportIdentity, includeWritten: boolean) {
  const submitted = participants.filter(p => p.response?.submitted_at)
  const ordered = identity === 'randomised' ? submitted.map(p => ({ p, key: crypto.randomUUID() })).sort((a, b) => a.key.localeCompare(b.key)).map(item => item.p) : submitted
  const people: ExportPerson[] = ordered.map((person, index) => ({
    label: identity === 'named' ? exportText(person.staff_name) : `Response ${String(index + 1).padStart(3, '0')}`,
    ...(identity === 'named' ? {
      email: person.email,
      submitted: new Intl.DateTimeFormat('en-NZ', { dateStyle: 'medium', timeStyle: 'medium', timeZone: 'Pacific/Auckland' }).format(new Date(person.response!.submitted_at!)),
    } : {}),
    answers: Object.fromEntries(round.question_schema.map(q => [q.id, q.type === 'text' && !includeWritten ? null : person.response!.answers[q.id] ?? null])),
  }))
  return {
    title: exportText(round.title), opens: surveyDate(round.opens_at), closes: surveyDate(round.closes_at),
    identity, includeWritten, eligible: participants.length, people,
    questions: round.question_schema.map((q, i) => ({ ...q, prompt: exportText(q.prompt), code: `Q${i + 1}`, typeLabel: exportText(QUESTION_TYPE_LABELS[q.type]) })),
    summary: round.question_schema.map((q, i) => ({ code: `Q${i + 1}`, prompt: exportText(q.prompt), ...analyseQuestion(q, participants) })),
  }
}

export function exportAnswer(data: SurveyExportData, person: ExportPerson, index: number, raw = false): string | number | boolean | null {
  const q = data.questions[index]
  if (q.type === 'text' && !data.includeWritten) return '[Written answer excluded]'
  const answer = person.answers[q.id]
  if (raw) return typeof answer === 'string' ? exportText(answer) : Array.isArray(answer) ? JSON.stringify(answer.map(exportText)) : answer ?? null
  return exportText(formatSurveyAnswer(q, answer))
}

export function downloadSurveyBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url; link.download = filename; document.body.append(link); link.click(); link.remove()
  // Mobile browsers can consume downloads asynchronously after the click.
  window.setTimeout(() => URL.revokeObjectURL(url), 60_000)
}

export function surveyExportFilename(title: string, identity: ExportIdentity, format: 'xlsx' | 'pdf') {
  return `${title.replace(/[^a-zA-Z0-9_-]+/g, '-').replace(/^-|-$/g, '').slice(0, 70) || 'survey'}-${identity}.${format}`
}
