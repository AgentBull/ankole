import { lstat, mkdir, unlink } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'

import { app } from './app'

const defaultSocketPath = resolve(import.meta.dir, '../../../var/ai_proxy.sock')

type BunServer = ReturnType<typeof Bun.serve>

/** Runtime handle for the local AI proxy Unix-socket server. */
export interface AIProxyServer {
  readonly server: BunServer
  readonly socketPath: string
  stop: () => Promise<void>
}

/** Options used when starting the local AI proxy server. */
export interface StartAIProxyServerOptions {
  socketPath?: string
}

/**
 * Resolves the Unix socket path used by Phoenix and local tools.
 *
 * A relative override is resolved from the current process so tests can use a
 * temporary path while the default stays inside the repository's `var/` tree.
 */
export function resolveSocketPath(socketPath = Bun.env.ANKOLE_AI_PROXY_SOCKET ?? defaultSocketPath) {
  return resolve(socketPath)
}

/**
 * Starts the AI proxy on a Unix socket and returns a cleanup-aware runtime.
 */
export async function startAIProxyServer(options: StartAIProxyServerOptions = {}): Promise<AIProxyServer> {
  const socketPath = resolveSocketPath(options.socketPath)

  await prepareSocketPath(socketPath)

  const server = Bun.serve({
    unix: socketPath,
    fetch: app.fetch
  })

  return {
    server,
    socketPath,
    stop: async () => {
      server.stop()
      await removeSocket(socketPath)
    }
  }
}

async function prepareSocketPath(socketPath: string) {
  await mkdir(dirname(socketPath), { recursive: true })

  try {
    const stat = await lstat(socketPath)

    if (!stat.isSocket()) {
      // Refusing non-sockets prevents a stale path bug from deleting a real file
      // such as a copied config or a developer-created placeholder.
      throw new Error(`Refusing to remove non-socket file at ${socketPath}`)
    }

    await unlink(socketPath)
  } catch (error) {
    if (isMissingPathError(error)) {
      return
    }

    throw error
  }
}

async function removeSocket(socketPath: string) {
  try {
    await unlink(socketPath)
  } catch (error) {
    if (!isMissingPathError(error)) {
      throw error
    }
  }
}

function isMissingPathError(error: unknown) {
  return error instanceof Error && 'code' in error && error.code === 'ENOENT'
}
