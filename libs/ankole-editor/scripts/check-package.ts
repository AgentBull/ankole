import { cp, mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'

const project = resolve(import.meta.dir, '..')
const consumer = await mkdtemp(resolve(tmpdir(), 'ankole-editor-consumer-'))
const manifest = JSON.parse(await readFile(resolve(project, 'package.json'), 'utf8'))

async function run(command: string[], cwd: string, env = process.env) {
  const child = Bun.spawn(command, { cwd, env, stdout: 'inherit', stderr: 'inherit' })
  if ((await child.exited) !== 0) throw new Error(`Command failed: ${command.join(' ')}`)
}

console.warn(`Isolated package consumer: ${consumer}`)
try {
  await run(
    ['bun', 'pm', 'pack', '--ignore-scripts', '--filename', resolve(consumer, 'editor.tgz'), '--quiet'],
    project
  )
  await run(
    ['bun', 'pm', 'pack', '--ignore-scripts', '--filename', resolve(consumer, 'uikit.tgz'), '--quiet'],
    resolve(project, '../uikit')
  )
  const dependencies = {
    [manifest.name]: './editor.tgz',
    '@ankole/uikit': './uikit.tgz',
    ...manifest.peerDependencies
  }
  const devDependencies = Object.fromEntries(
    [
      'vite',
      '@vitejs/plugin-react',
      '@tailwindcss/vite',
      'typescript',
      '@types/react',
      '@types/react-dom',
      '@types/bun'
    ].map(name => [name, manifest.devDependencies[name]])
  )
  await writeFile(
    resolve(consumer, 'package.json'),
    JSON.stringify(
      {
        name: 'block-editor-consumer-check',
        private: true,
        type: 'module',
        dependencies,
        devDependencies,
        overrides: { '@ankole/uikit': './uikit.tgz' },
        scripts: { build: 'bun --bun vite build', preview: 'bun --bun vite preview --host 127.0.0.1' }
      },
      null,
      2
    )
  )
  await mkdir(resolve(consumer, 'playground'))
  for (const name of ['embedded.html', 'embedded.tsx', 'embedded.css']) {
    await cp(resolve(project, 'playground', name), resolve(consumer, 'playground', name))
  }
  await mkdir(resolve(consumer, 'public'))
  await cp(resolve(project, 'public', 'resource-preview.html'), resolve(consumer, 'public', 'resource-preview.html'))
  await writeFile(
    resolve(consumer, 'vite.config.ts'),
    `
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: { dedupe: ['react', 'react-dom'] },
  build: { target: ['chrome126', 'firefox153', 'safari17'], cssTarget: ['chrome126', 'firefox153', 'safari17'],
    rolldownOptions: { input: 'playground/embedded.html' } }
})
`
  )
  await writeFile(
    resolve(consumer, 'tsconfig.json'),
    JSON.stringify(
      {
        compilerOptions: {
          target: 'ES2022',
          module: 'ESNext',
          moduleResolution: 'bundler',
          jsx: 'react-jsx',
          strict: true,
          skipLibCheck: true,
          noEmit: true,
          types: ['bun', 'vite/client']
        },
        include: ['playground', 'smoke.ts']
      },
      null,
      2
    )
  )
  // Check the public codecs in Bun. The embedding test runs the editor and PageSession in browsers.
  await writeFile(
    resolve(consumer, 'smoke.ts'),
    `
import { BlockEditor, useEditor, type EditorHandle } from '@ankole/block-editor'
import {
  PageCollaboration,
  PageSession,
  commentRanges,
  commentSelection,
  commitMention,
  insertEmbed,
  insertImage,
  insertMention,
  insertResource,
  mentionField,
  remoteSelections,
  revealComment,
  trackCommentSelection,
  type CommentRange,
  type CommentSelection,
  type EditorHost,
  type MentionCategory,
  type MentionItem,
  type MentionQueryResult,
  type MentionSession,
  type MentionTarget,
  type MountMentionOptions,
  type PageChanges,
  type RemoteSelection,
  type ResourceAttributes,
  type ResourceKind
} from '@ankole/block-editor/editor'
import { parseMarkdown, printMarkdown, printXml, parseXml, resourceContent, resourceText } from '@ankole/block-editor/document'

const mentionTarget: MentionTarget = { page: '019a2b00-0000-7000-8000-000000000001' }
const mentionCategory: MentionCategory = 'all'
const mentionItem: MentionItem = { target: mentionTarget, title: 'Roadmap' }
const mentionResult: MentionQueryResult = { items: [mentionItem], totalAllMatches: 1 }
const resourceKind: ResourceKind = 'bookmark'
const resourceAttrs: ResourceAttributes = { src: 'https://example.com', title: 'Example', view: 'card' }
const commentSel: CommentSelection = { from: 1, to: 4, quote: 'abc' }
const commentRange: CommentRange = { id: '019a2b00-0000-7000-8000-000000000002', from: 1, to: 4 }
const peerSelection: RemoteSelection = { id: 'peer', name: 'Alice', color: '#2469a2', anchor: 1, head: 1 }
const host: EditorHost = {
  resolveAsset: value => value,
  queryMentions: () => mentionResult,
  mountMention: (_target, _container, _options: MountMentionOptions) => () => {},
  requestComment: selection => void selection,
  openComment: ids => void ids
}
const response: PageChanges = { revision: 0, changes: [] }
const verifyHandle = (handle: EditorHandle | null, session: MentionSession | null) => ({ handle, session })
if (
  !BlockEditor ||
  !useEditor ||
  !PageCollaboration ||
  !PageSession ||
  !insertImage ||
  !insertEmbed ||
  !insertMention ||
  !commitMention ||
  !mentionField ||
  !insertResource ||
  !commentSelection ||
  !trackCommentSelection ||
  !commentRanges ||
  !revealComment ||
  !remoteSelections ||
  !host.resolveAsset ||
  !mentionCategory ||
  !resourceKind ||
  !resourceAttrs.src ||
  !commentSel.quote ||
  !commentRange.id ||
  !peerSelection.color ||
  !verifyHandle ||
  !response
) {
  throw new Error('Package export missing')
}
const source = [
  '<future version="0">',
  '  Content **with marks** and <mention page="019a2b00-0000-7000-8000-000000000001" />',
  '</future>',
  '',
  '<bookmark src="https://example.com" title="Example" view="card" />'
].join('\\n')
const page = parseMarkdown(source)
const xml = printXml(page)
if (printXml(parseXml(xml)) !== xml) throw new Error('Package XML mismatch')
if (printXml(parseMarkdown(printMarkdown(page))) !== xml) throw new Error('Package Markdown mismatch')
const commentXml = '<page><p><comment ids="019a2b00-0000-7000-8000-000000000002">Anchored</comment></p></page>'
if (printXml(parseXml(commentXml)) !== commentXml) throw new Error('Package comment anchor XML mismatch')
const bookmarkNode = page.children[1]
if (
  !bookmarkNode ||
  !('name' in bookmarkNode) ||
  resourceContent(bookmarkNode)?.src !== 'https://example.com' ||
  !resourceText(bookmarkNode)
) {
  throw new Error('Package resource helper mismatch')
}
`
  )
  await run(['bun', 'install'], consumer)
  await run(['bun', 'check', '--noEmit'], consumer)
  await run(['bun', 'smoke.ts'], consumer)
  await run(['bun', 'run', 'build'], consumer)
  await run(['bun', 'run', 'test:e2e', 'e2e/embedding.spec.ts'], project, {
    ...process.env,
    E2E_CONSUMER_ROOT: consumer,
    E2E_PREVIEW: '1'
  })
  await rm(consumer, { recursive: true })
  console.warn('Package installation, public types, codecs and three-browser embedding passed.')
} catch (error) {
  console.error(`Consumer files retained for inspection: ${consumer}`)
  throw error
}
