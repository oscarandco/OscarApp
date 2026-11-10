import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { Link, useLocation } from 'react-router-dom'
import { remindSurveyLater } from './surveyApi'
import { SurveyDialog } from './SurveyDialog'
import { surveyDate, surveyIsOpen, surveyPrimaryButton, surveySecondaryButton } from './surveyUtils'
import { useMySurveys } from './useMySurveys'
import { useSurveyClock } from './useSurveyClock'

export function SurveyLoginPrompt() {
  const query = useMySurveys()
  const now = useSurveyClock()
  const client = useQueryClient()
  const location = useLocation()
  const [dismissed, setDismissed] = useState<{ id: string; until: number } | null>(null)
  const later = useMutation({
    mutationFn: remindSurveyLater,
    onSuccess: (until, roundId) => {
      setDismissed({ id: roundId, until: new Date(until).getTime() })
      void client.invalidateQueries({ queryKey: ['surveys', 'mine'] })
    },
  })
  const survey = query.data?.find(round => surveyIsOpen(round, now) && !round.response?.submitted_at &&
    (!round.remind_after || new Date(round.remind_after).getTime() <= now))
  if (!survey || (survey.id === dismissed?.id && now < dismissed.until) || location.pathname.startsWith('/app/surveys')) return null

  return (
    <SurveyDialog title="You have a survey to answer" onDismiss={() => { if (!later.isPending) later.mutate(survey.id) }}>
      <p className="mt-3 text-sm text-slate-600">Your {survey.title} survey is ready. Take a few minutes to share your feedback.</p>
      <p className="mt-3 text-sm text-slate-600">{survey.question_schema.length} questions · {survey.question_schema.filter(q => q.required).length} required<br />Closes {surveyDate(survey.closes_at)} at midnight (NZ time).</p>
      <p className="mt-3 text-sm font-medium text-slate-700">Submitted answers are visible to authorised admins by name.</p>
      {later.isError ? <p role="alert" className="mt-3 text-sm text-red-700">Could not save your reminder. {later.error.message}</p> : null}
      <div className="mt-5 flex flex-wrap gap-3">
        <Link autoFocus className={surveyPrimaryButton} to={`/app/surveys/${survey.id}`}>Answer survey</Link>
        <button type="button" className={surveySecondaryButton} disabled={later.isPending} onClick={() => later.mutate(survey.id)}>
          {later.isPending ? 'Saving…' : 'Remind me later'}
        </button>
        {later.isError ? <button type="button" className={surveySecondaryButton} onClick={() => setDismissed({ id: survey.id, until: now + 24 * 3600_000 })}>Continue to app</button> : null}
      </div>
      <p className="mt-3 text-xs text-slate-500">Remind me later pauses the invitation for 24 hours. You can answer any time from Surveys.</p>
    </SurveyDialog>
  )
}
