import { Link, useParams } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { SurveyAnswers } from './SurveyAnswers'
import { SurveyIntroduction } from './SurveyIntroduction'
import { SurveyResponseForm } from './SurveyResponseForm'
import { responseRatingSummary, surveyCard, surveyDate, surveyIsOpen, surveyPrimaryButton } from './surveyUtils'
import { useMySurveys } from './useMySurveys'
import { useSurveyClock } from './useSurveyClock'

export function SurveysPage() {
  const { roundId } = useParams()
  const query = useMySurveys()
  const now = useSurveyClock()
  const client = useQueryClient()
  if (query.isPending) return <LoadingState message="Loading your surveys…" />
  if (query.isError) return <ErrorState error={query.error} onRetry={() => void query.refetch()} />
  const rounds = query.data
  const survey = rounds.find(round => round.id === roundId)

  if (roundId) {
    if (!survey) return <div className={surveyCard}><h1 className="text-xl font-semibold">Survey unavailable</h1><p className="mt-2 text-sm text-slate-600">This survey was not assigned to your account.</p><Link to="/app/surveys" className="mt-4 inline-block text-sm text-violet-700 underline">All surveys</Link></div>
    const submitted = survey.response?.submitted_at != null
    const previous = rounds.find(round => round.survey_id === survey.survey_id && round.response?.submitted_at && new Date(round.opens_at) < new Date(survey.opens_at))
    return <div className="mx-auto w-full max-w-3xl pb-6">
      <PageHeader title={survey.title} description={`Closes ${surveyDate(survey.closes_at)} at midnight (NZ time).`} />
      <div className={`${surveyCard} mb-4`}><SurveyIntroduction questions={survey.question_schema} description={survey.description} /></div>
      {submitted || !surveyIsOpen(survey, now) ? <div className={surveyCard}>
        <h2 className="font-semibold text-slate-900">{submitted ? 'Your submitted answers' : 'This survey is closed'}</h2>
        <p className="mt-1 text-sm text-slate-500">{submitted ? `Submitted ${surveyDate(survey.response!.submitted_at!)}. Thank you for sharing your experience.` : 'The response window has ended. Any saved draft remains private and was not submitted.'}</p>
        {survey.response ? <SurveyAnswers round={survey} response={survey.response} previous={previous?.response ? { round: previous, response: previous.response } : undefined} /> : null}
        <Link to="/app/surveys" className="mt-5 inline-block text-sm font-medium text-violet-700 underline">All surveys</Link>
      </div> : <SurveyResponseForm key={survey.id} survey={survey} onSubmitted={() => { void client.invalidateQueries({ queryKey: ['surveys'] }) }} />}
    </div>
  }

  return <div className="mx-auto w-full max-w-4xl pb-6">
    <PageHeader title="Surveys" description="Share your experience, and look back at your own previous responses." />
    <div className={`${surveyCard} mb-6`}><SurveyIntroduction /></div>
    {rounds.length === 0 ? <div className={`${surveyCard} text-sm text-slate-600`}>No surveys have been assigned to you yet. When a survey opens, you’ll see it here and receive an invitation after login.</div> : <div className="space-y-4">
      {rounds.map(round => {
        const submitted = Boolean(round.response?.submitted_at)
        const open = surveyIsOpen(round, now)
        const average = submitted ? responseRatingSummary(round.question_schema, round.response!.answers) : null
        return <article key={round.id} className={surveyCard}>
          <div className="flex flex-wrap items-start justify-between gap-4">
            <div>
              <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-violet-700">{submitted ? 'Submitted' : open ? round.response ? 'Draft in progress' : 'Open for your response' : 'Closed · not submitted'}</p>
              <h2 className="text-lg font-semibold text-slate-900">{round.title}</h2>
              <p className="mt-1 text-sm text-slate-500">{submitted ? `Submitted ${surveyDate(round.response!.submitted_at!)}` : `Closes ${surveyDate(round.closes_at)} at midnight (NZ time)`}</p>
              {average != null ? <p className="mt-3 text-sm text-slate-600">Your average rating: <strong className="text-slate-900">{average}</strong></p> : null}
            </div>
            <Link className={surveyPrimaryButton} to={`/app/surveys/${round.id}`}>{submitted ? 'View my answers' : open ? round.response ? 'Continue survey' : 'Answer survey' : 'View survey'}</Link>
          </div>
        </article>
      })}
      {rounds.filter(round => round.response?.submitted_at).length > 1 ? <p className="px-1 text-xs text-slate-500">Open a response to compare unchanged rating questions with the previous run of the same survey.</p> : null}
    </div>}
  </div>
}
