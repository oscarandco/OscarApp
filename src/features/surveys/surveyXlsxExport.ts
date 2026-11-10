import type { Cell, SheetData } from 'write-excel-file/browser'
import type { SurveyExportData } from './surveyExportData'
import { exportAnswer, exportText } from './surveyExportData'

const header = (values: string[]): Cell[] => values.map(value => ({ value, type: String, fontWeight: 'bold', textColor: '#FFFFFF', backgroundColor: '#5B21B6', height: 28, wrap: true, alignVertical: 'center' }))
const row = (values: (string | number | boolean | null)[], index: number, height = 30): Cell[] => values.map(value => ({
  value: value ?? '', type: typeof value === 'number' ? Number : typeof value === 'boolean' ? Boolean : String,
  // Explicit String cells keep survey text starting with =, +, - or @ literal.
  textColor: '#334155', backgroundColor: index % 2 ? '#F8FAFC' : '#FFFFFF', height, wrap: true, alignVertical: 'top',
}))

export async function buildSurveyXlsx(data: SurveyExportData): Promise<Blob> {
  const { default: writeExcelFile } = await import('write-excel-file/browser')
  const named = data.identity === 'named'
  const responses: SheetData = [header(['Respondent', ...(named ? ['Email', 'Submitted (NZ time)'] : []), ...data.questions.map(q => q.code)])]
  data.people.forEach((person, i) => {
    const values = [person.label, ...(named ? [person.email!, person.submitted!] : []), ...data.questions.map((_, j) => exportAnswer(data, person, j, true))]
    const length = Math.max(...values.map(v => typeof v === 'string' ? v.length : 0), 0)
    responses.push(row(values, i, Math.min(409, Math.max(30, Math.ceil(length / 55) * 14))))
  })
  const questions: SheetData = [header(['Code', 'Question', 'Answer type', 'Required', 'Scale / options'])]
  data.questions.forEach((q, i) => {
    const scale = q.type === 'agreement' ? '1 Strongly disagree; 2 Disagree; 3 Neutral; 4 Agree; 5 Strongly agree'
      : q.type === 'rating' ? `1 (${q.low_label}) to ${q.scale_max} (${q.high_label})`
        : q.options ? JSON.stringify(q.options) : q.type === 'yes_no' ? 'TRUE = Yes; FALSE = No' : 'Written text, up to 2,000 characters'
    questions.push(row([q.code, q.prompt, q.typeLabel, q.required ? 'Yes' : 'No', exportText(scale)], i, Math.max(42, Math.ceil(q.prompt.length / 70) * 15)))
  })
  const summary: SheetData = [
    [{ value: data.title, type: String, fontSize: 16, fontWeight: 'bold', textColor: '#5B21B6', height: 32, columnSpan: 8 }],
    row(['Run', `${data.opens} to ${data.closes}`], 0),
    row(['Identity', named ? 'Named responses' : 'Randomised IDs. Names, emails, account IDs and exact submission times omitted.'], 1, 42),
    row(['Written answers', data.includeWritten ? 'Included. Comments may identify people.' : 'Excluded from raw responses.'], 0),
    row(['Submitted / eligible', `${data.people.length} / ${data.eligible}`], 1),
    row(['Reading the data', 'Responses contains raw values. Questions explains each code, scale and options. Multiple selections are stored as JSON arrays.'], 0, 56),
    row(['Calculations', 'Submitted answers only. Skipped answers are excluded from averages. Agree % combines scores 4 and 5 on agreement questions only.'], 1, 56),
    header(['Code', 'Question', 'Answered', 'Skipped', 'Mean', 'Median', 'Scale max', 'Agree %']),
    ...data.summary.map((s, i) => row([s.code, exportText(s.prompt), s.answered, s.skipped, s.mean == null ? null : Number(s.mean.toFixed(4)), s.median,
      s.question.type === 'agreement' ? 5 : s.question.type === 'rating' ? s.question.scale_max! : null,
      s.favourable == null ? null : Number(s.favourable.toFixed(4))], i, Math.max(32, Math.ceil(s.prompt.length / 70) * 15))),
  ]
  return writeExcelFile([
    { sheet: 'Summary', data: summary, columns: [{ width: 24 }, { width: 80 }, ...Array.from({ length: 6 }, () => ({ width: 14 }))], showGridLines: false },
    { sheet: 'Responses', data: responses, columns: [{ width: 28 }, ...(named ? [{ width: 34 }, { width: 30 }] : []), ...data.questions.map(q => ({ width: q.type === 'text' ? 60 : q.type === 'multi_choice' ? 38 : 18 }))], stickyRowsCount: 1, stickyColumnsCount: 1, showGridLines: false, orientation: 'landscape' },
    { sheet: 'Questions', data: questions, columns: [{ width: 10 }, { width: 80 }, { width: 30 }, { width: 12 }, { width: 70 }], stickyRowsCount: 1, showGridLines: false },
  ], { fontFamily: 'Calibri', fontSize: 11 }).toBlob()
}
