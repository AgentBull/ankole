import { useEffect, useEffectEvent, useRef, useState } from 'react'

/** URL echoes must not replace input typed after the submitted search snapshot. */
export function useSearchDraft(
  query: string,
  commit: (draft: string) => void,
  { delay = 300, enabled = true, scope }: { delay?: number; enabled?: boolean; scope?: string } = {}
): [string, (value: string) => void] {
  const [draft, setDraft] = useState(query)
  const submitted = useRef(query)
  const previousQuery = useRef(query)
  const previousScope = useRef(scope)
  const commitDraft = useEffectEvent(commit)
  const restoring = (query !== previousQuery.current && query !== submitted.current) || scope !== previousScope.current
  useEffect(() => {
    previousQuery.current = query
    previousScope.current = scope
    if (!restoring) return
    submitted.current = query
    setDraft(query)
  }, [query, scope, restoring])
  useEffect(() => {
    if (restoring || !enabled || draft === query) return
    const send = () => {
      submitted.current = draft
      commitDraft(draft)
    }
    // Clearing is a single action; typing is a burst of input.
    if (!draft.trim()) {
      send()
      return
    }
    const timer = setTimeout(send, delay)
    return () => clearTimeout(timer)
  }, [draft, query, delay, enabled, restoring])
  return [draft, setDraft]
}
