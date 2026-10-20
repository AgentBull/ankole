import { Badge } from '@ankole/uikit/components/badge'
import { Button } from '@ankole/uikit/components/button'
import {
  RiArrowRightLine,
  RiArrowRightSLine,
  RiBracesLine,
  RiCheckLine,
  RiCloseLine,
  RiCodeSSlashLine,
  RiDownloadLine,
  RiFileTextLine,
  RiFlaskLine,
  RiLayoutLeftLine,
  RiRefreshLine,
  RiUploadLine
} from '@remixicon/react'
import { useCallback, useEffect, useEffectEvent, useRef, useState } from 'react'
import { BlockEditor } from '@ankole/block-editor'
import { PageSession, type Editor } from '@ankole/block-editor/editor'
import { parseMarkdown, printXml } from '@ankole/block-editor/document'
import type { PageWrite } from '../src/editor/page-session'
import type { SourceFormat } from '../src/document/tree'
import { sampleMarkdown } from './sample'

const storageKey = 'ankole.block-lab.markdown.v2'

function loadDocument() {
  let source = sampleMarkdown
  try {
    source = localStorage.getItem(storageKey) ?? sampleMarkdown
  } catch {
    /* The editor still works when browser storage is unavailable. */
  }
  try {
    parseMarkdown(source)
    return { source, recovery: null, error: '' }
  } catch (error) {
    return {
      source: '',
      recovery: source,
      error: `本地存档需要修复，原始源码已保留：${error instanceof Error ? error.message : String(error)}`
    }
  }
}

