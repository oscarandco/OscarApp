import fontUrl from '@/assets/fonts/NotoSans-Regular.ttf?url'
import type { SurveyExportData } from './surveyExportData'
import { exportAnswer, exportText } from './surveyExportData'

export async function buildSurveyPdf(data: SurveyExportData): Promise<Blob> {
  const [{ jsPDF }, { autoTable }, fontResponse] = await Promise.all([import('jspdf'), import('jspdf-autotable'), fetch(fontUrl)])
  if (!fontResponse.ok) throw new Error('The PDF font could not load. Please retry.')
  const bytes = new Uint8Array(await fontResponse.arrayBuffer())
  let binary = ''
  for (let i = 0; i < bytes.length; i += 32768) binary += String.fromCharCode(...bytes.subarray(i, i + 32768))
  const doc = new jsPDF({ unit: 'mm', format: 'a4', compress: true })
  doc.addFileToVFS('NotoSans-Regular.ttf', btoa(binary))
  doc.addFont('NotoSans-Regular.ttf', 'NotoSans', 'normal')
  doc.setFont('NotoSans', 'normal')
  doc.setProperties({ title: `${data.title} results`, author: 'Oscar&Co', subject: `${data.identity} survey results`, creator: 'Oscar&Co Staff App' })
  const pageHeader = (subtitle: string) => {
    doc.setFontSize(10); doc.setTextColor('#6d28d9'); doc.text('OSCAR&CO. | STAFF SURVEYS', 14, 15)
    doc.setFontSize(17); doc.setTextColor('#0f172a')
    const title = doc.splitTextToSize(data.title, 182) as string[]
    doc.text(title, 14, 26)
    const y = 29 + title.length * 6
    doc.setFontSize(9); doc.setTextColor('#475569')
    const subtitleLines = doc.splitTextToSize(subtitle, 182) as string[]
    doc.text(subtitleLines, 14, y)
    return y + subtitleLines.length * 4.5 + 6
  }
  const styles = { font: 'NotoSans', fontStyle: 'normal' as const, fontSize: 8, cellPadding: 2.5, overflow: 'linebreak' as const, textColor: '#334155' }
  const headerStyles = { fillColor: '#5b21b6', textColor: '#ffffff', fontStyle: 'normal' as const }
  const y = pageHeader(`${data.opens} to ${data.closes} | ${data.people.length} submitted / ${data.eligible} eligible | ${data.identity === 'named' ? 'Named responses' : 'Randomised response IDs'}`)
  doc.setFontSize(8)
  const privacy = data.identity === 'randomised' ? `Names, emails, account IDs and exact submission times are omitted. Written answers ${data.includeWritten ? 'are included and may identify people.' : 'are excluded.'}` : `Only submitted responses are included. Written answers ${data.includeWritten ? 'are included.' : 'are excluded.'}`
  const privacyLines = doc.splitTextToSize(privacy, 182) as string[]
  doc.text(privacyLines, 14, y)
  autoTable(doc, {
    startY: y + privacyLines.length * 4 + 5, margin: { top: 16, right: 14, bottom: 16, left: 14 },
    head: [['Question', 'Answered', 'Mean', 'Median', 'Agree %']],
    body: data.summary.map(s => [`${s.code}. ${exportText(s.prompt)}`, String(s.answered), s.mean == null ? '' : `${s.mean.toFixed(2)} / ${s.question.type === 'agreement' ? 5 : s.question.scale_max}`, s.median == null ? '' : String(s.median), s.favourable == null ? '' : `${s.favourable.toFixed(1)}%`]),
    styles, headStyles: headerStyles, alternateRowStyles: { fillColor: '#f8fafc' },
    columnStyles: { 0: { cellWidth: 100 }, 1: { cellWidth: 20 }, 2: { cellWidth: 24 }, 3: { cellWidth: 18 }, 4: { cellWidth: 20 } },
  })
  for (const person of data.people) {
    doc.addPage()
    const subtitle = data.identity === 'named' ? `${person.label} | ${person.email} | Submitted ${person.submitted} NZ time` : person.label
    const start = pageHeader(subtitle)
    autoTable(doc, {
      startY: start, margin: { top: 16, right: 14, bottom: 16, left: 14 }, head: [['Question', 'Answer']],
      body: data.questions.map((q, i) => [`${q.code}. ${q.prompt}`, String(exportAnswer(data, person, i) ?? '')]),
      styles, headStyles: headerStyles, alternateRowStyles: { fillColor: '#f8fafc' },
      columnStyles: { 0: { cellWidth: 87 }, 1: { cellWidth: 95 } }, rowPageBreak: 'auto',
      didDrawPage: hook => {
        if (hook.pageNumber > 1) {
          doc.setFont('NotoSans', 'normal'); doc.setFontSize(8); doc.setTextColor('#64748b')
          doc.text((doc.splitTextToSize(`${person.label} (continued)`, 182) as string[])[0], 14, 11)
        }
      },
    })
  }
  const pages = doc.getNumberOfPages()
  for (let page = 1; page <= pages; page++) {
    doc.setPage(page); doc.setFont('NotoSans', 'normal'); doc.setFontSize(8); doc.setTextColor('#64748b')
    doc.text(`${data.identity === 'named' ? 'Named results' : 'Randomised IDs'} | Submitted answers only`, 14, 289)
    doc.text(`${page} / ${pages}`, 196, 289, { align: 'right' })
  }
  return doc.output('blob')
}
