/** Build revision-specific CommonJS scripts and Tailwind CSS for the browser check. */
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import path from 'node:path'
import postcss from 'postcss'
import tailwind from '@tailwindcss/postcss'
import { buildApplet } from '../../../agent_computer/src/cli/pod/pod-cli'

const directory = import.meta.dir
await buildApplet(path.join(directory, 'published'))
const output = path.join(directory, 'public/dist')
const stylesheet = path.join(directory, 'applet/applet.css')
const css = await postcss([tailwind()]).process(await readFile(stylesheet, 'utf8'), { from: stylesheet })

await rm(output, { recursive: true, force: true })
for (const revision of ['revision-1', 'revision-2', 'broken']) {
  const target = path.join(output, revision)
  await mkdir(target, { recursive: true })
  const result = await Bun.build({
    entrypoints: [path.join(directory, 'applet/applet.tsx')],
    outdir: target,
    target: 'browser',
    format: 'cjs',
    external: ['react', 'react/jsx-runtime', 'react/jsx-dev-runtime', 'react-dom', 'react-dom/client', '@ankole/uikit'],
    naming: 'applet.js',
    define: {
      BUILD_REVISION: JSON.stringify(revision),
      FAIL_RENDER: String(revision === 'broken')
    }
  })
  if (!result.success) throw new AggregateError(result.logs, `Applet build failed: ${revision}`)
  await writeFile(
    path.join(target, 'applet.css'),
    `${css.css}\n.applet-title { font-size: ${revision === 'revision-2' ? '24px' : '16px'}; }`
  )
  await writeFile(
    path.join(target, 'applet.html'),
    '<!doctype html><html><head><link rel="stylesheet" href="./applet.css"><script src="./applet.js"></script></head><body></body></html>'
  )
}