export function App() {
  const [initial] = useState(loadDocument)
  const [session, setSession] = useState(() => ({ source: initial.source, id: 0 }))
  const [snapshot, setSnapshot] = useState(() => ({
    markdown: session.source,
    xml: printXml(parseMarkdown(session.source)),
    revision: 0
  }))
  const [revision, setRevision] = useState(0)
  const [editor, setEditor] = useState<Editor | null>(null)
  const [sourceOpen, setSourceOpen] = useState(initial.recovery !== null)
  const [draft, setDraft] = useState<PageWrite | null>(
    initial.recovery === null ? null : { source: initial.recovery, format: 'markdown', revision: 0 }
  )
  const [recoveryPending, setRecoveryPending] = useState(initial.recovery !== null)
  const [format, setFormat] = useState<SourceFormat>('markdown')
  const [composing, setComposing] = useState(false)
  const composingRef = useRef(false)
  const pageRef = useRef<PageSession | null>(null)
  const [notice, setNotice] = useState(initial.error)
  const [saveState, setSaveState] = useState('已保存到此浏览器')
  const [resetOpen, setResetOpen] = useState(false)
  const fileRef = useRef<HTMLInputElement>(null)
  const bufferVersion = useRef(0)
  // The XML of the page before a round trip. The reopened editor must show the same page.
  const reopening = useRef<string | null>(null)
  const onReady = useCallback((value: Editor) => {
    const page = new PageSession(value)
    pageRef.current = page
    setEditor(value)
    if (reopening.current !== null) {
      const same = page.read().xml === reopening.current
      reopening.current = null
      setNotice(same ? '往返一致 · 导出的 Markdown 重新打开后得到同一页面' : '往返检查发现内容差异，请检查 Markdown')
      if (!same) setSourceOpen(true)
    }
    return () => {
      page.dispose()
      if (pageRef.current === page) pageRef.current = null
    }
  }, [])
  const onChange = useCallback(() => setRevision(value => value + 1), [])
  const source = draft?.source ?? snapshot[format]
  const formatName = format === 'xml' ? 'XML' : 'Markdown'
  const save = useEffectEvent(() => {
    if (recoveryPending || !pageRef.current) return
    const value = pageRef.current.read()
    setSnapshot(value)
    try {
      localStorage.setItem(storageKey, value.markdown)
      setSaveState('已保存到此浏览器')
    } catch {
      setSaveState('浏览器存储不可用，请导出文件')
    }
  })
  useEffect(() => {
    if (recoveryPending) {
      setSaveState('原始存档已保留，请修复后应用')
      return
    }
    setSaveState('正在保存…')
    const timer = setTimeout(save, 250)
    return () => clearTimeout(timer)
  }, [revision, recoveryPending])
  // The page can close while React renders, when an Effect Event cannot run. Write the page directly.
  const recoveryRef = useRef(recoveryPending)
  useEffect(() => {
    recoveryRef.current = recoveryPending
  }, [recoveryPending])
  useEffect(() => {
    const flush = () => {
      if (recoveryRef.current || !pageRef.current) return
      try {
        localStorage.setItem(storageKey, pageRef.current.read().markdown)
      } catch {
        /* Storage is unavailable. The page can still be exported. */
      }
    }
    window.addEventListener('pagehide', flush)
    return () => window.removeEventListener('pagehide', flush)
  }, [])

  function refreshSource() {
    if (draft === null && pageRef.current) setSnapshot(pageRef.current.read())
  }

  function applySource() {
    if (!pageRef.current || draft === null || composingRef.current) return
    try {
      const applied = pageRef.current.apply(draft)
      setSnapshot(applied)
      setDraft(null)
      setRecoveryPending(false)
      setNotice(
        `${formatName} 已应用到文档${applied.warnings.length ? `。已保留：${applied.warnings.join('；')}` : ''}`
      )
    } catch (error) {
      setNotice(`无法应用：${error instanceof Error ? error.message : String(error)}`)
    }
  }

  // Export the page as Markdown and open it in a new editor.
  function roundTrip() {
    if (!pageRef.current || !editor || draft !== null || editor.composing || composingRef.current) return
    try {
      const { markdown, xml } = pageRef.current.read()
      reopening.current = xml
      setSession(previous => ({ source: markdown, id: previous.id + 1 }))
    } catch (error) {
      setNotice(`往返失败：${error instanceof Error ? error.message : String(error)}`)
    }
  }

  function download() {
    const currentSource = draft?.source ?? pageRef.current?.read()[format] ?? source
    const url = URL.createObjectURL(
      new Blob([currentSource], { type: `${format === 'xml' ? 'application/xml' : 'text/markdown'};charset=utf-8` })
    )
    const link = document.createElement('a')
    link.href = url
    link.download = `block-lab.${format === 'xml' ? 'xml' : 'md'}`
    link.click()
    URL.revokeObjectURL(url)
    setNotice(draft === null ? `已导出 ${formatName} 文档` : `已导出当前 ${formatName} 草稿`)
  }

  return (
    <div className={`app-shell ${sourceOpen ? 'with-source' : ''}`}>
      <aside className="sidebar">
        <div className="brand">
          <span className="brand-mark">a</span>
          <span>
            ankole<span className="brand-lab"> / lab</span>
          </span>
        </div>
        <div className="workspace-label">
          <RiFlaskLine size={16} />
          <span>Block Lab</span>
          <Badge variant="outline">DEMO</Badge>
        </div>
        <div className="sidebar-label">工作空间</div>
        <button
          className="sidebar-page"
          onClick={() => document.querySelector('.editor-content h1')?.scrollIntoView({ behavior: 'smooth' })}>
          <RiFileTextLine size={17} />
          写作与数据<span>⌘</span>
        </button>
        <div className="sidebar-label explore-label">在这份文档里</div>
        <button
          className="sidebar-link"
          onClick={() => document.querySelector('.callout')?.scrollIntoView({ behavior: 'smooth', block: 'center' })}>
          <span>01</span>可编辑的提示块
        </button>
        <button
          className="sidebar-link"
          onClick={() => document.querySelector('.embed')?.scrollIntoView({ behavior: 'smooth', block: 'center' })}>
          <span>02</span>数据库引用
        </button>
        <button
          className="sidebar-link"
          onClick={() => {
            refreshSource()
            setSourceOpen(true)
          }}>
          <span>03</span>一份完整的 Markdown
        </button>
        <div className="sidebar-spacer" />
        <div className="lab-note">
          <RiBracesLine size={20} />
          <strong>内容可读，也可带走。</strong>
          <p>正文和 Block 保存在同一个 Markdown 文件，也可以读写为 XML。</p>
          <button disabled={draft !== null} onClick={roundTrip}>
            验证往返
            <RiArrowRightLine size={14} />
          </button>
        </div>
        <div className="sidebar-footer">
          <span className="local-dot" />
          仅本地保存
          <Button
            size="icon-xs"
            variant="ghost"
            aria-label="恢复示例"
            title="恢复示例"
            onClick={() => setResetOpen(!resetOpen)}>
            <RiRefreshLine />
          </Button>
        </div>
        {resetOpen && (
          <div className="reset-confirm">
            <p>恢复示例会替换当前文档。请先导出需要保留的内容。</p>
            <Button
              size="xs"
              onClick={() => {
                if (composingRef.current || editor?.composing) return
                setSession(previous => ({ source: sampleMarkdown, id: previous.id + 1 }))
                setDraft(null)
                setRecoveryPending(false)
                setResetOpen(false)
                setNotice('已恢复示例文档')
              }}>
              恢复示例文档
            </Button>
            <Button size="xs" variant="ghost" onClick={() => setResetOpen(false)}>
              取消
            </Button>
          </div>
        )}
      </aside>
      <main className="main-area">
        <header className="topbar">
          <div className="breadcrumb">
            <RiLayoutLeftLine size={16} />
            <span>Block Lab</span>
            <RiArrowRightSLine size={15} />
            <strong>写作与数据</strong>
          </div>
          <div className="topbar-actions">
            <span className="save-state">
              <RiCheckLine size={13} />
              {saveState}
            </span>
            <Button
              variant={sourceOpen ? 'outline' : 'ghost'}
              size="sm"
              aria-pressed={sourceOpen}
              onClick={() => {
                refreshSource()
                if (!composingRef.current) setSourceOpen(draft !== null || !sourceOpen)
              }}>
              <RiCodeSSlashLine />
              Markdown
            </Button>
            <Button variant="outline" size="sm" disabled={composing} onClick={download}>
              <RiDownloadLine />
              导出
            </Button>
          </div>
        </header>
        {notice && (
          <div className="notice" role="status">
            <RiCheckLine size={15} />
            <span>{notice}</span>
            <button aria-label="关闭通知" onClick={() => setNotice('')}>
              <RiCloseLine size={16} />
            </button>
          </div>
        )}
        <div className="work-area">
          <section className="editor-pane">
            <BlockEditor
              key={session.id}
              initial={session.source}
              onReady={onReady}
              onChange={onChange}
              readOnly={draft !== null}
              header={
                <div className="document-meta">
                  <span className="document-symbol">✳</span>
                  <span>写作实验 / 001</span>
                  <span>Markdown 的另一种形态</span>
                </div>
              }
              footer={
                <div className="document-end">
                  <span />
                  内容，始终属于你
                  <span />
                </div>
              }
            />
          </section>
          {sourceOpen && (
            <aside className="source-pane">
              <div className="source-heading">
                <RiCodeSSlashLine size={18} />
                <div className="source-formats" role="group" aria-label="源码格式">
                  {(['markdown', 'xml'] as const).map(value => (
                    <Button
                      key={value}
                      size="xs"
                      variant={format === value ? 'outline' : 'ghost'}
                      aria-label={`${value === 'xml' ? 'XML' : 'Markdown'} 格式`}
                      aria-pressed={format === value}
                      disabled={draft !== null || composing}
                      onClick={() => setFormat(value)}>
                      {value === 'xml' ? 'XML' : 'Markdown'}
                    </Button>
                  ))}
                </div>
                <Badge variant="secondary">{format === 'xml' ? '.xml' : '.md'}</Badge>
                <button
                  aria-label={`关闭 ${formatName}`}
                  disabled={draft !== null || composing}
                  onClick={() => setSourceOpen(false)}>
                  <RiCloseLine size={17} />
                </button>
              </div>
              <div className="source-caption">
                {draft === null ? '修改源码，再应用到左侧文档。' : '源码有未应用修改，文档编辑已暂停。'}
              </div>
              <textarea
                aria-label={`${formatName} 源码`}
                spellCheck={false}
                className="source-editor"
                value={source}
                onCompositionStart={() => {
                  composingRef.current = true
                  setComposing(true)
                }}
                onCompositionEnd={() => {
                  composingRef.current = false
                  setComposing(false)
                }}
                onChange={e => {
                  bufferVersion.current++
                  setDraft(previous => ({
                    source: e.target.value,
                    format,
                    revision: previous?.revision ?? snapshot.revision
                  }))
                }}
              />
              <div className="source-stats">
                <span>UTF-8</span>
                <span>{new Blob([source]).size.toLocaleString()} bytes</span>
                <span>{source.split('\n').length} 行</span>
              </div>
              <div className="source-actions">
                <Button size="sm" variant="outline" disabled={composing} onClick={() => fileRef.current?.click()}>
                  <RiUploadLine />
                  打开文件
                </Button>
                <span />
                {draft !== null ? (
                  <>
                    <Button
                      variant="ghost"
                      size="sm"
                      disabled={composing || recoveryPending}
                      onClick={() => {
                        if (!composingRef.current) {
                          bufferVersion.current++
                          setDraft(null)
                        }
                      }}>
                      放弃修改
                    </Button>
                    <Button size="sm" disabled={composing} onClick={applySource}>
                      应用修改
                    </Button>
                  </>
                ) : (
                  <Button size="sm" onClick={roundTrip}>
                    <RiRefreshLine />
                    往返验证
                  </Button>
                )}
              </div>
              <input
                ref={fileRef}
                type="file"
                className="hidden"
                accept=".md,.markdown,.txt,.xml,text/markdown,text/plain,application/xml,text/xml"
                onChange={async e => {
                  const file = e.target.files?.[0]
                  if (!file) return
                  const current = pageRef.current!
                  const revision = current.revision
                  const buffer = ++bufferVersion.current
                  const content = await file.text()
                  if (current !== pageRef.current || composingRef.current || buffer !== bufferVersion.current) return
                  const fileFormat = file.name.toLowerCase().endsWith('.xml') ? 'xml' : 'markdown'
                  setFormat(fileFormat)
                  setDraft({ source: content, format: fileFormat, revision })
                  setNotice(`已打开 ${file.name}，应用后会替换当前文档`)
                  e.target.value = ''
                }}
              />
            </aside>
          )}
        </div>
      </main>
    </div>
  )
}
