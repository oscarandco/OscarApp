import type { SurveyParticipant, SurveyQuestion } from './surveyApi'
import { questionHasAnswer, questionOptions, surveyAverage } from './surveyUtils'

export function analyseQuestion(question: SurveyQuestion, participants: SurveyParticipant[]) {
  const responses = participants.flatMap(p => p.response?.submitted_at ? [p.response] : [])
  const answers = responses.map(r => r.answers[question.id]).filter(questionHasAnswer)
  const numeric = question.type === 'agreement' || question.type === 'rating'
  const scores = numeric ? answers.filter((a): a is number => typeof a === 'number').sort((a, b) => a - b) : []
  const mean = scores.length ? surveyAverage(scores) : null
  const median = scores.length ? scores.length % 2 ? scores[Math.floor(scores.length / 2)] : (scores[scores.length / 2 - 1] + scores[scores.length / 2]) / 2 : null
  const distribution = questionOptions(question).map(option => {
    const count = answers.filter(a => Array.isArray(a) ? a.includes(String(option.value)) : a === option.value).length
    return { ...option, count, percentage: answers.length ? count / answers.length * 100 : 0 }
  })
  const agree = question.type === 'agreement' ? scores.filter(a => a >= 4).length : null
  const neutral = question.type === 'agreement' ? scores.filter(a => a === 3).length : null
  const disagree = question.type === 'agreement' ? scores.filter(a => a <= 2).length : null
  return { question, answered: answers.length, skipped: responses.length - answers.length, mean, median, distribution, agree, neutral, disagree,
    favourable: agree != null && answers.length ? agree / answers.length * 100 : null }
}

export function comparableHistoryQuestion(question: SurveyQuestion, candidates: SurveyQuestion[]) {
  return candidates.find(q => q.id === question.id && q.prompt === question.prompt && q.type === question.type &&
    q.scale_max === question.scale_max && q.low_label === question.low_label && q.high_label === question.high_label &&
    JSON.stringify(q.options ?? []) === JSON.stringify(question.options ?? []))
}
