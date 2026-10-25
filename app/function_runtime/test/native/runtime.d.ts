declare namespace Deno {
  function readTextFileSync(path: string): string
  function readDirSync(path: string): Iterable<{ name: string }>
}

declare namespace EdgeRuntime {
  function getRuntimeMetrics(): Promise<{ activeUserWorkersCount: number; [key: string]: unknown }>
}

declare class EventManager implements AsyncIterable<{
  event_type: string
  event: { reason?: string; cpu_time_used?: number; msg?: string }
  metadata?: { service_path?: string }
}> {
  [Symbol.asyncIterator](): AsyncIterator<{
    event_type: string
    event: { reason?: string; cpu_time_used?: number; msg?: string }
    metadata?: { service_path?: string }
  }>
}
