import { Link } from 'react-router-dom'

import { PageHeader } from '@/components/layout/PageHeader'
import { useAccessProfile } from '@/features/access/accessContext'
import { accessRoleDisplayLabel } from '@/features/admin/types/accessManagement'

export function AdminHomePage() {
  const { normalized } = useAccessProfile()

  const roleLabel = normalized?.accessRole
    ? accessRoleDisplayLabel(normalized.accessRole)
    : '—'

  return (
    <>
      <PageHeader
        title="Admin"
        description="Payroll and commission tools for managers and administrators."
      />

      <div className="mb-8 rounded-lg border border-slate-200 bg-white px-4 py-3 text-sm text-slate-700 shadow-sm">
        <span className="font-medium text-slate-900">Access role: </span>
        <span className="font-mono text-slate-800">{roleLabel}</span>
        {normalized?.hasElevatedAccess ? (
          <span className="ml-2 text-xs text-slate-500">(elevated)</span>
        ) : null}
      </div>

      <ul className="grid max-w-lg gap-3">
        <li>
          <Link
            to="/app/admin/access"
            className="block rounded-lg border border-slate-200 bg-white px-4 py-4 text-left shadow-sm transition hover:border-violet-200 hover:bg-violet-50/50"
          >
            <span className="font-semibold text-slate-900">
              Access management
            </span>
            <p className="mt-1 text-sm text-slate-600">
              Link Supabase users to staff members and manage roles (admin
              actions).
            </p>
          </Link>
        </li>
        <li>
          <Link
            to="/app/admin/import-sales-data"
            className="block rounded-lg border border-slate-200 bg-white px-4 py-4 text-left shadow-sm transition hover:border-violet-200 hover:bg-violet-50/50"
          >
            <span className="font-semibold text-slate-900">Imports</span>
            <p className="mt-1 text-sm text-slate-600">
              Upload Sales Daily Sheets CSV and refresh payroll data.
            </p>
          </Link>
        </li>
        <li>
          <Link
            to="/app/admin/sales-summary"
            className="block rounded-lg border border-slate-200 bg-white px-4 py-4 text-left shadow-sm transition hover:border-violet-200 hover:bg-violet-50/50"
          >
            <span className="font-semibold text-slate-900">
              Admin weekly payroll
            </span>
            <p className="mt-1 text-sm text-slate-600">
              Summary across all staff in scope — open a week for line detail.
            </p>
          </Link>
        </li>
        <li>
          <Link
            to="/app/admin/weekly-payroll"
            className="block rounded-lg border border-slate-200 bg-white px-4 py-4 text-left shadow-sm transition hover:border-violet-200 hover:bg-violet-50/50"
          >
            <span className="font-semibold text-slate-900">
              Weekly commission dashboard
            </span>
            <p className="mt-1 text-sm text-slate-600">
              Pay-week totals, sales by location, and staff breakdowns by category.
            </p>
          </Link>
        </li>
        <li>
          <Link
            to="/app/admin/remuneration"
            className="block rounded-lg border border-slate-200 bg-white px-4 py-4 text-left shadow-sm transition hover:border-violet-200 hover:bg-violet-50/50"
          >
            <span className="font-semibold text-slate-900">
              Remuneration configuration
            </span>
            <p className="mt-1 text-sm text-slate-600">
              Manage commission plans, category rates, and assistant rules used in payroll.
            </p>
          </Link>
        </li>
        <li>
          <Link
            to="/app/admin/staff"
            className="block rounded-lg border border-slate-200 bg-white px-4 py-4 text-left shadow-sm transition hover:border-violet-200 hover:bg-violet-50/50"
          >
            <span className="font-semibold text-slate-900">Staff configuration</span>
            <p className="mt-1 text-sm text-slate-600">
              Maintain staff master data, roles, and remuneration assignment.
            </p>
          </Link>
        </li>
        <li>
          <Link
            to="/app/admin/products"
            className="block rounded-lg border border-slate-200 bg-white px-4 py-4 text-left shadow-sm transition hover:border-violet-200 hover:bg-violet-50/50"
          >
            <span className="font-semibold text-slate-900">Product configuration</span>
            <p className="mt-1 text-sm text-slate-600">
              Classify imported product lines for commission rates and reporting.
            </p>
          </Link>
        </li>
        <li>
          <Link
            to="/app/admin/quotes"
            className="block rounded-lg border border-slate-200 bg-white px-4 py-4 text-left shadow-sm transition hover:border-violet-200 hover:bg-violet-50/50"
          >
            <span className="font-semibold text-slate-900">Quote Configuration</span>
            <p className="mt-1 text-sm text-slate-600">
              Manage the Guest Quote page — global settings, sections, and services.
            </p>
          </Link>
        </li>
        <li>
          <Link
            to="/app/my-sales"
            className="block rounded-lg border border-slate-200 bg-white px-4 py-4 text-left shadow-sm transition hover:border-slate-300 hover:bg-slate-50"
          >
            <span className="font-semibold text-slate-900">My sales</span>
            <p className="mt-1 text-sm text-slate-600">
              Your own weekly commission summary and lines (stylist view).
            </p>
          </Link>
        </li>
      </ul>
    </>
  )
}
