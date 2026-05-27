import { useEffect, useMemo, useRef, useState } from 'react'

import { formatNzd } from '@/lib/formatters'

/**
 * One staff member's contribution to a single week. The chart stacks
 * segments bottom-up in the order supplied (so the largest contributor
 * across the whole window should appear first to keep the stack
 * visually stable from week to week).
 */
export type StackedSalesSegment = {
  staffId: string
  staffName: string
  color: string
  value: number
}

export type StackedSalesWeek = {
  weekStart: string
  total: number
  segments: StackedSalesSegment[]
}

type Mode = 'bar' | 'area'

type Props = {
  weeks: StackedSalesWeek[]
  height?: number
  formatY?: (n: number) => string
  emptyMessage?: string
  /** Stacked bar (default) or stacked area. Same data, same scale. */
  mode?: Mode
}

const DEFAULT_HEIGHT = 280
const MARGIN = { top: 12, right: 16, bottom: 36, left: 64 }
const BAR_GAP_PX = 2

/** Row height assumed when computing how many breakdown rows fit. */
const PANEL_ROW_HEIGHT_PX = 17

function formatWeekShort(iso: string): string {
  const d = new Date(`${iso}T00:00:00Z`)
  if (Number.isNaN(d.getTime())) return iso
  return d.toLocaleDateString('en-NZ', {
    day: 'numeric',
    month: 'short',
    timeZone: 'UTC',
  })
}

function formatWeekLong(iso: string): string {
  const d = new Date(`${iso}T00:00:00Z`)
  if (Number.isNaN(d.getTime())) return iso
  return d.toLocaleDateString('en-NZ', {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    timeZone: 'UTC',
  })
}

/**
 * Round the chart's Y axis maximum up to the nearest $1,000.
 *
 * The all staff sales chart almost always shows values in the
 * thousands so rounding to nice powers-of-ten ($50k for $16k, etc.)
 * leaves a lot of empty headroom. Rounding to the next whole
 * thousand keeps the bars/area filling most of the plot area.
 *
 * Edge cases:
 *  - max <= 0: fall back to $1,000.
 *  - max already on a clean thousand: return that value verbatim.
 */
function niceUpperBound(maxValue: number): number {
  if (maxValue <= 0) return 1000
  return Math.ceil(maxValue / 1000) * 1000
}

function pickTickStarts(weeks: StackedSalesWeek[]): Set<number> {
  const n = weeks.length
  if (n === 0) return new Set()
  const target = 8
  const step = Math.max(1, Math.ceil(n / target))
  const out = new Set<number>()
  for (let i = 0; i < n; i += step) out.add(i)
  out.add(n - 1)
  return out
}

