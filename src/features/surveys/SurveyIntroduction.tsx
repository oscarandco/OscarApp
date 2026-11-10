import type { SurveyQuestion } from './surveyApi'

export function SurveyIntroduction({ questions = [], description }: { questions?: SurveyQuestion[]; description?: string }) {
  return (
    <div className="space-y-2 text-sm leading-relaxed text-slate-600">
      <p className="whitespace-pre-wrap">{description || 'Share your experience at Oscar&Co and help us identify opportunities to improve our workplace.'}</p>
      {questions.length ? <p>{questions.length} questions · {questions.filter(q => q.required).length} required</p> : null}
      <p className="font-medium text-slate-700">Authorised admins can read your submitted answers by name. Drafts stay private.</p>
      <details className="text-xs text-slate-500"><summary className="cursor-pointer text-violet-700">How your responses are used</summary><p className="mt-2">Your answers stay linked to your account so you can view your history. Submitted answers, including written feedback, help identify workplace themes and improvements. They are not used to assess individual performance. Please share only what you feel comfortable sharing. Questions marked Required must be answered; optional questions can be skipped.</p></details>
    </div>
  )
}
