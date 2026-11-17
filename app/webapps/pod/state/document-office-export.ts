import { parseXml } from '@ankole/block-editor/document'
import type { QueryClient } from '@tanstack/react-query'
import { downloadBlob } from '../../common/browser-files'
import i18n from '../../common/i18n'
import { resolveOfficeFontBlobs, selectPendingFontFamilies } from '../office/office-fonts'
import { createPageExportEngine, type ExportFontNeeds, type PageExportEngine } from '../word/word-engine'
import { loadDocumentPrincipals, loadDocumentReferences } from './document-export'
import { prerenderPageForExport, type ExportNode, type PrerenderHooks } from './document-export-prerender'
import { documentFilename, type DocumentPrincipalReference, type DocumentReference } from './document-tools'
import { propertyText, type KnowledgeMetadata } from './knowledge-draft'

export type OfficeExportFormat = 'docx' | 'pdf'

export type DocumentOfficeExportInput = {
  pageID: string
  xml: string
  title: string
  icon?: string | null
  metadata?: KnowledgeMetadata
}

export type DocumentOfficeExportOptions = {
  createEngine?: () => PageExportEngine
  prerenderHooks?: PrerenderHooks
}

type SerializedMetadataRow = {
  key: string
  value: string
}

type SerializedResolvedReference = {
  title: string
  href: string
  restricted: boolean
}

type SerializedResolvedPrincipal = {
  name: string
  restricted: boolean
}

type SerializedPageExportRequest = {
  title: string
  iconText?: string
  iconAssetKey?: string
  metadataRows?: SerializedMetadataRow[]
  root: ExportNode
  references: Record<string, SerializedResolvedReference>
  principals: Record<string, SerializedResolvedPrincipal>
}

const DOCX_MIME_TYPE = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
const PDF_MIME_TYPE = 'application/pdf'
const MAX_FONT_CONVERGENCE_PASSES = 6
const MAX_TRANSIENT_FONT_RETRIES = 1

function isNestedValue(value: unknown): value is Record<string, unknown> | unknown[] {
  return value !== null && typeof value === 'object'
}

function isScalarArray(value: unknown): value is unknown[] {
  return Array.isArray(value) && !value.some(isNestedValue)
}

function collectMetadataReferenceIDs(metadata: KnowledgeMetadata | undefined): string[] {
  if (!metadata) return []
  const ids = new Set<string>()
  const visit = (value: unknown) => {
    if (Array.isArray(value)) {
      for (const item of value) visit(item)
      return
    }
    if (value !== null && typeof value === 'object') {
      for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
        if ((key === 'page_id' || key === 'subject') && typeof item === 'string' && item.trim()) {
          ids.add(item.trim())
        } else {
          visit(item)
        }
      }
    }
  }
  visit(metadata)
  return [...ids]
}

function formatKnowledgeValue(
  value: unknown,
  references: ReadonlyMap<string, DocumentReference>,
  indentLevel = 0
): string {
  if (isScalarArray(value)) {
    return value.map(item => propertyText(item)).join(', ')
  }
  if (Array.isArray(value)) {
    return value
      .map(item => formatKnowledgeValue(item, references, indentLevel))
      .filter(Boolean)
      .join('\n')
  }
  if (value !== null && typeof value === 'object') {
    const pad = indentLevel > 0 ? '  '.repeat(indentLevel) : ''
    return Object.entries(value as Record<string, unknown>)
      .map(([key, item]) => {
        if ((key === 'page_id' || key === 'subject') && typeof item === 'string' && item.trim()) {
          const resolved = references.get(item.trim())
          const label =
            resolved?.title ??
            i18n.t('pod.mention.restricted_page', {
              defaultValue: i18n.t('pod.document.reference_unavailable', { defaultValue: 'Restricted page' })
            })
          return `${pad}${key}: ${label}`
        }
        if (isNestedValue(item) && !isScalarArray(item)) {
          return `${pad}${key}:\n${formatKnowledgeValue(item, references, indentLevel + 1)}`
        }
        return `${pad}${key}: ${formatKnowledgeValue(item, references, indentLevel + 1)}`
      })
      .join('\n')
  }
  return propertyText(value)
}

export function formatKnowledgeMetadataRows(
  metadata: KnowledgeMetadata | undefined,
  references: ReadonlyMap<string, DocumentReference> = new Map()
): SerializedMetadataRow[] {
  if (!metadata) return []
  const rows: SerializedMetadataRow[] = []
  for (const [key, value] of Object.entries(metadata)) {
    const trimmedKey = key.trim()
    if (!trimmedKey) continue
    rows.push({
      key: trimmedKey,
      value: formatKnowledgeValue(value, references)
    })
  }
  return rows
}

