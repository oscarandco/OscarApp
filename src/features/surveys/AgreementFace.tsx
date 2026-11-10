const faceColours = ['text-rose-600', 'text-orange-600', 'text-slate-500', 'text-emerald-600', 'text-emerald-700']

export function AgreementFace({ value }: { value: number }) {
  const mouth = value === 1 ? 'M9 22 Q16 12 23 22' : value === 2 ? 'M10 21 Q16 16 22 21' : value === 3 ? 'M10 21 H22' : value === 4 ? 'M10 18 Q16 24 22 18' : 'M9 17 Q16 28 23 17 Z'
  return <svg viewBox="0 0 32 32" aria-hidden="true" className={`h-7 w-7 sm:h-8 sm:w-8 ${faceColours[value - 1]}`}>
    <circle cx="16" cy="16" r="14" fill="currentColor" opacity="0.09" />
    <circle cx="16" cy="16" r="13" fill="none" stroke="currentColor" strokeWidth="1.6" />
    <circle cx="11" cy="12" r="1.3" fill="currentColor" /><circle cx="21" cy="12" r="1.3" fill="currentColor" />
    <path d={mouth} fill={value === 5 ? 'currentColor' : 'none'} stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
  </svg>
}
