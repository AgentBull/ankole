type Route = { key: string; method: string; segments: string[] }

export function validateActions(value: unknown) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError('actions must be an object')
  }
  return Object.fromEntries(
    Object.entries(value).map(([key, action]) => {
      if (
        !key.trim() ||
        !action ||
        typeof action.handler !== 'function' ||
        (action.idempotent !== undefined && typeof action.idempotent !== 'boolean') ||
        (action.concurrencyKey !== undefined && typeof action.concurrencyKey !== 'function') ||
        !['parallel', 'serial_fifo', 'serial_coalesce'].includes(action.concurrency ?? 'parallel') ||
        !Number.isInteger(action.maxSlices ?? 1000) ||
        (action.maxSlices ?? 1000) < 1 ||
        (action.maxSlices ?? 1000) > 100000
      ) {
        throw new TypeError(`invalid action: ${key}`)
      }
      return [
        key,
        {
          idempotent: action.idempotent ?? false,
          concurrency: action.concurrency ?? 'parallel',
          maxSlices: action.maxSlices ?? 1000
        }
      ]
    })
  )
}

export function validateRoutes(value: unknown): Route[] {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError('default export must be a route object')
  }
  const patterns = new Set<string>()
  const routes = Reflect.ownKeys(value).map(key => {
    if (typeof key !== 'string' || typeof (value as Record<string, unknown>)[key] !== 'function') {
      throw new TypeError('route keys must be strings and handlers must be functions')
    }
    const match = /^(GET|POST|PUT|PATCH|DELETE) (\/.*)$/.exec(key)
    if (!match) throw new TypeError(`invalid route: ${key}`)
    const [, method, path] = match
    const segments = path === '/' ? [] : path.slice(1).split('/')
    const names = new Set<string>()
    for (const part of segments) {
      if (part.startsWith(':')) {
        const name = part.slice(1)
        if (!name || name.includes(':') || names.has(name)) {
          throw new TypeError(`invalid route parameter: ${key}`)
        }
        names.add(name)
      }
    }
    const pattern = `${method}/${segments.map(part => (part.startsWith(':') ? ':' : part)).join('/')}`
    if (patterns.has(pattern)) throw new TypeError(`conflicting route: ${key}`)
    patterns.add(pattern)
    return { key, method, segments }
  })
  return routes.sort((left, right) => {
    for (let i = 0; i < Math.min(left.segments.length, right.segments.length); i++) {
      const order = Number(left.segments[i].startsWith(':')) - Number(right.segments[i].startsWith(':'))
      if (order) return order
    }
    return 0
  })
}

export function matchRoute(routes: Route[], method: string, path: string) {
  if (!path.startsWith('/')) return { status: 404 }
  let segments: string[]
  try {
    segments = path === '/' ? [] : path.slice(1).split('/').map(decodeURIComponent)
  } catch {
    return { status: 400 }
  }
  let exists = false
  for (const route of routes) {
    if (route.segments.length !== segments.length) continue
    const params: Record<string, string> = {}
    if (
      !route.segments.every((part, index) => {
        if (!part.startsWith(':')) return part === segments[index]
        params[part.slice(1)] = segments[index]
        return segments[index] !== ''
      })
    ) {
      continue
    }
    exists = true
    if (route.method === method) return { route, params, status: 200 }
  }
  return { status: exists ? 405 : 404 }
}
