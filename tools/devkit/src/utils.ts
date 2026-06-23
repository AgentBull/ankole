import { spawn, type SpawnOptions } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import chalk from 'chalk'

export const devkitRootPath = dirname(fileURLToPath(import.meta.url))
export const packageRootPath = join(devkitRootPath, '..')
export const repoRootPath = join(packageRootPath, '..', '..')
export const appRootPath = join(repoRootPath, 'app')
export const composeFilePath = join(packageRootPath, 'external-services.docker-compose.yml')

export const styledError = (msg: string): string => `${chalk.bold.red('ERROR:')} ${msg}`
export const styledWarn = (msg: string): string => `${chalk.bold.yellow('WARN:')} ${msg}`

/** Runs a child command attached to the current terminal and rejects on failure. */
export async function runChild(command: string, args: string[], options: SpawnOptions = {}): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: 'inherit',
      ...options
    })

    child.on('error', reject)
    child.on('exit', code => {
      if (code === 0) {
        resolve()
        return
      }

      reject(new Error(`${command} ${args.join(' ')} exited with code ${code ?? 'unknown'}`))
    })
  })
}

export type CapturedChild = {
  status: number | null
  stdout: string
  stderr: string
  error?: Error
}

/**
 * Like {@link runChild} but captures stdout/stderr and never rejects on a
 * nonzero exit. Used by the `analyze` subcommands that shell out to knip/jscpd
 * and must parse their output and decide the exit code themselves (vs. the
 * inherit-and-throw contract of `runChild`, which `app-db` relies on).
 */
export async function runChildCaptured(
  command: string,
  args: string[],
  options: SpawnOptions = {}
): Promise<CapturedChild> {
  return await new Promise<CapturedChild>(resolve => {
    const child = spawn(command, args, {
      stdio: ['ignore', 'pipe', 'pipe'],
      ...options
    })

    let stdout = ''
    let stderr = ''
    child.stdout?.on('data', (chunk: Buffer) => {
      stdout += chunk.toString()
    })
    child.stderr?.on('data', (chunk: Buffer) => {
      stderr += chunk.toString()
    })
    child.on('error', error => resolve({ status: null, stdout, stderr, error }))
    child.on('close', code => resolve({ status: code, stdout, stderr }))
  })
}

/**
 * Resolve a locally-installed binary (knip, jscpd, ...). Prefers the devkit
 * package's own node_modules/.bin, then the repo root. Returns null if absent
 * so callers can emit an infra error (exit 2) instead of a violation (exit 1).
 */
export function resolveLocalBin(name: string): string | null {
  const candidates = [
    join(packageRootPath, 'node_modules', '.bin', name),
    join(repoRootPath, 'node_modules', '.bin', name)
  ]
  return candidates.find(candidate => existsSync(candidate)) ?? null
}

/** Builds Docker Compose arguments pinned to devkit's shared Compose file. */
export function composeArgs(args: string[]): string[] {
  return ['compose', '-f', composeFilePath, ...args]
}

/** Runs Docker Compose from the repository root. */
export async function runCompose(args: string[]): Promise<void> {
  await runChild('docker', composeArgs(args), {
    cwd: repoRootPath
  })
}

export type StartComposeServicesArgs = {
  pull?: boolean
  wait?: boolean
  waitTimeout?: number
}

/**
 * Bring up every service defined in the Compose file (Postgres, Redis, computer, ...).
 * Shared by `external-services start` and the `app-db` commands so the two
 * start paths cannot drift and silently omit a service.
 */
export async function startComposeServices({
  pull = true,
  wait = true,
  waitTimeout = 60
}: StartComposeServicesArgs = {}): Promise<void> {
  const args = ['up', '--detach', '--remove-orphans']
  if (pull) args.push('--pull', 'always')
  if (wait) args.push('--wait', '--wait-timeout', String(waitTimeout))

  await runCompose(args)
}

/**
 * Resolves the development database name used by app-db commands.
 *
 * The default still says `bullx_development` because the devkit currently keeps
 * compatibility with the inherited local database naming.
 */
export function resolveAppDatabaseName(explicitName?: string): string {
  if (explicitName) return validateDatabaseName(explicitName)

  const databaseUrl = loadAppEnvValue('DATABASE_URL')
  if (!databaseUrl) return 'bullx_development'

  try {
    const parsed = new URL(databaseUrl)
    const databaseName = decodeURIComponent(parsed.pathname.replace(/^\//, ''))
    return validateDatabaseName(databaseName || 'bullx_development')
  } catch {
    throw new Error(`Invalid DATABASE_URL in app env files: ${databaseUrl}`)
  }
}

/** Loads app development env files without overwriting already-set process env. */
export function loadAppDevelopmentEnv(): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    NODE_ENV: process.env.NODE_ENV ?? 'development'
  }

  for (const file of appEnvFiles()) {
    for (const [name, value] of Object.entries(parseEnvFile(file))) {
      if (env[name] === undefined) env[name] = value
    }
  }

  return env
}

function loadAppEnvValue(name: string): string | undefined {
  if (process.env[name]) return process.env[name]

  for (const file of appEnvFiles()) {
    const value = parseEnvFile(file)[name]
    if (value !== undefined) return value
  }
}

function appEnvFiles(): string[] {
  return [join(appRootPath, '.env.local'), join(appRootPath, '.env.development')]
}

function parseEnvFile(path: string): Record<string, string> {
  if (!existsSync(path)) return {}

  const parsed: Record<string, string> = {}
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith('#')) continue

    const separator = trimmed.indexOf('=')
    if (separator === -1) continue

    const key = trimmed.slice(0, separator).trim()
    const rawValue = trimmed.slice(separator + 1).trim()
    if (!key) continue

    // This parser intentionally handles only the simple KEY=value shape used by
    // local dev files. Bun loads richer .env syntax for real app runtime.
    parsed[key] = rawValue.replace(/^(['"])(.*)\1$/, '$2')
  }

  return parsed
}

function validateDatabaseName(name: string): string {
  if (/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(name)) return name

  throw new Error(`Unsupported PostgreSQL database name for devkit commands: ${name}`)
}
