import { accessSync, constants, existsSync, fstatSync, readFileSync, readlinkSync } from 'node:fs'
import { join } from 'node:path'
import {
  PERCEPTUAL_SHIM_DIR,
  checkEnvEscapeHatch,
  planArgvShaping,
  shapeCommandOutput
} from '../../tools/computer/perceptual-shaping'

async function main(): Promise<void> {
  const toolName = process.argv[2]
  const rawArgs = process.argv.slice(3)
  if (!toolName) {
    process.stderr.write('ankole-cli-shim: missing target tool name\n')
    process.exit(2)
  }

  const shimDir = process.env.ANKOLE_SHIM_DIR_OVERRIDE || PERCEPTUAL_SHIM_DIR
  const strippedPath = stripShimDirFromPath(process.env.PATH ?? '', shimDir)
  const realExecutable = resolveExecutable(toolName, strippedPath)
  if (!realExecutable) {
    process.stderr.write(`${toolName}: command not found\n`)
    process.exit(127)
  }

  if (shouldBypassProcessShim(process.env)) {
    const code = await execPassthrough(realExecutable, rawArgs, {
      ...process.env,
      PATH: strippedPath
    })
    process.exit(code)
  }

  const plan = planArgvShaping(toolName, rawArgs, process.env)
  if (plan.bypassed) {
    // Keep the shim directory on PATH for unshaped wrapper commands (such as
    // `npm test` or `bun run test`) so child test runners still pass through their shim.
    const nextPath = plan.bypassReason === 'unshaped_subcommand' ? (process.env.PATH ?? strippedPath) : strippedPath
    const code = await execPassthrough(realExecutable, rawArgs, {
      ...process.env,
      PATH: nextPath
    })
    process.exit(code)
  }

  const childEnv: Record<string, string> = {
    ...plan.envPatch,
    ...(Object.fromEntries(
      Object.entries(process.env).filter((entry): entry is [string, string] => entry[1] !== undefined)
    ) as Record<string, string>),
    PATH: strippedPath,
    ANKOLE_SHIM_ACTIVE: '1'
  }

  const proc = Bun.spawn([realExecutable, ...plan.args], {
    env: childEnv,
    stdin: 'inherit',
    stdout: 'pipe',
    stderr: 'pipe'
  })

  const forwardSignal = (sig: NodeJS.Signals) => {
    try {
      proc.kill(sig)
    } catch {}
  }
  process.on('SIGTERM', forwardSignal)
  process.on('SIGINT', forwardSignal)

  try {
    const [exitCode, stdoutBytes, stderrBytes] = await Promise.all([
      proc.exited,
      new Response(proc.stdout).arrayBuffer(),
      new Response(proc.stderr).arrayBuffer()
    ])
    const stdoutText = Buffer.from(stdoutBytes).toString('utf8')
    const stderrText = Buffer.from(stderrBytes).toString('utf8')

    if (plan.family === 'curl_json' || plan.family === 'shell_cat') {
      const { output } = shapeCommandOutput(plan, { exitCode, output: stdoutText })
      if (output.length > 0) {
        process.stdout.write(output.endsWith('\n') || !stdoutText.endsWith('\n') ? output : `${output}\n`)
      }
      if (stderrText.length > 0) process.stderr.write(stderrText)
      process.exit(exitCode)
    }

    const combined = [stdoutText, stderrText].filter(Boolean).join(stdoutText && stderrText ? '\n' : '')
    const { output } = shapeCommandOutput(plan, { exitCode, output: combined })
    if (output.length > 0) {
      const targetStream = stdoutText.length === 0 && stderrText.length > 0 ? process.stderr : process.stdout
      targetStream.write(output.endsWith('\n') ? output : `${output}\n`)
    }
    process.exit(exitCode)
  } finally {
    process.off('SIGTERM', forwardSignal)
    process.off('SIGINT', forwardSignal)
  }
}

export function shouldBypassProcessShim(env: Record<string, string | undefined>): boolean {
  if (checkEnvEscapeHatch(env)) return true

  // Never shape stdout redirected to a regular file (`cmd > file`).
  try {
    if (fstatSync(1).isFile()) return true
  } catch {
    return true
  }

  const harnessStdoutId = env.ANKOLE_HARNESS_STDOUT_ID
  if (harnessStdoutId) {
    if (existsSync('/proc/self/fd/1')) {
      try {
        return readlinkSync('/proc/self/fd/1') !== harnessStdoutId
      } catch {
        return true
      }
    }
    return false
  }

  if (env.ANKOLE_SHIM_DIRECT === '1') return false

  // When invoked without an outer login/BASH_ENV shell, only shape direct Codex child pipes.
  if (existsSync('/proc/self/fd/1')) {
    try {
      const fdTarget = readlinkSync('/proc/self/fd/1')
      if (!fdTarget.startsWith('pipe:') && !fdTarget.startsWith('socket:')) return true
      const parentComm = readFileSync(`/proc/${process.ppid}/comm`, 'utf8').trim()
      return parentComm !== 'codex'
    } catch {
      return true
    }
  }

  return true
}

function stripShimDirFromPath(pathEnv: string, shimDir: string): string {
  return pathEnv
    .split(':')
    .filter(entry => entry.length > 0 && entry !== shimDir)
    .join(':')
}

function resolveExecutable(toolName: string, pathEnv: string): string | undefined {
  for (const dir of pathEnv.split(':')) {
    if (!dir) continue
    const candidate = join(dir, toolName)
    try {
      accessSync(candidate, constants.X_OK)
      return candidate
    } catch {}
  }
  return undefined
}

async function execPassthrough(
  executable: string,
  args: string[],
  env: Record<string, string | undefined>
): Promise<number> {
  const cleanEnv = Object.fromEntries(
    Object.entries(env).filter((entry): entry is [string, string] => entry[1] !== undefined)
  )
  const proc = Bun.spawn([executable, ...args], {
    env: cleanEnv,
    stdin: 'inherit',
    stdout: 'inherit',
    stderr: 'inherit'
  })
  const forwardSignal = (sig: NodeJS.Signals) => {
    try {
      proc.kill(sig)
    } catch {}
  }
  process.on('SIGTERM', forwardSignal)
  process.on('SIGINT', forwardSignal)
  try {
    return await proc.exited
  } finally {
    process.off('SIGTERM', forwardSignal)
    process.off('SIGINT', forwardSignal)
  }
}

if (import.meta.main) {
  await main()
}
