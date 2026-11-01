# Unified Drive upgrade

Before applying migration `20261030120000`, stop all old control-plane writers
and Workers and back up PostgreSQL and the object store together. The migration
takes exclusive locks on the old trees, objects, grants, messages, and deliveries.
It may stream-copy large objects across tenant ownership boundaries while those
locks are held. Keep sufficient storage capacity for those copies, and keep the
backup until the upgraded application has passed permission and content checks.
There is no automatic down migration; rollback requires both backups.

## Identity, paths, and object ownership

Existing Page IDs become Drive node IDs. Their Pod property rows, content,
comments, favorites, and saved-message links remain. Public top-level pages move
under the tenant's space root, and private pages move under their owner's private
root. Filenames are normalized to valid node names, truncated on UTF-8 boundaries,
and disambiguated deterministically within each parent. Document, Base, and
Applet titles remain Pod properties.

A legacy file Page can have child Pages, but a Drive file cannot be a directory.
The migration checks for this shape before changing data and stops with the
tenant, file Page, and child Page IDs. Move those children to an appropriate
non-file parent before retrying; the migration does not change their kind,
identity, parent, or visibility automatically.

Old Agent paths become folder and file nodes under that Agent's private root,
including historical `chats/` paths. Published message attachments additionally
receive conversation file nodes. Pod-managed assets, Base attachments, Applet
files, and custom emojis move to `pod_files`; they do not become visible Drive
nodes. A file Page's primary bytes become its node's object reference.

Each retained object belongs to exactly one tenant. If an old global blob was
shared by several tenants, one tenant keeps its existing storage key and the
others receive new keys populated by streaming copies. The migration checks each
copy's digest and size before committing references. Equal bytes are not deduplicated
by the new store. Message attachments and pending, failed, or unknown deliveries
retain immutable object references; sent and expired deliveries retain metadata
without prolonging the old byte-retention boundary.

Message and delivery attachment arrays become ordered relation rows. Pending or
provider-external entries without stored bytes remain metadata-only rows. Durable
system attachment slots in conversation signals, inbound batches, and
`reply_attachment` tool results (including retained compaction output) are
rewritten from `blob_ref` to tenant-owned `object_id`. User text, arbitrary tool
output, metadata, provider payloads and recovery checkpoints remain opaque;
their keys and JSON-looking strings are preserved. Tenant-composite foreign keys
protect every retained object and node reference. Deleting a referenced node
clears the optional node link without deleting the frozen message object.

Unreferenced legacy storage keys are queued for deletion in the same database
transaction. Workers execute those jobs only after commit. A normal migration
exception rolls back SQL and removes copies created by that attempt. Abrupt
process or host termination can leave unreferenced copied keys; restore the
paired backups before retrying an interrupted upgrade. Do not delete legacy
keys manually while their references are being converted.

## Agent Home storage names

Worker storage names include the provider installation and the Agent's tenant
identity. Before upgrading storage whose name was derived only from the Agent
UID, stop the control plane and its Workers and back up every Home. Apply schema
migrations with the control plane still stopped. Obtain the destination name
from a one-off container or Pod running the new release:

```sh
/app/bin/ankole eval 'IO.puts(Ankole.Repo.with_tenant("TENANT_UUID", fn -> Ankole.AgentWorkers.ProviderKind.storage_name("INSTALLATION", "AGENT_UID") end))'
```

For Docker deployments with an unmigrated pooled `agents_data` volume, the
Compose migration service performs the copy after the schema migration. It
requires each old UID directory to identify exactly one current tenant. Resolve
ambiguous directories manually before retrying.

### Dedicated Docker volumes

For an existing per-Agent volume, copy its current contents to a new local
volume using the name above. Set `old_home`, `new_home`, `installation`,
`provider`, `tenant_id`, and `agent_uid` to the inspected source volume and its
owning provider and Agent. If the destination exists, inspect and reconcile it
before proceeding. With an unused destination name:

```sh
docker volume create --driver local \
  --label "ankole.installation=$installation" \
  --label "ankole.provider=$provider" \
  --label "ankole.tenant=$tenant_id" \
  --label "ankole.agent-uid=$agent_uid" "$new_home"
docker run --rm --network none --entrypoint sh \
  --mount "type=volume,source=$old_home,target=/source,readonly" \
  --mount "type=volume,source=$new_home,target=/target" docker:29-cli -ec \
  'cp -a /source/. /target/; chown -R 1000:1000 /target; sync'
```

If the pooled volume contains a completion marker at
`.ankole-worker-provider-migration/<uid>`, update that marker to the new volume
name only after verifying this copy. A previous completed migration means the
dedicated volume contains the current Home; the pooled directory may be stale.
Keep the old volume until the upgraded Worker has verified its files. Cache
volumes can start empty.

