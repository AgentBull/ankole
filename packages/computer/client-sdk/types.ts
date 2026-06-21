/**
 * Shared wire + public types for the BullX Computer SDK.
 *
 * The wire shapes mirror the worker / control-plane HTTP API described in the
 * Final Plan (§7, §12). Public option types stay close to the Vercel Computer SDK.
 */

/** A `fetch`-compatible function (overridable for tests / in-process use). */
export type FetchLike = typeof fetch

/** Worker coordinates returned by the control-plane resolver. */
export interface ResolvedWorker {
  workerId: string
  instanceId: string
  baseUrl: string
}

export interface WorkerTlsConfig {
  caCert: string
  cert: string
  key: string
}

/**
 * How the agent→worker binding was decided: an operator `explicit_pin`, an
 * `implicit` binding the control plane picked (e.g. least-loaded), or a `fallback`
 * when the preferred worker was unavailable. Mostly diagnostic — see `reason`.
 */
export type BindingKind = 'explicit_pin' | 'implicit' | 'fallback'

export interface SessionBinding {
  kind: BindingKind
  reason: string
}

/** Response of `POST /internal/computer/sessions/resolve`. */
export interface ResolveSessionResponse {
  agentUid: string
  worker: ResolvedWorker
  binding: SessionBinding
  /** Client certificate material used for worker mTLS. */
  tls: WorkerTlsConfig
}

/**
 * The three workspace mount points, as absolute paths inside the computer. They
 * separate installed library data, the agent's persistent user files, and scratch
 * space, so callers can place output where it belongs instead of guessing paths.
 */
export interface WorkspaceLayout {
  libraryContainers: string
  userFiles: string
  temp: string
}

/** Response of `PUT|GET /v1/sessions/{agent_uid}`. */
export interface SessionResponse {
  sessionId: string
  agentUid: string
  workerId: string
  /** True when the session was freshly created by this call, false when resumed. */
  created: boolean
  workspace: WorkspaceLayout
  createdAt: string
  lastUsedAt: string
}

/** Response of `POST /v1/sessions/{agent_uid}/stop`. */
export interface SessionSnapshot {
  sessionId: string
  agentUid: string
  workerId: string
  stoppedAt: string
}

/** Response of `GET /v1/worker`. */
export interface WorkerInfo {
  workerId: string
  instanceId: string
  version: string
  features: string[]
  capacity: { maxAgents: number; maxCommands: number }
  status: string
}

/**
 * Vercel-compatible parameters for `runCommand`.
 *
 * `detached` returns a live handle immediately instead of waiting for completion.
 * `stdout`/`stderr` opt into live streaming to caller sinks (omit to just collect
 * output afterwards). `timeoutMs` is the worker-side kill budget; `signal` aborts
 * from the client. `sudo` is accepted for shape-compatibility but rejected at call.
 */
export interface RunCommandParams {
  cmd: string
  args?: string[]
  cwd?: string
  env?: Record<string, string>
  sudo?: boolean
  detached?: boolean
  stdout?: WritableStream<Uint8Array>
  stderr?: WritableStream<Uint8Array>
  signal?: AbortSignal
  timeoutMs?: number
}

/** BullX extension: options for the persistent-shell `runShellCommand`. */
export interface RunShellCommandOptions {
  cwd?: string
  env?: Record<string, string>
  /** Execution scope (conversation) owning the persistent shell; omit for the agent-shared shell. */
  shellScope?: string
  stdout?: WritableStream<Uint8Array>
  stderr?: WritableStream<Uint8Array>
  timeoutMs?: number
  signal?: AbortSignal
}

/** A file to upload via `writeFiles`. `content` is buffered before packing. */
export interface ComputerFile {
  path: string
  content: string | Uint8Array | Buffer | Blob
  mode?: number
}

export type CommandStream = 'stdout' | 'stderr'

export interface CommandLog {
  stream: CommandStream
  data: string
}

/**
 * Lifecycle of a command on the worker. `finished` ran to its own exit, `killed`
 * was signalled (by timeout or an explicit kill), `error` failed to run at all.
 * Only `running` is non-terminal.
 */
export type CommandStatus = 'running' | 'finished' | 'killed' | 'error'

/** Worker view of a command (wire shape of the `command` NDJSON field). */
export interface CommandState {
  id: string
  status: CommandStatus
  detached?: boolean
  cwd?: string
  exitCode?: number | null
  pid?: number
}

export type FileKind = 'file' | 'dir' | 'symlink' | 'other'

export interface FileStat {
  path: string
  kind: FileKind
  size: number
  mode: number
  modifiedMs: number
}

export interface DirEntry {
  name: string
  kind: FileKind
  size: number
}

/** Summary of a live tmux terminal: its window count and whether a client is attached. */
export interface TerminalInfo {
  name: string
  windows: number
  attached: boolean
}

/** Options for starting a terminal: initial program, working dir, and pty size. */
export interface StartTerminalParams {
  command?: string
  cwd?: string
  cols?: number
  rows?: number
}

/**
 * One keystroke batch for a terminal. `input` is literal text; `keys` are named
 * keys (e.g. control sequences) for things that have no literal character; `enter`
 * appends a Return. They combine, so text plus a trailing Enter is one call.
 */
export interface SendTerminalParams {
  input?: string
  keys?: string[]
  enter?: boolean
}

export interface TerminalStatus {
  name: string
  // Open union: the listed values are the common outcomes, but `string` keeps the
  // type forward-compatible with new worker statuses without an SDK change.
  status: 'started' | 'exists' | 'sent' | 'killed' | string
}

/** A rendered snapshot of a terminal: `screen` is the visible text grid, not raw bytes. */
export interface TerminalCapture {
  name: string
  screen: string
}
