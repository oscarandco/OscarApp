import { useEffect, useMemo, useRef, useState } from 'react'

import { formatNzd } from '@/lib/formatters'

/**
 * One staff member's contribution to a single week. The chart stacks
 * segments bottom-up in the order supplied (so the largest contributor
 * across the whole window should appear first to keep the bar visually
 * stable from week to week).
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

type Props = {
  weeks: StackedSalesWeek[]
  height?: number
  formatY?: (n: number) => string
  emptyMessage?: string
}

const DEFAULT_HEIGHT = 280
const MARGIN = { top: 12, right: 16, bottom: 36, left: 64 }
const BAR_GAP_PX = 2

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

function niceUpperBound(maxValue: number): number {
  if (maxValue <= 0) return 100
  const exp = Math.floor(Math.log10(maxValue))
  const base = Math.pow(10, exp)
  const norm = maxValue / base
  let nice: number
  if (norm <= 1) nice = 1
  else if (norm <= 2) nice = 2
  else if (norm <= 2.5) nice = 2.5
  else if (norm <= 5) nice = 5
  else nice = 10
  return nice * base
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
}: Props) {
  const wrapRef = useRef<HTMLDivElement | null>(null)
  const [width, setWidth] = useState(700)
  const [hoverIndex, setHoverIndex] = useState<number | null>(null)

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

  function handleMove(e: React.MouseEvent<SVGSVGElement, MouseEvent>) {
    if (n === 0) return
    const rect = e.currentTarget.getBoundingClientRect()
    const xPx = e.clientX - rect.left
    if (xPx < MARGIN.left || xPx > MARGIN.left + plotW) {
      setHoverIndex(null)
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

  return (
    <div className="flex w-full flex-col gap-3 sm:flex-row sm:gap-4">
      <div ref={wrapRef} className="min-w-0 flex-1">
      <svg
        role="img"
        aria-label="Stacked bar chart"
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

        {/* X tick labels */}
        {weeks.map((w, i) => {
          if (!tickIdx.has(i)) return null
          return (
            <text
              key={`x-${i}`}
              x={barCenter(i)}
              y={MARGIN.top + plotH + 16}
              textAnchor="middle"
              fontSize={10}
              fill="#64748b"
            >
              {formatWeekShort(w.weekStart)}
            </text>
          )
        })}

        {/* Bars: stack segments bottom-up in input order */}
        {weeks.map((w, i) => {
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
        })}

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

      <div className="w-full shrink-0 rounded-md border border-slate-200 bg-slate-50/60 p-3 text-xs sm:w-56">
        {tooltip ? (
          <>
            <div className="mb-2 font-semibold text-slate-700">
              Week beginning {formatWeekLong(tooltip.weekStart)}
            </div>
            <div className="mb-2 flex items-center justify-between gap-2 border-b border-slate-200 pb-2">
              <span className="text-slate-500">Total sales ex GST</span>
              <span className="tabular-nums font-semibold text-slate-800">
                {yFormat(tooltip.total)}
              </span>
            </div>
            {tooltip.rows.length === 0 ? (
              <p className="text-slate-500">No sales this week.</p>
            ) : (
              <ul className="max-h-72 space-y-0.5 overflow-y-auto pr-1">
                {tooltip.rows.map((r) => (
                  <li
                    key={r.staffId}
                    className="flex items-center gap-2"
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
              </ul>
            )}
          </>
        ) : (
          <p className="text-slate-500">
            Hover a bar to see the weekly total and staff breakdown.
          </p>
        )}
      </div>
    </div>
  )
}
