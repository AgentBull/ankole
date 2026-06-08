declare module '*.jpg' {
  const src: string
  export default src
}

declare module '*.jpeg' {
  const src: string
  export default src
}

declare module '*.png' {
  const src: string
  export default src
}

declare module '*.gif' {
  const src: string
  export default src
}

declare module '*.webp' {
  const src: string
  export default src
}

declare module '*.svg' {
  const src: string
  export default src
}

declare module '*.toml' {
  const data: unknown
  export default data
}

declare module '*.css'

declare module 'react-dom/client' {
  import type { ReactNode } from 'react'

  export interface Root {
    render(children: ReactNode): void
    unmount(): void
  }

  export function createRoot(container: Element | DocumentFragment, options?: unknown): Root
  export function hydrateRoot(container: Element | Document, initialChildren: ReactNode, options?: unknown): Root
}
