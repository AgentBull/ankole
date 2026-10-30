import { BlockEditor, useEditor } from '@ankole/block-editor'
import {
  PageSession,
  PageCollaboration,
  insertImage,
  toggleFormat,
  undo,
  type Editor,
  type EditorHost,
  type EditorLabels
} from '@ankole/block-editor/editor'
import { StrictMode, useEffect, useMemo, useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import './embedded.css'

function HostToolbar() {
  const editor = useEditor()
  return (
    <div className="editor-toolbar" aria-label="Host toolbar">
      <button onMouseDown={event => event.preventDefault()} onClick={() => toggleFormat(editor, 'strong')}>
        Host bold
      </button>
      <button onClick={() => undo(editor)}>Undo second</button>
      <button
        onMouseDown={event => event.preventDefault()}
        onClick={() =>
          insertImage(editor, { src: 'ankole:asset/image', alt: 'Image description', title: 'Image title' })
        }>
        Insert image
      </button>
      <button
        onMouseDown={event => event.preventDefault()}
        onClick={() => insertImage(editor, { src: `ankole:asset/${'a'.repeat(8 * 1024 * 1024)}`, alt: 'Too large' })}>
        Insert oversized image
      </button>
    </div>
  )
}

function EmbeddedHost() {
  const [render, setRender] = useState(0)
  const [visible, setVisible] = useState(true)
  const [readOnly, setReadOnly] = useState(false)
  const [sources, setSources] = useState({ first: '', second: '' })
  const [lifecycle, setLifecycle] = useState({ ready: 0, disposed: 0 })
  const [observedRender, setObservedRender] = useState(0)
  const [revision, setRevision] = useState(0)
  const [hostSource, setHostSource] = useState('')
  const [target, setTarget] = useState<'first' | 'second'>('second')
  const [writeResult, setWriteResult] = useState('')
  const [toolbarVisible, setToolbarVisible] = useState(true)
  const [labels, setLabels] = useState<Partial<EditorLabels>>()
  const [collaboration, setCollaboration] = useState({ revision: 0, pending: false })
  const [commentEvent, setCommentEvent] = useState('')
  const [agentEvent, setAgentEvent] = useState('')
  const [acceptedFiles, setAcceptedFiles] = useState('')
  const [resolvedComments, setResolvedComments] = useState<readonly string[]>([])
  const [openedPage, setOpenedPage] = useState('')
  const mentionCatalog = useMemo(
    () => [
      {
        target: { page: '019a2b00-0000-7000-8000-000000000101' } as const,
        category: 'page' as const,
        title: 'Product Roadmap',
        subtitle: 'Product Space · 2m ago'
      },
      {
        target: { page: '019a2b00-0000-7000-8000-000000000102' } as const,
        category: 'page' as const,
        title: '季度复盘报告',
        subtitle: '公司空间 · 昨天'
      },
      {
        target: { principal: 'usr_alice_001' } as const,
        category: 'principal' as const,
        title: 'Alice Chen',
        subtitle: 'Staff Designer · alice@ankole.test'
      },
      {
        target: { principal: 'agt_research_001' } as const,
        category: 'principal' as const,
        title: 'Research Agent',
        badge: 'Agent',
        subtitle: '@researcher · Market synthesis'
      }
    ],
    []
  )
  const host = useMemo<EditorHost>(
    () => ({
      requestComment: selection => setCommentEvent(JSON.stringify(selection)),
      askAgent: selection => setAgentEvent(JSON.stringify(selection)),
      acceptFiles: async files => {
        if (files.some(file => file.name.startsWith('reject'))) throw new Error('Host rejected the files')
        setAcceptedFiles(files.map(file => file.name).join(' '))
      },
      openComment: ids => setCommentEvent(ids.join(' ')),
      openPage: id => setOpenedPage(id),
      resolveAsset: () => 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
      queryMentions({ query, category }) {
        const needle = query.trim().toLowerCase()
        const match = (entry: (typeof mentionCatalog)[number]) =>
          !needle ||
          entry.title.toLowerCase().includes(needle) ||
          (entry.subtitle?.toLowerCase().includes(needle) ?? false)
        const allMatches = mentionCatalog.filter(match)
        const items = category === 'all' ? allMatches : allMatches.filter(entry => entry.category === category)
        return {
          items: items.map(({ target, category: itemCat, title, subtitle, badge }) => ({
            target,
            title,
            subtitle,
            badge,
            section: category === 'all' ? (itemCat === 'page' ? '页面' : '主体') : undefined,
            sectionCategory: category === 'all' ? itemCat : undefined
          })),
          totalAllMatches: allMatches.length
        }
      },
      mountMention(target, container, options) {
        const entry = mentionCatalog.find(item =>
          'page' in target
            ? 'page' in item.target && item.target.page === target.page
            : 'principal' in item.target && item.target.principal === target.principal
        )
        if ('page' in target) {
          const link = document.createElement('a')
          link.href = `/p/${target.page}`
          link.textContent = entry?.title ?? 'Restricted page'
          link.onclick = event => {
            if (!event.metaKey && !event.ctrlKey && options.openPage) {
              event.preventDefault()
              options.openPage(target.page)
            }
          }
          container.replaceChildren(link)
          return () => container.replaceChildren()
        }
        container.textContent = `@${entry?.title ?? target.principal}`
        return () => {
          container.textContent = ''
        }
      },
      mentionText(target) {
        const entry = mentionCatalog.find(item =>
          'page' in target
            ? 'page' in item.target && item.target.page === target.page
            : 'principal' in item.target && item.target.principal === target.principal
        )
        if ('page' in target) return entry?.title ?? 'Restricted page'
        return `@${entry?.title ?? target.principal}`
      },
      matchPageUrl(url) {
        const match = /^https:\/\/ankole\.test\/p\/([0-9a-f-]{36})(?:[?#].*)?$/i.exec(url)
        return match?.[1] ?? null
      },
      mountEmbed(attributes, container) {
        const code = document.createElement('code')
        code.textContent = attributes.ref ?? ''
        container.append(code)
        container.dataset.host = 'mounted'
        return () => {
          code.remove()
        }
      }
    }),
    [mentionCatalog]
  )
  const pages = useRef<Partial<Record<'first' | 'second', PageSession>>>({})
  useEffect(() => {
    const timer = setTimeout(() => {
      setSources(value => ({
        first: pages.current.first?.read().markdown ?? value.first,
        second: pages.current.second?.read().markdown ?? value.second
      }))
    }, 250)
    return () => clearTimeout(timer)
  }, [revision])
  function ready(name: 'first' | 'second', editor: Editor) {
    const page = new PageSession(editor)
    const collaboration = new PageCollaboration(editor, 0, {
      clientID: name,
      // This package fixture acknowledges its own batches; Pod tests use the real server.
      async send(request) {
        return {
          revision: request.base_revision + 1,
          changes: [{ ...request, revision: request.base_revision + 1, kind: 'change' }]
        }
      },
      changed(state) {
        if (name === 'second') setCollaboration({ revision: state.revision, pending: state.pending })
      },
      reset() {},
      sync() {}
    })
    pages.current[name] = page
    setLifecycle(value => ({ ...value, ready: value.ready + 1 }))
    return () => {
      collaboration.dispose()
      page.dispose()
      if (pages.current[name] === page) delete pages.current[name]
      setLifecycle(value => ({ ...value, disposed: value.disposed + 1 }))
    }
  }
  return (
    <main className="embedding-page">
      <h1 data-testid="host-heading">Two independent editors</h1>
      <div className="host-controls">
        <button onClick={() => setRender(value => value + 1)}>Rerender host</button>
        <button onClick={() => setVisible(value => !value)}>Toggle first editor</button>
        <button onClick={() => setReadOnly(value => !value)}>Toggle read only</button>
        <button
          onClick={() => {
            const page = pages.current.first!
            page.apply({
              format: 'xml',
              source:
                '<page><p><comment ids="019a2b00-0000-7000-8000-000000000001">Anchored text</comment></p><p>Destination</p></page>',
              revision: page.revision
            })
          }}>
          Apply comment to first
        </button>
        <button
          onClick={() => {
            const page = pages.current.first!
            page.apply({
              format: 'xml',
              source:
                '<page><pre lang="ts">a<comment ids="019a2b00-0000-7000-8000-000000000001">b\n  c</comment>d</pre></page>',
              revision: page.revision
            })
          }}>
          Apply code comment to first
        </button>
        <output aria-label="Comment event">{commentEvent}</output>
        <output aria-label="Agent event">{agentEvent}</output>
        <output aria-label="Accepted files">{acceptedFiles}</output>
        <output aria-label="Opened page">{openedPage}</output>
        <button
          onClick={() => setResolvedComments(ids => (ids.length ? [] : ['019a2b00-0000-7000-8000-000000000001']))}>
          Toggle comment resolved
        </button>
        <button
          onClick={() => {
            const page = pages.current.first!
            page.apply({
              format: 'xml',
              revision: page.revision,
              source:
                '<page><p><comment ids="019a2b00-0000-7000-8000-000000000001 019a2b00-0000-7000-8000-000000000002">Overlapping threads</comment></p></page>'
            })
          }}>
          Apply overlapping comments
        </button>
        <button onClick={() => setToolbarVisible(value => !value)}>Toggle second toolbar</button>
        <button
          onClick={() =>
            setLabels({
              paragraph_title: 'Text',
              paragraph_detail: 'Plain paragraph',
              number_title: 'Numbered list',
              number_detail: 'Ordered items',
              check_title: 'Checklist',
              check_detail: 'Track tasks',
              slash_menu: 'Insert block',
              add_content: 'Add content',
              block_actions: 'Block actions'
            })
          }>
          Translate second editor
        </button>
        <button
          onClick={() => {
            const page = pages.current.second!
            page.apply({
              format: 'xml',
              source: '<page><callout tone="warning"><p>Applied XML</p></callout></page>',
              revision: page.revision
            })
          }}>
          Apply XML to second
        </button>
        <input aria-label="Host input" placeholder="Outside both editors" />
        <select
          aria-label="Source target"
          value={target}
          onChange={e => setTarget(e.target.value as 'first' | 'second')}>
          <option value="first">First</option>
          <option value="second">Second</option>
        </select>
        <textarea aria-label="Host source" value={hostSource} onChange={e => setHostSource(e.target.value)} />
        <button
          onMouseDown={e => e.preventDefault()}
          onClick={() => {
            const page = pages.current[target]!
            try {
              page.apply({ format: 'markdown', source: hostSource, revision: page.revision })
              setWriteResult('Applied')
            } catch (error) {
              setWriteResult((error as Error).message)
            }
          }}>
          Apply source without moving focus
        </button>
      </div>
      <output aria-label="Source write result">{writeResult}</output>
      <output aria-label="Host collaboration">{JSON.stringify(collaboration)}</output>
      <output aria-label="Lifecycle">{JSON.stringify(lifecycle)}</output>
      <output aria-label="Observed host render">{observedRender}</output>
      <section className="embedding-grid">
        <div data-testid="first-editor" className="embedding-panel">
          {visible && (
            <BlockEditor
              ariaLabel="First document"
              host={host}
              resolvedCommentIDs={resolvedComments}
              initial={render ? 'New initial must not replace edits' : '# First\n\nAlpha text'}
              onReady={editor => ready('first', editor)}
              readOnly={readOnly}
              onChange={() => {
                setRevision(value => value + 1)
                setObservedRender(render)
              }}
            />
          )}
        </div>
        <div data-testid="second-editor" className="embedding-panel">
          <BlockEditor
            ariaLabel="Second document"
            labels={labels}
            host={host}
            initial={'# Second\n\nBeta text'}
            onReady={editor => ready('second', editor)}
            onChange={() => setRevision(value => value + 1)}
            toolbar={toolbarVisible ? <HostToolbar /> : null}
          />
        </div>
      </section>
      <pre aria-label="First Markdown">{sources.first}</pre>
      <pre aria-label="Second Markdown">{sources.second}</pre>
    </main>
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <EmbeddedHost />
  </StrictMode>
)
