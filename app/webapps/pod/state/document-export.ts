import type { QueryClient } from '@tanstack/react-query'
import { podLocation } from '../../common/browser-context'
import i18n from '../../common/i18n'
import { InternalAPIError } from '../../common/internal-api-client'
import { fileURL, metadataFileURL, pageAPI, pageQuery } from '../content-api'
import { podFiles } from '../api/generated/sdk.gen'
import { isCustomEmojiIcon } from '../page-icon-value'
import {
  documentAssets,
  documentEmbedIDs,
  documentFilename,
  documentMarkdown,
  documentPlainText,
  documentPrincipalUIDs,
  documentReferenceIDs,
  type DocumentPrincipalReference,
  type DocumentReference
} from './document-tools'

export async function loadDocumentReferences(
  client: QueryClient,
  xmls: string[]
): Promise<Map<string, DocumentReference>> {
  const refs = [...new Set(xmls.flatMap(documentReferenceIDs))]
  return new Map<string, DocumentReference>(
    await Promise.all(
      refs.map(async ref => {
        const href = new URL(podLocation(`/pages/${ref}`).pathname, window.location.origin).href
        try {
          // Recheck access when copying; a stale cached title must not survive a read denial.
          const { page } = await client.fetchQuery({ ...pageQuery(ref), staleTime: 0 })
          if (page.deleted_at) {
            return [ref, { href, title: i18n.t('pod.document.reference_unavailable'), restricted: true }] as const
          }
          return [
            ref,
            {
              href,
              title: page.title.trim() || i18n.t('pod.content.untitled'),
              ...(page.type === 'file' ? { filePageID: ref } : {})
            }
          ] as const
        } catch (error) {
          if (!(error instanceof InternalAPIError) || ![403, 404].includes(error.status)) throw error
          return [
            ref,
            {
              href,
              title: i18n.t('pod.mention.restricted_page', {
                defaultValue: i18n.t('pod.document.reference_unavailable')
              }),
              restricted: true
            }
          ] as const
        }
      })
    )
  )
}

export async function loadDocumentPrincipals(
  xmls: string[],
  contextPageID?: string
): Promise<Map<string, DocumentPrincipalReference>> {
  const uids = [...new Set(xmls.flatMap(documentPrincipalUIDs))]
  if (uids.length === 0) return new Map()
  const entries = new Map<string, DocumentPrincipalReference>()
  for (let index = 0; index < uids.length; index += 200) {
    const slice = uids.slice(index, index + 200)
    const response = await pageAPI.resolveMentions({
      page_ids: [],
      principal_uids: slice,
      ...(contextPageID ? { context_page_id: contextPageID } : {})
    })
    for (const resolved of response.principals) {
      if (resolved.access === 'ok' || resolved.access === 'disabled') {
        entries.set(resolved.principal_uid, {
          name: (resolved.name ?? '').trim() || resolved.principal_uid
        })
      } else {
        entries.set(resolved.principal_uid, {
          name: i18n.t('pod.mention.restricted_principal', { defaultValue: 'Restricted user' }),
          restricted: true
        })
      }
    }
  }
  return entries
}

function documentHeading(title: string, icon?: string | null) {
  return [icon && !isCustomEmojiIcon(icon) ? icon : '', title].filter(Boolean).join(' ')
}

export function documentMarkdownForExport(
  pageID: string,
  xml: string,
  title: string,
  icon?: string | null,
  references: ReadonlyMap<string, DocumentReference> = new Map(),
  principals: ReadonlyMap<string, DocumentPrincipalReference> = new Map()
) {
  const markdown = documentMarkdown(xml, documentHeading(title, icon), {
    resolveReference: ref => references.get(ref),
    resolvePrincipal: uid => principals.get(uid),
    resolveAsset: source => readerAssetURL(pageID, source)
  })
  return withCustomIcon(markdown, isCustomEmojiIcon(icon) ? readerURL(metadataFileURL(icon)) : undefined)
}

export function documentPlainTextForCopy(
  pageID: string,
  xml: string,
  references: ReadonlyMap<string, DocumentReference> = new Map(),
  principals: ReadonlyMap<string, DocumentPrincipalReference> = new Map()
) {
  return documentPlainText(xml, {
    resolveReference: ref => references.get(ref),
    resolvePrincipal: uid => principals.get(uid),
    resolveAsset: source => readerAssetURL(pageID, source)
  })
}

// Copies use the reader's login, never the author's browser authentication reference.
function readerAssetURL(pageID: string, source: string) {
  return readerURL(fileURL(pageID, assetFilePath(source)))
}

function readerURL(path: string) {
  const url = new URL(path, window.location.origin)
  url.searchParams.delete('authentication_ref')
  return url.href
}

function withCustomIcon(markdown: string, source?: string) {
  return source ? `![](<${source}>)\n\n${markdown}` : markdown
}

function assetFilePath(source: string) {
  return `assets/${source.slice('ankole:asset/'.length)}`
}

