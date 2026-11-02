const CROCKFORD_LOWER = '0123456789abcdefghjkmnpqrstvwxyz'

/** The Kernel UUID URL codec: 16 bytes in 26-character lowercase Crockford Base32. */
export function uuidShorten(value: string): string | undefined {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value)) return
  const bits = BigInt(`0x${value.replaceAll('-', '')}`)
  let encoded = ''
  for (let step = 25n; step >= 0n; step -= 1n) {
    encoded += CROCKFORD_LOWER[Number((bits >> (step * 5n)) & 0x1fn)]
  }
  return encoded
}

export function uuidExpand(value: string): string | undefined {
  if (!/^[0-7][0-9a-hjkmnp-tv-z]{25}$/.test(value)) return
  let bits = 0n
  for (const ch of value) {
    bits = (bits << 5n) | BigInt(CROCKFORD_LOWER.indexOf(ch))
  }
  const hex = bits.toString(16).padStart(32, '0')
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}
