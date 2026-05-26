import logoUrl from '@/assets/logo.png'
import {
  type ContractorInvoiceHeader,
  type ContractorInvoiceLine,
  invoiceHasMultipleLocations,
} from '@/features/admin/types/contractorInvoice'
import {
  formatCommissionRateNearestHalfPercent,
  formatInvoiceLineDate,
  formatNzd,
  formatShortDate,
} from '@/lib/formatters'

type SourceInvoiceClick = {
  invoice: string
  locationId: string | null
  saleDate: string | null
}

type Props = {
  header: ContractorInvoiceHeader
  lines: ContractorInvoiceLine[]
  replacesInvoiceNumber: string | null
  replacedByInvoiceNumber: string | null
  /**
   * Optional click handler for the source invoice number in the lines
   * table. When supplied, each invoice number renders as a button that
   * looks **visually identical** to plain text (no colour change, no
   * underline, no bold) but invokes the handler with the line's
   * (invoice, location_id, sale_date) tuple. Used by the saved-invoice
   * detail page to open the KPI InvoiceDetailModal in-place. Print and
   * static rendering are unaffected.
   */
  onOpenInvoice?: (ref: SourceInvoiceClick) => void
}

/**
 * Button reset used to make the source invoice number clickable while
 * keeping it visually identical to surrounding plain text — no colour
 * shift, no underline, no font-weight change, no border, no padding.
 * `font: inherit` and `letter-spacing: inherit` ensure the button picks
 * up the exact typography of the containing cell.
 */
const PLAIN_TEXT_BTN_CLASS =
  'cursor-pointer border-0 bg-transparent p-0 m-0 text-inherit ' +
  '[font:inherit] [letter-spacing:inherit]'

const NON_GST_ACK =
  'GST Status and Responsibility Acknowledgement: The contractor providing services, as ' +
  'identified in this invoice, is not registered for Goods and Services Tax (GST) in New Zealand. ' +
  'Accordingly, no GST has been charged on the services provided. The contractor acknowledges ' +
  'their responsibility to monitor their income and will advise Corsa Wilde Limited immediately ' +
  'should their GST registration status change, necessitating adjustments to future invoicing ' +
  'and GST collection on services rendered.'

function joinAddressLines(parts: Array<string | null | undefined>): string[] {
  return parts.map((p) => (p ?? '').trim()).filter((p) => p !== '')
}

function formatGeneratedAt(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return iso
  const date = d.toLocaleDateString('en-NZ', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
  })
  const time = d.toLocaleTimeString('en-NZ', {
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  })
  return `${date} at ${time}`
}

function buyerBlock(header: ContractorInvoiceHeader): string[] {
  // Display-only block. Email is intentionally omitted from the printed
  // invoice to keep the BILL TO column compact; the underlying snapshot
  // values (buyer_email, buyer_phone, buyer_nzbn) remain on the row.
  const lines: string[] = []
  lines.push(header.buyer_legal_business_name)
  if (header.buyer_trading_name && header.buyer_trading_name.trim() !== '') {
    lines.push(`Trading as ${header.buyer_trading_name.trim()}`)
  }
  lines.push(
    ...joinAddressLines([
      header.buyer_street_address,
      header.buyer_suburb,
      header.buyer_city_postcode,
    ]),
  )
  if (header.buyer_gst_number && header.buyer_gst_number.trim() !== '') {
    lines.push(`GST No. ${header.buyer_gst_number.trim()}`)
  }
  return lines
}

function contractorBlock(header: ContractorInvoiceHeader): string[] {
  // Display-only block. Contractor email is intentionally omitted from
  // the printed invoice (still snapshotted on the row for the
  // "Email to staff member" helper on the detail page).
  const out: string[] = []
  const company = (header.contractor_company_name ?? '').trim()
  const fullName = (header.contractor_full_name ?? '').trim()
  if (company !== '') {
    out.push(company)
    if (fullName !== '') out.push(fullName)
  } else if (fullName !== '') {
    out.push(fullName)
  }
  out.push(
    ...joinAddressLines([
      header.contractor_street_address,
      header.contractor_suburb,
      header.contractor_city_postcode,
    ]),
  )
  if (header.contractor_gst_registered) {
    const gst = (header.contractor_gst_number_display_value ?? '').trim()
    if (gst !== '') out.push(`GST No. ${gst}`)
  } else {
    out.push('Not GST Registered')
  }
  return out
}

