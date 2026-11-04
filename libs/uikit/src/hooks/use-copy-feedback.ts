import { useEffect, useRef, useState } from 'react'

/** Restart copy feedback after each successful copy and dispose its timer with the control. */
export function useCopyFeedback<T>(empty: T, delay = 1500) {
  const [copied, setCopied] = useState(empty)
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined)
  useEffect(() => () => clearTimeout(timer.current), [])
  const reset = () => {
    clearTimeout(timer.current)
    setCopied(empty)
  }
  const markCopied = (value: T) => {
    clearTimeout(timer.current)
    setCopied(value)
    timer.current = setTimeout(() => setCopied(empty), delay)
  }
  return [copied, markCopied, reset] as const
}
