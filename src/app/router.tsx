import { Navigate, Route, Routes, useParams } from 'react-router-dom'

import { AuthenticatedLayout } from '@/app/AuthenticatedLayout'
import { RequireAdminAccess } from '@/components/auth/RequireAdminAccess'
import { RequireAuth } from '@/components/auth/RequireAuth'
import { RequirePageAccess } from '@/components/auth/RequirePageAccess'
import { AdminAccessManagementPage } from '@/features/admin/pages/AdminAccessManagementPage'
import { AdminHomePage } from '@/features/admin/pages/AdminHomePage'
import { AdminImportsPage } from '@/features/admin/pages/AdminImportsPage'
import { AdminPayrollDetailPage } from '@/features/admin/pages/AdminPayrollDetailPage'
import { AdminPayrollSummaryPage } from '@/features/admin/pages/AdminPayrollSummaryPage'
import { AdminQuoteConfigurationPage } from '@/features/admin/pages/AdminQuoteConfigurationPage'
import { AdminQuoteSectionDetailPage } from '@/features/admin/pages/AdminQuoteSectionDetailPage'
import { AdminWeeklyCommissionDashboardPage } from '@/features/admin/pages/AdminWeeklyCommissionDashboardPage'
import { ProductConfigurationPage } from '@/features/admin/pages/ProductConfigurationPage'
import { RemunerationConfigurationPage } from '@/features/admin/pages/RemunerationConfigurationPage'
import { StaffConfigurationPage } from '@/features/admin/pages/StaffConfigurationPage'
import { HomeRoute } from '@/features/auth/pages/HomeRoute'
import { LoginPage } from '@/features/auth/pages/LoginPage'
import { ResetPasswordPage } from '@/features/auth/pages/ResetPasswordPage'
import { PayrollSummaryPage } from '@/features/payroll/pages/PayrollSummaryPage'
import { PayrollWeekDetailPage } from '@/features/payroll/pages/PayrollWeekDetailPage'
import { KpiDashboardPage } from '@/features/kpi/pages/KpiDashboardPage'
import { GuestQuotePage } from '@/features/quote/pages/GuestQuotePage'
import { SavedQuoteDetailPage } from '@/features/quote/pages/SavedQuoteDetailPage'
import { SavedQuotesPage } from '@/features/quote/pages/SavedQuotesPage'
import { NotFoundPage } from '@/pages/NotFoundPage'

/**
 * Redirects a legacy detail URL (e.g. `/app/payroll/:payWeekStart`) to
 * its new location while preserving the dynamic segment. Keeps old
 * bookmarks and shared links working without flashing a 404.
 */
function LegacyParamRedirect({
  to,
  paramName,
}: {
  to: (value: string) => string
  paramName: string
}) {
  const params = useParams()
  const value = params[paramName]
  if (!value) {
    return <Navigate to="/app/my-sales" replace />
  }
  return <Navigate to={to(value)} replace />
}

