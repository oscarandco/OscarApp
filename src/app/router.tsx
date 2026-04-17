import { Navigate, Route, Routes } from 'react-router-dom'

import { AuthenticatedLayout } from '@/app/AuthenticatedLayout'
import { RequireAdminAccess } from '@/components/auth/RequireAdminAccess'
import { RequireAuth } from '@/components/auth/RequireAuth'
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
import { PayrollSummaryPage } from '@/features/payroll/pages/PayrollSummaryPage'
import { PayrollWeekDetailPage } from '@/features/payroll/pages/PayrollWeekDetailPage'
import { NotFoundPage } from '@/pages/NotFoundPage'

export function AppRouter() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      <Route element={<RequireAuth />}>
        <Route path="/app" element={<AuthenticatedLayout />}>
          <Route index element={<Navigate to="/app/payroll" replace />} />
          <Route path="payroll" element={<PayrollSummaryPage />} />
          <Route
            path="payroll/:payWeekStart"
            element={<PayrollWeekDetailPage />}
          />
          <Route element={<RequireAdminAccess />}>
            <Route path="admin" element={<AdminHomePage />} />
            <Route
              path="admin/access"
              element={<AdminAccessManagementPage />}
            />
            <Route path="admin/imports" element={<AdminImportsPage />} />
            <Route path="admin/payroll" element={<AdminPayrollSummaryPage />} />
            <Route
              path="admin/weekly-commission"
              element={<AdminWeeklyCommissionDashboardPage />}
            />
            <Route
              path="admin/remuneration"
              element={<RemunerationConfigurationPage />}
            />
            <Route
              path="admin/staff"
              element={<StaffConfigurationPage />}
            />
            <Route
              path="admin/products"
              element={<ProductConfigurationPage />}
            />
            <Route
              path="admin/payroll/:payWeekStart"
              element={<AdminPayrollDetailPage />}
            />
            <Route
              path="admin/quotes"
              element={<AdminQuoteConfigurationPage />}
            />
            <Route
              path="admin/quotes/sections/:sectionId"
              element={<AdminQuoteSectionDetailPage />}
            />
          </Route>
        </Route>
      </Route>
      <Route path="/" element={<Navigate to="/app/payroll" replace />} />
      <Route path="*" element={<NotFoundPage />} />
    </Routes>
  )
}
