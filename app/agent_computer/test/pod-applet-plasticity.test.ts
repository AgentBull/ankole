import { expect, test } from 'bun:test'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { annotateAppletSource, buildApplet, initializeApplet } from '../src/cli/pod/pod-applet'
import { commandFromArgs } from '../src/cli/pod/pod-cli'

test('source markers preserve JSX line numbers and do not rewrite text or expression strings', () => {
  const source = `const text = '<span>unrelated</span>'\nexport default () => <>\n  <div>{text}<span title={'<div>'}>label</span></div>\n  <input {...props} />\n  <input {...props} / >\n</>`
  const result = annotateAppletSource(source, 'src/OrderList.tsx')
  expect(result).toContain(`const text = '<span>unrelated</span>'`)
  expect(result).toContain('<div data-ankole-src="src/OrderList.tsx:3">')
  expect(result).toContain(`<span title={'<div>'} data-ankole-src="src/OrderList.tsx:3">`)
  expect(result).toContain('<input {...props}  data-ankole-src="src/OrderList.tsx:4"/>')
  expect(result).toContain('<input {...props}  data-ankole-src="src/OrderList.tsx:5"/ >')
  expect(() => annotateAppletSource(result, 'src/OrderList.tsx')).not.toThrow()
  expect(result.split('\n')).toHaveLength(source.split('\n').length)
})

test('an Applet imports host icons and emits source coordinates in its actual bundle', async () => {
  const root = await mkdtemp(join(tmpdir(), 'applet-icons-'))
  try {
    const directory = join(root, 'app')
    await initializeApplet(directory)
    await writeFile(
      join(directory, 'src/main.tsx'),
      `import {defineApplet} from '@ankole/applet-sdk'\nimport {AddRegular} from '@ankole/uikit/icons'\nexport const provider = defineApplet(()=><main><AddRegular/>Ready</main>)`
    )
    await buildApplet(directory)
    const script = await readFile(join(directory, 'dist/main.js'), 'utf8')
    expect(script).toContain('@ankole/uikit/icons')
    expect(script).toContain('src/main.tsx:3')
    expect(script).not.toContain('@fluentui/react-icons')
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('draft operations preserve the exact reviewed ID and inspection props', async () => {
  expect(
    await commandFromArgs(['applet', 'promote', 'page', '{"expected_draft_id":"draft-a","base_revision":3}'])
  ).toMatchObject({
    operation: 'applets.promote_draft',
    params: { id: 'page', expected_draft_id: 'draft-a', base_revision: 3 }
  })
  expect(
    await commandFromArgs([
      'applet',
      'inspect',
      'page',
      '--draft-id',
      'draft-a',
      '--props',
      '{"region":"华东"}',
      '--wait-ms',
      '0'
    ])
  ).toMatchObject({
    operation: 'applets.inspect_ticket',
    params: { id: 'page', draft_id: 'draft-a', embed_props: { region: '华东' } },
    inspect_options: { waitMs: 0 }
  })
  expect(
    await commandFromArgs(['applet', 'publish', 'app', '{"id":"page","base_revision":3,"draft":true}'])
  ).toMatchObject({
    operation: 'applets.publish',
    params: { id: 'page', base_revision: 3, draft: true },
    publish_directory: 'app'
  })
})