export function StaffTrendsStackedSalesChart({
  weeks,
  height = DEFAULT_HEIGHT,
  formatY,
  emptyMessage = 'No sales in this period.',
  mode = 'bar',
}: Props) {
  const wrapRef = useRef<HTMLDivElement | null>(null)
  const listRef = useRef<HTMLDivElement | null>(null)
  const [width, setWidth] = useState(700)
  const [hoverIndex, setHoverIndex] = useState<number | null>(null)
  const [listHeight, setListHeight] = useState<number>(0)

  useEffect(() => {
    const el = wrapRef.current
    if (!el) return
    const ro = new ResizeObserver((entries) => {
      for (const entry of entries) {
        const w = entry.contentRect.width
        if (w > 0) setWidth(Math.round(w))
      }
    })
    ro.observe(el)
    return () => ro.disconnect()
  }, [])

  useEffect(() => {
    const el = listRef.current
    if (!el) return
    const ro = new ResizeObserver((entries) => {
      for (const entry of entries) {
        const h = entry.contentRect.height
        if (h > 0) setListHeight(Math.round(h))
      }
    })
    ro.observe(el)
    return () => ro.disconnect()
  }, [])

  const yFormat = formatY ?? formatNzd

  const maxTotal = useMemo(() => {
    let m = 0
    for (const w of weeks) {
      if (w.total > m) m = w.total
    }
    return m
  }, [weeks])

  const yMax = useMemo(() => niceUpperBound(maxTotal), [maxTotal])

  const tickIdx = useMemo(() => pickTickStarts(weeks), [weeks])

  const plotW = Math.max(40, width - MARGIN.left - MARGIN.right)
  const plotH = Math.max(40, height - MARGIN.top - MARGIN.bottom)

  const n = weeks.length
  const barW =
    n === 0 ? 0 : Math.max(2, (plotW - (n - 1) * BAR_GAP_PX) / n)
  const barLeft = (i: number) => MARGIN.left + i * (barW + BAR_GAP_PX)
  const barCenter = (i: number) => barLeft(i) + barW / 2
  const xAreaAt = (i: number) =>
    n <= 1 ? MARGIN.left + plotW / 2 : MARGIN.left + (i * plotW) / (n - 1)
  const xAt = (i: number) => (mode === 'area' ? xAreaAt(i) : barCenter(i))
  const yAt = (v: number) => {
    if (yMax <= 0) return MARGIN.top + plotH
    return MARGIN.top + plotH - (v / yMax) * plotH
  }

  const yTickCount = 5
  const yTicks = useMemo(() => {
    const t: number[] = []
    for (let i = 0; i <= yTickCount; i++) t.push((yMax * i) / yTickCount)
    return t
  }, [yMax])

  /* ----------- area mode: build one polygon per staff in stack order */

  const areaPaths = useMemo(() => {
    if (mode !== 'area' || n === 0) return [] as { id: string; color: string; d: string }[]
    /* Collect staff metadata + per-week values (zero-padded). */
    const meta = new Map<string, { name: string; color: string }>()
    const totals = new Map<string, number>()
    const values = new Map<string, number[]>()
    for (let i = 0; i < n; i++) {
      for (const seg of weeks[i].segments) {
        if (!meta.has(seg.staffId)) {
          meta.set(seg.staffId, { name: seg.staffName, color: seg.color })
          values.set(seg.staffId, new Array(n).fill(0))
        }
      }
    }
    for (let i = 0; i < n; i++) {
      for (const seg of weeks[i].segments) {
        if (seg.value > 0) {
          values.get(seg.staffId)![i] = seg.value
          totals.set(seg.staffId, (totals.get(seg.staffId) ?? 0) + seg.value)
        }
      }
    }
    /* Biggest contributor goes at the bottom of the stack. */
    const stackOrder = [...totals.entries()]
      .sort((a, b) => b[1] - a[1])
      .map(([id]) => id)

    const cumulative = new Array(n).fill(0)
    const out: { id: string; color: string; d: string }[] = []
    for (const sid of stackOrder) {
      const m = meta.get(sid)!
      const vals = values.get(sid)!

      let d = ''
      for (let i = 0; i < n; i++) {
        const x = xAreaAt(i)
        const yTop = yAt(cumulative[i] + vals[i])
        d += `${i === 0 ? 'M' : ' L'}${x.toFixed(2)},${yTop.toFixed(2)}`
      }
      for (let i = n - 1; i >= 0; i--) {
        const x = xAreaAt(i)
        const yBot = yAt(cumulative[i])
        d += ` L${x.toFixed(2)},${yBot.toFixed(2)}`
      }
      d += ' Z'
      out.push({ id: sid, color: m.color, d })

      for (let i = 0; i < n; i++) cumulative[i] += vals[i]
    }
    return out
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mode, weeks, plotW, plotH, yMax])

  function handleMove(e: React.MouseEvent<SVGSVGElement, MouseEvent>) {
    if (n === 0) return
    const rect = e.currentTarget.getBoundingClientRect()
    const xPx = e.clientX - rect.left
    if (xPx < MARGIN.left || xPx > MARGIN.left + plotW) {
      setHoverIndex(null)
      return
    }
    if (mode === 'area') {
      const ratio = (xPx - MARGIN.left) / plotW
      let idx = Math.round(ratio * (n - 1))
      if (idx < 0) idx = 0
      if (idx > n - 1) idx = n - 1
      setHoverIndex(idx)
      return
    }
    const relX = xPx - MARGIN.left
    const slot = barW + BAR_GAP_PX
    let idx = Math.floor(relX / slot)
    if (idx < 0) idx = 0
    if (idx > n - 1) idx = n - 1
    setHoverIndex(idx)
  }

  function handleLeave() {
    setHoverIndex(null)
  }

  const hasAnyValue = maxTotal > 0

  const tooltip = useMemo(() => {
    if (hoverIndex == null || n === 0) return null
    const w = weeks[hoverIndex]
    const rows = w.segments
      .filter((s) => s.value > 0)
      .slice()
      .sort((a, b) => b.value - a.value)
    return { weekStart: w.weekStart, total: w.total, rows }
  }, [hoverIndex, n, weeks])

  /* Fit-aware row count: how many breakdown rows can the side panel
   * show without overflow. When more rows exist, the last visible row
   * becomes a "+ X more" indicator. */
  const visibleBreakdown = useMemo<{
    rows: StackedSalesSegment[]
    more: number
  }>(() => {
    if (!tooltip) return { rows: [], more: 0 }
    const all = tooltip.rows
    if (listHeight <= 0) return { rows: all, more: 0 }
    const capacity = Math.max(1, Math.floor(listHeight / PANEL_ROW_HEIGHT_PX))
    if (all.length <= capacity) return { rows: all, more: 0 }
    const visible = all.slice(0, Math.max(1, capacity - 1))
    return { rows: visible, more: all.length - visible.length }
  }, [tooltip, listHeight])

  return (
    <div className="flex w-full flex-col gap-3 sm:flex-row sm:items-stretch sm:gap-4">
      <div ref={wrapRef} className="min-w-0 flex-1">
        <svg
          role="img"
          aria-label={mode === 'area' ? 'Stacked area chart' : 'Stacked bar chart'}
          width={width}
          height={height}
          onMouseMove={handleMove}
          onMouseLeave={handleLeave}
          className="block"
        >
          {/* Y gridlines + labels */}
          {yTicks.map((t, idx) => {
            const y = yAt(t)
            return (
              <g key={`y-${idx}`}>
                <line
                  x1={MARGIN.left}
                  x2={MARGIN.left + plotW}
                  y1={y}
                  y2={y}
                  stroke="#e2e8f0"
                  strokeWidth={1}
                />
                <text
                  x={MARGIN.left - 8}
                  y={y}
                  textAnchor="end"
                  dominantBaseline="central"
                  fontSize={11}
                  fill="#64748b"
                >
                  {yFormat(t)}
                </text>
              </g>
            )
          })}

          {/* X axis baseline */}
          <line
            x1={MARGIN.left}
            x2={MARGIN.left + plotW}
            y1={MARGIN.top + plotH}
            y2={MARGIN.top + plotH}
            stroke="#cbd5e1"
            strokeWidth={1}
          />

          {/* X tick labels (positioned per mode for consistency with shapes) */}
          {weeks.map((w, i) => {
            if (!tickIdx.has(i)) return null
            return (
              <text
                key={`x-${i}`}
                x={xAt(i)}
                y={MARGIN.top + plotH + 16}
                textAnchor="middle"
                fontSize={10}
                fill="#64748b"
              >
                {formatWeekShort(w.weekStart)}
              </text>
            )
          })}

          {/* Stacked area: one filled polygon per staff in stack order */}
          {mode === 'area'
            ? areaPaths.map((p) => (
                <path
                  key={`area-${p.id}`}
                  d={p.d}
                  fill={p.color}
                  fillOpacity={0.85}
                  stroke="white"
                  strokeWidth={0.5}
                />
              ))
            : null}

          {/* Stacked bars: per-week segment rectangles */}
          {mode === 'bar'
            ? weeks.map((w, i) => {
                if (w.total <= 0) return null
                let cumulative = 0
                const x = barLeft(i)
                const isHover = hoverIndex === i
                return (
                  <g key={`bar-${i}`}>
                    {w.segments.map((seg) => {
                      if (seg.value <= 0) return null
                      const yBottom = yAt(cumulative)
                      cumulative += seg.value
                      const yTop = yAt(cumulative)
                      const segH = Math.max(0, yBottom - yTop)
                      return (
                        <rect
                          key={`seg-${i}-${seg.staffId}`}
                          x={x}
                          y={yTop}
                          width={barW}
                          height={segH}
                          fill={seg.color}
                          opacity={isHover ? 1 : 0.92}
                        >
                          <title>{`${seg.staffName}: ${yFormat(seg.value)}`}</title>
                        </rect>
                      )
                    })}
                    {isHover ? (
                      <rect
                        x={x - 0.5}
                        y={yAt(w.total) - 0.5}
                        width={barW + 1}
                        height={MARGIN.top + plotH - yAt(w.total) + 1}
                        fill="none"
                        stroke="#0f172a"
                        strokeWidth={1}
                        opacity={0.35}
                      />
                    ) : null}
                  </g>
                )
              })
            : null}

          {/* Area mode hover guide: dashed vertical line */}
          {mode === 'area' && hoverIndex != null && n > 0 ? (
            <line
              x1={xAreaAt(hoverIndex)}
              x2={xAreaAt(hoverIndex)}
              y1={MARGIN.top}
              y2={MARGIN.top + plotH}
              stroke="#0f172a"
              strokeWidth={1}
              strokeDasharray="3,3"
              opacity={0.4}
            />
          ) : null}

          {!hasAnyValue ? (
            <text
              x={MARGIN.left + plotW / 2}
              y={MARGIN.top + plotH / 2}
              textAnchor="middle"
              dominantBaseline="central"
              fontSize={12}
              fill="#94a3b8"
            >
              {emptyMessage}
            </text>
          ) : null}
        </svg>
      </div>

      {/* Right-side hover panel. Stretches full card height; fits as
       * many breakdown rows as the available height allows. */}
      <div
        className="flex w-full shrink-0 flex-col rounded-md border border-slate-200 bg-slate-50/60 px-3 py-2 text-xs sm:w-56"
        style={{ minHeight: height }}
      >
        {tooltip ? (
          <>
            <div className="font-semibold leading-tight text-slate-700">
              Week beginning {formatWeekLong(tooltip.weekStart)}
            </div>
            <div className="mt-1 flex items-center justify-between gap-2 leading-tight">
              <span className="text-slate-500">Total sales ex GST</span>
              <span className="tabular-nums font-semibold text-slate-800">
                {yFormat(tooltip.total)}
              </span>
            </div>
            <div
              ref={listRef}
              className="mt-1 min-h-0 flex-1 overflow-hidden"
            >
              {tooltip.rows.length === 0 ? (
                <p className="text-slate-500">No sales this week.</p>
              ) : (
                <ul>
                  {visibleBreakdown.rows.map((r) => (
                    <li
                      key={r.staffId}
                      className="flex items-center gap-2 leading-tight"
                      style={{ height: PANEL_ROW_HEIGHT_PX }}
                    >
                      <span
                        aria-hidden
                        className="inline-block h-2 w-2 shrink-0 rounded-full"
                        style={{ background: r.color }}
                      />
                      <span className="min-w-0 flex-1 truncate text-slate-600">
                        {r.staffName}
                      </span>
                      <span className="tabular-nums font-medium text-slate-800">
                        {yFormat(r.value)}
                      </span>
                    </li>
                  ))}
                  {visibleBreakdown.more > 0 ? (
                    <li
                      className="text-slate-400"
                      style={{ height: PANEL_ROW_HEIGHT_PX }}
                    >
                      + {visibleBreakdown.more} more
                    </li>
                  ) : null}
                </ul>
              )}
            </div>
          </>
        ) : (
          <p className="text-slate-500">
            Hover the chart to see the weekly total and staff breakdown.
          </p>
        )}
      </div>
    </div>
  )
}
