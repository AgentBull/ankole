import type { JsonObject as JSONObject } from '@agentbull/active-support'

export interface MemoryEntryReference {
  id: string
  lockVersion: number
  name: string
  store: string
}

export interface MemoryBlockReference {
  id: string
  lockVersion: number
  position: number
}

export interface MemoryRelationReference {
  id: string
}

type EntryState = MemoryEntryReference & {
  aliases: string[]
  blocks: Map<number, MemoryBlockReference>
  relations: Map<string, MemoryRelationReference>
}

const sourceMarker = /(?<![A-Za-z0-9_-])src:((?:signal-gateway-entry|brain-source):[A-Za-z0-9_-]+)(?![A-Za-z0-9_:-])/g
const sourceAliasMarker = /(?<![A-Za-z0-9_-])src:(source_[1-9]\d*)(?![A-Za-z0-9_-])/g

/** Keeps model-local references for one Agent turn. */
export class MemoryModelReferences {
  readonly #entries = new Map<string, EntryState>()
  readonly #sourceAliases = new Map<string, string>()
  readonly #sourceDocuments = new Map<string, string>()
  readonly #browseCursors = new Map<string, string>()
  readonly #blockCursors = new Map<string, string>()

  registerSource(documentID: string): string {
    const existing = this.#sourceAliases.get(documentID)
    if (existing) return existing

    const alias = `source_${this.#sourceAliases.size + 1}`
    this.#sourceAliases.set(documentID, alias)
    this.#sourceDocuments.set(alias, documentID)
    return alias
  }

  sourceDocument(source: string): string {
    const documentID = this.#sourceDocuments.get(source)
    if (!documentID) throw new Error(`unknown memory source ${source}; use a source returned in this turn`)
    return documentID
  }

  browseCursor(page: string): string {
    const cursor = this.#browseCursors.get(page)
    if (!cursor) throw new Error(`unknown memory page ${page}; use the page returned by memory_browse`)
    return cursor
  }

  blockCursor(entryName: string, position: number): string {
    const cursor = this.#blockCursors.get(blockCursorKey(entryName, position))
    if (!cursor) {
      throw new Error(
        `unknown block continuation after position ${position} for ${entryName}; open the preceding page first`
      )
    }
    return cursor
  }

  entry(name: string): MemoryEntryReference {
    const entry = this.#entries.get(referenceKey(name))
    if (!entry) throw new Error(`unknown memory entry ${name}; call memory_open with its canonical name first`)
    return entry
  }

  block(entryName: string, position: number): MemoryBlockReference {
    const entry = this.#entryState(entryName)
    const block = entry.blocks.get(position)
    if (!block) {
      throw new Error(`unknown block position ${position} for ${entry.name}; call memory_open for that block first`)
    }
    return block
  }

  relation(entryName: string, predicate: string, targetName: string): MemoryRelationReference {
    const entry = this.#entryState(entryName)
    const relation = entry.relations.get(relationKey(predicate, targetName))
    if (!relation) {
      throw new Error(
        `unknown relation ${entry.name} ${predicate} ${targetName}; call memory_open for ${entry.name} first`
      )
    }
    return relation
  }

  expandSourceMarkers(body: string): string {
    return body.replace(sourceAliasMarker, (_marker, source: string) => `src:${this.sourceDocument(source)}`)
  }

  invalidateEntries(): void {
    this.#entries.clear()
    this.#blockCursors.clear()
  }

