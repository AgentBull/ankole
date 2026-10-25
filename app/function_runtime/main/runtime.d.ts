declare const AsyncLocalStorage: typeof import('node:async_hooks').AsyncLocalStorage
declare const importApplet: () => Promise<{ default: Record<string, (input: unknown) => unknown> }>

declare namespace Deno {
  const env: { get(name: string): string | undefined }
  function mkdirSync(path: string, options: { recursive: boolean }): void
  function upgradeWebSocket(request: Request): { socket: WebSocket; response: Response }
  function serve(handler: (request: Request) => Response | Promise<Response>): unknown
  namespace errors {
    class WorkerRequestCancelled extends Error {}
    class WorkerMemoryLimitExceeded extends Error {}
  }
}

declare namespace EdgeRuntime {
  type UserWorker = {
    fetch(request: Request, options?: { signal?: AbortSignal }): Promise<Response>
    retire(): Promise<void>
  }
  namespace userWorkers {
    function create(options: Record<string, unknown>): Promise<UserWorker>
  }
  function applySupabaseTag(source: Request, destination: Request): void
  function waitUntil<T>(work: Promise<T>): Promise<T>
}
