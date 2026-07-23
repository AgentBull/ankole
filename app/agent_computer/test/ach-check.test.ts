import { describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

type Matrix = {
  hypotheses: Array<{ id: string; statement: string }>
  rows: Array<{
    id: string
    proposition: string
    source_paths?: string[]
    analytical_basis?: string
    relations: Record<string, { relation: string; rationale: string }>
  }>
  judgment: {
    hypothesis_refs: string[]
    confidence_basis: string
    confidence_limits: string[]
  }
}

const scriptPath = join(
  import.meta.dir,
  '..',
  '..',
  'library',
  'agent-plugins',
  'deep-research',
  'workspace-template',
  'tools',
  'ach_check.ts'
)

describe('@ankole/agent-computer Deep Research ACH structure check', () => {
  it('accepts semantic nonsense when the finite structure and local paths are valid', async () => {
    const root = workspace()

    try {
      writeMatrix(root, validMatrix())

      const result = await runCheck(root)

      expect(result).toEqual({
        exitCode: 0,
        stdout: 'No ACH structure or local source-path issues found.\n',
        stderr: ''
      })
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rejects empty and duplicate hypothesis or row IDs', async () => {
    const root = workspace()
    const matrix = validMatrix()
    matrix.hypotheses.push({ id: 'H1', statement: 'The duplicate moon is equally implausible.' })
    matrix.rows.push({ ...structuredClone(matrix.rows[0]!), id: ' ' })
    writeMatrix(root, matrix)

    try {
      const result = await runCheck(root)

      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('duplicate hypothesis id: H1')
      expect(result.stderr).toContain('row[2] id must be a non-empty string')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rejects incomplete matrix keys, unknown keys, invalid relations, and empty rationales', async () => {
    const root = workspace()
    const matrix = validMatrix()
    matrix.hypotheses.push({ id: 'toString', statement: 'An inherited property is not a matrix relation.' })
    delete matrix.rows[0]!.relations.H6
    matrix.rows[0]!.relations.H7 = { relation: 'expected', rationale: 'An extra hypothesis appeared.' }
    matrix.rows[0]!.relations.H1 = { relation: 'supports', rationale: 'This uses the wrong question.' }
    matrix.rows[0]!.relations.H2 = { relation: 'compatible', rationale: ' ' }
    writeMatrix(root, matrix)

    try {
      const result = await runCheck(root)

      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('row E1 is missing relation for H6')
      expect(result.stderr).toContain('row E1 is missing relation for toString')
      expect(result.stderr).toContain('row E1 has relation for unknown hypothesis H7')
      expect(result.stderr).toContain('row E1 relation H1 has an invalid relation')
      expect(result.stderr).toContain('row E1 relation H2 requires a non-empty rationale')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('requires a source path or analytical basis and checks referenced files', async () => {
    const root = workspace()
    const matrix = validMatrix()
    matrix.rows[0]!.source_paths = []
    matrix.rows[1]!.analytical_basis = ' '
    matrix.rows.push(rowWithSource('E3', 'sources/missing.md'))
    writeMatrix(root, matrix)

    try {
      const result = await runCheck(root)

      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('row E1 requires a source path or analytical_basis')
      expect(result.stderr).toContain('row E2 requires a source path or analytical_basis')
      expect(result.stderr).toContain('row E3 source_paths[0] does not exist: sources/missing.md')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rejects paths outside sources and symbolic-link escapes', async () => {
    const root = workspace()
    const matrix = validMatrix()
    writeFileSync(join(root, 'outside.md'), 'Outside the source inventory.\n')
    symlinkSync('../outside.md', join(root, 'sources', 'escape.md'))
    matrix.rows.push(rowWithSource('E3', '../outside.md'))
    matrix.rows.push(rowWithSource('E4', join(root, 'sources', 'implausible.md')))
    matrix.rows.push(rowWithSource('E5', 'sources/escape.md'))
    writeMatrix(root, matrix)

    try {
      const result = await runCheck(root)

      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('row E3 source_paths[0] must be a safe project-relative path inside sources')
      expect(result.stderr).toContain('row E4 source_paths[0] must be a safe project-relative path inside sources')
      expect(result.stderr).toContain('row E5 source_paths[0] escapes sources through a symbolic link')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('rejects empty, duplicate, and unknown judgment hypothesis references', async () => {
    const root = workspace()
    const matrix = validMatrix()
    matrix.judgment.hypothesis_refs = ['H1', 'H1', 'H7', ' ']
    writeMatrix(root, matrix)

    try {
      const result = await runCheck(root)

      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('duplicate judgment hypothesis reference: H1')
      expect(result.stderr).toContain('judgment references unknown hypothesis H7')
      expect(result.stderr).toContain('judgment.hypothesis_refs[3] must be a non-empty string')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('requires confidence basis and limits and rejects final confidence fields', async () => {
    const root = workspace()
    const matrix = validMatrix() as Matrix & {
      judgment: Matrix['judgment'] & { final_confidence?: string }
    }
    matrix.judgment.confidence_basis = ' '
    matrix.judgment.confidence_limits = ['Known limit.', ' ']
    matrix.judgment.final_confidence = 'high'
    writeMatrix(root, matrix)

    try {
      const result = await runCheck(root)

      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain(
        'judgment.final_confidence cannot store final confidence; put final confidence in report/report.md'
      )
      expect(result.stderr).toContain('judgment.confidence_basis must be a non-empty string')
      expect(result.stderr).toContain('judgment.confidence_limits[1] must be a non-empty string')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

function workspace(): string {
  const root = mkdtempSync(join(tmpdir(), 'ankole-ach-check-'))
  mkdirSync(join(root, 'sources'))
  writeFileSync(join(root, 'sources', 'implausible.md'), 'The moon filed a cheese invoice.\n')
  return root
}

function validMatrix(): Matrix {
  return {
    hypotheses: [
      { id: 'H1', statement: 'The moon is cheese.' },
      { id: 'H2', statement: 'The moon is a filing cabinet.' },
      { id: 'H3', statement: 'The moon is a contract.' },
      { id: 'H4', statement: 'The moon is a forgotten invoice.' },
      { id: 'H5', statement: 'The moon is a blue umbrella.' },
      { id: 'H6', statement: 'The moon is an impatient librarian.' }
    ],
    rows: [
      {
        id: 'E1',
        proposition: 'The moon filed a cheese invoice.',
        source_paths: ['sources/implausible.md'],
        relations: relations()
      },
      {
        id: 'E2',
        proposition: 'Purple is louder than Tuesday.',
        analytical_basis: 'A deliberately meaningless premise for the structure-only boundary test.',
        relations: relations('compatible')
      }
    ],
    judgment: {
      hypothesis_refs: ['H1', 'H2', 'H3', 'H4', 'H5', 'H6'],
      confidence_basis: 'The paperwork smells faintly of cheddar.',
      confidence_limits: ['No semantic statement in this fixture is meaningful.']
    }
  }
}

function rowWithSource(id: string, sourcePath: string): Matrix['rows'][number] {
  return {
    id,
    proposition: 'A path is present.',
    source_paths: [sourcePath],
    relations: relations()
  }
}

function relations(fixed?: string): Record<string, { relation: string; rationale: string }> {
  const names = ['expected', 'compatible', 'tension', 'contradicts', 'unknown', 'not_applicable']
  return Object.fromEntries(
    names.map((relation, index) => [
      `H${index + 1}`,
      {
        relation: fixed ?? relation,
        rationale: 'This rationale is structurally present and semantically meaningless.'
      }
    ])
  )
}

function writeMatrix(root: string, matrix: Matrix): void {
  writeFileSync(join(root, 'competing-hypotheses.yaml'), JSON.stringify(matrix, null, 2))
}

async function runCheck(root: string) {
  const process = Bun.spawn(['bun', scriptPath], { cwd: root, stdout: 'pipe', stderr: 'pipe' })
  const [exitCode, stdout, stderr] = await Promise.all([
    process.exited,
    new Response(process.stdout).text(),
    new Response(process.stderr).text()
  ])
  return { exitCode, stdout, stderr }
}
