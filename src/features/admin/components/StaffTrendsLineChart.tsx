import { useEffect, useMemo, useRef, useState } from 'react'

import { formatNzd } from '@/lib/formatters'

/**
 * One value series on the chart. `values` must be the same length as the
 * parent chart's `weekStarts` array; `null` represents a missing data
 * point and is drawn as a gap in the line. The series may represent any
 * dimension (staff member, metric, etc.); the chart only renders by
 * `label` / `color` and preserves the input order in legends and
 * tooltips.
 */
export type StaffTrendsSeries = {
  id: string
  label: string
  color: string
  /** values[i] aligns with weekStarts[i] supplied to the chart. */
  values: (number | null)[]
}

type Props = {
  weekStarts: string[]
  series: StaffTrendsSeries[]
  height?: number
  /** Y-axis label formatter. Defaults to NZD currency formatter. */
  formatY?: (n: number) => string
  /** Empty message rendered when no series have any non-null values. */
  emptyMessage?: string
  /**
   * Optional shared Y-axis maximum. When > 0 it overrides the per-chart
   * computed maximum. The chart still applies a "nice" rounding so the
   * tick labels stay tidy. Used by the page to lock multiple per-staff
   * charts to the same scale for visual comparison.
   */
  yMax?: number
}

const DEFAULT_HEIGHT = 280
const MARGIN = { top: 12, right: 16, bottom: 36, left: 64 }
const SIDE_PANEL_WIDTH_CLASS = 'sm:w-56'

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

function pickTickStarts(weekStarts: string[]): Set<number> {
  const n = weekStarts.length
  if (n === 0) return new Set()
  const target = 8
  const step = Math.max(1, Math.ceil(n / target))
  const out = new Set<number>()
  for (let i = 0; i < n; i += step) out.add(i)
  out.add(n - 1)
  return out
}