export function AppRouter() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      <Route path="/reset-password" element={<ResetPasswordPage />} />
      <Route path="/setup-account" element={<ResetPasswordPage />} />
      <Route element={<RequireAuth />}>
        <Route path="/app" element={<AuthenticatedLayout />}>
          {/* Default landing inside `/app` — Guest Quote is the page
              stylists use most often, so we send everyone there by
              default after login. Direct deep-links to other pages
              still resolve normally. */}
          <Route index element={<Navigate to="/app/guest-quote" replace />} />

          {/* Shared pages — every authenticated role may view. */}
          <Route path="my-sales" element={<PayrollSummaryPage />} />
          <Route
            path="my-sales/:payWeekStart"
            element={<PayrollWeekDetailPage />}
          />
          <Route path="guest-quote" element={<GuestQuotePage />} />
          <Route path="previous-quotes" element={<SavedQuotesPage />} />
          <Route
            path="previous-quotes/:quoteId"
            element={<SavedQuoteDetailPage />}
          />
          <Route
            path="kpis"
            element={
              <RequirePageAccess pageId="kpi_dashboard">
                <KpiDashboardPage />
              </RequirePageAccess>
            }
          />

          {/*
            Admin index / home. Kept under the legacy elevated gate
            (manager + admin) because TopNav still links to `/app/admin`
            as a dashboard shortcut and the page is not in the per-page
            access matrix.
          */}
          <Route element={<RequireAdminAccess />}>
            <Route path="admin" element={<AdminHomePage />} />
          </Route>

          {/* Admin-only pages. */}
          <Route
            path="admin/sales-summary"
            element={
              <RequirePageAccess pageId="commission_breakdown">
                <AdminPayrollSummaryPage />
              </RequirePageAccess>
            }
          />
          <Route
            path="admin/sales-summary/:payWeekStart"
            element={
              <RequirePageAccess pageId="commission_breakdown">
                <AdminPayrollDetailPage />
              </RequirePageAccess>
            }
          />
          <Route
            path="admin/weekly-payroll"
            element={
              <RequirePageAccess pageId="weekly_payroll">
                <AdminWeeklyCommissionDashboardPage />
              </RequirePageAccess>
            }
          />
          <Route
            path="admin/remuneration"
            element={
              <RequirePageAccess pageId="remuneration">
                <RemunerationConfigurationPage />
              </RequirePageAccess>
            }
          />
          <Route
            path="admin/staff"
            element={
              <RequirePageAccess pageId="staff">
                <StaffConfigurationPage />
              </RequirePageAccess>
            }
          />
          <Route
            path="admin/products"
            element={
              <RequirePageAccess pageId="products">
                <ProductConfigurationPage />
              </RequirePageAccess>
            }
          />
          <Route
            path="admin/quotes"
            element={
              <RequirePageAccess pageId="quotes">
                <AdminQuoteConfigurationPage />
              </RequirePageAccess>
            }
          />
          <Route
            path="admin/quotes/sections/:sectionId"
            element={
              <RequirePageAccess pageId="quotes">
                <AdminQuoteSectionDetailPage />
              </RequirePageAccess>
            }
          />

          {/* Manager + admin. */}
          <Route
            path="admin/import-sales-data"
            element={
              <RequirePageAccess pageId="imports">
                <AdminImportsPage />
              </RequirePageAccess>
            }
          />

          {/*
            Access page — admin: full; manager: view-only (write actions
            are already gated inside the page via
            canManageStaffAccessMappings); everyone else: none.
          */}
          <Route
            path="admin/access"
            element={
              <RequirePageAccess pageId="access">
                <AdminAccessManagementPage />
              </RequirePageAccess>
            }
          />

          {/*
            Legacy URL redirects. Keeps existing bookmarks, shared
            links, and any email deep-links working against the new
            paths. These sit inside `/app` so they still require auth.
          */}
          <Route
            path="payroll"
            element={<Navigate to="/app/my-sales" replace />}
          />
          <Route
            path="payroll/:payWeekStart"
            element={
              <LegacyParamRedirect
                paramName="payWeekStart"
                to={(v) => `/app/my-sales/${v}`}
              />
            }
          />
          <Route
            path="quote"
            element={<Navigate to="/app/guest-quote" replace />}
          />
          <Route
            path="quotes"
            element={<Navigate to="/app/previous-quotes" replace />}
          />
          <Route
            path="quotes/:quoteId"
            element={
              <LegacyParamRedirect
                paramName="quoteId"
                to={(v) => `/app/previous-quotes/${v}`}
              />
            }
          />
          <Route
            path="admin/payroll"
            element={<Navigate to="/app/admin/sales-summary" replace />}
          />
          <Route
            path="admin/payroll/:payWeekStart"
            element={
              <LegacyParamRedirect
                paramName="payWeekStart"
                to={(v) => `/app/admin/sales-summary/${v}`}
              />
            }
          />
          <Route
            path="admin/weekly-commission"
            element={<Navigate to="/app/admin/weekly-payroll" replace />}
          />
          <Route
            path="admin/imports"
            element={<Navigate to="/app/admin/import-sales-data" replace />}
          />
        </Route>
      </Route>
      <Route path="/" element={<HomeRoute />} />
      <Route path="*" element={<NotFoundPage />} />
    </Routes>
  )
}
