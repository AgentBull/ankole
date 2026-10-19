import type { Plugin } from 'vite'

/** Keep whole namespaces, including server-supplied activity labels and SaaS account navigation. */
export function podLocaleCatalog(catalog: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(catalog).filter(([namespace]) =>
      ['__meta__', 'common', 'pod', 'conversations', 'saas'].includes(namespace)
    )
  )
}

export function podLocaleCatalogPlugin(directory: string): Plugin {
  return {
    name: 'ankole-pod-locale-catalog',
    enforce: 'pre',
    transform(code, id) {
      const [file = '', query] = id.replaceAll('\\', '/').split('?')
      if (
        file.startsWith(directory.replaceAll('\\', '/') + '/') &&
        file.endsWith('.json') &&
        new URLSearchParams(query).has('pod')
      ) {
        return {
          code: JSON.stringify(podLocaleCatalog(JSON.parse(code))),
          // Query variants need an explicit type for Vite's native JSON plugin.
          moduleType: 'json'
        }
      }
    }
  }
}
