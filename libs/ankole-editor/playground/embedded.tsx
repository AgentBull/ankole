import { BlockEditor, useEditor } from '@ankole/block-editor'
import { PageSession, toggleFormat, undo, type Editor } from '@ankole/block-editor/editor'
import { StrictMode, useEffect, useRef, useState } from 'react'
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
    pages.current[name] = page
    setLifecycle(value => ({ ...value, ready: value.ready + 1 }))
    return () => {
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
        <button onClick={() => setToolbarVisible(value => !value)}>Toggle second toolbar</button>
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
      <output aria-label="Lifecycle">{JSON.stringify(lifecycle)}</output>
      <output aria-label="Observed host render">{observedRender}</output>
      <section className="embedding-grid">
        <div data-testid="first-editor" className="embedding-panel">
          {visible && (
            <BlockEditor
              ariaLabel="First document"
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