function serializeReferences(
  references: ReadonlyMap<string, DocumentReference>
): Record<string, SerializedResolvedReference> {
  const out: Record<string, SerializedResolvedReference> = {}
  for (const [id, ref] of references) {
    out[id] = {
      title: ref.title,
      href: ref.restricted ? '' : ref.href,
      restricted: Boolean(ref.restricted)
    }
  }
  return out
}

function serializePrincipals(
  principals: ReadonlyMap<string, DocumentPrincipalReference>
): Record<string, SerializedResolvedPrincipal> {
  const out: Record<string, SerializedResolvedPrincipal> = {}
  for (const [uid, principal] of principals) {
    out[uid] = {
      name: principal.name,
      restricted: Boolean(principal.restricted)
    }
  }
  return out
}

async function convergePdfExportFonts(engine: PageExportEngine, initialNeeds: ExportFontNeeds): Promise<void> {
  let currentNeeds = initialNeeds
  const attempted = new Set<string>()
  const retryCounts = new Map<string, number>()

  for (let pass = 0; pass < MAX_FONT_CONVERGENCE_PASSES; pass += 1) {
    const pending = selectPendingFontFamilies(
      {
        substitutedFamilies: currentNeeds.substitutedFamilies,
        missingGlyphFamilies: currentNeeds.missingGlyphFamilies
      },
      attempted
    )
    if (pending.length === 0) {
      break
    }

    const { blobs, complete } = await resolveOfficeFontBlobs(pending)
    if (complete) {
      for (const family of pending) attempted.add(family)
    } else {
      for (const family of pending) {
        const failures = retryCounts.get(family) ?? 0
        if (failures >= MAX_TRANSIENT_FONT_RETRIES) {
          attempted.add(family)
        } else {
          retryCounts.set(family, failures + 1)
        }
      }
    }

    if (blobs.length > 0) {
      currentNeeds = await engine.addExportFonts(blobs)
    }
  }
}

/**
 * Compiles a Document or Knowledge Page draft into print-quality `.docx` or `.pdf` bytes via a
 * disposable WordCraft WebAssembly Worker and triggers a browser file download.
 */
export async function downloadDocumentAsOffice(
  client: QueryClient,
  document: DocumentOfficeExportInput,
  format: OfficeExportFormat,
  options?: DocumentOfficeExportOptions
): Promise<void> {
  const { pageID, xml, title, icon, metadata } = document
  const parsedRoot = parseXml(xml)
  const metadataRefIDs = collectMetadataReferenceIDs(metadata)

  const [references, principals, prerendered] = await Promise.all([
    loadDocumentReferences(client, [parsedRoot], metadataRefIDs),
    loadDocumentPrincipals([parsedRoot], pageID),
    prerenderPageForExport({
      pageID,
      xml: parsedRoot,
      icon,
      format,
      hooks: options?.prerenderHooks
    })
  ])

  const metadataRows = formatKnowledgeMetadataRows(metadata, references)
  const effectiveTitle = title.trim() || i18n.t('pod.content.untitled', { defaultValue: 'Untitled' })

  const request: SerializedPageExportRequest = {
    title: effectiveTitle,
    ...(prerendered.iconText ? { iconText: prerendered.iconText } : {}),
    ...(prerendered.iconAssetKey ? { iconAssetKey: prerendered.iconAssetKey } : {}),
    ...(metadataRows.length > 0 ? { metadataRows } : {}),
    root: prerendered.root,
    references: serializeReferences(references),
    principals: serializePrincipals(principals)
  }

  const createEngine = options?.createEngine ?? createPageExportEngine
  const engine = createEngine()
  try {
    const initialFontNeeds = await engine.openPageExport(JSON.stringify(request), prerendered.assets, format === 'pdf')
    if (format === 'pdf' && initialFontNeeds) {
      await convergePdfExportFonts(engine, initialFontNeeds)
    }
    const bytes = format === 'docx' ? await engine.exportPageDocx() : await engine.exportPagePdf()
    const blob = new Blob([bytes as BlobPart], {
      type: format === 'docx' ? DOCX_MIME_TYPE : PDF_MIME_TYPE
    })
    downloadBlob(blob, documentFilename(title, 'document', format))
  } finally {
    engine.dispose()
  }
}
