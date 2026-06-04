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

export function composeArgs(args: string[]): string[] {
  return ['compose', '-f', composeFilePath, ...args]
}

export async function runCompose(args: string[]): Promise<void> {
  await runChild('docker', composeArgs(args), {
    cwd: repoRootPath
  })
}

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

    parsed[key] = rawValue.replace(/^(['"])(.*)\1$/, '$2')
  }

  return parsed
}

function validateDatabaseName(name: string): string {
  if (/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(name)) return name

  throw new Error(`Unsupported PostgreSQL database name for devkit commands: ${name}`)
}
