import { useEffect, useState } from 'react'

/** Keep input immediate while coalescing work that depends on its settled value. */
export function useDebouncedValue(value: string, delay: number): string {
  const [settled, setSettled] = useState(value)
  useEffect(() => {
    const timer = setTimeout(() => setSettled(value), delay)
    return () => clearTimeout(timer)
  }, [value, delay])
  return settled
}
