import { dirname } from 'node:path'
import { mkdir } from 'node:fs/promises'

const versionHeadingPattern =
  /^## Version ((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:alpha|beta|rc)(?:\.(?:0|[1-9][0-9]*))?)?) \((\d{4}-\d{2}-\d{2})\)$/
const releaseVersionPattern =
  /^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(alpha|beta|rc)(?:\.(?:0|[1-9][0-9]*))?)?$/

export type ChangelogRelease = {
  version: string
  date: string
  notes: string
}

export type ReleaseVersionPolicy = {
  isPrerelease: boolean
  usesCanary: boolean
}

export function releaseVersionPolicy(version: string): ReleaseVersionPolicy {
  const match = releaseVersionPattern.exec(version)
  if (!match) throw new Error(`unsupported release version: ${version}`)

  const prereleaseKind = match[1]
  return {
    isPrerelease: prereleaseKind !== undefined,
    usesCanary: prereleaseKind === 'alpha' || prereleaseKind === 'beta'
  }
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
  const [command, firstArgument, secondArgument] = args

  if (command === 'classify' && firstArgument && args.length === 2) {
    const policy = releaseVersionPolicy(firstArgument)
    process.stdout.write(`${policy.isPrerelease} ${policy.usesCanary}\n`)
    return
  }

  if (command !== 'extract' || !firstArgument || !secondArgument || args.length !== 3) {
    throw new Error('usage: changelog-release.ts extract CHANGELOG.md RELEASE_NOTES.md | classify VERSION')
  }

  const release = currentChangelogRelease(await Bun.file(firstArgument).text())
  await mkdir(dirname(secondArgument), { recursive: true })
  await Bun.write(secondArgument, release.notes)
  process.stdout.write(`${release.version}\n`)
}

if (import.meta.main) {
  await runCli(process.argv.slice(2))
}
