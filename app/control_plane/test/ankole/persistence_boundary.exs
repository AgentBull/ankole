# The persistence boundary of Ankole. Ankole.PersistenceBoundaryTest and the
# Credo checks AshBoundary and RawSQLTenant read this file.
#
# exceptions: modules (or {module, functions}) whose nature does not match
# Ash resource semantics. Each entry names its mismatch pattern from the
# architecture plan (section 2.2). An entry can use Ecto writes, Ecto row locks,
# Repo transactions, and Ecto queries of resource tables. A read model selects
# maps or values, not resource structs. The boundary test removes an entry that
# no longer uses the database directly.
#
# baseline: the reviewed count of each crossing per file ("kind:path"). Each
# domain task removes the entries of its own files; the final task asserts an
# empty baseline. Add a count only with a review of the crossing.
%{
  exceptions: %{
    # M2 process coordination: the Repo itself and its database clock, advisory
    # locks, and Oban job rows, which are not Ankole resources.
    Ankole.Repo => :m2_process_coordination,
    Ankole.AdvisoryLock => :m2_process_coordination,
    Ankole.Job => :m2_process_coordination,
    # M4 read models: projections of several resources that give maps.
    Ankole.AuthZ.Snapshot => :m4_read_model,
    {Ankole.AuthZ, [:restoration_review]} => :m4_read_model,
    {Ankole.Pod.Access, [:path, :canonical_navigation, :subtree_preserves_permissions?]} =>
      :m4_read_model,
    {Ankole.Pod.Jobs.PurgePage, [:descendants]} => :m4_read_model,
    {Ankole.Brain.ConversationsLearning, [:known_pages]} => :m4_read_model,
    {Ankole.Brain.Dreaming, [:consolidation_buckets, :term_usage]} => :m4_read_model,
    {Ankole.Brain.Merge,
     [:alias_candidates, :merge_scan_scope, :exclude_recorded_and_principal_pairs]} =>
      :m4_read_model,
    {Ankole.Workflow.Queries, [:capacity_candidate]} => :m4_read_model,
    # M7 dynamic schema: the Pod database subsystem owns db_records.
    Ankole.Pod.Database => :m7_dynamic_schema,
    Ankole.Pod.Database.Records => :m7_dynamic_schema,
    Ankole.Pod.Database.Schema => :m7_dynamic_schema,
    Ankole.Pod.Query => :m7_dynamic_schema,
    Ankole.Pod.Copy => :m7_dynamic_schema,
    Ankole.Pod.Values => :m7_dynamic_schema,
    # M8 set maintenance: DDL, tenant teardown, merges, and the one-time upgrade.
    Ankole.Brain.SearchIndexes => :m8_set_maintenance,
    {Ankole.Brain.Merge,
     [:repoint_timelines, :repoint_unique_rows, :repoint_links, :repoint_link_column]} =>
      :m8_set_maintenance,
    Ankole.Tenants.Jobs.Delete => :m8_set_maintenance,
    Ankole.Upgrade202610 => :m8_set_maintenance,
    # M9 retrieval: candidate, rerank, and fusion queries over row sets.
    Ankole.Brain.Recall => :m9_retrieval,
    {Ankole.Brain.Claims, [:find_dedup_action, :filter_live_parents, :current_external_facts]} =>
      :m9_retrieval
  },
  baseline: %{
    # advisory_lock
    "raw_sql_tenant:../control_plane_core/lib/ankole/advisory_lock.ex" => 2,
    # authz: staged facades. Callers in other tasks' files still call them in
    # their own transaction; each becomes a generic action when its callers use
    # the `_in_tx` form (hey/T9.md).
    "repo_transact:../control_plane_core/lib/ankole/authz.ex" => 2,
    # brain: a share lock of a Conversation row stays until Conversations gives
    # a lock function.
    "ecto_lock:../control_plane_core/lib/ankole/brain/conversations_learning.ex" => 1,
    # browser_sessions: a lock of a Human row and a read of bindings across tenants
    # stay until Principals gives these reads.
    "ecto_lock:../control_plane_core/lib/ankole/browser_sessions.ex" => 1,
    "ecto_resource:../control_plane_core/lib/ankole/browser_sessions.ex" => 1,
    # control_plane application
    "ecto_resource:lib/ankole/release.ex" => 1,
    # conversations
    "ecto_resource:../control_plane_core/lib/ankole/conversations.ex" => 2,
    # oidc: locks of tenant and Human rows stay until Tenants and Principals give
    # these reads.
    "ecto_lock:../control_plane_core/lib/ankole/oidc/claims.ex" => 2,
    "ecto_lock:../control_plane_core/lib/ankole/oidc/sessions.ex" => 2,
    # plugins: each transaction calls a composition function of another domain
    # (AuthZ synced IM group members, an external Conversation observation)
    # until that domain gives a top-level operation (hey/T14.md).
    "repo_transact:../../plugins/lark_adapter/lib/ankole/plugins/lark_adapter/im_groups.ex" => 2,
    "repo_transact:../../plugins/microsoft365_adapter/lib/ankole/plugins/microsoft365_adapter/teams_channels.ex" =>
      1,
    "repo_transact:../../plugins/slack_adapter/lib/ankole/plugins/slack_adapter/channels.ex" => 2,
    # principals: staged facades, as for authz. WorkCleanup counts admitted
    # Signal and automation attempts of all tenants until Signals and
    # AutomationJobs give that count.
    "repo_transact:../control_plane_core/lib/ankole/principals.ex" => 6,
    "repo_transact:../control_plane_core/lib/ankole/principals/mapping_requests.ex" => 1,
    "ecto_resource:../control_plane_core/lib/ankole/principals/work_cleanup.ex" => 4,
    # sessions: workspaces.ex waits for a Schedule cron define; its "lock:" in a
    # domain define query is an Ash share lock (the scanner reads it as Ecto).
    "cross_domain_ash:../control_plane_core/lib/ankole/sessions/workspaces.ex" => 1,
    "ecto_lock:../control_plane_core/lib/ankole/sessions/workspaces.ex" => 1,
    # setup
    "repo_transact:../control_plane_core/lib/ankole/setup/completion.ex" => 1,
    # signals: bindings.ex waits for an AppConfig read across tenants and a
    # global row removal in a caller's transaction (AppConfigure);
    # state_cleanup.ex waits for a Conversations tombstone expiry operation (T5).
    "cross_domain_ash:../control_plane_core/lib/ankole/signals/bindings.ex" => 1,
    "ecto_resource:../control_plane_core/lib/ankole/signals/bindings.ex" => 1,
    "bulk_result:../control_plane_core/lib/ankole/signals/state_cleanup.ex" => 2,
    "cross_domain_ash:../control_plane_core/lib/ankole/signals/state_cleanup.ex" => 1,
    "error_class:../control_plane_core/lib/ankole/signals/state_cleanup.ex" => 1,
    # tenants: staged facade, as for authz.
    "repo_transact:../control_plane_core/lib/ankole/tenants.ex" => 1
  }
}
