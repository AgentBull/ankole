defmodule Ankole.Brain.Supervision do
  @moduledoc """
  Human supervision use cases over one Principal's Brain.

  The caller supplies an already-authorized owner and human actor. This module
  owns Brain scope construction, store routing, recovery orchestration, paging,
  and the stable supervision read models. Transport parsing and authorization
  remain outside the Brain context.
  """

  import Ecto.Query

  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Schemas.AuditLog
  alias Ankole.Brain.Schemas.Entry
  alias Ankole.Brain.Schemas.EntryBlock
  alias Ankole.Brain.Schemas.EntryRelation
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.Entry, as: SignalEntry

  @default_page_limit 50
  @max_page_limit 100
  @surface_metadata %{"surface" => "console_rest"}

  @fitness_default_horizon_days 7
  @fitness_min_horizon_days 1
  @fitness_max_horizon_days 90
  @fitness_default_lookback_days 90
  @fitness_min_lookback_days 1
  @fitness_max_lookback_days 365
  @fitness_max_runs 100

  @type page_cursor :: {DateTime.t(), Ecto.UUID.t()}
  @type page :: %{required(:next_cursor) => page_cursor() | nil}

  @doc "Lists the current entry directory for an authorized human supervisor."
  @spec list_entries(String.t(), keyword()) :: {:ok, page()} | {:error, term()}
  def list_entries(owner_uid, opts \\ [])

  def list_entries(owner_uid, opts) when is_list(opts) do
    with {:ok, limit} <- page_limit(opts),
         {:ok, scope} <- Scope.for_console(owner_uid, Keyword.get(opts, :store_key) || :all),
         {:ok, rows} <-
           Knowledge.list_entries(scope, Keyword.put(opts, :limit, limit + 1)) do
      {entries, next_cursor} = page(rows, limit, &entry_cursor/1)

      {:ok,
       %{
         entries: Enum.map(entries, &entry_projection/1),
         next_cursor: next_cursor
       }}
    end
  end

  def list_entries(_owner_uid, _opts), do: {:error, :invalid_arguments}

  @doc "Opens one complete current entry projection for human supervision."
  @spec open_entry(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def open_entry(owner_uid, selector) do
    with {:ok, scope} <- Scope.for_console(owner_uid, :all),
         {:ok, projection} <- Knowledge.open(scope, selector, block_limit: :all) do
      {:ok, knowledge_projection(projection)}
    end
  end

  @doc "Applies one authorized human mutation batch after deriving its store."
  @spec apply_human_operations(String.t(), map() | [map()], String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def apply_human_operations(owner_uid, operations, actor_uid, opts \\ [])

  def apply_human_operations(owner_uid, operations, actor_uid, opts) when is_list(opts) do
    requested_store = Keyword.get(opts, :store_key)

    with {:ok, all_scope} <- Scope.for_console(owner_uid, :all) do
      Repo.transact(fn repo ->
        with {:ok, store_key} <-
               operation_store(repo, all_scope.owner_uid, requested_store, operations),
             {:ok, scope} <- Scope.for_store(all_scope.owner_uid, store_key),
             {:ok, result} <-
               Knowledge.apply_operations(
                 scope,
                 operations,
                 %{kind: :human, uid: actor_uid},
                 repo: repo,
                 metadata: @surface_metadata
               ) do
          {:ok, json_safe(result)}
        end
      end)
    end
  end

  def apply_human_operations(_owner_uid, _operations, _actor_uid, _opts),
    do: {:error, :invalid_arguments}

  @doc "Lists audit rows for supervision and explicit recovery."
  @spec list_audit(String.t(), keyword()) :: {:ok, page()} | {:error, term()}
  def list_audit(owner_uid, opts \\ [])

  def list_audit(owner_uid, opts) when is_list(opts) do
    with {:ok, limit} <- page_limit(opts),
         {:ok, scope} <- Scope.for_console(owner_uid, :all),
         {:ok, rows} <- Knowledge.list_audit(scope, Keyword.put(opts, :limit, limit + 1)) do
      {audit_log, next_cursor} = page(rows, limit, &audit_cursor/1)

      {:ok,
       %{
         audit_log: Enum.map(audit_log, &audit_projection/1),
         next_cursor: next_cursor
       }}
    end
  end

  def list_audit(_owner_uid, _opts), do: {:error, :invalid_arguments}

  @doc "Restores one audit record in the store recorded by that immutable audit row."
  @spec restore_audit(String.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def restore_audit(owner_uid, audit_id, actor_uid) do
    with {:ok, all_scope} <- Scope.for_console(owner_uid, :all),
         {:ok, [audit | _]} <- Knowledge.list_audit(all_scope, audit_id: audit_id, limit: 1),
         {:ok, scope} <- Scope.for_store(all_scope.owner_uid, audit.store_key),
         {:ok, restoration} <-
           Knowledge.restore_audit(
             scope,
             audit_id,
             %{kind: :human, uid: actor_uid},
             metadata: @surface_metadata
           ) do
      {:ok, json_safe(restoration)}
    else
      {:ok, []} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc "Atomically restores an exact audit selection across the owner's stores."
  @spec restore_audits(String.t(), [Ecto.UUID.t()], String.t()) ::
          {:ok, map()} | {:error, term()}
  def restore_audits(owner_uid, audit_ids, actor_uid) do
    with {:ok, scope} <- Scope.for_console(owner_uid, :all),
         {:ok, restoration} <-
           Knowledge.restore_audits(
             scope,
             audit_ids,
             %{kind: :human, uid: actor_uid},
             metadata: @surface_metadata
           ) do
      {:ok, json_safe(restoration)}
    end
  end

  @doc "Resolves one stable Brain source citation to its current provider mirror."
  @spec resolve_source(String.t()) :: {:ok, map()} | {:error, :not_found}
  def resolve_source(document_id) do
    case SignalsGateway.get_entry_by_document_id(document_id) do
      %SignalEntry{} = entry -> {:ok, source_projection(entry)}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Reads dreaming block writes as a selection-pressure signal over the audit log.

  A dreaming block write (`append_block`/`edit_block`, signed `dreaming`) is
  "corrected" when a human `edit_block`/`delete_block` lands on the same block
  within the horizon, with no intervening dreaming write of that block (so the
  correction is attributed to the dreaming output it actually overrode; restores
  already land as human deletes). Survival is only judged on writes whose full
  horizon has elapsed; more recent writes are reported as `pending`, not as
  survivors, so the rate stays longitudinally honest. Attribution is per run_id.
  """
  @spec dreaming_fitness(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def dreaming_fitness(owner_uid, opts \\ [])

  def dreaming_fitness(owner_uid, opts) when is_binary(owner_uid) and is_list(opts) do
    with {:ok, scope} <- Scope.for_console(owner_uid, :all),
         {:ok, horizon_days} <- fitness_horizon(opts),
         {:ok, lookback_days} <- fitness_lookback(opts) do
      now = DateTime.utc_now()
      lookback_start = shift_naive(now, -lookback_days)
      matured_before = shift_naive(now, -horizon_days)

      rows =
        fitness_run_rows(scope.owner_uid, lookback_start, matured_before, horizon_days)

      {:ok, fitness_projection(rows, horizon_days, lookback_days, now)}
    end
  end

  def dreaming_fitness(_owner_uid, _opts), do: {:error, :invalid_arguments}

  defp fitness_horizon(opts),
    do:
      bounded_days(
        Keyword.get(opts, :horizon_days),
        @fitness_default_horizon_days,
        @fitness_min_horizon_days,
        @fitness_max_horizon_days,
        :invalid_horizon_days
      )

  defp fitness_lookback(opts),
    do:
      bounded_days(
        Keyword.get(opts, :lookback_days),
        @fitness_default_lookback_days,
        @fitness_min_lookback_days,
        @fitness_max_lookback_days,
        :invalid_lookback_days
      )

  defp bounded_days(nil, default, _min, _max, _error), do: {:ok, default}

  defp bounded_days(value, _default, min, max, _error)
       when is_integer(value) and value >= min and value <= max,
       do: {:ok, value}

  defp bounded_days(_value, _default, _min, _max, error), do: {:error, error}

  defp shift_naive(%DateTime{} = now, days) do
    now
    |> DateTime.add(days * 86_400, :second)
    |> DateTime.to_naive()
  end

  # One owner's dreaming block writes in the lookback, each judged corrected only
  # if a human overrode the same block within the horizon before any later
  # dreaming write of that block. Grouped by the run that produced them.
  defp fitness_run_rows(owner_uid, lookback_start, matured_before, horizon_days) do
    sql = """
    SELECT
      dp.run_id,
      count(*) AS produced,
      count(*) FILTER (WHERE dp.matured) AS matured,
      count(*) FILTER (WHERE dp.matured AND dp.corrected) AS corrected,
      min(dp.inserted_at) AS first_at,
      max(dp.inserted_at) AS last_at
    FROM (
      SELECT
        p.metadata ->> 'run_id' AS run_id,
        (p.inserted_at <= $3) AS matured,
        EXISTS (
          SELECT 1
          FROM brain_audit_log h
          WHERE h.owner_uid = $1
            AND h.actor_kind = 'human'
            AND h.action IN ('edit_block', 'delete_block')
            AND h.block_id = p.block_id
            AND h.inserted_at > p.inserted_at
            AND h.inserted_at <= p.inserted_at + ($4 * INTERVAL '1 day')
            AND NOT EXISTS (
              SELECT 1
              FROM brain_audit_log later
              WHERE later.owner_uid = $1
                AND later.actor_kind = 'dreaming'
                AND later.action IN ('append_block', 'edit_block')
                AND later.block_id = p.block_id
                AND later.inserted_at > p.inserted_at
                AND later.inserted_at < h.inserted_at
            )
        ) AS corrected,
        p.inserted_at
      FROM brain_audit_log p
      WHERE p.owner_uid = $1
        AND p.actor_kind = 'dreaming'
        AND p.action IN ('append_block', 'edit_block')
        AND p.block_id IS NOT NULL
        AND p.inserted_at >= $2
    ) dp
    GROUP BY dp.run_id
    ORDER BY max(dp.inserted_at) DESC
    LIMIT $5
    """

    case Repo.query(sql, [
           owner_uid,
           lookback_start,
           matured_before,
           horizon_days,
           @fitness_max_runs
         ]) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &fitness_run_row/1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp fitness_run_row([run_id, produced, matured, corrected, first_at, last_at]) do
    survived = matured - corrected

    %{
      run_id: run_id,
      produced_block_writes: produced,
      matured_block_writes: matured,
      pending_block_writes: produced - matured,
      corrected_block_writes: corrected,
      survived_block_writes: survived,
      survival_rate: survival_rate(survived, matured),
      first_written_at: datetime(first_at),
      last_written_at: datetime(last_at)
    }
  end

  defp fitness_projection({:error, _reason}, horizon_days, lookback_days, now) do
    base_fitness_projection([], horizon_days, lookback_days, now)
  end

  defp fitness_projection(runs, horizon_days, lookback_days, now) do
    base_fitness_projection(runs, horizon_days, lookback_days, now)
  end

  defp base_fitness_projection(runs, horizon_days, lookback_days, now) do
    matured = Enum.sum(Enum.map(runs, & &1.matured_block_writes))
    corrected = Enum.sum(Enum.map(runs, & &1.corrected_block_writes))
    produced = Enum.sum(Enum.map(runs, & &1.produced_block_writes))
    survived = matured - corrected

    %{
      horizon_days: horizon_days,
      lookback_days: lookback_days,
      generated_at: datetime(now),
      produced_block_writes: produced,
      matured_block_writes: matured,
      pending_block_writes: produced - matured,
      corrected_block_writes: corrected,
      survived_block_writes: survived,
      survival_rate: survival_rate(survived, matured),
      runs: runs
    }
  end

  defp survival_rate(_survived, 0), do: nil
  defp survival_rate(survived, matured), do: Float.round(survived / matured, 4)

  defp operation_store(repo, owner_uid, requested_store, operations) do
    with {:ok, entry_ids, block_ids} <- operation_target_ids(operations),
         {:ok, entry_stores} <- entry_stores(repo, owner_uid, entry_ids),
         {:ok, block_stores} <- block_stores(repo, owner_uid, block_ids) do
      choose_operation_store(requested_store, Enum.uniq(entry_stores ++ block_stores))
    end
  end

  defp operation_target_ids(operations) do
    operations
    |> List.wrap()
    |> Enum.reduce_while({:ok, MapSet.new(), MapSet.new()}, fn
      operation, {:ok, entry_ids, block_ids} when is_map(operation) ->
        with {:ok, entry_ids} <- maybe_add_uuid(entry_ids, value(operation, :entry_id), :entry_id),
             {:ok, block_ids} <- maybe_add_uuid(block_ids, value(operation, :block_id), :block_id) do
          {:cont, {:ok, entry_ids, block_ids}}
        else
          {:error, _reason} = error -> {:halt, error}
        end

      _operation, _acc ->
        {:halt, {:error, :invalid_operations}}
    end)
    |> case do
      {:ok, entry_ids, block_ids} ->
        {:ok, MapSet.to_list(entry_ids), MapSet.to_list(block_ids)}

      {:error, _reason} = error ->
        error
    end
  end

  defp maybe_add_uuid(ids, nil, _key), do: {:ok, ids}

  defp maybe_add_uuid(ids, value, key) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, MapSet.put(ids, id)}
      :error -> {:error, {:invalid_field, key}}
    end
  end

  defp entry_stores(_repo, _owner_uid, []), do: {:ok, []}

  defp entry_stores(repo, owner_uid, entry_ids) do
    rows =
      repo.all(
        from entry in Entry,
          where: entry.owner_uid == ^owner_uid and entry.id in ^entry_ids,
          select: {entry.id, entry.store_key}
      )

    stores_for_targets(rows, entry_ids)
  end

  defp block_stores(_repo, _owner_uid, []), do: {:ok, []}

  defp block_stores(repo, owner_uid, block_ids) do
    rows =
      repo.all(
        from block in EntryBlock,
          where: block.owner_uid == ^owner_uid and block.id in ^block_ids,
          select: {block.id, block.store_key}
      )

    stores_for_targets(rows, block_ids)
  end

  defp stores_for_targets(rows, target_ids) do
    if MapSet.new(Enum.map(rows, &elem(&1, 0))) == MapSet.new(target_ids) do
      {:ok, Enum.map(rows, &elem(&1, 1))}
    else
      {:error, :not_found}
    end
  end

  defp choose_operation_store(nil, [store_key]), do: {:ok, store_key}
  defp choose_operation_store(nil, []), do: {:error, {:missing, "store"}}

  defp choose_operation_store(_requested_store, [_left, _right | _rest]),
    do: {:error, :mixed_store_operations}

  defp choose_operation_store(requested_store, []), do: {:ok, requested_store}
  defp choose_operation_store(store_key, [store_key]), do: {:ok, store_key}
  defp choose_operation_store(_requested_store, [_different]), do: {:error, :store_mismatch}

  defp page_limit(opts) do
    case Keyword.get(opts, :limit, @default_page_limit) do
      limit when is_integer(limit) and limit in 1..@max_page_limit -> {:ok, limit}
      _invalid -> {:error, :invalid_page_limit}
    end
  end

  defp page(rows, limit, cursor_fun) do
    current_page = Enum.take(rows, limit)
    next_cursor = if length(rows) > limit, do: current_page |> List.last() |> cursor_fun.()
    {current_page, next_cursor}
  end

  defp entry_cursor(%Entry{id: id, updated_at: updated_at}), do: {updated_at, id}
  defp audit_cursor(%AuditLog{id: id, inserted_at: inserted_at}), do: {inserted_at, id}

  defp knowledge_projection(projection) do
    %{
      entry: entry_projection(Map.fetch!(projection, :entry)),
      blocks: projection |> Map.fetch!(:blocks) |> Enum.map(&block_projection/1),
      relations: projection |> Map.fetch!(:relations) |> Enum.map(&relation_projection/1),
      backlinks: projection |> Map.fetch!(:backlinks) |> Enum.map(&relation_projection/1),
      markdown: Map.fetch!(projection, :markdown)
    }
  end

  defp entry_projection(%Entry{} = entry) do
    %{
      id: entry.id,
      owner_uid: entry.owner_uid,
      store_key: entry.store_key,
      name: entry.name,
      type: entry.type,
      summary: entry.summary,
      aliases: entry.aliases || [],
      properties: entry.properties || %{},
      lock_version: entry.lock_version,
      inserted_at: datetime(entry.inserted_at),
      updated_at: datetime(entry.updated_at)
    }
  end

  defp block_projection(%EntryBlock{} = block) do
    %{
      id: block.id,
      entry_id: block.entry_id,
      position: block.position,
      body: block.body,
      author_kind: atom_string(block.author_kind),
      author_uid: block.author_uid,
      embedding_state: atom_string(block.embedding_state),
      embedding_error: block.embedding_error,
      lock_version: block.lock_version,
      inserted_at: datetime(block.inserted_at),
      updated_at: datetime(block.updated_at)
    }
  end

  defp relation_projection(%EntryRelation{} = relation) do
    %{
      id: relation.id,
      source_entry_id: relation.source_entry_id,
      source_name: loaded_entry_name(relation.source_entry),
      predicate: relation.predicate,
      target_entry_id: relation.target_entry_id,
      target_name: loaded_entry_name(relation.target_entry),
      inserted_at: datetime(relation.inserted_at)
    }
  end

  defp relation_projection(%{relation: %EntryRelation{} = relation, target: %Entry{} = target}) do
    relation
    |> relation_projection()
    |> Map.put(:target_name, target.name)
  end

  defp relation_projection(%{relation: %EntryRelation{} = relation, source: %Entry{} = source}) do
    relation
    |> relation_projection()
    |> Map.put(:source_name, source.name)
  end

  defp audit_projection(%AuditLog{} = audit) do
    %{
      id: audit.id,
      owner_uid: audit.owner_uid,
      store_key: audit.store_key,
      actor_kind: atom_string(audit.actor_kind),
      actor_uid: audit.actor_uid,
      action: audit.action,
      entry_id: audit.entry_id,
      block_id: audit.block_id,
      relation_id: audit.relation_id,
      before: json_safe(audit.before),
      after: json_safe(audit.after),
      metadata: json_safe(audit.metadata || %{}),
      inserted_at: datetime(audit.inserted_at)
    }
  end

  defp source_projection(%SignalEntry{} = entry) do
    %{
      document_id: entry.document_id,
      signal_channel_id: entry.signal_channel_id,
      source_entry_id: entry.source_entry_id,
      text: entry.text,
      rich_content: json_safe(entry.rich_content),
      attachments: json_safe(entry.attachments || []),
      links: json_safe(entry.links || []),
      author: json_safe(entry.author || %{}),
      metadata: json_safe(entry.metadata || %{}),
      provider_time: datetime(entry.provider_time)
    }
  end

  defp loaded_entry_name(%Entry{name: name}), do: name
  defp loaded_entry_name(_not_loaded), do: nil

  defp json_safe(nil), do: nil
  defp json_safe(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, json_safe(item)} end)
  end

  defp json_safe(value), do: inspect(value)

  defp value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp atom_string(nil), do: nil
  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_string(value), do: to_string(value)

  defp datetime(nil), do: nil
  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
end
