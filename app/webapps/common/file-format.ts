export function formatFileBytes(bytes: number | null | undefined): string {
  if (bytes == null || !Number.isFinite(bytes) || bytes < 0) return ''
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  let size = bytes
  let unit = 0
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024
    unit += 1
  }
  const decimals = unit === 0 || size >= 10 ? 0 : 1
  return `${size.toFixed(decimals)} ${units[unit]}`
}
