import { Navigate, Route, Routes } from 'react-router-dom'

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
import { LoginPage } from '@/features/auth/pages/LoginPage'
import { ResetPasswordPage } from '@/features/auth/pages/ResetPasswordPage'
import { PayrollSummaryPage } from '@/features/payroll/pages/PayrollSummaryPage'
import { PayrollWeekDetailPage } from '@/features/payroll/pages/PayrollWeekDetailPage'
import { GuestQuotePage } from '@/features/quote/pages/GuestQuotePage'
import { SavedQuoteDetailPage } from '@/features/quote/pages/SavedQuoteDetailPage'
import { SavedQuotesPage } from '@/features/quote/pages/SavedQuotesPage'
import { NotFoundPage } from '@/pages/NotFoundPage'

export function AppRouter() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      <Route path="/reset-password" element={<ResetPasswordPage />} />
      <Route element={<RequireAuth />}>
        <Route path="/app" element={<AuthenticatedLayout />}>
          <Route index element={<Navigate to="/app/payroll" replace />} />

          {/* Shared pages — every authenticated role may view. */}
          <Route path="payroll" element={<PayrollSummaryPage />} />
          <Route
            path="payroll/:payWeekStart"
            element={<PayrollWeekDetailPage />}
          />
          <Route path="quote" element={<GuestQuotePage />} />
          <Route path="quotes" element={<SavedQuotesPage />} />
          <Route path="quotes/:quoteId" element={<SavedQuoteDetailPage />} />

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
            path="admin/payroll"
            element={
              <RequirePageAccess pageId="commission_breakdown">
                <AdminPayrollSummaryPage />
              </RequirePageAccess>
            }
          />
          <Route
            path="admin/payroll/:payWeekStart"
            element={
              <RequirePageAccess pageId="commission_breakdown">
                <AdminPayrollDetailPage />
              </RequirePageAccess>
            }
          />
          <Route
            path="admin/weekly-commission"
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
            path="admin/imports"
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
        </Route>
      </Route>
      <Route path="/" element={<Navigate to="/app/payroll" replace />} />
      <Route path="*" element={<NotFoundPage />} />
    </Routes>
  )
}
