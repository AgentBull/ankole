export type TurnActivityOptions = {
  sourceSignal?: AbortSignal
  inactivityTimeoutMs: number
}

export type TurnActivity = {
  signal: AbortSignal
  touch: (description?: string) => void
  withSuspended: <T>(description: string, fn: () => Promise<T>) => Promise<T>
  runStep: <T>(promise: Promise<T>, step: string) => Promise<T>
  cleanup: () => void
}

export function createTurnActivity(opts: TurnActivityOptions): TurnActivity {
  const controller = new AbortController()
  let timeout: ReturnType<typeof setTimeout> | undefined
  let suspended = 0
  const enabled = Number.isFinite(opts.inactivityTimeoutMs) && opts.inactivityTimeoutMs > 0

  const clear = (): void => {
    if (!timeout) return
    clearTimeout(timeout)
    timeout = undefined
  }

  const abort = (reason: unknown): void => {
    clear()
    if (!controller.signal.aborted) controller.abort(reason)
  }

  const touch = (): void => {
    if (!enabled || suspended > 0 || controller.signal.aborted) return
    clear()
    timeout = setTimeout(() => {
      abort(
        new DOMException(
          `Timed out after ${opts.inactivityTimeoutMs}ms without model/provider activity`,
          'TimeoutError'
        )
      )
    }, opts.inactivityTimeoutMs)
  }

  const withSuspended = async <T>(_description: string, fn: () => Promise<T>): Promise<T> => {
    suspended += 1
    clear()
    try {
      return await fn()
    } finally {
      suspended = Math.max(0, suspended - 1)
      touch()
    }
  }

  const runStep = <T>(promise: Promise<T>, step: string): Promise<T> => {
    return abortableTurnStep(promise, controller.signal, step, touch)
  }

  const onSourceAbort = (): void => abort(opts.sourceSignal?.reason)

  if (opts.sourceSignal?.aborted) {
    abort(opts.sourceSignal.reason)
  } else {
    opts.sourceSignal?.addEventListener('abort', onSourceAbort, { once: true })
    touch()
  }

  return {
    signal: controller.signal,
    touch,
    withSuspended,
    runStep,
    cleanup: () => {
      clear()
      opts.sourceSignal?.removeEventListener('abort', onSourceAbort)
    }
  }
}

function abortableTurnStep<T>(
  promise: Promise<T>,
  signal: AbortSignal,
  step: string,
  onActivity?: (description?: string) => void
): Promise<T> {
  if (signal.aborted) return Promise.reject(turnAbortError(signal, step))
  onActivity?.(`${step}:start`)

  return new Promise<T>((resolve, reject) => {
    const onAbort = () => {
      signal.removeEventListener('abort', onAbort)
      reject(turnAbortError(signal, step))
    }

    signal.addEventListener('abort', onAbort, { once: true })
    promise.then(
      value => {
        signal.removeEventListener('abort', onAbort)
        onActivity?.(`${step}:done`)
        resolve(value)
      },
      error => {
        signal.removeEventListener('abort', onAbort)
        reject(error)
      }
    )
  })
}

function turnAbortError(signal: AbortSignal, step: string): Error {
  const reason = signal.reason
  const message = reason instanceof Error ? reason.message : typeof reason === 'string' ? reason : 'turn aborted'
  return new Error(`${step} aborted: ${message}`)
}
