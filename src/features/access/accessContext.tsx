/* eslint-disable react-refresh/only-export-components -- context module co-locates provider and hooks */
import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  type ReactNode,
} from 'react'
import { useQuery } from '@tanstack/react-query'

import { normalizeAccessProfile } from '@/features/access/normalizeAccessProfile'
import {
  mergeRolePagePermissionRows,
  PAGE_ACCESS_MATRIX,
  type EffectivePageMatrix,
} from '@/features/access/pageAccessMatrix'
import type { AccessProfile, NormalizedAccess } from '@/features/access/types'
import { useAuth } from '@/features/auth/authContext'
import { rpcGetMyAccessProfile, rpcGetRolePagePermissions } from '@/lib/supabaseRpc'

/** High-level access resolution for bootstrap and UI. */
export type AccessBootstrapState =
  | 'loading'
  | 'error'
  | 'no_access'
  | 'inactive'
  | 'ready'

type AccessContextValue = {
  /** Raw RPC row; null when the user has no access row. */
  rawProfile: AccessProfile | null
  /** Present when the RPC returned a row (including inactive). */
  normalized: NormalizedAccess | null
  accessState: AccessBootstrapState
  /**
   * Effective matrix: DB-backed rows merged over `PAGE_ACCESS_MATRIX` when
   * `get_role_page_permissions` succeeds; otherwise the static defaults (no flicker).
   */
  effectivePageMatrix: EffectivePageMatrix
  isLoading: boolean
  isError: boolean
  error: Error | null
  refetch: () => void
}

const AccessContext = createContext<AccessContextValue | null>(null)

export function AccessProvider({ children }: { children: ReactNode }) {
  const { user } = useAuth()

  const query = useQuery({
    queryKey: ['access-profile', user?.id],
    queryFn: () => rpcGetMyAccessProfile(),
    enabled: Boolean(user),
  })

  const rawProfile = query.data ?? null

  const normalized = useMemo((): NormalizedAccess | null => {
    if (query.data == null) return null
    return normalizeAccessProfile(
      query.data,
      user?.id ?? null,
      user?.email ?? null,
    )
  }, [query.data, user?.id, user?.email])

  const accessState = useMemo((): AccessBootstrapState => {
    if (!user) return 'loading'
    if (query.isPending || query.isLoading) return 'loading'
    if (query.isError) return 'error'
    if (query.data === null) return 'no_access'
    if (normalized && !normalized.isActive) return 'inactive'
    return 'ready'
  }, [
    user,
    query.isPending,
    query.isLoading,
    query.isError,
    query.data,
    normalized,
  ])

  const rolePermQuery = useQuery({
    queryKey: ['role-page-permissions', user?.id],
    queryFn: () => rpcGetRolePagePermissions(),
    enabled: accessState === 'ready',
  })

  useEffect(() => {
    if (rolePermQuery.isError && rolePermQuery.error) {
      console.warn(
        '[access] get_role_page_permissions failed; using default PAGE_ACCESS_MATRIX',
        rolePermQuery.error,
      )
    }
  }, [rolePermQuery.isError, rolePermQuery.error])

  const effectivePageMatrix = useMemo((): EffectivePageMatrix => {
    if (accessState !== 'ready') return PAGE_ACCESS_MATRIX
    if (rolePermQuery.isError || rolePermQuery.data == null) {
      return PAGE_ACCESS_MATRIX
    }
    return mergeRolePagePermissionRows(rolePermQuery.data)
  }, [accessState, rolePermQuery.isError, rolePermQuery.data])

  const error =
    query.error instanceof Error ? query.error : query.error != null
      ? new Error(String(query.error))
      : null

  const value: AccessContextValue = {
    rawProfile,
    normalized,
    accessState,
    effectivePageMatrix,
    isLoading: Boolean(user) && (query.isPending || query.isLoading),
    isError: query.isError,
    error,
    refetch: () => {
      void query.refetch()
      void rolePermQuery.refetch()
    },
  }

  return (
    <AccessContext.Provider value={value}>{children}</AccessContext.Provider>
  )
}

export function useAccessProfile(): AccessContextValue {
  const ctx = useContext(AccessContext)
  if (!ctx) {
    throw new Error('useAccessProfile must be used within AccessProvider')
  }
  return ctx
}

/** True when access is active and role is manager or admin (or legacy superadmin), or equivalent flags. */
export function useHasElevatedAccess(): boolean {
  const { accessState, normalized } = useAccessProfile()
  if (accessState !== 'ready') return false
  return Boolean(normalized?.hasElevatedAccess)
}
