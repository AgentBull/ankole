/**
 * Normalize a computer-relative path for upload: drop `.` segments, collapse slashes,
 * and reject anything that would escape the workspace. The worker re-validates;
 * this just gives callers a clear, early error.
 */
export function normalizeComputerPath(path: string): string {
  const segments = path.split('/').filter(segment => segment.length > 0 && segment !== '.')
  if (segments.some(segment => segment === '..')) {
    throw new Error(`unsafe computer path (contains ".."): ${path}`)
  }
  if (segments.length === 0) throw new Error(`empty computer path: ${path}`)
  return segments.join('/')
}
