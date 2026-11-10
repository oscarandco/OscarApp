import { useEffect, useState } from 'react'

// Keep invitations, reminder expiry and closing times current in long-lived tabs.
export function useSurveyClock() {
  const [now, setNow] = useState(Date.now)
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 15_000)
    return () => window.clearInterval(timer)
  }, [])
  return now
}
