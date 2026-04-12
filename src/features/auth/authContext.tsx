/* eslint-disable react-refresh/only-export-components -- context module co-locates provider and hooks */
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react'
import type { Session, User } from '@supabase/supabase-js'
import { useQueryClient } from '@tanstack/react-query'

import { requireSupabaseClient } from '@/lib/supabase'

type AuthContextValue = {
  session: Session | null
  user: User | null
  /** True until the initial getSession() completes. */
  loading: boolean
  signInWithPassword: (
    email: string,
    password: string,
  ) => Promise<{ error: Error | null }>
  signOut: () => Promise<void>
}

const AuthContext = createContext<AuthContextValue | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient()
  const [session, setSession] = useState<Session | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    const client = requireSupabaseClient()
    let mounted = true

    void client.auth.getSession().then(({ data }) => {
      if (!mounted) return
      setSession(data.session)
      setLoading(false)
    })

    const {
      data: { subscription },
    } = client.auth.onAuthStateChange((_event, next) => {
      setSession(next)
    })

    return () => {
      mounted = false
      subscription.unsubscribe()
    }
  }, [])

  const signInWithPassword = useCallback(
    async (email: string, password: string) => {
      const { error } = await requireSupabaseClient().auth.signInWithPassword({
        email: email.trim(),
        password,
      })
      if (error) {
        return { error: new Error(error.message) }
      }
      return { error: null }
    },
    [],
  )

  const signOut = useCallback(async () => {
    await requireSupabaseClient().auth.signOut()
    queryClient.removeQueries({ queryKey: ['access-profile'] })
  }, [queryClient])

  const value = useMemo<AuthContextValue>(
    () => ({
      session,
      user: session?.user ?? null,
      loading,
      signInWithPassword,
      signOut,
    }),
    [session, loading, signInWithPassword, signOut],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext)
  if (!ctx) {
    throw new Error('useAuth must be used within AuthProvider')
  }
  return ctx
}

/** Session helpers for route guards and layout. */
export function useSession() {
  const { session, user, loading } = useAuth()
  return { session, user, loading }
}
