import { isIP } from 'node:net'
import { lookup } from 'node:dns/promises'
import type { BrowserContext, Request } from 'playwright-core'
import type { BrowserMaterial } from '../protocol'
import { BrowserDataError } from '../errors'

type HostClass = 'metadata' | 'private' | 'public'

export async function validateNavigationURL(value: string, material: BrowserMaterial): Promise<URL> {
  let url: URL
  try {
    url = new URL(value.includes('://') ? value : `https://${value}`)
  } catch {
    throw new BrowserDataError('invalid_command', `invalid URL: ${value}`)
  }
  if (url.protocol === 'file:' && material.navigation.allow_file_urls) return url
  if (!['http:', 'https:'].includes(url.protocol)) {
    throw new BrowserDataError('invalid_command', `unsupported browser URL protocol: ${url.protocol}`)
  }
  // URL hosts keep their IPv6 brackets; classification works on the bare address.
  const host = url.hostname.startsWith('[') ? url.hostname.slice(1, -1) : url.hostname
  if (!host) throw new BrowserDataError('invalid_command', 'browser URL requires a hostname')
  const addresses = isIP(host)
    ? [host]
    : (
        await lookup(host, { all: true }).catch(error => {
          throw new BrowserDataError('backend_unavailable', `browser hostname resolution failed: ${host}`, {
            retryable: true,
            cause: error
          })
        })
      ).map(({ address }) => address)
  for (const address of addresses) {
    const hostClass = classifyIPAddress(address)
    if (hostClass === 'metadata') {
      throw new BrowserDataError('invalid_command', `blocked browser navigation to metadata address: ${host}`)
    }
    if (hostClass === 'private' && material.navigation.ssrf_filter) {
      throw new BrowserDataError('invalid_command', `blocked browser navigation to private address: ${host}`)
    }
  }
  return url
}

export async function installNavigationPolicy(context: BrowserContext, material: BrowserMaterial): Promise<void> {
  await context.route('**/*', async route => {
    const request = route.request()
    if (!mainFrameNavigation(request)) {
      await route.continue()
      return
    }
    try {
      await validateNavigationURL(request.url(), material)
      await route.continue()
    } catch {
      await route.abort('blockedbyclient')
    }
  })
}

function mainFrameNavigation(request: Request): boolean {
  return request.isNavigationRequest() && request.frame() === request.frame().page().mainFrame()
}

// classifyIPAddress mirrors the kernel web URL host classification in
// app/kernel/src/common/web_url.rs. The browser data plane cannot link the
// native module, so parity is pinned by the shared vectors in
// app/kernel/test/vectors/web_url_host_classification.json, which the Rust,
// Elixir, and Bun suites all decode. Metadata addresses are cloud credential
// endpoints every guard rejects; private addresses are rejected only while
// the SSRF filter is enabled.
function classifyIPAddress(address: string): HostClass {
  if (address.includes(':')) return classifyIPv6(address)
  return classifyIPv4(address)
}

function classifyIPv4(address: string): HostClass {
  const parts = address.split('.').map(Number)
  if (parts.length !== 4 || parts.some(part => !Number.isInteger(part) || part < 0 || part > 255)) {
    return 'private'
  }
  const [a, b, c, d] = parts as [number, number, number, number]
  if (a === 169 && b === 254 && c === 169 && (d === 254 || d === 250 || d === 251)) return 'metadata'
  if (
    a === 0 ||
    a === 10 ||
    a === 127 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168)
  ) {
    return 'private'
  }
  return 'public'
}

function classifyIPv6(address: string): HostClass {
  const segments = parseIPv6Segments(address)
  if (!segments) return 'private'
  // IPv4-mapped addresses take the IPv4 verdict so `::ffff:10.0.0.1` cannot
  // sidestep the RFC1918 classification.
  if (segments.slice(0, 5).every(segment => segment === 0) && segments[5] === 0xffff) {
    return classifyIPv4(`${segments[6]! >> 8}.${segments[6]! & 0xff}.${segments[7]! >> 8}.${segments[7]! & 0xff}`)
  }
  const first = segments[0]!
  // AWS IMDSv6 endpoint.
  if (
    first === 0xfd00 &&
    segments[1] === 0x0ec2 &&
    segments.slice(2, 7).every(segment => segment === 0) &&
    segments[7] === 0x0254
  ) {
    return 'metadata'
  }
  // Link-local (fe80::/10) stays in the always-rejected metadata set.
  if ((first & 0xffc0) === 0xfe80) return 'metadata'
  if (segments.slice(0, 7).every(segment => segment === 0) && segments[7] === 1) return 'private'
  if ((first & 0xfe00) === 0xfc00) return 'private'
  return 'public'
}

function parseIPv6Segments(address: string): number[] | null {
  // A numeric zone id (`fe80::1%eth0`) does not change the class.
  let text = address.toLowerCase().split('%')[0]!
  if (text.includes('.')) {
    const lastColon = text.lastIndexOf(':')
    if (lastColon === -1) return null
    const v4Parts = text
      .slice(lastColon + 1)
      .split('.')
      .map(Number)
    if (v4Parts.length !== 4 || v4Parts.some(part => !Number.isInteger(part) || part < 0 || part > 255)) {
      return null
    }
    text = `${text.slice(0, lastColon)}:${((v4Parts[0]! << 8) | v4Parts[1]!).toString(16)}:${((v4Parts[2]! << 8) | v4Parts[3]!).toString(16)}`
  }
  const halves = text.split('::')
  if (halves.length > 2) return null
  const head = halves[0] === '' ? [] : halves[0]!.split(':')
  const tail = halves.length === 2 && halves[1] !== '' ? halves[1]!.split(':') : []
  if (halves.length === 1 && head.length !== 8) return null
  const fill = 8 - head.length - tail.length
  if (fill < 0) return null
  const segments = [...head, ...Array<string>(fill).fill('0'), ...tail].map(group => Number.parseInt(group, 16))
  if (segments.length !== 8 || segments.some(segment => Number.isNaN(segment) || segment > 0xffff)) return null
  return segments
}