  searchResult(details: JSONObject): JSONObject {
    const results = arrayField(details, 'results').map(result => this.#searchItem(result))
    return compactObject({
      status: stringField(details, 'status'),
      result_completeness: stringField(details, 'result_completeness'),
      results,
      history_notice: stringField(details, 'history_notice'),
      degraded_reasons: stringArrayField(details, 'degraded_reasons')
    })
  }

  browseResult(details: JSONObject): JSONObject {
    const documentID = stringField(details, 'document_id')
    const nextCursor = stringField(details, 'next_cursor')
    const entries = arrayField(details, 'entries').map(entry => this.#chatMessage(entry))

    return compactObject({
      status: stringField(details, 'status'),
      ...(documentID ? { source: this.registerSource(documentID) } : {}),
      history_notice: stringField(details, 'history_notice'),
      entries,
      ...(nextCursor ? { next_page: this.#registerBrowseCursor(nextCursor) } : {})
    })
  }

  openResult(details: JSONObject, requestedName?: string): JSONObject {
    const rawEntry = recordField(details, 'entry')
    if (!rawEntry) return this.genericResult(details)

    const state = this.#registerEntry(rawEntry)
    if (!state) return this.genericResult(details)
    if (requestedName) this.#entries.set(referenceKey(requestedName), state)

    const blocks = arrayField(details, 'blocks')
    const blockPositions = new Map<string, number>()

    const modelBlocks = blocks.flatMap(rawBlock => {
      const id = stringField(rawBlock, 'id')
      const position = positiveIntegerField(rawBlock, 'position')
      const lockVersion = positiveIntegerField(rawBlock, 'lock_version')
      if (!id || !position || !lockVersion) return []

      const block = { id, position, lockVersion }
      state.blocks.set(position, block)
      blockPositions.set(id, position)
      const body = this.#rewriteSourceMarkers(stringField(rawBlock, 'body') ?? '')

      return [
        compactObject({
          position,
          body,
          author_kind: stringField(rawBlock, 'author_kind'),
          inserted_at: stringField(rawBlock, 'inserted_at'),
          updated_at: stringField(rawBlock, 'updated_at')
        })
      ]
    })

    const citations = arrayField(details, 'citations').flatMap(rawCitation => {
      const blockID = stringField(rawCitation, 'block_id')
      const documentID = stringField(rawCitation, 'document_id')
      const position = blockID ? blockPositions.get(blockID) : undefined
      if (!documentID || !position) return []

      return [
        compactObject({
          block_position: position,
          source: this.registerSource(documentID),
          source_kind: stringField(rawCitation, 'source_kind')
        })
      ]
    })

    const relations = arrayField(details, 'relations').flatMap(raw => {
      const relation = recordField(raw, 'relation')
      const target = recordField(raw, 'target')
      const relationID = relation && stringField(relation, 'id')
      const predicate = relation && stringField(relation, 'predicate')
      const targetState = target && this.#registerEntry(target)
      if (!relationID || !predicate || !targetState) return []

      state.relations.set(relationKey(predicate, targetState.name), { id: relationID })
      return [
        compactObject({
          predicate,
          target: compactObject({ name: targetState.name, type: stringField(target, 'type') })
        })
      ]
    })

    const backlinks = arrayField(details, 'backlinks').flatMap(raw => {
      const relation = recordField(raw, 'relation')
      const source = recordField(raw, 'source')
      const predicate = relation && stringField(relation, 'predicate')
      const sourceState = source && this.#registerEntry(source)
      if (!predicate || !sourceState) return []

      return [
        compactObject({
          predicate,
          source: compactObject({ name: sourceState.name, type: stringField(source, 'type') })
        })
      ]
    })

    const nextBlockCursor = stringField(details, 'next_block_cursor')
    const lastPosition = modelBlocks.at(-1)?.position
    if (nextBlockCursor && typeof lastPosition === 'number') {
      this.#blockCursors.set(blockCursorKey(state.name, lastPosition), nextBlockCursor)
      if (requestedName) this.#blockCursors.set(blockCursorKey(requestedName, lastPosition), nextBlockCursor)
    }

    return compactObject({
      status: stringField(details, 'status'),
      history_notice: stringField(details, 'history_notice'),
      entry: compactObject({
        name: state.name,
        type: stringField(rawEntry, 'type'),
        summary: stringField(rawEntry, 'summary'),
        aliases: stringArrayField(rawEntry, 'aliases'),
        properties: objectField(rawEntry, 'properties'),
        inserted_at: stringField(rawEntry, 'inserted_at'),
        updated_at: stringField(rawEntry, 'updated_at')
      }),
      blocks: modelBlocks,
      citations,
      relations,
      backlinks,
      ...(nextBlockCursor && typeof lastPosition === 'number' ? { next_after_position: lastPosition } : {})
    })
  }

  updateResult(details: JSONObject): JSONObject {
    return compactObject({ status: stringField(details, 'status') ?? 'updated' })
  }

  genericResult(details: JSONObject): JSONObject {
    return scrubRecord(details, this)
  }

  #registerEntry(raw: Record<string, unknown>): EntryState | undefined {
    const id = stringField(raw, 'id')
    const name = stringField(raw, 'name')
    const lockVersion = positiveIntegerField(raw, 'lock_version')
    const store = stringField(raw, 'store_key')
    if (!id || !name || !lockVersion || !store) return undefined

    const existing = this.#entries.get(referenceKey(name))
    const state: EntryState =
      existing && existing.id === id
        ? { ...existing, lockVersion, name, store, aliases: stringArrayField(raw, 'aliases') ?? [] }
        : {
            id,
            lockVersion,
            name,
            store,
            aliases: stringArrayField(raw, 'aliases') ?? [],
            blocks: new Map(),
            relations: new Map()
          }

    this.#entries.set(referenceKey(name), state)
    for (const alias of state.aliases) this.#entries.set(referenceKey(alias), state)
    return state
  }

  #entryState(name: string): EntryState {
    const entry = this.#entries.get(referenceKey(name))
    if (!entry) throw new Error(`unknown memory entry ${name}; call memory_open with its canonical name first`)
    return entry
  }

  #registerBrowseCursor(cursor: string): string {
    for (const [alias, current] of this.#browseCursors) {
      if (current === cursor) return alias
    }

    const alias = `page_${this.#browseCursors.size + 1}`
    this.#browseCursors.set(alias, cursor)
    return alias
  }

  #searchItem(raw: Record<string, unknown>): JSONObject {
    const layer = stringField(raw, 'layer')
    if (layer === 'knowledge') {
      return compactObject({
        layer,
        kind: stringField(raw, 'kind'),
        name: stringField(raw, 'name'),
        type: stringField(raw, 'type'),
        summary: stringField(raw, 'summary'),
        aliases: stringArrayField(raw, 'aliases'),
        properties: objectField(raw, 'properties'),
        updated_at: stringField(raw, 'updated_at'),
        snippet: this.#rewriteSourceMarkers(stringField(raw, 'snippet') ?? '')
      })
    }

    const documentID = stringField(raw, 'document_id')
    return compactObject({
      layer,
      kind: stringField(raw, 'kind'),
      topic: stringField(raw, 'topic'),
      question: stringField(raw, 'question'),
      text: stringField(raw, 'text'),
      resolution: stringField(raw, 'resolution'),
      systems: stringArrayField(raw, 'systems'),
      started_at: stringField(raw, 'started_at'),
      ended_at: stringField(raw, 'ended_at'),
      observed_at: stringField(raw, 'observed_at'),
      channel: objectField(raw, 'channel'),
      speaker: stringField(raw, 'speaker'),
      history_notice: stringField(raw, 'history_notice'),
      summary_notice: stringField(raw, 'summary_notice'),
      ...(documentID ? { source: this.registerSource(documentID) } : {}),
      messages: arrayField(raw, 'messages').map(message => this.#chatMessage(message))
    })
  }

  #chatMessage(raw: Record<string, unknown>): JSONObject {
    const documentID = stringField(raw, 'document_id')
    return compactObject({
      ...(documentID ? { source: this.registerSource(documentID) } : {}),
      observed_at: stringField(raw, 'observed_at'),
      speaker: stringField(raw, 'speaker'),
      text: stringField(raw, 'text'),
      anchor: booleanField(raw, 'anchor')
    })
  }

