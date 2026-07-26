/*
 * Guards motion failures that are invisible in development and silent in production.
 *
 * Two happened. The CSS minifier folded an `animation` shorthand together with an
 * adjacent `animation-timeline` into one declaration every browser rejects, so the
 * entrance never ran and the built page just looked never-animated. Later the scroll
 * timeline itself proved to be the defect: Firefox and older Safari drop
 * `animation-timeline` whole, so the entrance now rides an observer and a class, and
 * content may be hidden only behind the `js-reveal` gate that script applies.
 */
import { readFile, readdir } from 'node:fs/promises'
import { join } from 'node:path'

const ASSET_DIR = join(import.meta.dirname, '..', 'dist', '_astro')

const files = (await readdir(ASSET_DIR)).filter(name => name.endsWith('.css'))
const css = (await Promise.all(files.map(name => readFile(join(ASSET_DIR, name), 'utf8')))).join('\n')

const failures = []

if (/animation:[^;}]*\bview\(/.test(css)) {
  failures.push('`animation` shorthand carries view(); the declaration is invalid and will not run')
}

if (/\banimation-timeline\b/.test(css)) {
  failures.push('a scroll timeline is back; Firefox and older Safari drop it, so the entrance dies there')
}

if (!css.includes('.js-reveal')) {
  failures.push('the js-reveal gate is gone; either entrances are dead or content hides without JavaScript')
}

// Any rule that hides a reveal target must carry the gate in every selector of its list.
for (const match of css.matchAll(/([^{}]+)\{[^}]*opacity:\s*0[^}]*\}/g)) {
  const selectors = match[1].split(',')
  for (const selector of selectors) {
    if (selector.includes('[data-reveal]') && !selector.includes('js-reveal')) {
      failures.push(`ungated hide rule: \`${selector.trim()}\` — content vanishes for readers without JavaScript`)
    }
  }
}

if (failures.length > 0) {
  console.error('Motion CSS check failed:')
  for (const failure of failures) console.error(`  - ${failure}`)
  process.exit(1)
}

process.stdout.write(`Motion CSS check passed across ${files.length} stylesheet(s).\n`)
