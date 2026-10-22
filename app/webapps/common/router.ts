import { useCallback, useMemo } from 'react'
import { flushSync } from 'react-dom'
import { useLocation, useRouter } from '@tanstack/react-router'

export type SearchParamsInput =
  | URLSearchParams
  | string
  | Record<string, string | readonly string[]>
  | Iterable<[string, string]>
  | readonly [string, string][]
  | ((prev: URLSearchParams) => URLSearchParams)

export interface SetSearchParamsOptions {
  replace?: boolean
  preventScrollReset?: boolean
  flushSync?: boolean
}

export function parseRouterSearch(searchStr: string): Record<string, string> {
  return Object.fromEntries(new URLSearchParams(searchStr))
}

export function linkTarget(to: string | { pathname: string; search?: string }): {
  to: string
  search?: Record<string, string>
} {
  if (typeof to !== 'string') {
    return to.search ? { to: to.pathname, search: parseRouterSearch(to.search) } : { to: to.pathname }
  }
  const queryIndex = to.indexOf('?')
  if (queryIndex === -1) return { to }
  return {
    to: to.slice(0, queryIndex),
    search: parseRouterSearch(to.slice(queryIndex))
  }
}

export function stringifyRouterSearch(search: Record<string, unknown>): string {
  const params = new URLSearchParams()
  for (const [key, value] of Object.entries(search)) {
    if (value == null || value === false) continue
    if (Array.isArray(value)) {
      for (const item of value) {
        if (item != null) params.append(key, String(item))
      }
      continue
    }
    params.set(key, String(value))
  }
  const str = params.toString()
  return str ? `?${str}` : ''
}

function toURLSearchParams(
  input: Exclude<SearchParamsInput, (prev: URLSearchParams) => URLSearchParams>
): URLSearchParams {
  if (
    input instanceof URLSearchParams ||
    typeof input === 'string' ||
    Array.isArray(input) ||
    Symbol.iterator in Object(input)
  ) {
    return new URLSearchParams(input as string | URLSearchParams | string[][])
  }
  const params = new URLSearchParams()
  for (const [key, value] of Object.entries(input)) {
    if (Array.isArray(value)) {
      for (const item of value) params.append(key, item)
    } else if (typeof value === 'string') {
      params.set(key, value)
    }
  }
  return params
}

export function useSearchParams(): [
  URLSearchParams,
  (nextInit: SearchParamsInput, navigateOptions?: SetSearchParamsOptions) => void
] {
  const router = useRouter()
  const searchStr = useLocation({ select: location => location.searchStr })
  const searchParams = useMemo(() => new URLSearchParams(searchStr), [searchStr])

  const setSearchParams = useCallback(
    (nextInit: SearchParamsInput, navigateOptions?: SetSearchParamsOptions) => {
      const current = new URLSearchParams(router.latestLocation.searchStr)
      const next = typeof nextInit === 'function' ? nextInit(current) : toURLSearchParams(nextInit)
      const run = () => {
        void router.navigate({
          to: '.',
          search: Object.fromEntries(next),
          replace: navigateOptions?.replace,
          resetScroll: navigateOptions?.preventScrollReset ? false : undefined
        })
      }
      if (navigateOptions?.flushSync) flushSync(run)
      else run()
    },
    [router]
  )

  return [searchParams, setSearchParams]
}
