import net from 'node:net'
import { ms } from '@pleisto/active-support'

export interface RateLimitConfig {
  maxAttempts?: number
  windowMs?: number
  lockoutMs?: number
  exemptLoopback?: boolean
  pruneIntervalMs?: number
}

export interface RateLimitCheckResult {
  allowed: boolean
  remaining: number
  retryAfterMs: number
}

export interface AuthRateLimiter {
  check(ip: string | undefined, scope?: string): RateLimitCheckResult
  recordFailure(ip: string | undefined, scope?: string): void
  reset(ip: string | undefined, scope?: string): void
  size(): number
  prune(): void
  dispose(): void
}

const DEFAULT_MAX_ATTEMPTS = 10
const DEFAULT_WINDOW_MS = ms('1m')
const DEFAULT_LOCKOUT_MS = ms('5m')
const DEFAULT_PRUNE_INTERVAL_MS = ms('1m')
const DEFAULT_SCOPE = 'default'

interface Entry {
  attempts: number[]
  lockedUntil?: number
}

export function createAuthRateLimiter(config: RateLimitConfig = {}): AuthRateLimiter {
  const maxAttempts = config.maxAttempts ?? DEFAULT_MAX_ATTEMPTS
  const windowMs = config.windowMs ?? DEFAULT_WINDOW_MS
  const lockoutMs = config.lockoutMs ?? DEFAULT_LOCKOUT_MS
  const exemptLoopback = config.exemptLoopback ?? true
  const pruneIntervalMs = config.pruneIntervalMs ?? DEFAULT_PRUNE_INTERVAL_MS
  const entries = new Map<string, Entry>()
  const timer = pruneIntervalMs > 0 ? setInterval(() => prune(), pruneIntervalMs) : undefined
  timer?.unref?.()

  function key(rawIp: string | undefined, rawScope?: string): { key: string; ip: string } {
    const ip = normalizeRateLimitClientIp(rawIp)
    const scope = rawScope?.trim() || DEFAULT_SCOPE
    return { key: `${scope}:${ip}`, ip }
  }

  function exempt(ip: string): boolean {
    return exemptLoopback && isLoopbackAddress(ip)
  }

  function slide(entry: Entry, now: number): void {
    const cutoff = now - windowMs
    entry.attempts = entry.attempts.filter(ts => ts > cutoff)
  }

  function check(rawIp: string | undefined, scope?: string): RateLimitCheckResult {
    const resolved = key(rawIp, scope)
    if (exempt(resolved.ip)) return { allowed: true, remaining: maxAttempts, retryAfterMs: 0 }
    const now = Date.now()
    const entry = entries.get(resolved.key)
    if (!entry) return { allowed: true, remaining: maxAttempts, retryAfterMs: 0 }
    if (entry.lockedUntil && now < entry.lockedUntil) {
      return { allowed: false, remaining: 0, retryAfterMs: entry.lockedUntil - now }
    }
    if (entry.lockedUntil && now >= entry.lockedUntil) {
      entry.lockedUntil = undefined
      entry.attempts = []
    }
    slide(entry, now)
    const remaining = Math.max(0, maxAttempts - entry.attempts.length)
    return { allowed: remaining > 0, remaining, retryAfterMs: 0 }
  }

  function recordFailure(rawIp: string | undefined, scope?: string): void {
    const resolved = key(rawIp, scope)
    if (exempt(resolved.ip)) return
    const now = Date.now()
    let entry = entries.get(resolved.key)
    if (!entry) {
      entry = { attempts: [] }
      entries.set(resolved.key, entry)
    }
    if (entry.lockedUntil && now < entry.lockedUntil) return
    slide(entry, now)
    entry.attempts.push(now)
    if (entry.attempts.length >= maxAttempts) entry.lockedUntil = now + lockoutMs
  }

  function reset(rawIp: string | undefined, scope?: string): void {
    entries.delete(key(rawIp, scope).key)
  }

  function prune(): void {
    const now = Date.now()
    for (const [entryKey, entry] of entries) {
      if (entry.lockedUntil && now < entry.lockedUntil) continue
      slide(entry, now)
      if (entry.attempts.length === 0) entries.delete(entryKey)
    }
  }

  function dispose(): void {
    if (timer) clearInterval(timer)
    entries.clear()
  }

  return { check, recordFailure, reset, size: () => entries.size, prune, dispose }
}

export function clientIpFromRequest(request: Request): string | undefined {
  const forwarded = request.headers.get('x-forwarded-for')?.split(',')[0]?.trim()
  return (
    forwarded ||
    request.headers.get('x-real-ip')?.trim() ||
    request.headers.get('cf-connecting-ip')?.trim() ||
    undefined
  )
}

export function normalizeRateLimitClientIp(ip: string | undefined): string {
  if (!ip) return 'unknown'
  const trimmed = ip.trim()
  if (trimmed.startsWith('::ffff:')) return trimmed.slice('::ffff:'.length)
  return trimmed || 'unknown'
}

function isLoopbackAddress(ip: string): boolean {
  const normalized = normalizeRateLimitClientIp(ip).toLowerCase()
  if (normalized === 'localhost' || normalized === '::1') return true
  if (net.isIP(normalized) === 4) return normalized.startsWith('127.')
  return false
}
