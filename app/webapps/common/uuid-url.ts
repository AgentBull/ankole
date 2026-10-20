/** The Kernel UUID URL codec: 16 bytes in canonical, padding-free base64url. */
export function uuidShorten(value: string): string | undefined {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value)) return
  const bytes = value
    .replaceAll('-', '')
    .match(/../g)!
    .map(byte => Number.parseInt(byte, 16))
  return btoa(String.fromCharCode(...bytes))
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replace(/=+$/, '')
}

export function uuidExpand(value: string): string | undefined {
  if (!/^[A-Za-z0-9_-]{22}$/.test(value)) return
  const bytes = atob(`${value.replaceAll('-', '+').replaceAll('_', '/')}==`)
  const hex = Array.from(bytes, byte => byte.charCodeAt(0).toString(16).padStart(2, '0')).join('')
  const uuid = `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
  return uuidShorten(uuid) === value ? uuid : undefined
}
