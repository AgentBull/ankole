const desktopRow = 32
const narrowRow = 40

/** Matches `.pod-base-grid` cell height, including the narrow layout. */
export function baseGridRowEstimate(): number {
  if (typeof matchMedia !== 'function') return desktopRow
  return matchMedia('(max-width: 639px)').matches ? narrowRow : desktopRow
}
