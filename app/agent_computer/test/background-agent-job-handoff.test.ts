import { describe, expect, it } from 'bun:test'
import {
  BACKGROUND_AGENT_JOB_HANDOFF_MAX_PATH_BYTES,
  BACKGROUND_AGENT_JOB_HANDOFF_MAX_PATHS,
  backgroundAgentJobPathHandoff,
  boundedBackgroundAgentJobPaths
} from '../src/core/background-agent-job-handoff'
import { boundedFilesChangedFromCodexDiff } from '../src/core/codex-runner/protocol'

describe('@ankole/agent-computer BackgroundAgentJob path handoff', () => {
  it('bounds hostile path sets by count and serialized bytes without hiding the total', () => {
    const manyPaths = Array.from({ length: 50_000 }, (_, index) => `/agents/agent-1/user-files/report-${index}.pdf`)
    const countBounded = backgroundAgentJobPathHandoff({
      total_count: manyPaths.length,
      paths: manyPaths,
      truncated: false
    })

    expect(countBounded).toMatchObject({ total_count: 50_000, truncated: true })
    expect(countBounded?.paths).toHaveLength(BACKGROUND_AGENT_JOB_HANDOFF_MAX_PATHS)
    expect(countBounded?.paths[0]).toBe(manyPaths[0])
    expect(countBounded?.paths).not.toContain(manyPaths.at(-1))

    const longPaths = Array.from(
      { length: 8 },
      (_, index) => `/agents/agent-1/user-files/${String(index).padStart(2, '0')}-${'x'.repeat(3_000)}.pdf`
    )
    const byteBounded = boundedBackgroundAgentJobPaths(longPaths)

    expect(byteBounded.total_count).toBe(longPaths.length)
    expect(byteBounded.paths.length).toBeGreaterThan(0)
    expect(byteBounded.paths.length).toBeLessThan(longPaths.length)
    expect(new TextEncoder().encode(JSON.stringify(byteBounded.paths)).byteLength).toBeLessThanOrEqual(
      BACKGROUND_AGENT_JOB_HANDOFF_MAX_PATH_BYTES
    )
    expect(byteBounded.truncated).toBe(true)
  })

  it('counts aggregate diff file blocks without retaining old rename paths', () => {
    const handoff = boundedFilesChangedFromCodexDiff(
      '--- a/old-name.md\r\n+++ b/new-name.md\r\n--- a/deleted.md\r\n+++ /dev/null\r\n'
    )

    expect(handoff).toEqual({
      total_count: 2,
      paths: ['deleted.md', 'new-name.md'],
      truncated: false
    })
  })
})