function isMissingOrForbidden(error: unknown): boolean {
  return error instanceof InternalAPIError && (error.status === 403 || error.status === 404)
}

/** A download captures the supplied draft, then gathers local assets and embedded File Pages before saving. */
export async function downloadDocument(
  client: QueryClient,
  document: { pageID: string; xml: string; title: string; icon?: string | null }
): Promise<void> {
  const { pageID, xml, title, icon } = document
  const [references, principals] = await Promise.all([
    loadDocumentReferences(client, [xml]),
    loadDocumentPrincipals([xml], pageID)
  ])
  const filename = documentFilename(title)
  const assets = documentAssets(xml)
  const embeddedFileReferences = documentEmbedIDs(xml)
    .map(id => references.get(id))
    .filter((reference): reference is DocumentReference & { filePageID: string } => Boolean(reference?.filePageID))
  if (!assets.length && !embeddedFileReferences.length && !isCustomEmojiIcon(icon)) {
    saveDownload(
      new Blob([documentMarkdownForExport(pageID, xml, title, icon, references, principals)], {
        type: 'text/markdown;charset=utf-8'
      }),
      filename
    )
    return
  }

  const chunks: BlobPart[] = []
  let zipError: unknown
  let archive: import('fflate').Zip | undefined
  let ZipPassThroughCtor: typeof import('fflate').ZipPassThrough | undefined
  let bundledCount = 0

  const appendEntry = async (path: string, bytes: Uint8Array) => {
    if (!archive || !ZipPassThroughCtor) {
      const fflate = await import('fflate')
      ZipPassThroughCtor = fflate.ZipPassThrough
      // Images and uploaded files are usually compressed already; storing them avoids a costly recompression.
      archive = new fflate.Zip((err, chunk) => {
        if (err) zipError = err
        else chunks.push(chunk as BlobPart)
      })
    }
    if (zipError) throw zipError
    const entry = new ZipPassThroughCtor(path)
    archive.add(entry)
    entry.push(bytes, true)
    if (zipError) throw zipError
  }

  const tryAddFile = async (url: string, name: string): Promise<string | undefined> => {
    const response = await fetch(new URL(url, window.location.origin).href, { credentials: 'same-origin' })
    if (response.status === 403 || response.status === 404) return undefined
    if (!response.ok) throw new InternalAPIError(response.status, response.statusText, {})
    const safeName = name.replace(/[\\/:*?"<>|\p{Cc}\s]+/gu, '-').replace(/^\.+/, '') || 'attachment'
    bundledCount += 1
    const path = `assets/${bundledCount}-${safeName}`
    await appendEntry(path, new Uint8Array(await response.arrayBuffer()))
    return path.split('/').map(encodeURIComponent).join('/')
  }

  const assetPaths = new Map<string, string>()
  for (const source of assets) {
    const path = await tryAddFile(fileURL(pageID, assetFilePath(source)), source.split('/').at(-1) || 'attachment')
    if (path) assetPaths.set(source, path)
  }

  const embedPaths = new Map<string, string>()
  for (const reference of embeddedFileReferences) {
    let manifest: Awaited<ReturnType<typeof podFiles>> | undefined
    try {
      manifest = await podFiles({ path: { id: reference.filePageID } })
    } catch (error) {
      if (!isMissingOrForbidden(error)) throw error
    }
    const file = manifest?.files.find(item => !item.path.startsWith('assets/') && !item.path.startsWith('attachments/'))
    if (!file) continue
    const path = await tryAddFile(
      fileURL(reference.filePageID, file.path, file.sha256),
      file.path.split('/').at(-1) || 'attachment'
    )
    if (path) embedPaths.set(reference.filePageID, path)
  }

  const customIcon = isCustomEmojiIcon(icon)
    ? await tryAddFile(metadataFileURL(icon), icon.split('/').at(-1) || 'icon')
    : undefined

  const markdown = documentMarkdown(xml, documentHeading(title, icon), {
    resolveAsset: source => assetPaths.get(source) ?? readerURL(fileURL(pageID, assetFilePath(source))),
    resolveReference: ref => references.get(ref),
    resolveEmbed: ref => {
      const reference = references.get(ref)
      const bundled = embedPaths.get(ref)
      return reference && bundled ? { ...reference, href: bundled } : reference
    },
    resolvePrincipal: uid => principals.get(uid)
  })
  const content = withCustomIcon(markdown, customIcon)

  if (!archive) {
    saveDownload(new Blob([content], { type: 'text/markdown;charset=utf-8' }), filename)
    return
  }

  await appendEntry(filename, new TextEncoder().encode(content))
  archive.end()
  if (zipError) throw zipError
  saveDownload(new Blob(chunks, { type: 'application/zip' }), filename.replace(/\.md$/, '.zip'))
}

function saveDownload(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob)
  const anchor = window.document.createElement('a')
  anchor.href = url
  anchor.download = filename
  anchor.click()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}
