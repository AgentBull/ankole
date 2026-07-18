defmodule Ankole.Brain.Knowledge do
  @moduledoc """
  Transactional structured knowledge operations and live Markdown projection.

  All reads apply owner and readable-store predicates in SQL. Authored writes
  derive owner, store, and author from a trusted `Brain.Scope` and actor;
  operation payloads cannot override them. The two actorless mechanical
  operations cannot author content and require an explicit causal surface. A
  batch either commits its mutations and append-only audits together or leaves
  no partial state.
  """

  import Ecto.Changeset, only: [change: 1, change: 2, optimistic_lock: 2]
  import Ecto.Query

  alias Ankole.Brain.Citations
  alias Ankole.Brain.Knowledge.WriteAuthority
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Schemas.AuditLog
  alias Ankole.Brain.Schemas.Entry
  alias Ankole.Brain.Schemas.EntryBlock
  alias Ankole.Brain.Schemas.EntryRelation
  alias Ankole.Brain.ThreatScanner
  alias Ankole.Ecto.JSONPayload
  alias Ankole.Principals
  alias Ankole.Repo

  @actor_kinds [:human, :agent, :dreaming]
  @mechanical_operations ~w(create_entry delete_block)
  @default_limit 50
  @max_limit 200
  @max_bulk_restore 10_000

  @type actor :: %{
          required(:kind) => :human | :agent | :dreaming | String.t(),
          required(:uid) => String.t()
        }
  @type operation :: map()

  @doc "Applies one or more structured operations in one transaction."
  @spec apply_operations(Scope.t(), operation() | [operation()], actor(), keyword()) ::
          {:ok, %{results: [map()], touched_entry_ids: [Ecto.UUID.t()]}} | {:error, term()}
  def apply_operations(scope, operations, actor, opts \\ [])

  def apply_operations(%Scope{writable_store_key: nil}, _operations, _actor, _opts),
    do: {:error, :read_only_scope}

  def apply_operations(%Scope{} = scope, operations, actor, opts) when is_list(opts) do
    with {:ok, operations} <- normalize_operations(operations),
         {:ok, actor} <- normalize_actor(actor),
         {:ok, authority} <- WriteAuthority.build(actor, opts),
         {:ok, metadata} <- normalize_metadata(Keyword.get(opts, :metadata, %{})) do
      execute_operations(scope, operations, actor, authority, metadata, opts)
    end
  end

  def apply_operations(_scope, _operations, _actor, _opts), do: {:error, :invalid_arguments}

  @doc """
  Applies one actorless mechanical operation with an explicit causal surface.

  This path is intentionally limited to creating an empty structural entry or
  deleting a block. It cannot author or edit knowledge content.
  """
  @spec apply_mechanical_operation(Scope.t(), operation(), map(), keyword()) ::
          {:ok, %{results: [map()], touched_entry_ids: [Ecto.UUID.t()]}} | {:error, term()}
  def apply_mechanical_operation(scope, operation, metadata, opts \\ [])

  def apply_mechanical_operation(
        %Scope{writable_store_key: nil},
        _operation,
        _metadata,
        _opts
      ),
      do: {:error, :read_only_scope}

  def apply_mechanical_operation(%Scope{} = scope, operation, metadata, opts)
      when is_map(operation) and is_map(metadata) and is_list(opts) do
    with {:ok, operation_name} <- operation_name(operation),
         :ok <- validate_mechanical_operation(operation_name, operation),
         {:ok, metadata} <- normalize_mechanical_metadata(metadata),
         {:ok, authority} <- WriteAuthority.build(%{kind: nil, uid: nil}, opts) do
      execute_operations(
        scope,
        [operation],
        %{kind: nil, uid: nil},
        authority,
        metadata,
        opts
      )
    end
  end

  def apply_mechanical_operation(_scope, _operation, _metadata, _opts),
    do: {:error, :invalid_arguments}

  @doc "Opens an entry by UUID or exact name and renders its current projection."
  @spec open(Scope.t(), map() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def open(scope, selector, opts \\ [])

  def open(%Scope{} = scope, selector, opts) when is_list(opts) do
    with :ok <- validate_requested_store(scope, Keyword.get(opts, :store_key)),
         %Entry{} = entry <- fetch_entry_for_read(Repo, scope, selector, opts) do
      projection(Repo, scope, entry, opts)
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def open(_scope, _selector, _opts), do: {:error, :invalid_arguments}

  @doc "Lists entry directory rows with all optional filters applied in SQL."
  @spec list_entries(Scope.t(), keyword()) :: {:ok, [Entry.t()]} | {:error, term()}
  def list_entries(scope, opts \\ [])

  def list_entries(%Scope{} = scope, opts) when is_list(opts) do
    with :ok <- validate_requested_store(scope, Keyword.get(opts, :store_key)) do
      query =
        Entry
        |> scope_entries(scope)
        |> maybe_where(:store_key, Keyword.get(opts, :store_key))
        |> maybe_where(:type, Keyword.get(opts, :type))
        |> maybe_entry_search(Keyword.get(opts, :query))
        |> maybe_updated_after(Keyword.get(opts, :updated_after))
        |> maybe_updated_before(Keyword.get(opts, :updated_before))
        |> maybe_before_entry_cursor(Keyword.get(opts, :cursor))
        |> maybe_author_kind(Keyword.get(opts, :author_kind))
        |> maybe_author_uid(Keyword.get(opts, :author_uid))
        |> order_by([entry], desc: entry.updated_at, desc: entry.id)
        |> limit(^limit(opts))
        |> offset(^offset(opts))

      {:ok, Repo.all(query)}
    end
  end

  def list_entries(_scope, _opts), do: {:error, :invalid_arguments}

  @doc "Lists audit rows for supervision and explicit recovery surfaces."
  @spec list_audit(Scope.t(), keyword()) :: {:ok, [AuditLog.t()]} | {:error, term()}
  def list_audit(scope, opts \\ [])

  def list_audit(%Scope{} = scope, opts) when is_list(opts) do
    with :ok <- validate_requested_store(scope, Keyword.get(opts, :store_key)),
         {:ok, audit_id} <- optional_uuid(Keyword.get(opts, :audit_id), :audit_id),
         {:ok, entry_id} <- optional_uuid(Keyword.get(opts, :entry_id), :entry_id) do
      query =
        AuditLog
        |> scope_audit(scope)
        |> maybe_where(:id, audit_id)
        |> maybe_where(:store_key, Keyword.get(opts, :store_key))
        |> maybe_where(:action, Keyword.get(opts, :action))
        |> maybe_where(:entry_id, entry_id)
        |> maybe_enum_where(:actor_kind, Keyword.get(opts, :actor_kind), @actor_kinds)
        |> maybe_where(:actor_uid, Keyword.get(opts, :actor_uid))
        |> maybe_metadata_text("run_id", Keyword.get(opts, :run_id))
        |> maybe_inserted_after(Keyword.get(opts, :inserted_after))
        |> maybe_inserted_before(Keyword.get(opts, :inserted_before))
        |> maybe_before_audit_cursor(Keyword.get(opts, :cursor))
        |> order_by([audit], desc: audit.inserted_at, desc: audit.id)
        |> limit(^limit(opts))
        |> offset(^offset(opts))

      {:ok, Repo.all(query)}
    end
  end

  def list_audit(_scope, _opts), do: {:error, :invalid_arguments}

  @doc "Restores the durable content described by one audit row and audits the restore."
  @spec restore_audit(Scope.t(), Ecto.UUID.t(), actor(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def restore_audit(scope, audit_id, actor, opts \\ [])

  def restore_audit(%Scope{writable_store_key: nil}, _audit_id, _actor, _opts),
    do: {:error, :read_only_scope}

  def restore_audit(%Scope{} = scope, audit_id, actor, opts) when is_list(opts) do
    with {:ok, audit_id} <- cast_uuid(audit_id, :audit_id),
         {:ok, actor} <- normalize_actor(actor),
         {:ok, metadata} <- normalize_metadata(Keyword.get(opts, :metadata, %{})) do
      Repo.transact(fn repo -> restore_audit_in_tx(repo, scope, audit_id, actor, metadata) end)
    end
  end

  def restore_audit(_scope, _audit_id, _actor, _opts), do: {:error, :invalid_arguments}

  @doc "Atomically restores an explicit audit selection in reverse chronological order."
  @spec restore_audits(Scope.t(), [Ecto.UUID.t()], actor(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def restore_audits(scope, audit_ids, actor, opts \\ [])

  def restore_audits(%Scope{} = scope, audit_ids, actor, opts)
      when is_list(audit_ids) and is_list(opts) do
    with {:ok, audit_ids} <- normalize_audit_ids(audit_ids),
         {:ok, actor} <- normalize_actor(actor),
         {:ok, metadata} <- normalize_metadata(Keyword.get(opts, :metadata, %{})) do
      batch_restore_id = Ecto.UUID.generate()

      Repo.transact(fn repo ->
        audits =
          AuditLog
          |> scope_audit(scope)
          |> where([audit], audit.id in ^audit_ids)
          |> order_by([audit], desc: audit.inserted_at, desc: audit.id)
          |> lock("FOR UPDATE")
          |> repo.all()

        if length(audits) != length(audit_ids) do
          {:error, :audit_selection_changed}
        else
          audits
          |> Enum.reduce_while({:ok, []}, fn audit, {:ok, restorations} ->
            with {:ok, restore_scope} <- Scope.for_store(scope.owner_uid, audit.store_key),
                 {:ok, restoration} <-
                   restore_audit_in_tx(
                     repo,
                     restore_scope,
                     audit.id,
                     actor,
                     Map.merge(metadata, %{
                       "batch_restore_id" => batch_restore_id,
                       "batch_restore_size" => length(audit_ids)
                     })
                   ) do
              {:cont, {:ok, [restoration | restorations]}}
            else
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
          |> case do
            {:ok, restorations} ->
              {:ok,
               %{
                 batch_restore_id: batch_restore_id,
                 restored_count: length(restorations),
                 restorations: Enum.reverse(restorations)
               }}

            {:error, _reason} = error ->
              error
          end
        end
      end)
    end
  end

  def restore_audits(_scope, _audit_ids, _actor, _opts), do: {:error, :invalid_arguments}

  @doc false
  @spec restore_mechanical_audit(Scope.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def restore_mechanical_audit(scope, audit_id, metadata, opts \\ [])

  def restore_mechanical_audit(%Scope{} = scope, audit_id, metadata, opts)
      when is_map(metadata) and is_list(opts) do
    with {:ok, audit_id} <- cast_uuid(audit_id, :audit_id),
         {:ok, metadata} <- normalize_mechanical_metadata(metadata) do
      run = fn repo ->
        restore_audit_in_tx(repo, scope, audit_id, %{kind: nil, uid: nil}, metadata)
      end

      case Keyword.get(opts, :repo) do
        nil -> Repo.transact(run)
        repo when is_atom(repo) -> run.(repo)
        _invalid -> {:error, :invalid_repo}
      end
    end
  end

  def restore_mechanical_audit(_scope, _audit_id, _metadata, _opts),
    do: {:error, :invalid_arguments}

  defp restore_audit_in_tx(repo, scope, audit_id, actor, metadata) do
    with %AuditLog{} = source_audit <- fetch_audit_for_write(repo, scope, audit_id),
         {:ok, restore_result, before_snapshot, after_snapshot, touched} <-
           restore_source_audit(repo, scope, source_audit),
         {:ok, restore_action} <- restore_audit_action(source_audit.action),
         {:ok, restore_audit} <-
           insert_audit(
             repo,
             scope,
             actor,
             restore_action,
             audit_ids(source_audit),
             before_snapshot,
             after_snapshot,
             Map.merge(metadata, %{
               "restored_audit_id" => source_audit.id,
               "restored_action" => source_audit.action
             })
           ),
         :ok <- validate_protected_projections(repo, scope, touched) do
      {:ok,
       Map.merge(restore_result, %{
         restored_audit_id: source_audit.id,
         restore_audit_id: restore_audit.id,
         touched_entry_ids: Enum.uniq(touched)
       })}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp apply_operation_batch(repo, scope, actor, authority, operations, metadata) do
    Enum.reduce_while(operations, {:ok, [], [], %{}}, fn operation,
                                                         {:ok, results, touched, fences} ->
      prepared_operation = prepare_batch_operation(operation, fences)

      case apply_operation(repo, scope, actor, authority, prepared_operation, metadata) do
        {:ok, result, operation_touched} ->
          fences = update_batch_fences(fences, operation, result)
          {:cont, {:ok, [result | results], operation_touched ++ touched, fences}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, results, touched, _fences} ->
        {:ok, Enum.reverse(results), Enum.uniq(touched)}

      {:error, _reason} = error ->
        error
    end
  end

  defp execute_operations(scope, operations, actor, authority, metadata, opts) do
    run = fn repo ->
      with {:ok, results, touched_entry_ids} <-
             apply_operation_batch(repo, scope, actor, authority, operations, metadata),
           :ok <- validate_protected_projections(repo, scope, touched_entry_ids) do
        {:ok,
         %{
           results: results,
           touched_entry_ids: Enum.uniq(touched_entry_ids)
         }}
      end
    end

    case Keyword.get(opts, :repo) do
      nil -> Repo.transact(run)
      repo when is_atom(repo) -> run.(repo)
      _invalid -> {:error, :invalid_repo}
    end
  end

  defp apply_operation(repo, scope, actor, authority, operation, metadata) do
    with {:ok, operation_name} <- operation_name(operation),
         :ok <- WriteAuthority.authorize_operation(authority, operation_name, operation),
         :ok <- authorize_curation_guide_operation(repo, scope, actor, operation_name, operation) do
      case operation_name do
        "create_entry" -> create_entry(repo, scope, actor, authority, operation, metadata)
        "delete_entry" -> delete_entry(repo, scope, actor, operation, metadata)
        "append_block" -> append_block(repo, scope, actor, authority, operation, metadata)
        "edit_block" -> edit_block(repo, scope, actor, authority, operation, metadata)
        "delete_block" -> delete_block(repo, scope, actor, operation, metadata)
        "set_property" -> set_property(repo, scope, actor, operation, metadata)
        "set_summary" -> set_summary(repo, scope, actor, operation, metadata)
        "set_aliases" -> set_aliases(repo, scope, actor, operation, metadata)
        "set_name" -> set_name(repo, scope, actor, operation, metadata)
        "set_type" -> set_type(repo, scope, actor, operation, metadata)
        "add_relation" -> add_relation(repo, scope, actor, operation, metadata)
        "remove_relation" -> remove_relation(repo, scope, actor, operation, metadata)
        unknown -> {:error, {:unsupported_operation, unknown}}
      end
    end
  end

  defp create_entry(repo, scope, actor, authority, operation, metadata) do
    attrs = %{
      owner_uid: scope.owner_uid,
      store_key: scope.writable_store_key,
      name: value(operation, :name),
      type: value(operation, :type),
      summary: value(operation, :summary, ""),
      aliases: value(operation, :aliases, []),
      properties: value(operation, :properties, %{})
    }

    with {:ok, entry} <- repo.insert(Entry.changeset(%Entry{}, attrs)),
         {:ok, initial_block} <-
           insert_initial_block(repo, scope, actor, authority, entry, operation),
         after_snapshot =
           if(initial_block, do: entry_bundle_snapshot(repo, entry), else: entry_snapshot(entry)),
         {:ok, _audit} <-
           insert_audit(
             repo,
             scope,
             actor,
             "create_entry",
             %{entry_id: entry.id, block_id: initial_block && initial_block.id},
             nil,
             after_snapshot,
             metadata
           ) do
      {:ok,
       %{
         operation: "create_entry",
         entry_id: entry.id,
         entry_lock_version: entry.lock_version,
         block_id: initial_block && initial_block.id,
         block_lock_version: initial_block && initial_block.lock_version
       }, [entry.id]}
    end
  end

  defp insert_initial_block(repo, scope, actor, authority, entry, operation) do
    case value(operation, :initial_body) do
      nil ->
        {:ok, nil}

      body when is_binary(body) ->
        case String.trim(body) do
          "" ->
            {:ok, nil}

          body ->
            with {:ok, block} <-
                   repo.insert(
                     EntryBlock.changeset(%EntryBlock{}, %{
                       entry_id: entry.id,
                       owner_uid: entry.owner_uid,
                       store_key: entry.store_key,
                       position: 0,
                       body: body,
                       author_kind: actor.kind,
                       author_uid: actor.uid
                     })
                   ),
                 :ok <- Citations.sync(repo, scope, authority, block) do
              {:ok, block}
            end
        end

      _invalid ->
        {:error, {:invalid_field, :initial_body}}
    end
  end

  defp delete_entry(repo, scope, actor, operation, metadata) do
    with {:ok, entry_id} <- required_uuid(operation, :entry_id),
         {:ok, expected_version} <- required_version(operation, :expected_entry_lock_version),
         %Entry{} = entry <- fetch_entry_for_write(repo, scope, entry_id, true),
         :ok <- ensure_version(:entry, entry.id, entry.lock_version, expected_version),
         before_snapshot = entry_bundle_snapshot(repo, entry),
         touched = bundle_neighbor_ids(before_snapshot),
         {:ok, _entry} <- repo.delete(entry),
         {:ok, _audit} <-
           insert_audit(
             repo,
             scope,
             actor,
             "delete_entry",
             %{entry_id: entry.id},
             before_snapshot,
             nil,
             metadata
           ) do
      {:ok, %{operation: "delete_entry", entry_id: entry.id}, touched}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp append_block(repo, scope, actor, authority, operation, metadata) do
    with {:ok, entry_id} <- required_uuid(operation, :entry_id),
         {:ok, expected_version} <- required_version(operation, :expected_entry_lock_version),
         %Entry{} = entry <- fetch_entry_for_write(repo, scope, entry_id, true),
         :ok <- ensure_version(:entry, entry.id, entry.lock_version, expected_version),
         position <- next_block_position(repo, entry.id),
         {:ok, block} <-
           repo.insert(
             EntryBlock.changeset(%EntryBlock{}, %{
               entry_id: entry.id,
               owner_uid: entry.owner_uid,
               store_key: entry.store_key,
               position: position,
               body: value(operation, :body),
               author_kind: actor.kind,
               author_uid: actor.uid
             })
           ),
         :ok <- Citations.sync(repo, scope, authority, block),
         {:ok, entry} <- bump_entry(repo, entry),
         {:ok, _audit} <-
           insert_audit(
             repo,
             scope,
             actor,
             "append_block",
             %{entry_id: entry.id, block_id: block.id},
             nil,
             block_snapshot(block),
             Map.put(metadata, "entry_lock_version", entry.lock_version)
           ) do
      {:ok,
       %{
         operation: "append_block",
         entry_id: entry.id,
         entry_lock_version: entry.lock_version,
         block_id: block.id,
         block_lock_version: block.lock_version
       }, [entry.id]}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp edit_block(repo, scope, actor, authority, operation, metadata) do
    with {:ok, block_id} <- required_uuid(operation, :block_id),
         {:ok, expected_version} <- required_version(operation, :expected_block_lock_version),
         %EntryBlock{} = block <- fetch_block_for_write(repo, scope, block_id),
         :ok <- ensure_version(:block, block.id, block.lock_version, expected_version),
         before_snapshot = block_snapshot(block),
         {:ok, block} <-
           repo.update(
             EntryBlock.update_changeset(block, %{
               body: value(operation, :body),
               author_kind: actor.kind,
               author_uid: actor.uid
             }),
             stale_error_field: :lock_version
           ),
         :ok <- Citations.sync(repo, scope, authority, block, before_snapshot["body"]),
         :ok <- touch_entry(repo, block.entry_id),
         {:ok, _audit} <-
           insert_audit(
             repo,
             scope,
             actor,
             "edit_block",
             %{entry_id: block.entry_id, block_id: block.id},
             before_snapshot,
             block_snapshot(block),
             metadata
           ) do
      {:ok,
       %{
         operation: "edit_block",
         entry_id: block.entry_id,
         block_id: block.id,
         block_lock_version: block.lock_version
       }, [block.entry_id]}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp delete_block(repo, scope, actor, operation, metadata) do
    with {:ok, block_id} <- required_uuid(operation, :block_id),
         {:ok, expected_version} <- required_version(operation, :expected_block_lock_version),
         %EntryBlock{} = block <- fetch_block_for_write(repo, scope, block_id),
         :ok <- ensure_version(:block, block.id, block.lock_version, expected_version),
         before_snapshot = block_snapshot(block),
         {:ok, _block} <-
           block
           |> change()
           |> optimistic_lock(:lock_version)
           |> repo.delete(stale_error_field: :lock_version),
         :ok <- touch_entry(repo, block.entry_id),
         {:ok, _audit} <-
           insert_audit(
             repo,
             scope,
             actor,
             "delete_block",
             %{entry_id: block.entry_id, block_id: block.id},
             before_snapshot,
             nil,
             metadata
           ) do
      {:ok, %{operation: "delete_block", entry_id: block.entry_id, block_id: block.id},
       [block.entry_id]}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp set_property(repo, scope, actor, operation, metadata) do
    with {:ok, key} <- required_nonblank(operation, :key),
         {:ok, entry_id} <- required_uuid(operation, :entry_id),
         %Entry{} = entry <- fetch_entry_for_write(repo, scope, entry_id, false) do
      properties =
        case value(operation, :value) do
          nil -> Map.delete(entry.properties, key)
          property_value -> Map.put(entry.properties, key, property_value)
        end

      update_entry(repo, scope, actor, operation, metadata, entry, "set_property", %{
        properties: properties
      })
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp set_summary(repo, scope, actor, operation, metadata),
    do: update_entry_field(repo, scope, actor, operation, metadata, "set_summary", :summary)

  defp set_aliases(repo, scope, actor, operation, metadata),
    do: update_entry_field(repo, scope, actor, operation, metadata, "set_aliases", :aliases)

  defp set_name(repo, scope, actor, operation, metadata),
    do: update_entry_field(repo, scope, actor, operation, metadata, "set_name", :name)

  defp set_type(repo, scope, actor, operation, metadata),
    do: update_entry_field(repo, scope, actor, operation, metadata, "set_type", :type)

  defp update_entry_field(repo, scope, actor, operation, metadata, action, field) do
    with {:ok, entry_id} <- required_uuid(operation, :entry_id),
         %Entry{} = entry <- fetch_entry_for_write(repo, scope, entry_id, false) do
      update_entry(
        repo,
        scope,
        actor,
        operation,
        metadata,
        entry,
        action,
        %{field => value(operation, field)}
      )
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp update_entry(repo, scope, actor, operation, metadata, entry, action, attrs) do
    with {:ok, expected_version} <- required_version(operation, :expected_entry_lock_version),
         :ok <- ensure_version(:entry, entry.id, entry.lock_version, expected_version),
         before_snapshot = entry_snapshot(entry),
         {:ok, entry} <-
           repo.update(Entry.update_changeset(entry, attrs), stale_error_field: :lock_version),
         {:ok, _audit} <-
           insert_audit(
             repo,
             scope,
             actor,
             action,
             %{entry_id: entry.id},
             before_snapshot,
             entry_snapshot(entry),
             metadata
           ) do
      {:ok, %{operation: action, entry_id: entry.id, entry_lock_version: entry.lock_version},
       [entry.id]}
    end
  end

  defp add_relation(repo, scope, actor, operation, metadata) do
    with {:ok, entry_id} <- required_uuid(operation, :entry_id),
         {:ok, target_entry_id} <- required_uuid(operation, :target_entry_id),
         {:ok, expected_version} <- required_version(operation, :expected_entry_lock_version),
         %Entry{} = source <- fetch_entry_for_write(repo, scope, entry_id, true),
         :ok <- ensure_version(:entry, source.id, source.lock_version, expected_version),
         %Entry{} = target <- fetch_relation_target(repo, source, target_entry_id),
         {:ok, relation} <-
           repo.insert(
             EntryRelation.changeset(%EntryRelation{}, %{
               owner_uid: source.owner_uid,
               store_key: source.store_key,
               source_entry_id: source.id,
               predicate: value(operation, :predicate),
               target_entry_id: target.id
             })
           ),
         {:ok, source} <- bump_entry(repo, source),
         {:ok, _audit} <-
           insert_audit(
             repo,
             scope,
             actor,
             "add_relation",
             %{entry_id: source.id, relation_id: relation.id},
             nil,
             relation_snapshot(relation),
             Map.put(metadata, "entry_lock_version", source.lock_version)
           ) do
      {:ok,
       %{
         operation: "add_relation",
         entry_id: source.id,
         entry_lock_version: source.lock_version,
         relation_id: relation.id
       }, [source.id, target.id]}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp remove_relation(repo, scope, actor, operation, metadata) do
    with {:ok, entry_id} <- required_uuid(operation, :entry_id),
         {:ok, relation_id} <- required_uuid(operation, :relation_id),
         {:ok, expected_version} <- required_version(operation, :expected_entry_lock_version),
         %Entry{} = source <- fetch_entry_for_write(repo, scope, entry_id, true),
         :ok <- ensure_version(:entry, source.id, source.lock_version, expected_version),
         %EntryRelation{} = relation <- fetch_relation_for_write(repo, source, relation_id),
         before_snapshot = relation_snapshot(relation),
         {:ok, _relation} <- repo.delete(relation),
         {:ok, source} <- bump_entry(repo, source),
         {:ok, _audit} <-
           insert_audit(
             repo,
             scope,
             actor,
             "remove_relation",
             %{entry_id: source.id, relation_id: relation.id},
             before_snapshot,
             nil,
             Map.put(metadata, "entry_lock_version", source.lock_version)
           ) do
      {:ok,
       %{
         operation: "remove_relation",
         entry_id: source.id,
         entry_lock_version: source.lock_version,
         relation_id: relation.id
       }, [source.id, relation.target_entry_id]}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp insert_audit(
         repo,
         scope,
         actor,
         action,
         ids,
         before_snapshot,
         after_snapshot,
         metadata
       ) do
    %AuditLog{}
    |> AuditLog.changeset(%{
      owner_uid: scope.owner_uid,
      store_key: scope.writable_store_key,
      actor_kind: actor.kind,
      actor_uid: actor.uid,
      action: action,
      entry_id: Map.get(ids, :entry_id),
      block_id: Map.get(ids, :block_id),
      relation_id: Map.get(ids, :relation_id),
      before: before_snapshot,
      after: after_snapshot,
      metadata: metadata
    })
    |> repo.insert()
  end

  defp projection(repo, scope, %Entry{} = entry, opts) do
    with {:ok, blocks, next_block_cursor} <- load_block_page(repo, entry.id, opts) do
      relations =
        repo.all(
          from relation in EntryRelation,
            join: target in Entry,
            on: target.id == relation.target_entry_id,
            where: relation.source_entry_id == ^entry.id,
            order_by: [asc: relation.predicate, asc: target.name],
            select: %{relation: relation, target: target}
        )

      backlinks_query =
        from relation in EntryRelation,
          join: source in Entry,
          on: source.id == relation.source_entry_id,
          where: relation.target_entry_id == ^entry.id,
          order_by: [asc: source.name, asc: relation.predicate],
          select: %{relation: relation, source: source}

      backlinks = repo.all(scope_backlinks(backlinks_query, scope))

      {:ok,
       %{
         entry: entry,
         blocks: blocks,
         citations: Citations.for_entry(repo, entry.id),
         relations: relations,
         backlinks: backlinks,
         markdown: render_markdown(entry, blocks, relations, backlinks),
         next_block_cursor: next_block_cursor
       }}
    end
  end

  defp load_block_page(repo, entry_id, opts) do
    with {:ok, cursor} <- decode_block_cursor(Keyword.get(opts, :block_cursor)),
         {:ok, page_limit} <- block_limit(Keyword.get(opts, :block_limit, @default_limit)) do
      query =
        from block in EntryBlock,
          where: block.entry_id == ^entry_id,
          order_by: [asc: block.position, asc: block.id]

      query = after_block_cursor(query, cursor)

      case page_limit do
        :all ->
          {:ok, repo.all(query), nil}

        page_limit ->
          rows = repo.all(from block in query, limit: ^(page_limit + 1))

          {blocks, more?} =
            if length(rows) > page_limit,
              do: {Enum.take(rows, page_limit), true},
              else: {rows, false}

          next_cursor = if more?, do: blocks |> List.last() |> encode_block_cursor()
          {:ok, blocks, next_cursor}
      end
    end
  end

  defp render_markdown(entry, blocks, relations, backlinks) do
    aliases =
      case entry.aliases do
        [] -> []
        values -> ["- 别名：" <> Enum.join(values, "、")]
      end

    properties =
      entry.properties
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, value} -> "- #{key}：#{inspect(value, limit: :infinity)}" end)

    body = Enum.map(blocks, &render_block/1)

    relation_lines =
      Enum.map(relations, fn %{relation: relation, target: target} ->
        "- #{relation.predicate} → [[#{target.name}]]"
      end)

    backlink_lines =
      Enum.map(backlinks, fn %{relation: relation, source: source} ->
        "- [[#{source.name}]] — #{relation.predicate}"
      end)

    [
      ["# #{entry.name}", "", "- 类型：#{entry.type}"] ++ aliases,
      section("简介", blank_to_empty(entry.summary)),
      section("属性", properties),
      section("正文", body),
      section("关系", relation_lines),
      section("反向链接", backlink_lines)
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> String.trim()
  end

  defp section(_title, []), do: []
  defp section(title, lines) when is_list(lines), do: ["", "## #{title}", "" | lines]
  defp section(title, line) when is_binary(line), do: section(title, [line])
  defp blank_to_empty(value) when value in [nil, ""], do: []
  defp blank_to_empty(value), do: value

  defp render_block(block) do
    author =
      case block.author_uid do
        uid when is_binary(uid) -> "#{block.author_kind}:#{uid}"
        _missing -> to_string(block.author_kind)
      end

    updated_at =
      case block.updated_at do
        %DateTime{} = value -> DateTime.to_iso8601(value)
        %NaiveDateTime{} = value -> NaiveDateTime.to_iso8601(value)
        _missing -> "unknown"
      end

    "> 块：#{block.id} · 作者：#{author} · 最后修改：#{updated_at}\n\n#{block.body}"
  end

  defp validate_protected_projections(_repo, _scope, []), do: :ok

  defp validate_protected_projections(repo, scope, entry_ids) do
    entries =
      repo.all(
        from entry in Entry,
          where:
            entry.owner_uid == ^scope.owner_uid and entry.id in ^Enum.uniq(entry_ids) and
              (entry.type == "agent_system_pinned_memo" or
                 fragment("jsonb_exists(?, 'channel_id')", entry.properties)),
          lock: "FOR SHARE"
      )

    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case projection(repo, scope, entry, block_limit: :all) do
        {:ok, %{markdown: markdown}} ->
          case ThreatScanner.validate(markdown) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp fetch_entry_for_read(repo, scope, selector, opts) do
    query =
      Entry
      |> scope_entries(scope)
      |> maybe_where(:store_key, Keyword.get(opts, :store_key))
      |> prefer_scope_store(scope)

    case selector_value(selector) do
      nil ->
        nil

      selector ->
        case Ecto.UUID.cast(selector) do
          {:ok, id} ->
            repo.one(from entry in query, where: entry.id == ^id, limit: 1)

          :error ->
            repo.one(
              from entry in query,
                where:
                  entry.name == ^selector or
                    fragment("? = ANY(?)", ^selector, entry.aliases),
                limit: 1
            )
        end
    end
  end

  defp fetch_entry_for_write(repo, scope, entry_id, lock?) do
    query =
      from entry in Entry,
        where:
          entry.owner_uid == ^scope.owner_uid and entry.store_key == ^scope.writable_store_key and
            entry.id == ^entry_id

    query = if lock?, do: from(entry in query, lock: "FOR UPDATE"), else: query
    repo.one(query)
  end

  defp fetch_block_for_write(repo, scope, block_id, lock? \\ false) do
    query =
      from block in EntryBlock,
        where:
          block.owner_uid == ^scope.owner_uid and block.store_key == ^scope.writable_store_key and
            block.id == ^block_id

    query = if lock?, do: from(block in query, lock: "FOR UPDATE"), else: query
    repo.one(query)
  end

  defp fetch_relation_target(repo, source, target_entry_id) do
    allowed_stores =
      if source.store_key == "public", do: ["public"], else: [source.store_key, "public"]

    repo.one(
      from entry in Entry,
        where:
          entry.owner_uid == ^source.owner_uid and entry.store_key in ^allowed_stores and
            entry.id == ^target_entry_id
    )
  end

  defp fetch_relation_for_write(repo, source, relation_id) do
    repo.one(
      from relation in EntryRelation,
        where:
          relation.id == ^relation_id and relation.owner_uid == ^source.owner_uid and
            relation.store_key == ^source.store_key and relation.source_entry_id == ^source.id
    )
  end

  defp fetch_audit_for_write(repo, scope, audit_id) do
    repo.one(
      from audit in AuditLog,
        where:
          audit.id == ^audit_id and audit.owner_uid == ^scope.owner_uid and
            audit.store_key == ^scope.writable_store_key,
        lock: "FOR UPDATE"
    )
  end

  defp next_block_position(repo, entry_id) do
    case repo.one(
           from block in EntryBlock,
             where: block.entry_id == ^entry_id,
             select: max(block.position)
         ) do
      nil -> 0
      position -> position + 1
    end
  end

  defp bump_entry(repo, entry) do
    entry
    |> change(lock_version: entry.lock_version + 1)
    |> repo.update()
  end

  defp touch_entry(repo, entry_id) do
    now = DateTime.utc_now()

    case repo.update_all(from(entry in Entry, where: entry.id == ^entry_id),
           set: [updated_at: now]
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :not_found}
    end
  end

  defp ensure_version(_kind, _id, version, version), do: :ok

  defp ensure_version(kind, id, actual, expected) do
    {:error, {:stale, %{kind: kind, id: id, expected: expected, actual: actual}}}
  end

  # One batch is one optimistic edit against one observed entry version. Later
  # operations are rebound only when they still carry that original fence.
  defp prepare_batch_operation(operation, fences) do
    with {:ok, entry_id} <- fetch_value(operation, :entry_id),
         {:ok, expected} <- fetch_value(operation, :expected_entry_lock_version),
         %{base: ^expected, current: current} <- Map.get(fences, entry_id) do
      Map.put(operation, :expected_entry_lock_version, current)
    else
      _no_existing_fence -> operation
    end
  end

  defp update_batch_fences(fences, operation, result) do
    with entry_id when not is_nil(entry_id) <- Map.get(result, :entry_id),
         current when is_integer(current) <- Map.get(result, :entry_lock_version),
         {:ok, expected} <- fetch_value(operation, :expected_entry_lock_version) do
      Map.update(fences, entry_id, %{base: expected, current: current}, fn fence ->
        %{fence | current: current}
      end)
    else
      _no_entry_fence -> fences
    end
  end

  defp normalize_operations(operation) when is_map(operation), do: {:ok, [operation]}

  defp normalize_operations([operation | _rest] = operations) when is_map(operation) do
    if Enum.all?(operations, &is_map/1),
      do: {:ok, operations},
      else: {:error, :invalid_operations}
  end

  defp normalize_operations(_operations), do: {:error, :invalid_operations}

  defp normalize_actor(actor) when is_map(actor) do
    with {:ok, kind} <- normalize_actor_kind(value(actor, :kind)),
         {:ok, uid} <- normalize_actor_uid(kind, value(actor, :uid)) do
      {:ok, %{kind: kind, uid: uid}}
    end
  end

  defp normalize_actor(_actor), do: {:error, :invalid_actor}

  defp normalize_actor_kind(kind) when kind in @actor_kinds, do: {:ok, kind}
  defp normalize_actor_kind("human"), do: {:ok, :human}
  defp normalize_actor_kind("agent"), do: {:ok, :agent}
  defp normalize_actor_kind("dreaming"), do: {:ok, :dreaming}
  defp normalize_actor_kind(_kind), do: {:error, :invalid_actor_kind}

  defp normalize_actor_uid(_kind, uid) do
    case Principals.normalize_uid(uid) do
      {:ok, uid} -> {:ok, uid}
      {:error, :invalid_uid} -> {:error, :invalid_actor_uid}
    end
  end

  defp normalize_metadata(metadata) do
    case JSONPayload.normalize_map(metadata, allow_datetime: true) do
      {:ok, metadata} -> {:ok, metadata}
      {:error, reason} -> {:error, {:invalid_metadata, reason}}
    end
  end

  defp normalize_mechanical_metadata(metadata) do
    with {:ok, metadata} <- normalize_metadata(metadata),
         surface when is_binary(surface) <- Map.get(metadata, "surface"),
         surface when surface != "" <- String.trim(surface) do
      {:ok, Map.put(metadata, "surface", surface)}
    else
      nil -> {:error, :mechanical_operation_surface_required}
      "" -> {:error, :mechanical_operation_surface_required}
      _invalid -> {:error, :mechanical_operation_surface_required}
    end
  end

  defp validate_mechanical_operation("create_entry", operation) do
    if value(operation, :summary, "") == "" and value(operation, :aliases, []) == [] and
         value(operation, :properties, %{}) == %{} and
         value(operation, :initial_body) in [nil, ""] do
      :ok
    else
      {:error, :mechanical_entry_must_be_empty}
    end
  end

  defp validate_mechanical_operation(operation, _attrs)
       when operation in @mechanical_operations,
       do: :ok

  defp validate_mechanical_operation(operation, _attrs),
    do: {:error, {:actor_required_for_operation, operation}}

  defp operation_name(operation) do
    case value(operation, :operation) do
      operation when is_atom(operation) -> {:ok, Atom.to_string(operation)}
      operation when is_binary(operation) -> {:ok, operation}
      _invalid -> {:error, {:missing_field, :operation}}
    end
  end

  defp authorize_curation_guide_operation(
         _repo,
         %Scope{writable_store_key: store_key},
         actor,
         "create_entry",
         operation
       ) do
    if value(operation, :type) == "brain_curation_guide" do
      cond do
        actor.kind != :human -> {:error, :curation_guide_human_only}
        store_key != "public" -> {:error, :curation_guide_must_be_public}
        true -> :ok
      end
    else
      :ok
    end
  end

  defp authorize_curation_guide_operation(repo, scope, actor, operation_name, operation) do
    requested_guide? =
      operation_name == "set_type" and value(operation, :type) == "brain_curation_guide"

    case operation_entry(repo, scope, operation_name, operation) do
      %Entry{type: "brain_curation_guide"} when actor.kind != :human ->
        {:error, :curation_guide_human_only}

      %Entry{} when requested_guide? and actor.kind != :human ->
        {:error, :curation_guide_human_only}

      %Entry{store_key: store_key} when requested_guide? and store_key != "public" ->
        {:error, :curation_guide_must_be_public}

      _entry_or_missing ->
        :ok
    end
  end

  defp operation_entry(repo, scope, operation_name, operation)
       when operation_name in ["edit_block", "delete_block"] do
    with {:ok, block_id} <- required_uuid(operation, :block_id),
         %EntryBlock{} = block <- fetch_block_for_write(repo, scope, block_id) do
      repo.get(Entry, block.entry_id)
    else
      _missing_or_invalid -> nil
    end
  end

  defp operation_entry(repo, scope, _operation_name, operation) do
    with {:ok, entry_id} <- required_uuid(operation, :entry_id) do
      fetch_entry_for_write(repo, scope, entry_id, false)
    else
      _missing_or_invalid -> nil
    end
  end

  defp required(operation, key) do
    case fetch_value(operation, key) do
      {:ok, nil} -> {:error, {:missing_field, key}}
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp required_nonblank(operation, key) do
    with {:ok, value} <- required(operation, key),
         true <- is_binary(value) and String.trim(value) != "" do
      {:ok, String.trim(value)}
    else
      false -> {:error, {:invalid_field, key}}
      {:error, _reason} = error -> error
    end
  end

  defp required_uuid(operation, key) do
    with {:ok, value} <- required(operation, key) do
      cast_uuid(value, key)
    end
  end

  defp optional_uuid(nil, _key), do: {:ok, nil}
  defp optional_uuid(value, key), do: cast_uuid(value, key)

  defp cast_uuid(value, key) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_field, key}}
    end
  end

  defp required_version(operation, key) do
    with {:ok, version} <- required(operation, key),
         true <- is_integer(version) and version > 0 do
      {:ok, version}
    else
      false -> {:error, {:invalid_field, key}}
      {:error, _reason} = error -> error
    end
  end

  defp value(map, key, default \\ nil) do
    case fetch_value(map, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp fetch_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp selector_value(%{} = selector), do: value(selector, :entry_id) || value(selector, :name)
  defp selector_value(selector) when is_binary(selector), do: selector
  defp selector_value(_selector), do: nil

  defp scope_entries(query, %Scope{readable_store_keys: :all, owner_uid: owner_uid}),
    do: from(entry in query, where: entry.owner_uid == ^owner_uid)

  defp scope_entries(query, %Scope{readable_store_keys: stores, owner_uid: owner_uid}),
    do: from(entry in query, where: entry.owner_uid == ^owner_uid and entry.store_key in ^stores)

  defp scope_audit(query, %Scope{readable_store_keys: :all, owner_uid: owner_uid}),
    do: from(audit in query, where: audit.owner_uid == ^owner_uid)

  defp scope_audit(query, %Scope{readable_store_keys: stores, owner_uid: owner_uid}),
    do: from(audit in query, where: audit.owner_uid == ^owner_uid and audit.store_key in ^stores)

  defp scope_backlinks(query, %Scope{readable_store_keys: :all, owner_uid: owner_uid}),
    do: from([relation, source] in query, where: source.owner_uid == ^owner_uid)

  defp scope_backlinks(query, %Scope{readable_store_keys: stores, owner_uid: owner_uid}),
    do:
      from([relation, source] in query,
        where: source.owner_uid == ^owner_uid and source.store_key in ^stores
      )

  defp validate_requested_store(_scope, nil), do: :ok
  defp validate_requested_store(%Scope{readable_store_keys: :all}, _store), do: :ok

  defp validate_requested_store(%Scope{readable_store_keys: stores}, store) do
    if store in stores, do: :ok, else: {:error, :store_not_readable}
  end

  defp maybe_where(query, _field, nil), do: query
  defp maybe_where(query, field, value), do: where(query, [row], field(row, ^field) == ^value)

  defp maybe_metadata_text(query, _key, nil), do: query

  defp maybe_metadata_text(query, key, value),
    do: where(query, [row], fragment("?->>? = ?", row.metadata, ^key, ^value))

  defp maybe_enum_where(query, _field, nil, _allowed), do: query

  defp maybe_enum_where(query, field, value, allowed) do
    case normalize_known_atom(value, allowed) do
      {:ok, value} -> where(query, [row], field(row, ^field) == ^value)
      :error -> where(query, [row], false)
    end
  end

  defp maybe_updated_after(query, nil), do: query
  defp maybe_updated_after(query, value), do: where(query, [entry], entry.updated_at >= ^value)
  defp maybe_updated_before(query, nil), do: query
  defp maybe_updated_before(query, value), do: where(query, [entry], entry.updated_at <= ^value)
  defp maybe_inserted_after(query, nil), do: query
  defp maybe_inserted_after(query, value), do: where(query, [audit], audit.inserted_at >= ^value)
  defp maybe_inserted_before(query, nil), do: query
  defp maybe_inserted_before(query, value), do: where(query, [audit], audit.inserted_at <= ^value)

  defp maybe_entry_search(query, nil), do: query

  defp maybe_entry_search(query, search_text) do
    block_entry_ids =
      from block in EntryBlock,
        where: fragment("? @@@ ?", block.body, ^search_text),
        select: block.entry_id

    where(
      query,
      [entry],
      fragment("? @@@ ?", entry.search_text, ^search_text) or
        entry.id in subquery(block_entry_ids)
    )
  end

  defp maybe_before_entry_cursor(query, nil), do: query

  defp maybe_before_entry_cursor(query, {updated_at, id}) do
    where(
      query,
      [entry],
      entry.updated_at < ^updated_at or (entry.updated_at == ^updated_at and entry.id < ^id)
    )
  end

  defp maybe_before_audit_cursor(query, nil), do: query

  defp maybe_before_audit_cursor(query, {inserted_at, id}) do
    where(
      query,
      [audit],
      audit.inserted_at < ^inserted_at or (audit.inserted_at == ^inserted_at and audit.id < ^id)
    )
  end

  defp maybe_author_kind(query, nil), do: query

  defp maybe_author_kind(query, value) do
    case normalize_known_atom(value, @actor_kinds) do
      {:ok, kind} ->
        block_ids =
          from(block in EntryBlock, where: block.author_kind == ^kind, select: block.entry_id)

        where(query, [entry], entry.id in subquery(block_ids))

      :error ->
        where(query, [entry], false)
    end
  end

  defp maybe_author_uid(query, nil), do: query

  defp maybe_author_uid(query, uid) do
    block_ids = from(block in EntryBlock, where: block.author_uid == ^uid, select: block.entry_id)
    where(query, [entry], entry.id in subquery(block_ids))
  end

  defp prefer_scope_store(query, %Scope{writable_store_key: writable}) when is_binary(writable) do
    order_by(query, [entry],
      asc:
        fragment(
          "CASE WHEN ? = ? THEN 0 WHEN ? = 'public' THEN 1 ELSE 2 END",
          entry.store_key,
          ^writable,
          entry.store_key
        ),
      asc: entry.store_key,
      asc: entry.id
    )
  end

  defp prefer_scope_store(query, %Scope{writable_store_key: nil}) do
    order_by(query, [entry],
      asc: fragment("CASE WHEN ? = 'public' THEN 0 ELSE 1 END", entry.store_key),
      asc: entry.store_key,
      asc: entry.id
    )
  end

  defp block_limit(:all), do: {:ok, :all}

  defp block_limit(value) when is_integer(value) and value > 0,
    do: {:ok, min(value, @max_limit)}

  defp block_limit(_value), do: {:error, :invalid_block_limit}

  defp after_block_cursor(query, nil), do: query

  defp after_block_cursor(query, %{position: position, id: id}) do
    where(
      query,
      [block],
      block.position > ^position or (block.position == ^position and block.id > ^id)
    )
  end

  defp encode_block_cursor(%EntryBlock{position: position, id: id}) do
    Base.url_encode64("#{position}:#{id}", padding: false)
  end

  defp decode_block_cursor(nil), do: {:ok, nil}

  defp decode_block_cursor(cursor) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [position_text, id] <- String.split(decoded, ":", parts: 2),
         {position, ""} when position >= 0 <- Integer.parse(position_text),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, %{position: position, id: id}}
    else
      _invalid -> {:error, :invalid_block_cursor}
    end
  end

  defp decode_block_cursor(_cursor), do: {:error, :invalid_block_cursor}

  defp normalize_known_atom(value, allowed) when is_atom(value) do
    if value in allowed, do: {:ok, value}, else: :error
  end

  defp normalize_known_atom(value, allowed) when is_binary(value) do
    Enum.find_value(allowed, :error, fn allowed_value ->
      if Atom.to_string(allowed_value) == value, do: {:ok, allowed_value}
    end)
  end

  defp normalize_known_atom(_value, _allowed), do: :error

  defp normalize_audit_ids(ids) when length(ids) in 1..@max_bulk_restore do
    Enum.reduce_while(ids, {:ok, []}, fn value, {:ok, acc} ->
      case cast_uuid(value, :audit_id) do
        {:ok, id} -> {:cont, {:ok, [id | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} ->
        normalized = Enum.reverse(normalized)

        if length(Enum.uniq(normalized)) == length(normalized),
          do: {:ok, normalized},
          else: {:error, :duplicate_audit_id}

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_audit_ids(_ids), do: {:error, :invalid_audit_selection}

  defp limit(opts) do
    case Keyword.get(opts, :limit, @default_limit) do
      value when is_integer(value) and value > 0 -> min(value, @max_limit)
      _invalid -> @default_limit
    end
  end

  defp offset(opts) do
    case Keyword.get(opts, :offset, 0) do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> 0
    end
  end

  # Restore operations deliberately restore durable content, not historical
  # lock versions. Existing rows retain monotonic optimistic-lock versions.
  defp restore_audit_action("create_entry"), do: {:ok, "delete_entry"}
  defp restore_audit_action("delete_entry"), do: {:ok, "create_entry"}
  defp restore_audit_action("append_block"), do: {:ok, "delete_block"}
  defp restore_audit_action("delete_block"), do: {:ok, "append_block"}
  defp restore_audit_action("edit_block"), do: {:ok, "edit_block"}
  defp restore_audit_action("set_property"), do: {:ok, "set_property"}
  defp restore_audit_action("set_summary"), do: {:ok, "set_summary"}
  defp restore_audit_action("set_aliases"), do: {:ok, "set_aliases"}
  defp restore_audit_action("set_name"), do: {:ok, "set_name"}
  defp restore_audit_action("set_type"), do: {:ok, "set_type"}
  defp restore_audit_action("add_relation"), do: {:ok, "remove_relation"}
  defp restore_audit_action("remove_relation"), do: {:ok, "add_relation"}
  defp restore_audit_action(action), do: {:error, {:audit_not_restorable, action}}

  defp restore_source_audit(repo, scope, %AuditLog{action: "create_entry"} = audit) do
    case fetch_entry_for_write(repo, scope, audit.entry_id, true) do
      %Entry{} = entry ->
        before = entry_bundle_snapshot(repo, entry)
        touched = bundle_neighbor_ids(before)

        with :ok <- ensure_created_entry_unchanged(repo, entry, audit),
             {:ok, _entry} <- repo.delete(entry) do
          {:ok, %{restored: "create_entry", entry_id: entry.id}, before, nil, touched}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp restore_source_audit(
         repo,
         scope,
         %AuditLog{action: "delete_entry", before: before} = audit
       ) do
    with :ok <- ensure_object_absent(repo.get(Entry, audit_entry_id(before)), audit),
         {:ok, entry} <- restore_entry_bundle(repo, scope, before) do
      after_snapshot = entry_bundle_snapshot(repo, entry)
      {:ok, %{restored: "delete_entry", entry_id: entry.id}, nil, after_snapshot, [entry.id]}
    end
  end

  defp restore_source_audit(repo, scope, %AuditLog{action: "append_block"} = audit) do
    case fetch_block_for_write(repo, scope, audit.block_id, true) do
      %EntryBlock{} = block ->
        before = block_snapshot(block)

        with :ok <- ensure_block_unchanged(block, audit.after, audit),
             {:ok, _block} <- repo.delete(block),
             :ok <- touch_entry(repo, block.entry_id) do
          {:ok, %{restored: "append_block", block_id: block.id}, before, nil, [block.entry_id]}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp restore_source_audit(
         repo,
         scope,
         %AuditLog{action: "delete_block", before: before} = audit
       ) do
    with :ok <- ensure_object_absent(repo.get(EntryBlock, audit.block_id), audit),
         {:ok, block} <- restore_deleted_block(repo, scope, before),
         :ok <- Citations.reindex(repo, block),
         :ok <- touch_entry(repo, block.entry_id) do
      {:ok, %{restored: "delete_block", block_id: block.id}, nil, block_snapshot(block),
       [block.entry_id]}
    end
  end

  defp restore_source_audit(repo, scope, %AuditLog{action: "edit_block", before: before} = audit) do
    with %EntryBlock{} = block <- fetch_block_for_write(repo, scope, audit.block_id, true),
         :ok <- ensure_block_unchanged(block, audit.after, audit),
         current = block_snapshot(block),
         {:ok, block} <-
           repo.update(
             EntryBlock.update_changeset(block, %{
               body: before["body"],
               author_kind: before["author_kind"],
               author_uid: before["author_uid"]
             }),
             stale_error_field: :lock_version
           ),
         :ok <- Citations.reindex(repo, block),
         :ok <- touch_entry(repo, block.entry_id) do
      {:ok, %{restored: "edit_block", block_id: block.id}, current, block_snapshot(block),
       [block.entry_id]}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp restore_source_audit(
         repo,
         scope,
         %AuditLog{action: "set_property", before: before, after: after_snapshot} = audit
       ) do
    with %Entry{} = entry <- fetch_entry_for_write(repo, scope, audit.entry_id, true),
         {:ok, key} <- changed_property_key(before, after_snapshot),
         :ok <-
           ensure_map_value_matches(entry.properties, after_snapshot["properties"], key, audit),
         current = entry_snapshot(entry),
         properties = restore_map_value(entry.properties, before["properties"], key),
         {:ok, entry} <- repo.update(Entry.update_changeset(entry, %{properties: properties})),
         after_snapshot = entry_snapshot(entry) do
      {:ok, %{restored: "set_property", entry_id: entry.id}, current, after_snapshot, [entry.id]}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp restore_source_audit(
         repo,
         scope,
         %AuditLog{action: action, before: before, after: after_snapshot} = audit
       )
       when action in ["set_summary", "set_aliases", "set_name", "set_type"] do
    field =
      case action do
        "set_summary" -> :summary
        "set_aliases" -> :aliases
        "set_name" -> :name
        "set_type" -> :type
      end

    key = Atom.to_string(field)

    with %Entry{} = entry <- fetch_entry_for_write(repo, scope, audit.entry_id, true),
         :ok <- ensure_value_matches(Map.fetch!(entry, field), after_snapshot[key], audit),
         current = entry_snapshot(entry),
         {:ok, entry} <- repo.update(Entry.update_changeset(entry, %{field => before[key]})),
         after_snapshot = entry_snapshot(entry) do
      {:ok, %{restored: action, entry_id: entry.id}, current, after_snapshot, [entry.id]}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp restore_source_audit(repo, scope, %AuditLog{action: "add_relation"} = audit) do
    relation_query =
      from relation in EntryRelation,
        where: relation.id == ^audit.relation_id,
        lock: "FOR UPDATE"

    case repo.one(relation_query) do
      %EntryRelation{owner_uid: owner_uid, store_key: store_key} = relation
      when owner_uid == scope.owner_uid and store_key == scope.writable_store_key ->
        before = relation_snapshot(relation)

        with :ok <- ensure_relation_unchanged(relation, audit.after, audit),
             %Entry{} = source <-
               fetch_entry_for_write(repo, scope, relation.source_entry_id, true),
             {:ok, _relation} <- repo.delete(relation),
             {:ok, _source} <- bump_entry(repo, source) do
          {:ok, %{restored: "add_relation", relation_id: relation.id}, before, nil,
           [relation.source_entry_id, relation.target_entry_id]}
        else
          nil -> {:error, :not_found}
          {:error, _reason} = error -> error
        end

      _missing_or_wrong_scope ->
        {:error, :not_found}
    end
  end

  defp restore_source_audit(
         repo,
         scope,
         %AuditLog{action: "remove_relation", before: before} = audit
       ) do
    with :ok <- ensure_object_absent(repo.get(EntryRelation, audit.relation_id), audit),
         %Entry{} = source <- fetch_entry_for_write(repo, scope, before["source_entry_id"], true),
         {:ok, relation} <- restore_deleted_relation(repo, scope, before),
         {:ok, _source} <- bump_entry(repo, source) do
      {:ok, %{restored: "remove_relation", relation_id: relation.id}, nil,
       relation_snapshot(relation), [relation.source_entry_id, relation.target_entry_id]}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp restore_source_audit(_repo, _scope, audit),
    do: {:error, {:audit_not_restorable, audit.action}}

  defp ensure_created_entry_unchanged(
         repo,
         entry,
         %AuditLog{after: %{"kind" => "entry"}} = audit
       ) do
    with :ok <- ensure_entry_unchanged(entry, audit.after, audit),
         false <- entry_has_children?(repo, entry.id) do
      :ok
    else
      true -> audit_restore_conflict(audit, :state_changed)
      {:error, _reason} = error -> error
    end
  end

  defp ensure_created_entry_unchanged(
         repo,
         entry,
         %AuditLog{after: %{"kind" => "entry_bundle"}} = audit
       ),
       do:
         ensure_value_matches(
           bundle_comparable(entry_bundle_snapshot(repo, entry)),
           bundle_comparable(audit.after),
           audit
         )

  defp ensure_created_entry_unchanged(_repo, _entry, audit),
    do: audit_restore_conflict(audit, :invalid_after_snapshot)

  defp ensure_entry_unchanged(entry, expected, audit) do
    keys = ~w(id owner_uid store_key name type summary aliases properties)

    ensure_value_matches(
      Map.take(entry_snapshot(entry), keys),
      Map.take(expected || %{}, keys),
      audit
    )
  end

  defp ensure_block_unchanged(block, expected, audit) do
    keys = ~w(id entry_id owner_uid store_key position body author_kind author_uid)

    ensure_value_matches(
      Map.take(block_snapshot(block), keys),
      Map.take(expected || %{}, keys),
      audit
    )
  end

  defp ensure_relation_unchanged(relation, expected, audit) do
    keys = ~w(id owner_uid store_key source_entry_id predicate target_entry_id)

    ensure_value_matches(
      Map.take(relation_snapshot(relation), keys),
      Map.take(expected || %{}, keys),
      audit
    )
  end

  defp bundle_comparable(bundle) do
    %{
      "entry" =>
        comparable(
          bundle["entry"],
          ~w(id owner_uid store_key name type summary aliases properties)
        ),
      "blocks" =>
        bundle["blocks"]
        |> Kernel.||([])
        |> Enum.map(
          &comparable(
            &1,
            ~w(id entry_id owner_uid store_key position body author_kind author_uid)
          )
        )
        |> Enum.sort_by(& &1["id"]),
      "relations" =>
        bundle["relations"]
        |> Kernel.||([])
        |> Enum.map(
          &comparable(
            &1,
            ~w(id owner_uid store_key source_entry_id predicate target_entry_id)
          )
        )
        |> Enum.sort_by(& &1["id"])
    }
  end

  defp comparable(snapshot, keys), do: Map.take(snapshot || %{}, keys)

  defp entry_has_children?(repo, entry_id) do
    block_exists? =
      repo.exists?(from block in EntryBlock, where: block.entry_id == ^entry_id)

    relation_exists? =
      repo.exists?(
        from relation in EntryRelation,
          where: relation.source_entry_id == ^entry_id or relation.target_entry_id == ^entry_id
      )

    block_exists? or relation_exists?
  end

  defp ensure_object_absent(nil, _audit_or_kind), do: :ok

  defp ensure_object_absent(_object, %AuditLog{} = audit),
    do: audit_restore_conflict(audit, :object_present)

  defp ensure_value_matches(value, value, _audit), do: :ok

  defp ensure_value_matches(_current, _expected, audit),
    do: audit_restore_conflict(audit, :state_changed)

  defp changed_property_key(before, after_snapshot) do
    before_properties = before["properties"] || %{}
    after_properties = after_snapshot["properties"] || %{}

    keys =
      (Map.keys(before_properties) ++ Map.keys(after_properties))
      |> Enum.uniq()
      |> Enum.filter(fn key ->
        map_value(before_properties, key) != map_value(after_properties, key)
      end)

    case keys do
      [key] -> {:ok, key}
      _invalid -> {:error, :invalid_audit_snapshot}
    end
  end

  defp ensure_map_value_matches(current, expected, key, audit),
    do: ensure_value_matches(map_value(current, key), map_value(expected || %{}, key), audit)

  defp restore_map_value(current, before, key) do
    case map_value(before || %{}, key) do
      {:present, value} -> Map.put(current, key, value)
      :absent -> Map.delete(current, key)
    end
  end

  defp map_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:present, value}
      :error -> :absent
    end
  end

  defp audit_entry_id(%{"entry" => %{"id" => id}}), do: id
  defp audit_entry_id(_snapshot), do: nil

  defp audit_restore_conflict(audit, reason) do
    {:error,
     {:audit_restore_conflict,
      %{audit_id: audit.id, action: audit.action, entry_id: audit.entry_id, reason: reason}}}
  end

  defp restore_entry_bundle(repo, scope, %{"entry" => entry_data} = bundle) do
    if entry_data["owner_uid"] == scope.owner_uid and
         entry_data["store_key"] == scope.writable_store_key do
      entry = %Entry{id: entry_data["id"]}

      with {:ok, entry} <- repo.insert(Entry.changeset(entry, entry_attrs(entry_data))),
           :ok <- restore_bundle_blocks(repo, bundle["blocks"] || []),
           :ok <- restore_bundle_relations(repo, bundle["relations"] || []) do
        {:ok, entry}
      end
    else
      {:error, :audit_scope_mismatch}
    end
  end

  defp restore_entry_bundle(_repo, _scope, _snapshot), do: {:error, :invalid_audit_snapshot}

  defp restore_bundle_blocks(repo, blocks) do
    Enum.reduce_while(blocks, :ok, fn block_data, :ok ->
      case restore_deleted_block(repo, nil, block_data) do
        {:ok, block} ->
          case Citations.reindex(repo, block) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp restore_bundle_relations(repo, relations) do
    Enum.reduce_while(relations, :ok, fn relation_data, :ok ->
      case restore_deleted_relation(repo, nil, relation_data) do
        {:ok, _relation} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp restore_deleted_block(repo, scope, data) when is_map(data) do
    if is_nil(scope) or
         (data["owner_uid"] == scope.owner_uid and data["store_key"] == scope.writable_store_key) do
      block = %EntryBlock{id: data["id"]}

      repo.insert(
        EntryBlock.changeset(block, %{
          entry_id: data["entry_id"],
          owner_uid: data["owner_uid"],
          store_key: data["store_key"],
          position: data["position"],
          body: data["body"],
          author_kind: data["author_kind"],
          author_uid: data["author_uid"],
          embedding: data["embedding"],
          embedding_dimensions: data["embedding_dimensions"],
          embedding_state: data["embedding_state"],
          embedding_error: data["embedding_error"]
        })
      )
    else
      {:error, :audit_scope_mismatch}
    end
  end

  defp restore_deleted_relation(repo, scope, data) when is_map(data) do
    if is_nil(scope) or
         (data["owner_uid"] == scope.owner_uid and data["store_key"] == scope.writable_store_key) do
      relation = %EntryRelation{id: data["id"]}

      repo.insert(
        EntryRelation.changeset(relation, %{
          owner_uid: data["owner_uid"],
          store_key: data["store_key"],
          source_entry_id: data["source_entry_id"],
          predicate: data["predicate"],
          target_entry_id: data["target_entry_id"]
        })
      )
    else
      {:error, :audit_scope_mismatch}
    end
  end

  defp entry_attrs(data) do
    %{
      owner_uid: data["owner_uid"],
      store_key: data["store_key"],
      name: data["name"],
      type: data["type"],
      summary: data["summary"] || "",
      aliases: data["aliases"] || [],
      properties: data["properties"] || %{}
    }
  end

  defp entry_bundle_snapshot(repo, entry) do
    blocks =
      repo.all(
        from block in EntryBlock, where: block.entry_id == ^entry.id, order_by: block.position
      )

    relations =
      repo.all(
        from relation in EntryRelation,
          where: relation.source_entry_id == ^entry.id or relation.target_entry_id == ^entry.id
      )

    %{
      "kind" => "entry_bundle",
      "entry" => entry_snapshot(entry),
      "blocks" => Enum.map(blocks, &block_snapshot/1),
      "relations" => Enum.map(relations, &relation_snapshot/1)
    }
  end

  defp entry_snapshot(entry) do
    %{
      "kind" => "entry",
      "id" => entry.id,
      "owner_uid" => entry.owner_uid,
      "store_key" => entry.store_key,
      "name" => entry.name,
      "type" => entry.type,
      "summary" => entry.summary,
      "aliases" => entry.aliases,
      "properties" => entry.properties,
      "lock_version" => entry.lock_version,
      "inserted_at" => datetime(entry.inserted_at),
      "updated_at" => datetime(entry.updated_at)
    }
  end

  defp block_snapshot(block) do
    %{
      "kind" => "entry_block",
      "id" => block.id,
      "entry_id" => block.entry_id,
      "owner_uid" => block.owner_uid,
      "store_key" => block.store_key,
      "position" => block.position,
      "body" => block.body,
      "author_kind" => enum_string(block.author_kind),
      "author_uid" => block.author_uid,
      "embedding" => block.embedding,
      "embedding_dimensions" => block.embedding_dimensions,
      "embedding_state" => enum_string(block.embedding_state),
      "embedding_error" => block.embedding_error,
      "lock_version" => block.lock_version,
      "inserted_at" => datetime(block.inserted_at),
      "updated_at" => datetime(block.updated_at)
    }
  end

  defp relation_snapshot(relation) do
    %{
      "kind" => "entry_relation",
      "id" => relation.id,
      "owner_uid" => relation.owner_uid,
      "store_key" => relation.store_key,
      "source_entry_id" => relation.source_entry_id,
      "predicate" => relation.predicate,
      "target_entry_id" => relation.target_entry_id,
      "inserted_at" => datetime(relation.inserted_at),
      "updated_at" => datetime(relation.updated_at)
    }
  end

  defp bundle_neighbor_ids(%{"relations" => relations, "entry" => %{"id" => entry_id}}) do
    relations
    |> Enum.flat_map(&[&1["source_entry_id"], &1["target_entry_id"]])
    |> Enum.reject(&(&1 in [nil, entry_id]))
    |> Enum.uniq()
  end

  defp bundle_neighbor_ids(_bundle), do: []

  defp audit_ids(audit) do
    %{entry_id: audit.entry_id, block_id: audit.block_id, relation_id: audit.relation_id}
  end

  defp enum_string(nil), do: nil
  defp enum_string(value) when is_atom(value), do: Atom.to_string(value)
  defp enum_string(value), do: value
  defp datetime(nil), do: nil
  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
