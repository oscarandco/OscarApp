import { useState } from 'react'
import type { SurveyParticipant, SurveyRound } from './surveyApi'
import { SurveyDialog } from './SurveyDialog'
import { downloadSurveyBlob, prepareSurveyExport, surveyExportFilename, type ExportIdentity } from './surveyExportData'
import { surveyAdminInput, surveyPrimaryButton, surveySecondaryButton } from './surveyUtils'

export function SurveyExportDialog({ round, participants, onClose }: { round: SurveyRound; participants: SurveyParticipant[]; onClose: () => void }) {
  const [format, setFormat] = useState<'xlsx' | 'pdf'>('xlsx')
  const [identity, setIdentity] = useState<ExportIdentity>('named')
  const [includeWritten, setIncludeWritten] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [done, setDone] = useState('')
  const submitted = participants.filter(p => p.response?.submitted_at).length
  async function download() {
    setBusy(true); setError(''); setDone('')
    try {
      // Build a new shuffled mapping for every randomised export. Never export
      // account IDs or a hidden identity lookup sheet.
      const data = prepareSurveyExport(round, participants, identity, includeWritten)
      const blob = format === 'xlsx' ? await (await import('./surveyXlsxExport')).buildSurveyXlsx(data) : await (await import('./surveyPdfExport')).buildSurveyPdf(data)
      downloadSurveyBlob(blob, surveyExportFilename(round.title, identity, format))
      setDone(`${format.toUpperCase()} ready. Your download has started.`)
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'The export could not be created. Please retry.') }
    finally { setBusy(false) }
  }
  return <SurveyDialog title="Export survey results" onDismiss={() => { if (!busy) onClose() }}>
    <p className="mt-2 text-sm text-slate-600">{round.title} · {submitted} submitted responses. Drafts and non-respondents are not included in raw results.</p>
    <div className="mt-4 grid gap-3 sm:grid-cols-2">
      <div><label htmlFor="export-format" className="mb-1 block text-xs font-medium text-slate-700">File format</label><select id="export-format" disabled={busy} className={surveyAdminInput} value={format} onChange={e => setFormat(e.target.value as 'xlsx' | 'pdf')}><option value="xlsx">Excel workbook (.xlsx)</option><option value="pdf">PDF report (.pdf)</option></select></div>
      <div><label htmlFor="export-identity" className="mb-1 block text-xs font-medium text-slate-700">Respondent identities</label><select id="export-identity" disabled={busy} className={surveyAdminInput} value={identity} onChange={e => { const next = e.target.value as ExportIdentity; setIdentity(next); setIncludeWritten(next === 'named'); setDone('') }}><option value="named">Names and emails</option><option value="randomised">Randomised response IDs</option></select></div>
    </div>
    <label className="mt-4 flex min-h-11 items-center gap-2 text-sm text-slate-700"><input type="checkbox" checked={includeWritten} disabled={busy} onChange={e => setIncludeWritten(e.target.checked)} className="size-4 accent-violet-700" />Include written answers</label>
    {identity === 'randomised' ? <p className="mt-1 rounded-lg bg-violet-50 p-3 text-xs leading-relaxed text-violet-900">Names, emails, account IDs and exact submission times are removed. Rows are shuffled and assigned new IDs for each download. Written answers may still identify people, so they are excluded by default.</p> : null}
    <p className="mt-3 text-xs text-slate-500">Excel includes raw responses, a question key and summary statistics. PDF includes the summary and each respondent’s answers. Files are generated locally in your browser.</p>
    {error ? <p role="alert" className="mt-3 text-sm text-red-700">{error}</p> : null}
    {done ? <p role="status" className="mt-3 text-sm text-emerald-700">{done}</p> : null}
    <div className="mt-5 grid gap-2 sm:flex"><button type="button" disabled={busy || submitted === 0} className={`${surveyPrimaryButton} min-h-12`} onClick={() => void download()}>{busy ? 'Preparing file...' : 'Download results'}</button><button type="button" autoFocus disabled={busy} className={surveySecondaryButton} onClick={onClose}>Close</button></div>
  </SurveyDialog>
}