### Dedicated Kubernetes claims

For `storage.claimTemplate`, create the destination claim from the provider's configured
Home claim template, then restore its backup or copy the old claim through a
temporary Pod while both Workers are stopped. Give the claim the destination
name, the `ankole.io/installation` and `ankole.io/provider` labels from its
provider, `ankole.tenant` with the tenant ID, `ankole.io/agent` with the final
16-character hash in the storage name, and `ankole.io/task: storage`. Set the
`ankole.io/agent-uid` annotation to the Agent UID. Preserve ownership as
`1000:1000`. Keep the old claim until the upgraded Worker has verified its files;
cache claims can start empty.

## Kubernetes shared Agent Homes

Workers using `storage.sharedClaim` mount a directory named by
`Ankole.AgentWorkers.ProviderKind.storage_name/2` within the shared claim. The
name includes the provider installation and the Agent's tenant-qualified
identity. Before starting upgraded Workers, move each legacy bare-UID directory
to that name. Keep the control plane and Workers stopped while moving directories,
and back up the claim first.

Keep the control-plane Deployment scaled to zero. Use a one-off Pod with the new
release image, the same database credentials and encryption key, and the shared
claim mounted at `/agents`. Apply the schema migrations, then run
`/app/bin/ankole eval 'Ankole.Upgrade202610.import_agent_home("/agents")'` while
the bare-UID directories are still present. The import starts its own database
connection without starting the Worker supervisors. The
[Helm deployment guide](../../tools/deploy/helm/ankole-agent/README.md) describes
the claim's required ownership and read permissions.

Mount the same claim in the preparation Pod used for the import and rename each
Agent's directory to its [tenant-qualified storage name](#agent-home-storage-names).
If that destination already exists,
inspect both directories and resolve their contents before proceeding; do not
overwrite it. Start the upgraded Workers only after every assigned Agent's Home
has been moved, then verify that each Worker sees its own files.

## Authorization changes

For a member or Agent without a legacy private Page, the migration initializes
owner permissions on the new private Drive root, as normal root creation does.
For existing private Pages, the permission comparison below verifies the
migrated grants.

The migration rewrites Pod resource patterns and `page_*` actions to Drive
patterns and `node_*` actions, including user-set grant edges. Conditions that
read the renamed `resource` or `action` CEL variables stop the migration with
specific grant IDs. Rewrite those conditions deliberately before upgrading; the
migration cannot infer their intended meaning. Other conditions are preserved.

Old private top-level pages always received their owner's private grants even
when `inherit_permissions` was false. Under an explicit private root, they use
`inherit_permissions: true` to preserve that effective access. Existing local
ACLs remain. The migration compares old and new effective permission bits for
every retained Principal and old Page and aborts on a difference. This comparison
uses the empty request context; preserved request-context conditions still need
the application's contextual authorization tests.

The global patterns `site_console:files` and `site_console:agent:*:files` become
`site_console:drive`, preserving each holder, action, and condition. A concrete
`site_console:agent:<uid>:files` grant becomes `drive:private:<uid>:**` within its
tenant. Its `read` action becomes `node_view`; `update` becomes `node_view`,
`node_contribute`, and `node_edit`; and `delete` becomes `node_edit`. Drive uses
`node_edit` for both replacement and deletion, so this mapping intentionally
merges those capabilities within that Agent's private directory. The
`node_contribute` grant preserves creation within nested folders. Grant holders,
conditions, descriptions, metadata, and timestamps are preserved; identical
resulting rules are deduplicated.

The migration rejects a concrete file grant if its target is not an Agent in
the grant's tenant, if the UID contains wildcard syntax, or if the action is
unsupported. Adjust the reported grants before retrying. The scoped conversion
runs after the existing Page-permission comparison because these Console grants
previously governed a separate file tree.

The upgrade also renames `pod.trash_retention_days` to
`drive.trash_retention_days` and retargets queued Page purge jobs to node purge
jobs. Base-table cleanup jobs remain with Pod. The old `files` and `drive_files`
tables and Page topology columns are removed after validation succeeds.

## Verification and FUSE

`integration/drive_migration_test.exs` exercises both a fresh database and an
upgrade fixture with shared multi-tenant blobs, all reference owners, conditional
and user-set grants, private inheritance, trash, saved attachments, and deferred
integrity checks. It creates and drops isolated temporary databases; it does not
upgrade the development database. Run it with the integration-test environment
described in [CONTRIBUTING](../../CONTRIBUTING.md#run-the-right-checks).

This schema upgrade does not publish FUSE. The current Kubernetes baseline lacks
the required device and mount capability. `ankole-files` continues using the
unified store until every built-in provider passes the release prerequisite in
[Agent Workers](../design-docs/AgentWorkers.md#drive-fuse-release-prerequisite).
