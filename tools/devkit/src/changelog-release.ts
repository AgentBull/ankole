import { dirname } from 'node:path'
import { mkdir } from 'node:fs/promises'

const versionHeadingPattern =
  /^## Version ((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)) \((\d{4}-\d{2}-\d{2})\)$/

export type ChangelogRelease = {
  version: string
  date: string
  notes: string
}

export function currentChangelogRelease(source: string): ChangelogRelease {
  const lines = source.replaceAll('\r\n', '\n').split('\n')
  const headingIndex = lines.findIndex(line => line.startsWith('## '))
  if (headingIndex === -1) throw new Error('CHANGELOG.md has no level-two version heading')

  const heading = lines[headingIndex]!
  const match = versionHeadingPattern.exec(heading)
  if (!match) {
    throw new Error('the first level-two CHANGELOG.md heading must be "## Version MAJOR.MINOR.PATCH (YYYY-MM-DD)"')
  }

  const [, version, date] = match
  if (!isCalendarDate(date!)) throw new Error(`CHANGELOG.md version ${version} has an invalid date`)

  const nextHeadingOffset = lines.slice(headingIndex + 1).findIndex(line => line.startsWith('## '))
  const notesEnd = nextHeadingOffset === -1 ? lines.length : headingIndex + 1 + nextHeadingOffset
  const notesLines = lines.slice(headingIndex + 1, notesEnd)

  while (notesLines[0]?.trim() === '') notesLines.shift()
  while (notesLines.at(-1)?.trim() === '') notesLines.pop()
  if (notesLines.length === 0) throw new Error(`CHANGELOG.md version ${version} has no release notes`)

  return {
    version: version!,
    date: date!,
    notes: `${notesLines.join('\n')}\n`
  }
}

function isCalendarDate(value: string): boolean {
  const date = new Date(`${value}T00:00:00Z`)
  return !Number.isNaN(date.valueOf()) && date.toISOString().slice(0, 10) === value
}

async function runCli(args: string[]): Promise<void> {
  const [command, changelogPath, notesOutput] = args
  if (command !== 'extract' || !changelogPath || !notesOutput || args.length !== 3) {
    throw new Error('usage: changelog-release.ts extract CHANGELOG.md RELEASE_NOTES.md')
  }

  const release = currentChangelogRelease(await Bun.file(changelogPath).text())
  await mkdir(dirname(notesOutput), { recursive: true })
  await Bun.write(notesOutput, release.notes)
  process.stdout.write(`${release.version}\n`)
}

if (import.meta.main) {
  await runCli(process.argv.slice(2))
}