export function StaffTrendsLineChart({
  weekStarts,
  series,
  height = DEFAULT_HEIGHT,
  formatY,
  emptyMessage = 'No data for the selected staff in this period.',
  yMax: yMaxProp,
}: Props) {
  const wrapRef = useRef<HTMLDivElement | null>(null)
  const [width, setWidth] = useState(600)
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

  const dataMax = useMemo(() => {
    let m = 0
    for (const s of series) {
      for (const v of s.values) {
        if (v != null && v > m) m = v
      }
    }
    return m
  }, [series])

  const yMax = useMemo(() => {
    const candidate = yMaxProp && yMaxProp > 0 ? yMaxProp : dataMax
    return niceUpperBound(candidate)
  }, [yMaxProp, dataMax])

  const tickStartsIdx = useMemo(() => pickTickStarts(weekStarts), [weekStarts])

  const yTickCount = 5
  const yTicks = useMemo(() => {
    const ticks: number[] = []
    for (let i = 0; i <= yTickCount; i++) {
      ticks.push((yMax * i) / yTickCount)
    }
    return ticks
  }, [yMax])

  const plotW = Math.max(40, width - MARGIN.left - MARGIN.right)
  const plotH = Math.max(40, height - MARGIN.top - MARGIN.bottom)

  const n = weekStarts.length
  const xAt = (i: number) => {
    if (n <= 1) return MARGIN.left + plotW / 2
    return MARGIN.left + (i * plotW) / (n - 1)
  }
  const yAt = (v: number) => {
    if (yMax <= 0) return MARGIN.top + plotH
    return MARGIN.top + plotH - (v / yMax) * plotH
  }

  const hasAnyValue = series.some((s) => s.values.some((v) => v != null && v !== 0))

  function handleMove(e: React.MouseEvent<SVGSVGElement, MouseEvent>) {
    if (n === 0) return
    const rect = e.currentTarget.getBoundingClientRect()
    const xPx = e.clientX - rect.left
    if (n === 1) {
      setHoverIndex(0)
      return
    }
    const ratio = (xPx - MARGIN.left) / plotW
    let idx = Math.round(ratio * (n - 1))
    if (idx < 0) idx = 0
    if (idx > n - 1) idx = n - 1
    setHoverIndex(idx)
  }

  function handleLeave() {
    setHoverIndex(null)
  }

  function buildPath(values: (number | null)[]): string {
    let d = ''
    let pen = false
    for (let i = 0; i < values.length; i++) {
      const v = values[i]
      if (v == null) {
        pen = false
        continue
      }
      const x = xAt(i)
      const y = yAt(v)
      d += `${pen ? ' L' : 'M'}${x.toFixed(2)},${y.toFixed(2)}`
      pen = true
    }
    return d
  }

  const tooltipRows = useMemo(() => {
    if (hoverIndex == null || n === 0) return null
    const i = hoverIndex
    const rows = series.map((s) => ({
      id: s.id,
      name: s.label,
      color: s.color,
      value: s.values[i],
    }))
    return { i, weekIso: weekStarts[i], rows }
  }, [hoverIndex, n, series, weekStarts])

  return (
    <div className="flex w-full flex-col gap-3 sm:flex-row sm:gap-4">
      <div ref={wrapRef} className="min-w-0 flex-1">
        <svg
          role="img"
          aria-label="Line chart"
          width={width}
          height={height}
          onMouseMove={handleMove}
          onMouseLeave={handleLeave}
          className="block"
        >
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

          <line
            x1={MARGIN.left}
            x2={MARGIN.left + plotW}
            y1={MARGIN.top + plotH}
            y2={MARGIN.top + plotH}
            stroke="#cbd5e1"
            strokeWidth={1}
          />

          {weekStarts.map((iso, i) => {
            if (!tickStartsIdx.has(i)) return null
            const x = xAt(i)
            return (
              <text
                key={`x-${i}`}
                x={x}
                y={MARGIN.top + plotH + 16}
                textAnchor="middle"
                fontSize={10}
                fill="#64748b"
              >
                {formatWeekShort(iso)}
              </text>
            )
          })}

          {series.map((s) => (
            <path
              key={`line-${s.id}`}
              d={buildPath(s.values)}
              stroke={s.color}
              strokeWidth={2}
              fill="none"
              strokeLinejoin="round"
              strokeLinecap="round"
            />
          ))}

          {hoverIndex != null && n > 0 ? (
            <g>
              <line
                x1={xAt(hoverIndex)}
                x2={xAt(hoverIndex)}
                y1={MARGIN.top}
                y2={MARGIN.top + plotH}
                stroke="#94a3b8"
                strokeWidth={1}
                strokeDasharray="3,3"
              />
              {series.map((s) => {
                const v = s.values[hoverIndex]
                if (v == null) return null
                return (
                  <circle
                    key={`dot-${s.id}`}
                    cx={xAt(hoverIndex)}
                    cy={yAt(v)}
                    r={3.5}
                    fill={s.color}
                    stroke="white"
                    strokeWidth={1.5}
                  />
                )
              })}
            </g>
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

      <div
        className={`w-full shrink-0 rounded-md border border-slate-200 bg-slate-50/60 p-3 text-xs ${SIDE_PANEL_WIDTH_CLASS}`}
      >
        {tooltipRows ? (
          <>
            <div className="mb-2 font-semibold text-slate-700">
              Week beginning {formatWeekLong(tooltipRows.weekIso)}
            </div>
            <ul className="space-y-1">
              {tooltipRows.rows.map((r) => (
                <li key={r.id} className="flex items-start gap-2">
                  <span
                    aria-hidden
                    className="mt-1 inline-block h-2 w-2 shrink-0 rounded-full"
                    style={{ background: r.color }}
                  />
                  <div className="flex-1 min-w-0">
                    <div className="truncate text-slate-600">{r.name}</div>
                    <div className="tabular-nums font-medium text-slate-800">
                      {r.value == null ? 'No data' : yFormat(r.value)}
                    </div>
                  </div>
                </li>
              ))}
            </ul>
          </>
        ) : (
          <p className="text-slate-500">
            Hover the chart to see weekly values.
          </p>
        )}
      </div>
    </div>
  )
}
