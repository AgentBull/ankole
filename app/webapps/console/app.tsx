import type { SpaDescriptor } from '../common/placeholder-app'

/** Descriptor for the temporary console SPA shell. */
export const consoleSpa: SpaDescriptor = {
  basename: '/console',
  eyebrow: 'Control plane',
  kind: 'console'
}
