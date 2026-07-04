/**
 * Writes one JSON-line worker event to stdout or stderr.
 *
 * Worker logs are parsed by operators and tests, so this helper keeps event
 * shape consistent while still letting warnings/errors go to stderr.
 */
export function logWorkerEvent(
  event: string,
  fields: Record<string, unknown> = {},
  stream: 'stdout' | 'stderr' = 'stdout'
): void {
  const line = `${JSON.stringify({ event, ...fields })}\n`
  if (stream === 'stderr') {
    process.stderr.write(line)
    return
  }

  process.stdout.write(line)
}
