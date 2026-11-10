import { requireSupabaseClient } from '@/lib/supabase'

export type QuestionType = 'agreement' | 'rating' | 'yes_no' | 'single_choice' | 'multi_choice' | 'text'
export type SurveyQuestion = {
  id: string
  prompt: string
  type: QuestionType
  required: boolean
  scale_max?: number
  low_label?: string
  high_label?: string
  options?: string[]
}
export type SurveyAnswer = number | boolean | string | string[] | null
export type SurveyAnswerMap = Record<string, SurveyAnswer>
export type SurveySchedule = 'manual' | 'once' | 'weekly' | 'monthly' | 'quarterly' | 'yearly'
export type SurveyDefinition = {
  id: string
  name: string
  description: string
  questions: SurveyQuestion[]
  schedule_kind: SurveySchedule
  start_on: string | null
  duration_days: number
  schedule_enabled: boolean
  is_archived: boolean
  updated_at: string
  next_run_on: string | null
}
export type SurveyDefinitionInput = Omit<SurveyDefinition, 'id' | 'updated_at' | 'next_run_on' | 'is_archived'> & { id: string | null; updated_at: string | null }

export type SurveyResponse = {
  round_id: string
  user_id: string
  answers: SurveyAnswerMap
  scores: (number | null)[]
  comments: string[]
  revision: number
  updated_at: string
  submitted_at: string | null
}

export type SurveyRound = {
  id: string
  survey_id: string
  run_on: string
  description: string
  question_schema: SurveyQuestion[]
  quarter_start: string
  title: string
  questions: string[]
  written_questions: string[]
  opens_at: string
  closes_at: string
  closed_at: string | null
  launch_source: 'automatic' | 'admin'
}

export type MySurvey = SurveyRound & {
  remind_after: string | null
  response: SurveyResponse | null
}

export type AdminSurveyRound = SurveyRound & { participant_count: number; submitted_count: number }
export type SurveyParticipant = {
  user_id: string
  staff_name: string
  email: string
  response: SurveyResponse | null
}
export type AdminSurveys = { surveys: SurveyDefinition[]; rounds: AdminSurveyRound[] }

async function rpc<T>(name: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await requireSupabaseClient().rpc(name, args)
  if (error) throw new Error(error.message || 'Could not complete the survey request')
  return data as T
}

export const getMySurveys = () => rpc<MySurvey[]>('get_my_staff_surveys')
export const getAdminSurveys = () => rpc<AdminSurveys>('get_admin_staff_surveys')
export const getSurveyResults = (roundId: string) => rpc<SurveyParticipant[]>('get_staff_survey_results', { p_round_id: roundId })
export const launchSurvey = ({ surveyId, closesOn }: { surveyId: string; closesOn: string }) => rpc<string>('launch_configured_staff_survey', { p_survey_id: surveyId, p_closes_on: closesOn })
export const closeSurvey = (roundId: string) => rpc<null>('close_staff_survey', { p_round_id: roundId })
export const remindSurveyLater = (roundId: string) => rpc<string>('remind_staff_survey_later', { p_round_id: roundId })
export const saveSurveyDefinition = (survey: SurveyDefinitionInput) => rpc<string>('save_staff_survey_definition', {
  p_id: survey.id, p_name: survey.name, p_description: survey.description, p_questions: survey.questions,
  p_schedule_kind: survey.schedule_kind, p_start_on: survey.start_on, p_duration_days: survey.duration_days,
  p_schedule_enabled: survey.schedule_enabled, p_updated_at: survey.updated_at,
})
export const archiveSurvey = ({ survey, archived }: { survey: SurveyDefinition; archived: boolean }) => rpc<null>('archive_staff_survey', {
  p_survey_id: survey.id, p_archived: archived, p_updated_at: survey.updated_at,
})
export const saveSurveyResponse = (roundId: string, answers: SurveyAnswerMap, submit: boolean, revision: number) =>
  rpc<SurveyResponse>('save_configured_staff_survey_response', {
    p_round_id: roundId, p_answers: answers, p_submit: submit, p_revision: revision,
  })
