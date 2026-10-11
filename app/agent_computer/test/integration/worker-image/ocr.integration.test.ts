import { afterAll, beforeAll, describe, expect, test } from 'bun:test'
import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { join } from 'node:path'

const ocrScript = '/repo/app/library/skills/ocr/scripts/ocr.py'

describe('OCR Skill on the Worker', () => {
  let agentHome: string
  let workspaceRoot: string
  let imagePath: string

  beforeAll(() => {
    agentHome = mkdtempSync('/agents/ankole-ocr-')
    workspaceRoot = join(agentHome, 'jobs', 'job-1')
    imagePath = join(workspaceRoot, 'ocr-smoke.png')
    mkdirSync(workspaceRoot, { recursive: true })

    const result = spawnSync(
      '/usr/local/bin/python',
      [
        '-c',
        [
          'from pathlib import Path',
          'from PIL import Image, ImageDraw, ImageFont',
          'font_path = sorted(Path("/usr/share/fonts/truetype/ibm-plex-sans-sc").glob("*.ttf"))[0]',
          'image = Image.new("RGB", (720, 130), "white")',
          'draw = ImageDraw.Draw(image)',
          'draw.text((30, 30), "Ankole OCR 2026", font=ImageFont.truetype(str(font_path), 56), fill="black")',
          'image.save(Path(__import__("sys").argv[1]))'
        ].join('\n'),
        imagePath
      ],
      { encoding: 'utf8', timeout: 10_000 }
    )

    expect(result.status, `${result.stderr}\n${result.stdout}`).toBe(0)
  })

  afterAll(() => {
    if (agentHome) rmSync(agentHome, { recursive: true, force: true })
  })

  test('runs RapidOCR with OpenVINO', () => {
    const result = spawnSync('python', [ocrScript, imagePath], {
      cwd: workspaceRoot,
      env: {
        PATH: '/usr/local/bin:/usr/bin:/bin',
        HOME: agentHome,
        LANG: 'C.UTF-8'
      },
      encoding: 'utf8',
      timeout: 30_000
    })

    expect(result.status, `${result.stderr}\n${result.stdout}`).toBe(0)
    expect(result.stdout).toContain('OCR')
    expect(result.stdout).toContain('2026')
  }, 30_000)
})
