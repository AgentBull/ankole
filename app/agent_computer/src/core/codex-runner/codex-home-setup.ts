const setupTails = new Map<string, Promise<void>>()

/**
 * Serializes setup that changes one Agent Codex Home. Worker placement keeps
 * all live work for an Agent in this process, so a process-local queue is the
 * correct lock boundary. Job execution stays concurrent after setup finishes.
 */
export async function withCodexHomeSetup<T>(codexHome: string, setup: () => Promise<T>): Promise<T> {
  if (!codexHome) throw new Error('Codex Home is required for shared setup')

  const previous = setupTails.get(codexHome) ?? Promise.resolve()
  let release = (): void => undefined
  const tail = new Promise<void>(resolve => {
    release = resolve
  })
  setupTails.set(codexHome, tail)

  await previous
  try {
    return await setup()
  } finally {
    release()
    if (setupTails.get(codexHome) === tail) setupTails.delete(codexHome)
  }
}
