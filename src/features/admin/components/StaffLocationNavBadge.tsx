/**
 * Compact O / T location pill used in Staff Admin nav and Weekly Payroll tables.
 * `letter` null keeps a fixed 16px slot so names align.
 */
export function StaffLocationNavBadge({ letter }: { letter: 'O' | 'T' | null }) {
  return (
    <span className="flex h-4 w-4 shrink-0 items-center justify-center">
      {letter === 'O' ? (
        <span
          className="inline-flex h-4 w-4 items-center justify-center rounded-full bg-violet-600 text-[9px] font-semibold leading-none text-white"
          title="Orewa"
          aria-label="Primary location: Orewa"
        >
          O
        </span>
      ) : letter === 'T' ? (
        <span
          className="inline-flex h-4 w-4 items-center justify-center rounded-full bg-sky-800 text-[9px] font-semibold leading-none text-sky-100"
          title="Takapuna"
          aria-label="Primary location: Takapuna"
        >
          T
        </span>
      ) : null}
    </span>
  )
}
