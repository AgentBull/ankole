import { Elysia } from 'elysia'

/** Minimal health surface for the Unix-socket AI proxy process. */
export const app = new Elysia()
  .get('/', () => ({
    service: 'ai_proxy',
    status: 'ok'
  }))
  .get('/health', () => ({
    service: 'ai_proxy',
    status: 'ok'
  }))

export type AiProxyApp = typeof app
