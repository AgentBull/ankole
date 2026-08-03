const setupTails = new Map<string, Promise<void>>()

export type TryCodexHomeSetupResult<T> = { acquired: true; value: T } | { acquired: false }

/**
 * Serializes setup that changes one Agent Codex Home. Worker placement keeps
 * all live work for an Agent in this process, so a process-local queue is the
 * correct lock boundary. A queued caller can stop without letting later setup
 * pass the active setup. Job execution stays concurrent after setup finishes.
 */
export async function withCodexHomeSetup<T>(
  codexHome: string,
  setup: () => Promise<T>,
  abortSignal?: AbortSignal
): Promise<T> {
  if (!codexHome) throw new Error('Codex Home is required for shared setup')
  abortSignal?.throwIfAborted()

  const previous = setupTails.get(codexHome) ?? Promise.resolve()
  let release = (): void => undefined
  const completion = new Promise<void>(resolve => {
    release = resolve
  })
  // A canceled caller can release completion early, but its tail still follows
  // previous. This keeps later setup behind the setup that is still active.
  const tail = previous.then(() => completion)
  setupTails.set(codexHome, tail)
  void tail.then(() => {
    if (setupTails.get(codexHome) === tail) setupTails.delete(codexHome)
  })

  try {
    await waitForSetupTurn(previous, abortSignal)
    abortSignal?.throwIfAborted()
    return await setup()
  } finally {
    release()
  }
}

/**
 * Runs setup only when this Agent Codex Home has no queued or active setup.
 * The check and queue insertion stay in one JavaScript event-loop turn.
 */
export async function tryWithCodexHomeSetup<T>(
  codexHome: string,
  setup: () => Promise<T>,
  abortSignal?: AbortSignal
): Promise<TryCodexHomeSetupResult<T>> {
  if (!codexHome) throw new Error('Codex Home is required for shared setup')
  abortSignal?.throwIfAborted()
  if (setupTails.has(codexHome)) return { acquired: false }

  return {
    acquired: true,
    value: await withCodexHomeSetup(codexHome, setup, abortSignal)
  }
}

function waitForSetupTurn(previous: Promise<void>, abortSignal?: AbortSignal): Promise<void> {
  abortSignal?.throwIfAborted()
  if (!abortSignal) return previous

  return new Promise((resolve, reject) => {
    const onAbort = (): void => {
      abortSignal.removeEventListener('abort', onAbort)
      reject(abortSignal.reason ?? new DOMException('Codex Home setup wait was aborted', 'AbortError'))
    }
    abortSignal.addEventListener('abort', onAbort, { once: true })
    void previous.then(() => {
      abortSignal.removeEventListener('abort', onAbort)
      if (abortSignal.aborted) {
        reject(abortSignal.reason ?? new DOMException('Codex Home setup wait was aborted', 'AbortError'))
      } else {
        resolve()
      }
    })
  })
}