/**
 * BCTI-style invoice rendering for the saved-invoice detail page and the
 * print/PDF output. Layout:
 *
 *   [O&C icon]                                 BUYER CREATED TAX INVOICE
 *   ────────────────────────────────────────────────────────────────────
 *   SUPPLIER     Company / Full name           BILL TO      Buyer legal name
 *                Address                                    Address
 *                GST status                                 GST No.
 *
 *   INVOICE NO.  {invoice_number}              PAY WEEK     {pay_week range}
 *   INVOICE DATE {invoice_date}                GST STATUS   {gst status}
 *
 *   ┌ Description ────────────────────────── Invoiced (ex GST) │ Commission │ Amount ┐
 *   │ Tue, 12 May – INV96149 – Debi Rowan        $250.00          35%        $87.50 │
 *   │  … one row per Kitomba client invoice …                                       │
 *   └──────────────────────────────────────────────────────────────────────────────┘
 *                                                Subtotal …
 *                                                GST 15% / 0%
 *                                                TOTAL
 *
 *   [non-GST acknowledgement if not registered]
 *   [small footer with generation timestamp]
 *
 * The card is intentionally LEFT-aligned with the surrounding page content
 * (no `mx-auto`) so it sits flush with the page header. `@media print`
 * strips the page chrome (set via `.print-hide` on the parent page) and
 * removes our screen border/shadow so the print/PDF matches a clean A4 page.
 */
