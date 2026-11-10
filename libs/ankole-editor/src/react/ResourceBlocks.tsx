import { useEffect, useId, useLayoutEffect, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { Button } from '@ankole/uikit/components/button'
import { Input } from '@ankole/uikit/components/input'
import { RiGlobalLine, RiLink } from '@remixicon/react'
import { Embed, EmbedHref, EmbedRef, embedAttributes, embedChanges, type EmbedPatch } from '../blocks/embed'
import {
  resourceAttributes,
  resourceBlocks,
  resourceChanges,
  resourceEditorField,
  resourceEditorOpenKey,
  type ResourceAttributes
} from '../blocks/resources'
import {
  assetURL,
  iframeURL,
  mediaKind,
  normalizeWebURL,
  replaceResourceSource,
  videoEmbedURL,
  webURL,
  type ResourceView
} from '../document/resources'
import { dispatchStep } from '../editor/block-insert'
import { BlockSelection } from '../editor/block-selection'
import { unitAt } from '../editor/block-target'
import type { EditorHost } from '../editor/host-context'
import { isKnowledge } from '../editor/knowledge'
import {
  cachedLinkMetadata,
  convertPageEmbedToMention,
  convertResourceBlockView,
  selectBlockAt,
  switchBlockView,
  subscribeLinkMetadata,
  unfurlEmbed
} from '../editor/link-views'
import { useEditor, useEditorLabel, useEditorState } from './context'
import {
  DEFAULT_EMBED_HEIGHT,
  EmbedFrame,
  parseSavedEmbedHeight,
  ResourceBlockContainer,
  ResourceEditForm,
  ResourceFloatingToolbar,
  useResourceBlockController,
  type ResourceTitleKey
} from './resource-controls'

const containerIDs = new WeakMap<Element, number>()
let nextID = 0

function resourceHostname(src: string): string {
  try {
    return new URL(src, typeof window === 'undefined' ? 'http://localhost' : window.location.href).hostname
  } catch {
    return src
  }
}

/** React owns controls inside atomic nodes; the editor owns positions, selection and persistence. */
export function ResourceBlocks({ host }: { host?: EditorHost }) {
  const editor = useEditor()
  const state = useEditorState()
  const [portals, setPortals] = useState<ReactNode[]>([])
  // nodeDOM flushes pending editor updates, so synchronize portals after React renders.
  useLayoutEffect(() => {
    const activePos = state.field(resourceEditorField, false) ?? null
    const openKey = state.field(resourceEditorOpenKey, false) ?? 0
    const singleSelectedBefore =
      state.selection instanceof BlockSelection && state.selection.blocks.length === 1
        ? state.selection.blocks[0]!.before
        : null
    const nextPortals: ReactNode[] = []
    state.doc.iterate((node, pos) => {
      const isExternalEmbed = node.type === Embed.type && node.mark(EmbedHref) !== undefined
      const isMedia = !isExternalEmbed && resourceBlocks.some(block => block.type === node.type)
      if (!isExternalEmbed && !isMedia) return
      const dom = editor.nodeDOM(pos)
      const container = dom?.matches('.editor-resource') ? dom : dom?.querySelector('.editor-resource')
      if (!container) return false
      if (!containerIDs.has(container)) containerIDs.set(container, ++nextID)
      const selected = singleSelectedBefore !== null && unitAt(state.doc, pos, 1)?.before === singleSelectedBefore
      const blockOpenKey = activePos === pos ? openKey : 0
      nextPortals.push(
        createPortal(
          isExternalEmbed ? (
            <ExternalEmbedBlock
              attrs={embedAttributes(node)}
              selected={selected}
              container={container}
              host={host}
              openKey={blockOpenKey}
            />
          ) : (
            <MediaResourceBlock
              attrs={resourceAttributes(node)}
              selected={selected}
              container={container}
              host={host}
              openKey={blockOpenKey}
            />
          ),
          container,
          String(containerIDs.get(container))
        )
      )
      return false
    })
    setPortals(nextPortals)
  }, [editor, state, host])
  return portals
}

export function MediaResourceBlock({
  attrs,
  selected = false,
  container,
  host,
  openKey = 0
}: {
  attrs: ResourceAttributes
  selected?: boolean
  container: Element
  host?: EditorHost
  openKey?: number
}) {
  const label = useEditorLabel()
  const readOnly = useEditorState(state => state.readOnly)
  const knowledge = useEditorState(isKnowledge)
  const [edits, setEdits] = useState<ResourceAttributes>({})
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [reloadKey, setReloadKey] = useState(0)
  const fileInputRef = useRef<HTMLInputElement>(null)
  const formId = useId()

  const resetEdits = () => {
    setEdits({})
    setError('')
  }

  const ctrl = useResourceBlockController({
    container,
    openKey,
    readOnly,
    selected,
    initialEditing: !attrs.src,
    onOpenFromCommand: resetEdits
  })

  const draft = { ...attrs, ...edits }
  const hasSrc = Boolean(attrs.src)
  const prevHasSrc = useRef(hasSrc)
  useEffect(() => {
    if (prevHasSrc.current === hasSrc) return
    prevHasSrc.current = hasSrc
    if (!hasSrc) {
      resetEdits()
      ctrl.setEditing(true)
    } else if (Object.keys(edits).length === 0) {
      ctrl.setEditing(false)
    }
  }, [hasSrc, edits])

  const view: ResourceView = attrs.view ?? 'preview'
  const src = attrs.src ? assetURL(attrs.src, host?.resolveAsset) : null
  const title = attrs.title || (attrs.src ? attrs.src.split('/').at(-1) || attrs.src : label('media_title'))
  const resolvedKind = mediaKind(attrs)

  const updateMedia = (next: ResourceAttributes): boolean => {
    if (ctrl.editor.state.readOnly || !container.isConnected) return false
    const target = ctrl.editor.nodeFromDOM(container)
    if (!target || !resourceBlocks.some(block => block.type === target.node.type)) return false
    const changes = resourceChanges(target.node, target.pos, next)
    if (changes.length > 0) {
      dispatchStep(ctrl.editor, { changes, userEvent: 'resource.configure' })
    }
    return true
  }

  const finishEditing = (selectBlock: boolean) => {
    resetEdits()
    ctrl.finishCloseEditor(selectBlock)
  }

  const save = () => {
    const hadSource = Boolean(attrs.src)
    const address = draft.src?.trim() ?? ''
    const valid = address.startsWith('ankole:asset/') && address === attrs.src ? address : normalizeWebURL(address)
    if (!valid) {
      setError(label('resource_invalid'))
      return
    }
    const patch: ResourceAttributes = { ...edits, src: valid }
    if ('title' in patch) patch.title = patch.title?.trim() || undefined
    if (updateMedia(patch)) {
      finishEditing(hadSource)
    }
  }

  const upload = async (file: File) => {
    if (!host?.uploadAsset || busy) return
    if (!(knowledge ? /^image\// : /^(image|video)\//).test(file.type)) {
      setError(label('resource_media_invalid'))
      return
    }
    const hadSource = Boolean(attrs.src)
    setBusy(true)
    setError('')
    try {
      const uploaded = await host.uploadAsset(file)
      if (!ctrl.alive.current) return
      const next: ResourceAttributes = {
        ...replaceResourceSource(uploaded),
        title: uploaded.title ?? file.name
      }
      if (updateMedia(next)) {
        finishEditing(hadSource)
      }
    } catch (reason) {
      if (ctrl.alive.current) setError(reason instanceof Error ? reason.message : label('resource_upload_failed'))
    } finally {
      if (ctrl.alive.current) setBusy(false)
    }
  }

  let preview: ReactNode = null
  let hasFramePreview = false
  if (src && view === 'preview') {
    const frameSrc = resolvedKind === 'video' && videoEmbedURL(src) ? iframeURL(src) : null
    if (frameSrc) {
      hasFramePreview = true
      preview = (
        <EmbedFrame
          frameSrc={frameSrc}
          title={title}
          reloadKey={reloadKey}
          resizable={false}
          savedHeight={DEFAULT_EMBED_HEIGHT}
        />
      )
    } else if (resolvedKind === 'image') {
      preview = <img className="resource-media" src={src} alt={attrs.title ?? ''} loading="lazy" />
    } else {
      preview = <video className="resource-media" src={src} controls playsInline preload="metadata" />
    }
  }

  const showViewMenu = !readOnly && !knowledge
  const showFloatingToolbar =
    !ctrl.editing &&
    Boolean(src) &&
    (readOnly ? hasFramePreview && ctrl.activeHoverOrFocus : ctrl.activeHoverOrFocus || ctrl.showToolbarForSelection)
  const linkSummaryLabel =
    view === 'link' ? (attrs.src?.startsWith('ankole:asset/') ? title : (attrs.src ?? title)) : title
  const isCreating = !attrs.src

  return (
    <>
      <ResourceFloatingToolbar
        open={showFloatingToolbar}
        anchorRef={ctrl.blockRef}
        titleKey="media_title"
        src={src}
        readOnly={readOnly}
        hasFramePreview={hasFramePreview}
        showViewMenu={showViewMenu}
        view={view}
        views={['link', 'card', 'preview']}
        viewMenuOpen={ctrl.viewMenuOpen}
        layoutDependency={DEFAULT_EMBED_HEIGHT}
        onOpenChangeViewMenu={open => {
          ctrl.setViewMenuOpen(open)
          if (open) ctrl.clearHoverTimer()
        }}
        onSelectView={value => {
          const target = container.isConnected ? ctrl.editor.nodeFromDOM(container) : null
          if (!target || ctrl.editor.state.readOnly) return
          switchBlockView(
            ctrl.editor,
            target.pos,
            resourceChanges(target.node, target.pos, { view: value }),
            'resource.configure'
          )
          ctrl.editor.focus()
        }}
        onReload={() => setReloadKey(current => current + 1)}
        onEdit={ctrl.startEditing}
        onPointerEnter={() => {
          ctrl.clearHoverTimer()
          ctrl.setToolbarHovered(true)
        }}
        onPointerLeave={() => {
          if (!ctrl.viewMenuOpen) ctrl.scheduleLeave(ctrl.setToolbarHovered)
        }}
        onFocusChange={ctrl.setToolbarFocused}
        onDismiss={ctrl.dismissToolbar}
      />
      <ResourceBlockContainer
        blockRef={ctrl.blockRef}
        kind="media"
        view={view}
        selected={selected}
        editing={ctrl.editing}
        readOnly={readOnly}
        container={container}
        onPointerEnter={() => {
          ctrl.clearHoverTimer()
          ctrl.setHovered(true)
        }}
        onPointerLeave={() => {
          if (!ctrl.viewMenuOpen) ctrl.scheduleLeave(ctrl.setHovered)
        }}
        onSelectBlock={ctrl.selectThisBlock}>
        {ctrl.editing && !readOnly ? (
          <ResourceEditForm
            formId={formId}
            titleKey="media_title"
            compact={isCreating}
            busy={busy}
            error={error}
            address={draft.src ?? ''}
            title={draft.title ?? ''}
            addressInputRef={ctrl.addressInputRef}
            uploadControl={
              host?.uploadAsset ? (
                <>
                  <input
                    ref={fileInputRef}
                    className="sr-only"
                    type="file"
                    aria-label={label('resource_upload')}
                    accept={knowledge ? 'image/*' : 'image/*,video/*'}
                    disabled={busy}
                    onChange={event => {
                      const file = event.target.files?.[0]
                      event.target.value = ''
                      if (file) void upload(file)
                    }}
                  />
                  <Button
                    type="button"
                    variant="outline"
                    size={isCreating ? 'xs' : 'sm'}
                    disabled={busy}
                    onClick={() => fileInputRef.current?.click()}>
                    {label(busy ? 'resource_uploading' : 'resource_upload')}
                  </Button>
                </>
              ) : null
            }
            onChangeAddress={value => {
              setError('')
              setEdits({ ...edits, ...replaceResourceSource({ src: value }) })
            }}
            onChangeTitle={value => setEdits({ ...edits, title: value })}
            onSave={save}
            onCancel={() => finishEditing(true)}>
            <div role="group" aria-label={label('resource_kind')} className="resource-actions">
              {(knowledge ? (['image'] as const) : (['image', 'video'] as const)).map(value => (
                <Button
                  key={value}
                  type="button"
                  variant="ghost"
                  size="xs"
                  aria-pressed={mediaKind(draft) === value}
                  onClick={() => setEdits({ ...edits, kind: value })}>
                  {label(`resource_${value}_kind`)}
                </Button>
              ))}
            </div>
          </ResourceEditForm>
        ) : preview ? (
          preview
        ) : src ? (
          <a className="resource-summary" href={src} target="_blank" rel="noopener noreferrer">
            <RiLink className="resource-symbol" aria-hidden="true" />
            <span className="resource-copy">
              <span className="resource-name">{linkSummaryLabel}</span>
              {view === 'card' && (
                <>
                  {attrs.description && <span className="resource-description">{attrs.description}</span>}
                  <small>{resourceHostname(src)}</small>
                </>
              )}
            </span>
          </a>
        ) : (
          <p className="resource-empty">{label('media_title')}</p>
        )}
      </ResourceBlockContainer>
    </>
  )
}

export function defaultFaviconUrl(href: string | null): string | null {
  const safe = href ? webURL(href) : null
  if (!safe) return null
  try {
    return `${new URL(safe).origin}/favicon.ico`
  } catch {
    return null
  }
}

export function ExternalEmbedBlock({
  attrs,
  selected = false,
  container,
  host,
  openKey = 0
}: {
  attrs: EmbedPatch
  selected?: boolean
  container: Element
  host?: EditorHost
  openKey?: number
}) {
  const label = useEditorLabel()
  const readOnly = useEditorState(state => state.readOnly)
  const knowledge = useEditorState(isKnowledge)
  const [edits, setEdits] = useState<EmbedPatch>({})
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [reloadKey, setReloadKey] = useState(0)
  const [coverFailed, setCoverFailed] = useState(false)
  const [iconFailed, setIconFailed] = useState(false)
  const [, setMetaVersion] = useState(0)
  const [draggingResize, setDraggingResize] = useState(false)
  const savedHeight = parseSavedEmbedHeight(attrs.height)
  const [displayHeight, setDisplayHeight] = useState(savedHeight)
  const formId = useId()

  useEffect(() => {
    if (!draggingResize) setDisplayHeight(savedHeight)
  }, [savedHeight, draggingResize])

  const resetEdits = () => {
    setEdits({})
    setError('')
  }

  const ctrl = useResourceBlockController({
    container,
    openKey,
    readOnly,
    selected,
    initialEditing: !attrs.href,
    onOpenFromCommand: resetEdits
  })

  const draft = { ...attrs, ...edits }
  const view: 'card' | 'preview' = attrs.view === 'card' ? 'card' : 'preview'
  const titleKey: ResourceTitleKey = view === 'card' ? 'bookmark_title' : 'embed_title'

  const hasHref = Boolean(attrs.href)
  const prevHasHref = useRef(hasHref)
  useEffect(() => {
    if (prevHasHref.current === hasHref) return
    prevHasHref.current = hasHref
    if (!hasHref) {
      resetEdits()
      ctrl.setEditing(true)
    } else if (Object.keys(edits).length === 0) {
      ctrl.setEditing(false)
    }
  }, [hasHref, edits])

  useEffect(() => subscribeLinkMetadata(host, () => setMetaVersion(version => version + 1)), [host])
  useEffect(() => setCoverFailed(false), [attrs.image])
  useEffect(() => setIconFailed(false), [attrs.href])

  const src = attrs.href ? assetURL(attrs.href, host?.resolveAsset) : null
  const title = attrs.title || (attrs.href ? attrs.href.split('/').at(-1) || attrs.href : label(titleKey))
  const webLinkSwitchable = Boolean(attrs.href && webURL(attrs.href))

  const updateEmbed = (patch: EmbedPatch): number | null => {
    if (ctrl.editor.state.readOnly || !container.isConnected) return null
    const target = ctrl.editor.nodeFromDOM(container)
    if (!target || target.node.type !== Embed.type) return null
    const changes = embedChanges(target.node, target.pos, patch)
    if (changes.length > 0) {
      dispatchStep(ctrl.editor, { changes, userEvent: 'embed.configure' })
    }
    return target.pos
  }

  const finishEditing = (selectBlock: boolean) => {
    resetEdits()
    ctrl.finishCloseEditor(selectBlock)
  }

  const convertMatchedInternalPage = (pageId: string, canEmbed: boolean): boolean => {
    if (!ctrl.alive.current || ctrl.editor.state.readOnly || !container.isConnected) return false
    const target = ctrl.editor.nodeFromDOM(container)
    if (!target || target.node.type !== Embed.type) return false
    resetEdits()
    ctrl.setEditing(false)
    if (canEmbed) {
      dispatchStep(ctrl.editor, {
        changes: {
          from: target.pos,
          to: target.pos + target.node.length,
          insert: [Embed.withMarks([EmbedRef.of(pageId)])]
        },
        selection: cx => selectBlockAt(cx.doc, target.pos),
        userEvent: 'embed.configure'
      })
      ctrl.editor.focus()
    } else {
      convertPageEmbedToMention(ctrl.editor, target.pos, pageId)
    }
    return true
  }

  const save = () => {
    if (busy) return
    const hadHref = Boolean(attrs.href)
    const address = draft.href?.trim() ?? ''
    const normalizedWeb = normalizeWebURL(address)

    if (!knowledge && address) {
      const directPageId = address.startsWith('ankole:page/') ? address.slice('ankole:page/'.length).trim() : null
      const matchedPageId =
        directPageId ||
        (normalizedWeb
          ? (host?.matchPageUrl?.(normalizedWeb) ?? host?.matchPageUrl?.(address))
          : host?.matchPageUrl?.(address))
      if (matchedPageId && container.isConnected && ctrl.editor.nodeFromDOM(container)?.node.type === Embed.type) {
        const decision = host?.canEmbedPage?.(matchedPageId)
        if (decision instanceof Promise) {
          setBusy(true)
          setError('')
          void decision
            .then(
              canEmbed => {
                convertMatchedInternalPage(matchedPageId, canEmbed)
              },
              () => {
                convertMatchedInternalPage(matchedPageId, false)
              }
            )
            .finally(() => {
              if (ctrl.alive.current) setBusy(false)
            })
        } else {
          convertMatchedInternalPage(matchedPageId, decision === true)
        }
        return
      }
    }

    // Host addresses may be kept while editing a caption, but cannot be entered as external URLs.
    const valid = address.startsWith('ankole:asset/') && address === attrs.href ? address : normalizedWeb
    if (!valid) {
      setError(label('resource_invalid'))
      return
    }
    const rawImage = 'image' in edits ? (edits.image?.trim() ?? '') : (attrs.image?.trim() ?? '')
    const validImage = rawImage ? normalizeWebURL(rawImage) : undefined
    if (rawImage && !validImage) {
      setError(label('resource_invalid'))
      return
    }

    const previousHref = attrs.href ? (normalizeWebURL(attrs.href) ?? attrs.href) : undefined
    const sourceChanged = Boolean(previousHref && previousHref !== valid)
    const patch: EmbedPatch = { ...edits, href: valid }
    if ('title' in patch) patch.title = patch.title?.trim() || undefined
    else if (sourceChanged) patch.title = undefined
    if ('description' in patch) patch.description = patch.description?.trim() || undefined
    else if (sourceChanged) patch.description = undefined
    if ('image' in patch) patch.image = validImage ?? undefined
    else if (sourceChanged) patch.image = undefined

    const updatedPos = updateEmbed(patch)
    if (updatedPos !== null) {
      finishEditing(hadHref)
      const effectiveTitle = 'title' in patch ? patch.title : attrs.title
      const effectiveDesc = 'description' in patch ? patch.description : attrs.description
      const effectiveImg = 'image' in patch ? patch.image : attrs.image
      if (!effectiveTitle || (view === 'card' && !effectiveDesc && !effectiveImg)) {
        void unfurlEmbed(ctrl.editor, valid, updatedPos)
      }
    }
  }

  const frameSrc = src && view === 'preview' ? iframeURL(src) : null
  const hasFramePreview = Boolean(frameSrc)
  const preview = frameSrc ? (
    <EmbedFrame
      frameSrc={frameSrc}
      title={title}
      reloadKey={reloadKey}
      resizable={!readOnly}
      savedHeight={savedHeight}
      onDraggingChange={setDraggingResize}
      onDisplayHeightChange={setDisplayHeight}
      onCommitHeight={height => {
        updateEmbed({ height: String(height) })
      }}
      onSelectBlock={ctrl.selectThisBlock}
    />
  ) : null

  const views: ResourceView[] = webLinkSwitchable ? ['link', 'title', 'card', 'preview'] : ['link', 'card', 'preview']
  const showViewMenu = !readOnly && !knowledge && webLinkSwitchable
  const cachedMeta = src ? cachedLinkMetadata(host, src) : undefined
  const faviconUrl = cachedMeta?.icon ?? defaultFaviconUrl(src)
  const coverUrl = view === 'card' && attrs.image ? webURL(attrs.image) : null
  const isCreating = !attrs.href

  const showFloatingToolbar =
    !ctrl.editing &&
    Boolean(src) &&
    !draggingResize &&
    (readOnly ? hasFramePreview && ctrl.activeHoverOrFocus : ctrl.activeHoverOrFocus || ctrl.showToolbarForSelection)

  return (
    <>
      <ResourceFloatingToolbar
        open={showFloatingToolbar}
        anchorRef={ctrl.blockRef}
        titleKey={titleKey}
        src={src}
        readOnly={readOnly}
        hasFramePreview={hasFramePreview}
        showViewMenu={showViewMenu}
        view={view}
        views={views}
        viewMenuOpen={ctrl.viewMenuOpen}
        layoutDependency={displayHeight}
        onOpenChangeViewMenu={open => {
          ctrl.setViewMenuOpen(open)
          if (open) ctrl.clearHoverTimer()
        }}
        onSelectView={value => {
          const target = container.isConnected ? ctrl.editor.nodeFromDOM(container) : null
          if (target) void convertResourceBlockView(ctrl.editor, target.pos, value)
        }}
        onReload={() => setReloadKey(current => current + 1)}
        onEdit={ctrl.startEditing}
        onPointerEnter={() => {
          ctrl.clearHoverTimer()
          ctrl.setToolbarHovered(true)
        }}
        onPointerLeave={() => {
          if (!ctrl.viewMenuOpen) ctrl.scheduleLeave(ctrl.setToolbarHovered)
        }}
        onFocusChange={ctrl.setToolbarFocused}
        onDismiss={ctrl.dismissToolbar}
      />
      <ResourceBlockContainer
        blockRef={ctrl.blockRef}
        kind="embed"
        view={view}
        selected={selected}
        editing={ctrl.editing}
        readOnly={readOnly}
        container={container}
        onPointerEnter={() => {
          ctrl.clearHoverTimer()
          ctrl.setHovered(true)
        }}
        onPointerLeave={() => {
          if (!ctrl.viewMenuOpen) ctrl.scheduleLeave(ctrl.setHovered)
        }}
        onSelectBlock={ctrl.selectThisBlock}>
        {ctrl.editing && !readOnly ? (
          <ResourceEditForm
            formId={formId}
            titleKey={titleKey}
            compact={isCreating}
            busy={busy}
            error={error}
            address={draft.href ?? ''}
            title={draft.title ?? ''}
            addressInputRef={ctrl.addressInputRef}
            onChangeAddress={value => {
              setError('')
              setEdits({ ...edits, href: value })
            }}
            onChangeTitle={value => setEdits({ ...edits, title: value })}
            onSave={save}
            onCancel={() => finishEditing(true)}>
            {view === 'card' && (
              <>
                <label htmlFor={`${formId}-description`}>
                  {label('resource_description')}
                  <Input
                    id={`${formId}-description`}
                    value={draft.description ?? ''}
                    disabled={busy}
                    onChange={event => setEdits({ ...edits, description: event.target.value })}
                  />
                </label>
                <label htmlFor={`${formId}-image`}>
                  {label('resource_image')}
                  <Input
                    id={`${formId}-image`}
                    value={draft.image ?? ''}
                    placeholder="https://"
                    autoCorrect="off"
                    autoCapitalize="off"
                    spellCheck={false}
                    disabled={busy}
                    onChange={event => setEdits({ ...edits, image: event.target.value })}
                  />
                </label>
              </>
            )}
          </ResourceEditForm>
        ) : preview ? (
          preview
        ) : src ? (
          webLinkSwitchable && view === 'card' ? (
            <a className="resource-summary resource-bookmark-card" href={src} target="_blank" rel="noopener noreferrer">
              {coverUrl && !coverFailed && (
                <img
                  className="resource-cover"
                  src={coverUrl}
                  alt=""
                  loading="lazy"
                  onError={() => setCoverFailed(true)}
                />
              )}
              <span className="resource-copy">
                <span className="resource-meta">
                  {faviconUrl && !iconFailed ? (
                    <img
                      className="resource-favicon"
                      src={faviconUrl}
                      alt=""
                      loading="lazy"
                      onError={() => setIconFailed(true)}
                    />
                  ) : (
                    <RiGlobalLine className="resource-favicon-fallback" aria-hidden="true" />
                  )}
                  <small className="resource-url">{attrs.href ?? src}</small>
                </span>
                <span className="resource-name">{title}</span>
                {attrs.description && <span className="resource-description">{attrs.description}</span>}
              </span>
            </a>
          ) : (
            <a className="resource-summary" href={src} target="_blank" rel="noopener noreferrer">
              <RiLink className="resource-symbol" aria-hidden="true" />
              <span className="resource-copy">
                <span className="resource-name">{title}</span>
                {view === 'card' && (
                  <>
                    {attrs.description && <span className="resource-description">{attrs.description}</span>}
                    <small>{resourceHostname(src)}</small>
                  </>
                )}
              </span>
            </a>
          )
        ) : (
          <p className="resource-empty">{label(titleKey)}</p>
        )}
      </ResourceBlockContainer>
    </>
  )
}
