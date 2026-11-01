# The persistence boundary of Ankole. Ankole.PersistenceBoundaryTest and the
# Credo checks AshBoundary and RawSQLTenant read this file.
#
# exceptions: modules (or {module, functions}) whose nature does not match
# Ash resource semantics. Each entry names its mismatch pattern (see
# "Persistence boundary" in CONTRIBUTING.md). An entry can use Ecto writes,
# Ecto row locks, Repo transactions, and Ecto queries of resource tables. A
# read model selects maps or values, not resource structs. The user approves
# each new entry. The boundary test removes an entry that no longer uses the
# database directly.
%{
  exceptions: %{
    # M2 process coordination: the Repo itself and its database clock, advisory
    # locks, and Oban job rows, which are not Ankole resources.
    Ankole.Repo => :m2_process_coordination,
    Ankole.AdvisoryLock => :m2_process_coordination,
    Ankole.Job => :m2_process_coordination,
    # M4 read models: projections of several resources that give maps.
    Ankole.AuthZ.Snapshot => :m4_read_model,
    {Ankole.Files.Nodes,
     [:path, :descendants, :ancestor_ids, :hidden_trashed_ids, :shared_root_ids]} =>
      :m4_read_model,
    {Ankole.Brain.ConversationsLearning, [:known_pages]} => :m4_read_model,
    {Ankole.Brain.Dreaming, [:consolidation_buckets, :term_usage]} => :m4_read_model,
    {Ankole.Brain.Merge,
     [:alias_candidates, :merge_scan_scope, :exclude_recorded_and_principal_pairs]} =>
      :m4_read_model,
    {Ankole.Workflow.Queries, [:capacity_candidate]} => :m4_read_model,
    # M7 dynamic schema: the Pod database subsystem owns base_records.
    Ankole.Pod.Bases => :m7_dynamic_schema,
    Ankole.Pod.Bases.Records => :m7_dynamic_schema,
    Ankole.Pod.Query => :m7_dynamic_schema,
    Ankole.Pod.Copy => :m7_dynamic_schema,
    Ankole.Pod.BaseRepo => :m7_dynamic_schema,
    Ankole.Pod.Bases.Promote => :m7_dynamic_schema,
    # M8 set maintenance: DDL, tenant teardown, merges, and the one-time upgrade.
    Ankole.Brain.SearchIndexes => :m8_set_maintenance,
    {Ankole.Brain.Merge,
     [:repoint_timelines, :repoint_unique_rows, :repoint_links, :repoint_link_column]} =>
      :m8_set_maintenance,
    {Ankole.Tenants.Jobs.Delete, [:delete_batch, :delete_rows, :finish, :finish_in_tx]} =>
      :m8_set_maintenance,
    Ankole.Upgrade202610 => :m8_set_maintenance,
    Ankole.Principals.Rename.References => :m8_set_maintenance,
    {Ankole.Files.Access, [:reanchor_pass_through_children]} => :m8_set_maintenance,
    # M9 retrieval: candidate, rerank, and fusion queries over row sets.
    Ankole.Brain.Recall => :m9_retrieval,
    {Ankole.Pod.Pages.Queries, [:state_page_ids, :trash_candidates]} => :m9_retrieval,
    {Ankole.Brain.Claims, [:find_dedup_action, :filter_live_parents, :current_external_facts]} =>
      :m9_retrieval
  }
}