export function ContractorInvoicePrintView({
  header,
  lines,
  replacesInvoiceNumber,
  replacedByInvoiceNumber,
  onOpenInvoice,
}: Props) {
  const showLocationColumn = invoiceHasMultipleLocations(lines)
  const isVoided = header.status === 'voided'
  const buyer = buyerBlock(header)
  const contractor = contractorBlock(header)
  const gstPctLabel = header.contractor_gst_registered ? '15%' : '0%'

  return (
    <>
      <style>{`
        @media print {
          /*
            Compact A4 page margins for the printed invoice / saved PDF.
            Top/bottom kept small (8mm) to claw back vertical whitespace
            so more invoice lines fit per page; left/right held at 10mm
            so nothing gets clipped by the browser's print engine and so
            the table doesn't crowd the paper edge. If the browser's
            native "Headers and footers" option is enabled in the print
            dialog the engine will still reserve room for URL / page #
            inside these margins, which can squeeze the content — turn
            that off in the print dialog for the cleanest output.
          */
          @page { size: A4; margin: 8mm 10mm; }
          html, body { background: #fff !important; }
          .print-hide { display: none !important; }
          .print-area {
            box-shadow: none !important;
            border: 0 !important;
            padding: 0 !important;
            max-width: none !important;
            margin: 0 !important;
            color: #000 !important;
          }
          .print-area * {
            color: inherit;
          }
          /* Soften the slate ink down to pure-print friendly contrast. */
          .ink-muted { color: #444 !important; }
        }
      `}</style>

      <article
        className="print-area max-w-4xl rounded-lg border border-slate-200 bg-white px-8 py-8 text-[12.5px] leading-relaxed text-slate-900 shadow-sm sm:px-10"
        data-testid="contractor-invoice-print-view"
      >
        {isVoided ? (
          <div className="mb-5 rounded-md border-2 border-rose-300 bg-rose-50 px-3 py-2 text-center">
            <p className="text-lg font-bold uppercase tracking-[0.2em] text-rose-700">
              VOIDED
            </p>
            {header.voided_at ? (
              <p className="text-[11px] text-rose-800">
                Voided on {formatShortDate(header.voided_at)}
                {header.void_reason ? ` — ${header.void_reason}` : ''}
                {replacedByInvoiceNumber
                  ? ` · Replaced by ${replacedByInvoiceNumber}`
                  : ''}
              </p>
            ) : null}
          </div>
        ) : null}

        {/*
          Header band — intentionally minimal: the same Oscar & Co
          wordmark used by the app TopNav / SideNav (`@/assets/logo.png`
          at `h-6 w-auto`) on the left, single-line `Buyer Created Tax
          Invoice` on the right. No divider beneath — the layout reads
          cleanly into the Supplier / Bill To section directly below.
        */}
        <header className="flex items-center justify-between gap-6">
          <img
            src={logoUrl}
            alt=""
            aria-hidden="true"
            className="h-6 w-auto shrink-0 select-none"
          />
          <p className="text-right text-[12px] font-semibold uppercase tracking-[0.22em] text-slate-700">
            Buyer Created Tax Invoice
          </p>
        </header>

        {/*
          Top content row: Supplier (contractor) on the LEFT, Bill To
          (buyer) on the RIGHT. Inside each column the label sits on the
          same horizontal line as the first detail line (Company / Buyer
          legal name) using a 2-col grid `[label_col | values_col]`. The
          label column width (`LABEL_COL`) is shared with the Invoice
          Details grid below so the value columns line up vertically
          across both sections — Supplier values align with Invoice No.
          values on the left, Bill To values align with Pay Week values
          on the right. `pt-0.5` on the label nudges its smaller-cap text
          down so the baseline reads naturally with the larger first
          value line.
        */}
        <section className="mt-6 grid grid-cols-1 gap-8 sm:grid-cols-2">
          <div className="grid grid-cols-[6.5rem_1fr] items-start gap-x-6">
            <p className="ink-muted pt-0.5 text-[10px] font-semibold uppercase tracking-[0.18em] text-slate-500">
              Supplier
            </p>
            <div className="space-y-0.5">
              {contractor.map((line, i) => (
                <p
                  key={i}
                  className={i === 0 ? 'font-semibold text-slate-900' : ''}
                >
                  {line}
                </p>
              ))}
            </div>
          </div>
          <div className="grid grid-cols-[6.5rem_1fr] items-start gap-x-6">
            <p className="ink-muted pt-0.5 text-[10px] font-semibold uppercase tracking-[0.18em] text-slate-500">
              Bill To
            </p>
            <div className="space-y-0.5">
              {buyer.map((line, i) => (
                <p
                  key={i}
                  className={i === 0 ? 'font-semibold text-slate-900' : ''}
                >
                  {line}
                </p>
              ))}
            </div>
          </div>
        </section>

        {/*
          Invoice details — mirrors the Supplier / Bill To structure
          exactly: outer 2-col grid (left half | right half) with the
          same `gap-8` gutter, and each half is a `[6.5rem | 1fr]` dl
          grid with `gap-x-6`. Sharing label-column width and gap with
          the section above means the value columns line up vertically
          across both sections.

          Pairing:
            LEFT  →  INVOICE NO.   under SUPPLIER
                     INVOICE DATE
            RIGHT →  PAY WEEK      under BILL TO
                     GST STATUS

          Labels use the same uppercase / 10px / tracked-0.18em / muted
          style as SUPPLIER / BILL TO so the visual rhythm is consistent.
        */}
        <section className="mt-5 grid grid-cols-1 gap-8 sm:grid-cols-2">
          <dl className="grid grid-cols-[6.5rem_1fr] items-start gap-x-6 gap-y-1">
            <dt className="ink-muted pt-0.5 text-[10px] font-semibold uppercase tracking-[0.18em] text-slate-500">
              Invoice No.
            </dt>
            <dd className="font-semibold text-slate-900">
              {header.invoice_number}
            </dd>
            <dt className="ink-muted pt-0.5 text-[10px] font-semibold uppercase tracking-[0.18em] text-slate-500">
              Invoice Date
            </dt>
            <dd className="text-slate-900">
              {formatShortDate(header.invoice_date)}
            </dd>
          </dl>
          <dl className="grid grid-cols-[6.5rem_1fr] items-start gap-x-6 gap-y-1">
            <dt className="ink-muted pt-0.5 text-[10px] font-semibold uppercase tracking-[0.18em] text-slate-500">
              Pay Week
            </dt>
            <dd className="text-slate-900">
              {formatShortDate(header.pay_week_start)} –{' '}
              {formatShortDate(header.pay_week_end)}
            </dd>
            <dt className="ink-muted pt-0.5 text-[10px] font-semibold uppercase tracking-[0.18em] text-slate-500">
              GST Status
            </dt>
            <dd className="text-slate-900">
              {header.contractor_gst_registered
                ? 'GST registered (15%)'
                : 'Not GST registered'}
            </dd>
          </dl>
        </section>

        {replacesInvoiceNumber ? (
          <p className="ink-muted mt-4 text-[11px] text-slate-500">
            Replaces:{' '}
            <span className="font-medium text-slate-700">
              {replacesInvoiceNumber}
            </span>
          </p>
        ) : null}

        {/* Lines table */}
        <section className="mt-6">
          <table className="w-full table-auto border-collapse text-[11.5px]">
            <thead>
              <tr className="border-b border-slate-300 text-[10px] font-semibold uppercase tracking-[0.12em] text-slate-600">
                <th className="py-1.5 pr-3 text-left">Description</th>
                {showLocationColumn ? (
                  <th className="whitespace-nowrap py-1.5 pr-3 text-left">
                    Loc
                  </th>
                ) : null}
                <th className="whitespace-nowrap py-1.5 pr-3 text-right">
                  Invoiced to Guest (Ex. GST)
                </th>
                <th className="whitespace-nowrap py-1.5 pr-3 text-center">
                  Commission
                </th>
                <th className="whitespace-nowrap py-1.5 text-right">Amount</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {lines.map((l) => {
                const datePart = formatInvoiceLineDate(l.sale_date)
                const invoicePart = l.source_invoice_number
                const clientPart = (l.customer_name ?? '').trim() || '—'
                const invoiceEl = onOpenInvoice ? (
                  <button
                    type="button"
                    className={PLAIN_TEXT_BTN_CLASS}
                    onClick={() =>
                      onOpenInvoice({
                        invoice: invoicePart,
                        locationId: l.location_id,
                        saleDate: l.sale_date,
                      })
                    }
                    aria-label={`View invoice detail for ${invoicePart}`}
                  >
                    {invoicePart}
                  </button>
                ) : (
                  invoicePart
                )
                return (
                  <tr key={l.id}>
                    <td className="py-1 pr-3 align-top">
                      {datePart} – {invoiceEl} – {clientPart}
                    </td>
                    {showLocationColumn ? (
                      <td className="whitespace-nowrap py-1 pr-3 align-top text-slate-600">
                        {l.location_name ?? '—'}
                      </td>
                    ) : null}
                    <td className="whitespace-nowrap py-1 pr-3 text-right align-top tabular-nums">
                      {formatNzd(l.client_invoice_amount_ex_gst)}
                    </td>
                    <td className="whitespace-nowrap py-1 pr-3 text-center align-top tabular-nums">
                      {formatCommissionRateNearestHalfPercent(
                        l.commission_percentage,
                      )}
                    </td>
                    <td className="whitespace-nowrap py-1 text-right align-top tabular-nums">
                      {formatNzd(l.contractor_amount_ex_gst)}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </section>

        {/* Totals — anchored lower-right */}
        <section className="mt-6 flex justify-end">
          <dl className="grid w-full max-w-[18rem] grid-cols-[auto_1fr] gap-x-6 gap-y-1 text-[12px]">
            <dt className="ink-muted text-[10px] font-semibold uppercase tracking-[0.18em] text-slate-500">
              Subtotal
            </dt>
            <dd className="text-right tabular-nums text-slate-900">
              {formatNzd(header.subtotal_ex_gst)}
            </dd>
            <dt className="ink-muted text-[10px] font-semibold uppercase tracking-[0.18em] text-slate-500">
              GST {gstPctLabel}
            </dt>
            <dd className="text-right tabular-nums text-slate-900">
              {formatNzd(header.gst_amount)}
            </dd>
            <dt className="mt-1 border-t border-slate-400 pt-2 text-[12px] font-semibold uppercase tracking-[0.18em] text-slate-900">
              Total
            </dt>
            <dd className="mt-1 border-t border-slate-400 pt-2 text-right text-[15px] font-bold tabular-nums text-slate-900">
              {formatNzd(header.total_inc_gst)}
            </dd>
          </dl>
        </section>

        {/*
          Non-GST acknowledgement — rendered as a centred footer note
          rather than a chunky warning panel. Widened to ~52rem (close to
          the article's inner content width) so the long IRD-style copy
          wraps to ~3 lines instead of 4 at normal invoice/print width.
          Font size kept at 10px for readability; vertical spacing tight
          so the footer sits close beneath it.
        */}
        {!header.contractor_gst_registered ? (
          <p className="ink-muted mx-auto mt-4 max-w-[52rem] text-center text-[10px] leading-snug text-slate-500">
            {NON_GST_ACK}
          </p>
        ) : null}

        {/*
          Subtle one-line footer — generation note left, calculation note
          right, anchored by `flex justify-between`. Right-side copy is
          slightly trimmed from the previous wording so both halves fit on
          a single row at A4/normal print width without forcing a wrap.
          Top margin and divider padding are tight to keep the overall
          footer height minimal. `flex-wrap` is intentionally retained as
          a defensive fall-back for very narrow viewports.
        */}
        <footer className="ink-muted mt-3 flex flex-wrap items-baseline justify-between gap-x-6 gap-y-0.5 border-t border-slate-200 pt-1.5 text-[9.5px] leading-snug text-slate-500">
          <p className="text-left">
            Generated by Oscar &amp; Co Staff App on{' '}
            {formatGeneratedAt(header.source_generated_at)}.
          </p>
          <p className="text-right">
            Amounts based on payroll data, staff status, commission rules,
            and GST status at time of generation.
          </p>
        </footer>
      </article>
    </>
  )
}
