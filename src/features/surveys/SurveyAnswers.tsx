import type { SurveyResponse, SurveyRound } from './surveyApi'
import { comparableQuestion, formatSurveyAnswer } from './surveyUtils'

export function SurveyAnswers({ round, response, previous }: { round: SurveyRound; response: SurveyResponse; previous?: { round: SurveyRound; response: SurveyResponse } }) {
  return <ol className="divide-y divide-slate-100">
    {round.question_schema.map((q, i) => {
      const answer = response.answers[q.id]
      const previousQuestion = previous?.round.question_schema.find(p => comparableQuestion(q, p))
      const before = previousQuestion ? previous?.response.answers[previousQuestion.id] : null
      return <li key={q.id} className="py-4">
        <p className="text-sm font-medium text-slate-800">{i + 1}. {q.prompt}</p>
        <p className="mt-2 whitespace-pre-wrap break-words text-sm text-violet-900">{formatSurveyAnswer(q, answer)}</p>
        {typeof before === 'number' && typeof answer === 'number' ? <p className="mt-1 text-xs text-slate-500">Previous: {before} · Change: {answer - before > 0 ? '+' : ''}{answer - before}</p> : null}
      </li>
    })}
  </ol>
}
