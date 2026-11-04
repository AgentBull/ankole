import { z } from 'zod'

/** Human-facing label accepted by the turn-local shell CLIs. */
export const CLILabel = z.string().trim().min(1).max(500)

export function positiveInteger(value: string, name: string): number {
  const parsed = Number(value)
  if (!Number.isSafeInteger(parsed) || parsed <= 0) throw new Error(`${name} must be a positive integer`)
  return parsed
}

export function helpRequested(args: string[]): boolean {
  return args.some(arg => arg === '--help' || arg === '-h')
}

export function assertOnlyOptions(
  options: ReadonlyMap<string, unknown>,
  allowed: readonly string[],
  errorPrefix = 'unknown option'
): void {
  for (const name of options.keys()) {
    if (!allowed.includes(name)) throw new Error(`${errorPrefix} ${name}`)
  }
}
