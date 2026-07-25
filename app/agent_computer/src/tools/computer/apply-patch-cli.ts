/**
 * `apply_patch` command-line shim for the Codex Job runtime.
 *
 * Codex models edit files either through the `apply_patch` tool or by piping the
 * same V4A envelope into an `apply_patch` command from the shell. The second form
 * reaches a real shell, so the command must exist in the worker image; without it
 * the model loses a turn to `command not found` and then invents its own patcher.
 *
 * The envelope dialect stays owned by `v4a.ts` and the hunk-location rules stay
 * owned by `fuzzy-match.ts`. This file only adds the filesystem side that the
 * `patch` tool cannot supply: it runs outside the worker computer session, and it
 * executes Delete and the `*** Move to:` rename.
 */

import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { findScopedFuzzyMatch } from './fuzzy-match'
import { parseV4APatch, type V4AHunk } from './v4a'

const USAGE = `usage: apply_patch [PATCH]

Applies a V4A patch envelope. Reads the envelope from PATCH when given, and from
standard input otherwise.

  *** Begin Patch
  *** Update File: path/to/file
  *** Move to: path/to/renamed
  @@ optional context anchor
  -removed line
  +added line
  *** Add File: path/to/new
  +content
  *** Delete File: path/to/old
  *** End Patch
`

/** Text-file conventions captured before an edit so the write can restore them. */
interface FileEncoding {
  hasBom: boolean
  lineEnding: '\n' | '\r\n'
}

/** One file's staged content, kept normalized (LF, no BOM) until the flush. */
type PlannedWrite = { encoding: FileEncoding; text: string }

export function runApplyPatch(argv: string[], stdin: () => string): { text: string; ok: boolean } {
  const [first] = argv
  if (first === '--help' || first === '-h') return { ok: true, text: USAGE }

  const patch = first ?? stdin()
  if (patch.trim().length === 0) return { ok: false, text: 'apply_patch: empty patch' }

  const operations = parseV4APatch(patch)
  if (operations.length === 0) return { ok: false, text: 'apply_patch: no operations parsed from patch' }

  // Every operation is staged first, so a hunk that fails to match aborts the batch
  // before any file is touched. Staging also lets one envelope operate on a file it
  // created or moved earlier, which reading the disk directly could not see.
  const planned = new Map<string, PlannedWrite>()
  const removals = new Set<string>()
  const report: string[] = []
  const staged = (path: string) => planned.has(path) || (existsSync(path) && !removals.has(path))

  try {
    for (const operation of operations) {
      if (operation.kind === 'add') {
        const path = resolve(operation.path)
        if (staged(path)) throw new Error(`file already exists: ${operation.path}`)
        removals.delete(path)
        planned.set(path, {
          encoding: { hasBom: false, lineEnding: '\n' },
          text: withTrailingNewline(operation.content)
        })
        report.push(`A ${operation.path}`)
        continue
      }
      if (operation.kind === 'delete') {
        const path = resolve(operation.path)
        if (!staged(path)) throw new Error(`file not found: ${operation.path}`)
        planned.delete(path)
        removals.add(path)
        report.push(`D ${operation.path}`)
        continue
      }
      const path = resolve(operation.path)
      if (!staged(path)) throw new Error(`file not found: ${operation.path}`)
      const current = planned.get(path) ?? readPlannedWrite(path, operation.path)
      const edited = { encoding: current.encoding, text: applyHunks(current.text, operation.hunks, operation.path) }
      if (operation.moveTo === undefined) {
        planned.set(path, edited)
        report.push(`M ${operation.path}`)
        continue
      }
      // An Update that carries `*** Move to:` edits and renames in one operation, so
      // the edited content lands at the destination and the source disappears.
      const destination = resolve(operation.moveTo)
      if (staged(destination)) throw new Error(`file already exists: ${operation.moveTo}`)
      planned.delete(path)
      planned.set(destination, edited)
      if (existsSync(path)) removals.add(path)
      report.push(`M ${operation.path} -> ${operation.moveTo}`)
    }
  } catch (error) {
    return { ok: false, text: `apply_patch: ${error instanceof Error ? error.message : String(error)}` }
  }

  for (const [path, write] of planned) {
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, restore(write.encoding, write.text))
  }
  for (const path of removals) rmSync(path, { force: true })

  return { ok: true, text: `Success. Updated the following files:\n${report.join('\n')}` }
}

/** Loads an existing file into the staging map, keeping its encoding for the write. */
function readPlannedWrite(path: string, reported: string): PlannedWrite {
  if (!statSync(path).isFile()) throw new Error(`not a regular file: ${reported}`)
  const buffer = readFileSync(path)
  return { encoding: readEncoding(buffer), text: normalize(buffer) }
}

/** Locates each hunk against the running text and splices in its replacement. */
function applyHunks(text: string, hunks: V4AHunk[], path: string): string {
  let current = text
  let cursor = 0
  for (const hunk of hunks) {
    const search = hunk.search.replace(/\r\n/g, '\n')
    const replacement = hunk.replace.replace(/\r\n/g, '\n')
    const located = findScopedFuzzyMatch(current, search, {
      ...(hunk.context === undefined ? {} : { context: hunk.context }),
      ...(hunk.endOfFile === undefined ? {} : { endOfFile: hunk.endOfFile }),
      start: cursor
    })
    if (!located) throw new Error(`patch hunk did not match in ${path}; re-read the file and include longer context`)
    current = `${current.slice(0, located.start)}${replacement}${current.slice(located.end)}`
    cursor = located.start + replacement.length
  }
  return current
}

function readEncoding(buffer: Buffer): FileEncoding {
  const text = buffer.toString('utf8')
  return { hasBom: text.startsWith('﻿'), lineEnding: text.includes('\r\n') ? '\r\n' : '\n' }
}

function normalize(buffer: Buffer): string {
  return buffer.toString('utf8').replace(/^﻿/, '').replace(/\r\n/g, '\n')
}

function restore(encoding: FileEncoding, text: string): string {
  const body = encoding.lineEnding === '\r\n' ? text.replace(/\n/g, '\r\n') : text
  return encoding.hasBom ? `﻿${body}` : body
}

function withTrailingNewline(content: string): string {
  return content.length === 0 || content.endsWith('\n') ? content : `${content}\n`
}

if (import.meta.main) {
  const result = runApplyPatch(process.argv.slice(2), () => readFileSync(0, 'utf8'))
  process.stdout.write(`${result.text}\n`)
  if (!result.ok) process.exit(1)
}
