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

if (!css.includes('.js-reveal')) {
  failures.push('the js-reveal gate is gone; either entrances are dead or content hides without JavaScript')
}

// Shared components have their own scroll effects. Check the declarations that style page entrances.
for (const [, selectorList, declarations] of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
  for (const selector of selectorList.split(',')) {
    if (!/\[data-reveal(?:=["']?(?:rise|wipe)["']?)?\]/.test(selector)) continue
    if (/\banimation-timeline\s*:/.test(declarations)) {
      failures.push(`the entrance on \`${selector.trim()}\` depends on a scroll timeline`)
    }
    if (/\bopacity:\s*0(?:[;}!\s]|$)/.test(declarations) && !selector.includes('js-reveal')) {
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
