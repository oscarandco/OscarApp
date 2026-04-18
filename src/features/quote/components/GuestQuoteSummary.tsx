/**
 * Bottom-of-page summary table for the stylist Guest Quote page.
 *
 * Visual intent: a plain bordered table that reads like a receipt —
 * grouped subtotals, Green Fee as its own row, and a bolded Total at
 * the bottom. Grouping and green-fee-always rule come from
 * `buildQuoteSummary`; this component is presentation only.
 */
import type { QuoteSummary } from '@/features/quote/lib/quoteCalculations'
import { formatNzd } from '@/lib/formatters'

type Props = {
  summary: QuoteSummary
}

export function GuestQuoteSummary({ summary }: Props) {
  return (
    <div
      className="mt-6 overflow-hidden rounded border border-slate-200 bg-white text-[13px]"
      data-testid="guest-quote-summary"
      role="region"
      aria-label="Quote summary"
    >
      <table className="w-full">
        <tbody>
          {summary.groups.length === 0 ? (
            <tr>
              <td
                className="px-3 py-1.5 text-slate-500"
                colSpan={2}
                data-testid="guest-quote-summary-empty"
              >
                No services selected yet.
              </td>
            </tr>
          ) : (
            summary.groups.map((group) => (
              <tr
                key={group.key}
                className="border-b border-slate-100"
                data-testid={`guest-quote-summary-row-${group.key}`}
              >
                <td className="px-3 py-1 font-medium text-slate-700">
                  {group.label}
                </td>
                <td className="w-24 px-3 py-1 text-right tabular-nums text-slate-800">
                  {formatNzd(group.subtotal)}
                </td>
              </tr>
            ))
          )}
          <tr
            className="border-b border-slate-100"
            data-testid="guest-quote-summary-green-fee"
          >
            <td className="px-3 py-1 font-medium text-slate-700">
              Green Fee
            </td>
            <td className="w-24 px-3 py-1 text-right tabular-nums text-slate-800">
              {formatNzd(summary.greenFee)}
            </td>
          </tr>
          <tr
            className="bg-slate-50"
            data-testid="guest-quote-summary-total"
          >
            <td className="px-3 py-1.5 text-right text-[12px] font-semibold uppercase tracking-wide text-slate-600">
              Total
            </td>
            <td className="w-24 px-3 py-1.5 text-right text-[14px] font-semibold tabular-nums text-emerald-600">
              {formatNzd(summary.grandTotal)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  )
}
