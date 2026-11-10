import { useEffect, useRef, type ReactNode } from 'react'

export function SurveyDialog({ title, children, onDismiss, wide = false }: { title: string; children: ReactNode; onDismiss: () => void; wide?: boolean }) {
  const ref = useRef<HTMLDialogElement>(null)
  useEffect(() => {
    const dialog = ref.current
    dialog?.showModal()
    return () => dialog?.close()
  }, [])
  return (
    <dialog ref={ref} aria-labelledby="survey-dialog-title" onCancel={event => { event.preventDefault(); onDismiss() }}
      className={`fixed inset-0 m-auto max-h-[90dvh] w-[calc(100%-1.5rem)] overflow-y-auto overscroll-contain rounded-2xl border border-slate-200 bg-white p-4 shadow-xl backdrop:bg-black/40 sm:p-6 ${wide ? 'max-w-3xl' : 'max-w-lg'}`}>
      <h2 id="survey-dialog-title" className="text-xl font-semibold text-slate-900">{title}</h2>
      {children}
    </dialog>
  )
}
