// Shared result contract for every `analyze` check module.

export type ExitCode = 0 | 1 | 2

export interface Finding {
  category: string
  file: string
  line: number
  kind: string
  specifier: string
  resolved: string
  reason: string
}

export interface CheckResult {
  /** Subcommand name, e.g. 'cycles'. */
  check: string
  /** True when the check passed (no violations). */
  ok: boolean
  /** 0 pass, 1 violations, 2 tool/infra error. */
  exitCode: ExitCode
  /** One-line summary for the `all` aggregate table. */
  summary: string
  /** Full human-readable report (printed unless --json). */
  human: string
  /** Machine-readable payload (printed with --json). */
  json: unknown
}

export interface CheckOptions {
  json?: boolean
}
