import { sql } from 'drizzle-orm'
import {
  boolean,
  check,
  index,
  jsonb,
  pgTable,
  primaryKey,
  text,
  timestamp,
  uniqueIndex,
  uuid
} from 'drizzle-orm/pg-core'
import { Agents, type JsonObject, type JsonValue } from './principals'

/** Canonical skill registry. `default_enabled` is the only distinction for built-in always-on skills. */
export const LibrarySkills = pgTable(
  'library_skills',
  {
    id: uuid('id').primaryKey().notNull(),
    name: text('name').notNull(),
    description: text('description').notNull(),
    // `default_enabled`: should this skill be on for an agent that has no explicit
    // assignment (see AgentSkillAssignments). `enabled`: registry-wide kill switch
    // for the skill itself, independent of per-agent choices.
    defaultEnabled: boolean('default_enabled').default(false).notNull(),
    enabled: boolean('enabled').default(true).notNull(),
    // Where the skill came from (e.g. 'builtin'); built-ins are re-synced from
    // disk while other sources are not.
    sourceKind: text('source_kind').default('builtin').notNull(),
    // Hash of the on-disk source; lets a builtin sync skip re-import when unchanged.
    sourceHash: text('source_hash'),
    rootPath: text('root_path').notNull(),
    metadata: jsonb('metadata').$type<JsonObject>().default({}).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    // Soft-delete marker: archived skills are retained (assignments may still
    // reference them) but excluded from the active set.
    archivedAt: timestamp('archived_at', { withTimezone: true })
  },
  t => [
    uniqueIndex('library_skills_name_index').on(t.name),
    // Serves "which skills are on by default" listing without scanning the table.
    index('library_skills_enabled_index').on(t.enabled, t.defaultEnabled),
    // Slug shape: lowercase, used as a stable handle and in paths.
    check('library_skills_name_format', sql`${t.name} ~ '^[a-z][a-z0-9_-]{0,63}$'`),
    check('library_skills_description_nonempty', sql`length(trim(${t.description})) > 0`),
    check('library_skills_root_path_nonempty', sql`length(trim(${t.rootPath})) > 0`),
    check('library_skills_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`)
  ]
)

/** Canonical base files for a skill. Agent runtime never writes these directly. */
export const LibrarySkillFiles = pgTable(
  'library_skill_files',
  {
    id: uuid('id').primaryKey().notNull(),
    skillId: uuid('skill_id')
      .notNull()
      .references(() => LibrarySkills.id, { onDelete: 'cascade' }),
    // Path within the skill's virtual tree; the check below keeps it relative.
    virtualPath: text('virtual_path').notNull(),
    contentText: text('content_text').notNull(),
    // BLAKE3 of the content, for cheap change detection during sync.
    contentBlake3: text('content_blake3').notNull(),
    contentMediaType: text('content_media_type').default('text/plain').notNull(),
    metadata: jsonb('metadata').$type<JsonObject>().default({}).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [
    uniqueIndex('library_skill_files_skill_path_index').on(t.skillId, t.virtualPath),
    index('library_skill_files_skill_index').on(t.skillId),
    // Path-traversal guard: rejects absolute paths, any `..` segment, and double
    // slashes, so a stored path can never escape the skill's materialized root.
    check('library_skill_files_virtual_path_relative', sql`${t.virtualPath} !~ '(^/|(^|/)\.\.(/|$)|//)'`),
    check('library_skill_files_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`)
  ]
)

/** Agent-specific enable/disable override for a canonical skill. Missing row means `skills.default_enabled`. */
export const AgentSkillAssignments = pgTable(
  'agent_skill_assignments',
  {
    agentUid: text('agent_uid')
      .notNull()
      .references(() => Agents.uid, { onDelete: 'cascade' }),
    skillId: uuid('skill_id')
      .notNull()
      .references(() => LibrarySkills.id, { onDelete: 'cascade' }),
    enabled: boolean('enabled').notNull(),
    reason: text('reason'),
    metadata: jsonb('metadata').$type<JsonObject>().default({}).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [
    primaryKey({ columns: [t.agentUid, t.skillId] }),
    index('agent_skill_assignments_agent_index').on(t.agentUid),
    check('agent_skill_assignments_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`)
  ]
)

/** Agent-owned library filesystem entries: SOUL.md, MISSION.md, and per-agent skill append overlays. */
export const AgentLibraryContainerEntries = pgTable(
  'agent_library_container_entries',
  {
    id: uuid('id').primaryKey().notNull(),
    agentUid: text('agent_uid')
      .notNull()
      .references(() => Agents.uid, { onDelete: 'cascade' }),
    virtualPath: text('virtual_path').notNull(),
    // 'file' or 'directory' (see check below); directories let the tree carry
    // empty folders and metadata-only nodes.
    entryKind: text('entry_kind').default('file').notNull(),
    // What produced this entry (soul/mission/skill_append/setting/memory/...).
    // Distinguishes agent-authored content from system-managed overlays so sync
    // and rendering can treat them differently.
    sourceKind: text('source_kind').notNull(),
    // Back-reference to the origin (e.g. the skill a skill_append overlays).
    sourceRef: jsonb('source_ref').$type<JsonObject>().default({}).notNull(),
    // Exactly one of contentText / contentBytes is set (see one-content check):
    // text entries keep readable content; binary entries hold base64/byte content.
    contentText: text('content_text'),
    contentBytes: text('content_bytes'),
    contentMediaType: text('content_media_type').default('text/plain').notNull(),
    contentBlake3: text('content_blake3').notNull(),
    metadata: jsonb('metadata').$type<JsonObject>().default({}).notNull(),
    enabled: boolean('enabled').default(true).notNull(),
    version: text('version').default('1').notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    // Soft delete: a path is freed for reuse the moment this is set, while the old
    // row is kept for history.
    deletedAt: timestamp('deleted_at', { withTimezone: true })
  },
  t => [
    // Uniqueness applies only to live entries, so one agent has at most one active
    // entry per path, yet any number of soft-deleted rows can share that path.
    uniqueIndex('agent_library_entries_active_path_index')
      .on(t.agentUid, t.virtualPath)
      .where(sql`${t.deletedAt} IS NULL`),
    // Serves per-agent tree listing filtered by enabled, ordered by path.
    index('agent_library_entries_agent_index').on(t.agentUid, t.enabled, t.virtualPath),
    // Same path-traversal guard as skill files: no absolute paths, no `..`, no `//`.
    check('agent_library_entries_virtual_path_relative', sql`${t.virtualPath} !~ '(^/|(^|/)\.\.(/|$)|//)'`),
    check('agent_library_entries_kind_check', sql`${t.entryKind} in ('file', 'directory')`),
    check(
      'agent_library_entries_source_check',
      sql`${t.sourceKind} in ('soul', 'mission', 'skill_append', 'setting', 'memory', 'system', 'user', 'computer')`
    ),
    // Text/bytes are mutually exclusive: an entry is either textual or binary,
    // never both. (Both-null is allowed, e.g. a directory entry.)
    check(
      'agent_library_entries_one_content',
      sql`not (${t.contentText} is not null and ${t.contentBytes} is not null)`
    ),
    check('agent_library_entries_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`),
    check('agent_library_entries_source_ref_object', sql`jsonb_typeof(${t.sourceRef}) = 'object'`)
  ]
)

/**
 * Hash short-circuit for full overwrite sync from app/library/skills.
 *
 * One row per sync unit (`sync_key`) remembers the hash last successfully synced.
 * Startup compares the current source hash and skips the otherwise destructive
 * full overwrite when nothing changed, so an unchanged build does not churn the
 * library tables on every boot.
 */
export const LibraryBuiltinSyncState = pgTable('library_builtin_sync_state', {
  syncKey: text('sync_key').primaryKey().notNull(),
  contentHash: text('content_hash').notNull(),
  metadata: jsonb('metadata').$type<JsonValue>().default({}).notNull(),
  syncedAt: timestamp('synced_at', { withTimezone: true })
    .default(sql`now()`)
    .notNull()
})
