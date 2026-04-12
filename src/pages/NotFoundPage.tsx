import { Link } from 'react-router-dom'

export function NotFoundPage() {
  return (
    <div className="flex min-h-dvh flex-col items-center justify-center bg-slate-50 px-4">
      <h1 className="text-2xl font-semibold text-slate-900">Page not found</h1>
      <p className="mt-2 text-sm text-slate-600">
        That route does not exist in this app.
      </p>
      <Link
        to="/app/payroll"
        className="mt-6 text-sm font-medium text-violet-700 hover:text-violet-900"
      >
        Go to payroll home
      </Link>
    </div>
  )
}
