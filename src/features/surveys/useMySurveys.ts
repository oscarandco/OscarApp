import { useQuery } from '@tanstack/react-query'
import { useAccessProfile } from '@/features/access/accessContext'
import { getMySurveys } from './surveyApi'

export function useMySurveys() {
  const { normalized, accessState } = useAccessProfile()
  return useQuery({
    queryKey: ['surveys', 'mine', 'builder', normalized?.userId],
    queryFn: getMySurveys,
    enabled: accessState === 'ready',
    staleTime: 15_000,
    refetchInterval: 60_000,
  })
}