  #rewriteSourceMarkers(value: string): string {
    return value.replace(sourceMarker, (_marker, documentID: string) => `src:${this.registerSource(documentID)}`)
  }
}

function scrubRecord(raw: Record<string, unknown>, references: MemoryModelReferences): JSONObject {
  const output: JSONObject = {}

  for (const [key, value] of Object.entries(raw)) {
    if (key === 'document_id' && typeof value === 'string') {
      output.source = references.registerSource(value)
      continue
    }
    if (hiddenKey(key)) continue

    const scrubbed = scrubValue(value, references)
    if (scrubbed !== undefined) output[key] = scrubbed
  }

  return output
}

function scrubValue(value: unknown, references: MemoryModelReferences): JSONObject[string] | undefined {
  if (value === null || typeof value === 'boolean' || typeof value === 'number') return value
  if (typeof value === 'string') {
    return value.replace(sourceMarker, (_marker, documentID: string) => `src:${references.registerSource(documentID)}`)
  }
  if (Array.isArray(value)) {
    return value.flatMap(item => {
      const scrubbed = scrubValue(item, references)
      return scrubbed === undefined ? [] : [scrubbed]
    })
  }
  if (isRecord(value)) return scrubRecord(value, references)
  return undefined
}

function hiddenKey(key: string): boolean {
  return (
    key === 'id' ||
    key === 'store' ||
    key === 'store_key' ||
    key === 'metadata' ||
    key === 'error' ||
    key === 'lock_version' ||
    key.endsWith('_error') ||
    key.endsWith('_id') ||
    key.endsWith('_ids') ||
    key.endsWith('_uid') ||
    key.endsWith('_uids')
  )
}

function compactObject(values: Record<string, unknown>): JSONObject {
  return Object.fromEntries(Object.entries(values).filter(([, value]) => value !== undefined)) as JSONObject
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function recordField(record: Record<string, unknown>, key: string): Record<string, unknown> | undefined {
  const value = record[key]
  return isRecord(value) ? value : undefined
}

function objectField(record: Record<string, unknown>, key: string): JSONObject | undefined {
  return recordField(record, key) as JSONObject | undefined
}

function arrayField(record: Record<string, unknown>, key: string): Record<string, unknown>[] {
  const value = record[key]
  return Array.isArray(value) ? value.filter(isRecord) : []
}

function stringField(record: Record<string, unknown>, key: string): string | undefined {
  const value = record[key]
  return typeof value === 'string' && value !== '' ? value : undefined
}

function stringArrayField(record: Record<string, unknown>, key: string): string[] | undefined {
  const value = record[key]
  if (!Array.isArray(value)) return undefined
  return value.filter((item): item is string => typeof item === 'string')
}

function positiveIntegerField(record: Record<string, unknown>, key: string): number | undefined {
  const value = record[key]
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0 ? value : undefined
}

function booleanField(record: Record<string, unknown>, key: string): boolean | undefined {
  const value = record[key]
  return typeof value === 'boolean' ? value : undefined
}

function referenceKey(value: string): string {
  return value.trim().normalize('NFKC').toLocaleLowerCase()
}

function relationKey(predicate: string, targetName: string): string {
  return `${referenceKey(predicate)}\u0000${referenceKey(targetName)}`
}

function blockCursorKey(entryName: string, position: number): string {
  return `${referenceKey(entryName)}\u0000${position}`
}
