defmodule Ankole.Brain.Status do
  @moduledoc "Single read-only health surface for long-term memory."

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.Brain.Config
  alias Ankole.Brain.Dreaming.StageA
  alias Ankole.Brain.Embedding
  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Schemas.BlockCitation
  alias Ankole.Brain.Schemas.Cursor
  alias Ankole.Brain.Schemas.Entry
  alias Ankole.Brain.Schemas.EntryBlock
  alias Ankole.Brain.Schemas.EntryRelation
  alias Ankole.Brain.Schemas.Episode
  alias Ankole.Brain.Schemas.RetainedSource
  alias Ankole.Brain.Sources
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Entry, as: SignalEntry

  @episode_backlog_alert 200
  @block_backlog_alert 500
  @stuck_seconds 1_800
  @stale_days 90
  @long_projection_lines 200
  @date_name ~r/(?:\d{4}-\d{2}|20\d\d年)/u

  @spec run(String.t() | Scope.t()) :: {:ok, map()} | {:error, term()}
  def run(owner_uid) when is_binary(owner_uid) do
    with {:ok, scope} <- Scope.for_console(owner_uid, :all), do: run(scope)
  end

  def run(%Scope{} = scope) do
    entries = scoped_entries(scope)
    blocks = scoped_blocks(entries)

    with {:ok, knowledge_config} <- Config.knowledge(),
         {:ok, diagnostics} <- diagnostics(scope, knowledge_config, entries, blocks) do
      block_embeddings = embedding_counts(blocks)
      {channels, episodes} = channel_statuses(scope.owner_uid)
      stage_b = stage_b_status(scope.owner_uid)
      embedding = embedding_status()
      stuck_jobs = stuck_jobs(scope.owner_uid)
      memo = memo_status(entries, blocks, knowledge_config["pinned_memo_max_tokens"])
      lints = lint_status(entries, blocks, diagnostics)

      alerts =
        alerts(channels, stage_b, episodes, block_embeddings, embedding, stuck_jobs, memo, lints)

      {:ok,
       %{
         "status" => if(alerts == [], do: "ok", else: "error"),
         "owner_uid" => scope.owner_uid,
         "generated_at" => DateTime.utc_now(:microsecond) |> DateTime.to_iso8601(),
         "alerts" => alerts,
         "stage_a" => %{
           "channels" => channels,
           "episodes" => Map.put(episodes, "pending_alert_threshold", @episode_backlog_alert)
         },
         "stage_b" => stage_b,
         "entry_block_embeddings" =>
           Map.put(block_embeddings, "pending_alert_threshold", @block_backlog_alert),
         "embedding" => embedding,
         "stuck_curation_jobs" => stuck_jobs,
         "memo" => memo,
         "lints" => lints,
         "diagnostics" => diagnostics
       }}
    end
  end

  defp diagnostics(%Scope{} = scope, knowledge_config, entries, blocks) do
    with {:ok, projections} <- entry_projections(scope, entries) do
      visible_channel_ids = visible_channel_ids(scope)

      {:ok,
       %{
         "status" => "ok",
         "checked_entry_count" => length(entries),
         "orphan_entries" => orphan_entries(entries, blocks, scope),
         "long_entries" => long_entries(entries, projections),
         "stale_entries" => stale_entries(entries, visible_channel_ids),
         "over_budget_pinned_memos" =>
           over_budget_pinned_memos(
             entries,
             projections,
             knowledge_config["pinned_memo_max_tokens"]
           ),
         "failed_embeddings" => failed_embeddings(entries, blocks),
         "uncited_generated_blocks" => uncited_generated_blocks(entries, blocks),
         "broken_citations" => broken_citations(scope, entries, blocks),
         "unintegrated_sources" => unintegrated_sources(scope),
         "dreaming_blocks" => dreaming_blocks(entries, blocks)
       }}
    end
  end

  defp entry_projections(scope, entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, projections} ->
      case Knowledge.open(scope, entry.id, block_limit: :all) do
        {:ok, %{markdown: markdown}} ->
          {:cont, {:ok, Map.put(projections, entry.id, markdown)}}

        {:error, reason} ->
          {:halt, {:error, {:brain_health_projection_failed, entry.id, reason}}}
      end
    end)
  end

  defp orphan_entries(entries, blocks, scope) do
    related_ids =
      EntryRelation
      |> scope_rows(scope)
      |> select([relation], {relation.source_entry_id, relation.target_entry_id})
      |> Repo.all()
      |> Enum.flat_map(fn {source, target} -> [source, target] end)
      |> MapSet.new()

    bodies_by_entry = Enum.group_by(blocks, & &1.entry_id, &String.downcase(&1.body))

    entries
    |> Enum.reject(&MapSet.member?(related_ids, &1.id))
    |> Enum.reject(fn entry ->
      names = [entry.name | entry.aliases || []] |> Enum.map(&String.downcase/1)

      bodies_by_entry
      |> Map.delete(entry.id)
      |> Map.values()
      |> List.flatten()
      |> Enum.any?(fn body -> Enum.any?(names, &String.contains?(body, &1)) end)
    end)
    |> Enum.map(&entry_ref/1)
  end

  defp long_entries(entries, projections) do
    Enum.flat_map(entries, fn entry ->
      line_count =
        projections
        |> Map.fetch!(entry.id)
        |> String.split("\n")
        |> length()

      if line_count > @long_projection_lines,
        do: [entry_ref(entry) |> Map.put("line_count", line_count)],
        else: []
    end)
  end

  defp stale_entries(entries, visible_channel_ids) do
    Enum.flat_map(entries, fn entry ->
      case latest_source_mention(entry, visible_channel_ids) do
        %DateTime{} = latest ->
          stale_entry_result(entry, latest)

        %NaiveDateTime{} = latest ->
          stale_entry_result(entry, DateTime.from_naive!(latest, "Etc/UTC"))

        nil ->
          []
      end
    end)
  end

  defp stale_entry_result(entry, latest) do
    age_days = DateTime.diff(latest, entry.updated_at, :day)

    if age_days > @stale_days do
      [
        entry_ref(entry)
        |> Map.put("entry_updated_at", DateTime.to_iso8601(entry.updated_at))
        |> Map.put("latest_source_mention_at", DateTime.to_iso8601(latest))
        |> Map.put("lag_days", age_days)
      ]
    else
      []
    end
  end

  defp latest_source_mention(_entry, []), do: nil

  defp latest_source_mention(entry, visible_channel_ids) do
    terms = [entry.name | entry.aliases || []] |> Enum.reject(&(&1 == ""))

    SignalEntry
    |> where([signal], signal.signal_channel_id in ^visible_channel_ids)
    |> where([signal], not is_nil(signal.text))
    |> where([signal], fragment("? ILIKE ANY(?)", signal.text, ^like_terms(terms)))
    |> select(
      [signal],
      max(
        fragment(
          "COALESCE(?, ?, ?)",
          signal.provider_time,
          signal.last_seen_at,
          signal.inserted_at
        )
      )
    )
    |> Repo.one()
  end

  defp visible_channel_ids(%Scope{} = scope) do
    readable_stores = readable_stores(scope)

    scope.owner_uid
    |> SignalsGateway.visible_channels()
    |> Enum.filter(&store_readable?(readable_stores, channel_store_key(scope, &1)))
    |> Enum.map(& &1.id)
  end

  defp readable_stores(%Scope{readable_store_keys: :all}), do: :all
  defp readable_stores(%Scope{readable_store_keys: stores}), do: stores

  defp channel_store_key(%Scope{}, %Channel{kind: :im_dm, metadata: metadata}) do
    case Map.get(metadata || %{}, "dm_peer_principal_uid") do
      peer_uid when is_binary(peer_uid) and peer_uid != "" -> "dm:#{String.downcase(peer_uid)}"
      _missing -> :unknown
    end
  end

  defp channel_store_key(%Scope{owner_uid: owner_uid}, %Channel{kind: :im_group, id: id}) do
    if SignalsGateway.confidential_channel?(owner_uid, id), do: "channel:#{id}", else: "shared"
  end

  defp channel_store_key(%Scope{}, %Channel{}), do: "shared"

  defp store_readable?(:all, _store_key), do: true
  defp store_readable?(stores, store_key), do: store_key in stores

  defp over_budget_pinned_memos(entries, projections, budget) do
    entries
    |> Enum.filter(&(&1.type == "agent_system_pinned_memo"))
    |> Enum.flat_map(fn entry ->
      tokens =
        projections
        |> Map.fetch!(entry.id)
        |> Ankole.Kernel.estimate_o200k_base_tokens()

      if tokens > budget,
        do: [
          entry_ref(entry)
          |> Map.merge(%{"estimated_tokens" => tokens, "budget" => budget})
        ],
        else: []
    end)
  end

  defp failed_embeddings(entries, blocks) do
    names = Map.new(entries, &{&1.id, &1.name})

    blocks
    |> Enum.filter(&(&1.embedding_state == :failed))
    |> Enum.map(fn block ->
      %{
        "entry_id" => block.entry_id,
        "entry_name" => names[block.entry_id],
        "block_id" => block.id,
        "block_position" => block.position,
        "error" => block.embedding_error
      }
    end)
  end

  defp uncited_generated_blocks(entries, blocks) do
    names = Map.new(entries, &{&1.id, &1.name})
    block_ids = Enum.map(blocks, & &1.id)

    cited_block_ids =
      BlockCitation
      |> where([citation], citation.block_id in ^block_ids)
      |> select([citation], citation.block_id)
      |> Repo.all()
      |> MapSet.new()

    blocks
    |> Enum.filter(&(&1.author_kind in [:agent, :dreaming]))
    |> Enum.reject(&MapSet.member?(cited_block_ids, &1.id))
    |> Enum.map(fn block ->
      %{
        "entry_id" => block.entry_id,
        "entry_name" => names[block.entry_id],
        "block_id" => block.id,
        "reason" => "generated_claim_without_source"
      }
    end)
  end

  defp broken_citations(_scope, _entries, []), do: []

  defp broken_citations(scope, entries, blocks) do
    names = Map.new(entries, &{&1.id, &1.name})
    entry_by_block = Map.new(blocks, &{&1.id, &1.entry_id})

    BlockCitation
    |> where([citation], citation.block_id in ^Map.keys(entry_by_block))
    |> order_by([citation], asc: citation.block_id, asc: citation.document_id)
    |> Repo.all()
    |> Enum.flat_map(fn citation ->
      case Sources.resolve(Repo, scope, citation.document_id) do
        {:ok, _source} ->
          []

        {:error, reason} ->
          entry_id = entry_by_block[citation.block_id]

          [
            %{
              "entry_id" => entry_id,
              "entry_name" => names[entry_id],
              "block_id" => citation.block_id,
              "document_id" => citation.document_id,
              "reason" => to_string(reason)
            }
          ]
      end
    end)
  end

  defp unintegrated_sources(scope) do
    RetainedSource
    |> scope_rows(scope)
    |> join(:left, [source], citation in BlockCitation,
      on: citation.document_id == source.document_id
    )
    |> group_by([source], [
      source.id,
      source.document_id,
      source.title,
      source.capture_method,
      source.store_key,
      source.inserted_at
    ])
    |> having([_source, citation], count(citation.block_id) == 0)
    |> order_by([source], asc: source.inserted_at, asc: source.id)
    |> select([source], %{
      "document_id" => source.document_id,
      "title" => source.title,
      "capture_method" => source.capture_method,
      "store_key" => source.store_key,
      "captured_at" => source.inserted_at
    })
    |> Repo.all()
    |> Enum.map(&Map.update!(&1, "captured_at", fn value -> DateTime.to_iso8601(value) end))
  end

  defp dreaming_blocks(entries, blocks) do
    names = Map.new(entries, &{&1.id, &1.name})

    blocks
    |> Enum.filter(&(&1.author_kind == :dreaming))
    |> Enum.map(fn block ->
      %{
        "entry_id" => block.entry_id,
        "entry_name" => names[block.entry_id],
        "block_id" => block.id,
        "updated_at" => DateTime.to_iso8601(block.updated_at)
      }
    end)
  end

  defp like_terms([]), do: ["%"]
  defp like_terms(terms), do: Enum.map(terms, &"%#{escape_like(&1)}%")

  defp escape_like(term), do: String.replace(term, ["%", "_"], fn char -> "\\#{char}" end)

  defp scope_rows(query, %Scope{readable_store_keys: :all, owner_uid: owner_uid}) do
    shared_owner_uid = Scope.shared_owner_uid()

    where(
      query,
      [row],
      row.owner_uid == ^owner_uid or
        (row.owner_uid == ^shared_owner_uid and row.store_key == "shared")
    )
  end

  defp scope_rows(query, %Scope{readable_store_keys: stores, owner_uid: owner_uid}) do
    shared_owner_uid = Scope.shared_owner_uid()
    private_stores = Enum.reject(stores, &(&1 == "shared"))
    shared? = "shared" in stores

    where(
      query,
      [row],
      (row.owner_uid == ^owner_uid and row.store_key in ^private_stores) or
        (^shared? and row.owner_uid == ^shared_owner_uid and row.store_key == "shared")
    )
  end

  defp scoped_entries(%Scope{} = scope) do
    Entry
    |> scope_rows(scope)
    |> order_by([entry], asc: entry.store_key, asc: entry.name)
    |> Repo.all()
  end

  defp scoped_blocks([]), do: []

  defp scoped_blocks(entries) do
    entry_ids = Enum.map(entries, & &1.id)

    EntryBlock
    |> where([block], block.entry_id in ^entry_ids)
    |> order_by([block], asc: block.entry_id, asc: block.position)
    |> Repo.all()
  end

  defp embedding_counts(queryable) when is_atom(queryable) do
    queryable
    |> group_by([row], row.embedding_state)
    |> select([row], {row.embedding_state, count(row.id)})
    |> Repo.all()
    |> counts()
  end

  defp embedding_counts(rows) when is_list(rows) do
    rows
    |> Enum.frequencies_by(& &1.embedding_state)
    |> Enum.to_list()
    |> counts()
  end

  defp counts(rows) do
    counts = Map.new(rows, fn {state, count} -> {to_string(state), count} end)

    %{
      "total" => Enum.sum(Map.values(counts)),
      "pending" => Map.get(counts, "pending", 0),
      "synced" => Map.get(counts, "synced", 0),
      "failed" => Map.get(counts, "failed", 0)
    }
  end

  defp channel_statuses(owner_uid) do
    channels = SignalsGateway.visible_channels(owner_uid)
    channel_ids = Enum.map(channels, & &1.id)
    {episode_counts_by_channel, episode_counts} = episode_counts(channel_ids)

    cursors =
      Cursor
      |> where([cursor], cursor.scope_kind == :channel and cursor.scope_key in ^channel_ids)
      |> Repo.all()
      |> Map.new(&{&1.scope_key, &1})

    statuses =
      Enum.map(channels, fn channel ->
        cursor = Map.get(cursors, channel.id)

        {processor_uid, processor_error} =
          case StageA.processor_for_channel(channel.id) do
            {:ok, uid} -> {uid, nil}
            {:error, reason} -> {nil, inspect(reason)}
          end

        %{
          "channel_id" => channel.id,
          "channel_name" => channel.name,
          "channel_kind" => to_string(channel.kind),
          "processor_agent_uid" => processor_uid,
          "cursor_observed_at" => datetime(cursor && cursor.cursor_entry_observed_at),
          "unavailable_reason" => (cursor && cursor.unavailable_reason) || processor_error,
          "episodes" => Map.get(episode_counts_by_channel, channel.id, counts([]))
        }
      end)

    {statuses, episode_counts}
  end

  defp episode_counts(channel_ids) do
    rows =
      Episode
      |> where([episode], episode.signal_channel_id in ^channel_ids)
      |> group_by([episode], [episode.signal_channel_id, episode.embedding_state])
      |> select(
        [episode],
        {episode.signal_channel_id, episode.embedding_state, count(episode.id)}
      )
      |> Repo.all()

    by_channel =
      rows
      |> Enum.group_by(&elem(&1, 0), fn {_channel_id, state, count} -> {state, count} end)
      |> Map.new(fn {channel_id, state_counts} -> {channel_id, counts(state_counts)} end)

    aggregate =
      rows
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 2))
      |> Enum.map(fn {state, state_counts} -> {state, Enum.sum(state_counts)} end)
      |> counts()

    {by_channel, aggregate}
  end

  defp stage_b_status(owner_uid) do
    case Repo.get(Principal, owner_uid) do
      %Principal{type: :agent} -> agent_stage_b_status(owner_uid)
      %Principal{} -> non_agent_stage_b_status()
      nil -> non_agent_stage_b_status()
    end
  end

  defp agent_stage_b_status(owner_uid) do
    cursor = Repo.get_by(Cursor, scope_kind: :principal, scope_key: owner_uid)
    retryable_jobs = retryable_jobs(owner_uid)

    model =
      case ModelProfiles.resolve_runtime_profile(owner_uid, "light") do
        {:ok, _profile} ->
          %{"status" => "ok", "agent_uid" => owner_uid, "reason" => nil}

        {:error, reason} ->
          %{"status" => "error", "agent_uid" => owner_uid, "reason" => inspect(reason)}
      end

    %{
      "model" => model,
      "last_success_at" => cursor && get_in(cursor.metadata || %{}, ["last_run_at"]),
      "retryable_jobs" => retryable_jobs,
      "unavailable_reason" => (cursor && cursor.unavailable_reason) || model["reason"]
    }
  end

  defp non_agent_stage_b_status do
    %{
      "model" => %{"status" => "not_applicable", "agent_uid" => nil, "reason" => nil},
      "last_success_at" => nil,
      "retryable_jobs" => [],
      "unavailable_reason" => nil
    }
  end

  defp embedding_status do
    case Embedding.resolve_model() do
      {:ok, %{agent_uid: uid, dimensions: dimensions}} ->
        stale_vectors = stale_vector_counts(uid, dimensions)

        %{
          "status" => if(stale_vectors["total"] == 0, do: "ok", else: "error"),
          "configuration_status" => "ok",
          "model_agent_uid" => uid,
          "dimensions" => dimensions,
          "reason" =>
            if(stale_vectors["total"] == 0,
              do: nil,
              else: "stored vectors use a different embedding space"
            ),
          "stale_vectors" => stale_vectors
        }

      {:error, reason} ->
        %{
          "status" => "error",
          "configuration_status" => "error",
          "model_agent_uid" => nil,
          "dimensions" => nil,
          "reason" => inspect(reason),
          "stale_vectors" => nil
        }
    end
  end

  defp stale_vector_counts(model_agent_uid, dimensions) do
    entry_blocks =
      EntryBlock
      |> where(
        [block],
        block.embedding_state == :synced and
          (block.embedding_model_agent_uid != ^model_agent_uid or
             block.embedding_dimensions != ^dimensions)
      )
      |> Repo.aggregate(:count, :id)

    episodes =
      Episode
      |> where(
        [episode],
        episode.embedding_state == :synced and
          (episode.embedding_model_agent_uid != ^model_agent_uid or
             episode.embedding_dimensions != ^dimensions)
      )
      |> Repo.aggregate(:count, :id)

    %{
      "total" => entry_blocks + episodes,
      "entry_blocks" => entry_blocks,
      "episodes" => episodes
    }
  end

  defp stuck_jobs(owner_uid) do
    cutoff = DateTime.utc_now(:microsecond) |> DateTime.add(-@stuck_seconds, :second)
    worker = "Ankole.Brain.Jobs.CuratePrincipal"

    Oban.Job
    |> where(
      [job],
      job.worker == ^worker and job.state == "executing" and job.attempted_at < ^cutoff and
        fragment("?->>'principal_uid' = ?", job.args, ^owner_uid)
    )
    |> order_by([job], asc: job.attempted_at, asc: job.id)
    |> select([job], %{id: job.id, args: job.args, attempted_at: job.attempted_at})
    |> Repo.all()
    |> Enum.map(fn job ->
      %{
        "job_id" => job.id,
        "principal_uid" => job.args["principal_uid"],
        "attempted_at" => datetime(job.attempted_at)
      }
    end)
  end

  defp retryable_jobs(owner_uid) do
    worker = "Ankole.Brain.Jobs.CuratePrincipal"

    Oban.Job
    |> where(
      [job],
      job.worker == ^worker and job.state == "retryable" and
        fragment("?->>'principal_uid' = ?", job.args, ^owner_uid)
    )
    |> order_by([job], asc: job.scheduled_at, asc: job.id)
    |> select(
      [job],
      map(job, [:id, :args, :attempt, :max_attempts, :attempted_at, :scheduled_at])
    )
    |> Repo.all()
    |> Enum.map(fn job ->
      %{
        "job_id" => job.id,
        "principal_uid" => job.args["principal_uid"],
        "attempt" => job.attempt,
        "max_attempts" => job.max_attempts,
        "attempted_at" => datetime(job.attempted_at),
        "scheduled_at" => datetime(job.scheduled_at)
      }
    end)
  end

  # Oban retries a transient provider failure on its own. An operator needs the
  # alert only when the next run is the last one for this Principal.
  defp last_curation_attempt?(job), do: job["attempt"] >= job["max_attempts"] - 1

  defp memo_status(entries, blocks, budget) do
    blocks_by_entry = Enum.group_by(blocks, & &1.entry_id)

    entries
    |> Enum.filter(&(&1.store_key == "self" and &1.type == "agent_system_pinned_memo"))
    |> Enum.map(fn entry ->
      text =
        blocks_by_entry
        |> Map.get(entry.id, [])
        |> Enum.map(& &1.body)
        |> Enum.join("\n\n")

      tokens = Ankole.Kernel.estimate_o200k_base_tokens(text)

      %{
        "entry_id" => entry.id,
        "estimated_tokens" => tokens,
        "budget" => budget,
        "over_budget" => tokens > budget,
        "snapshot_truncated" => tokens > budget
      }
    end)
  end

  defp lint_status(entries, blocks, diagnostics) do
    blocks_by_entry = Enum.group_by(blocks, & &1.entry_id)

    dated_names =
      entries
      |> Enum.filter(&Regex.match?(@date_name, &1.name))
      |> Enum.map(&entry_ref/1)

    near_duplicate_names = near_duplicate_names(entries)

    zero_body_entries =
      entries
      |> Enum.filter(&(Map.get(blocks_by_entry, &1.id, []) == []))
      |> Enum.map(&entry_ref/1)

    %{
      "dated_names" => lint(dated_names),
      "near_duplicate_names" => lint(near_duplicate_names),
      "long_entries" => lint(diagnostics["long_entries"]),
      "zero_body_entries" => lint(zero_body_entries)
    }
  end

  defp near_duplicate_names(entries) do
    entries
    |> Enum.group_by(&{&1.owner_uid, &1.store_key})
    |> Enum.flat_map(fn {{_owner_uid, store_key}, store_entries} ->
      normalized = Enum.map(store_entries, &{&1, normalize_name(&1.name)})

      for {left, left_name} <- normalized,
          {right, right_name} <- normalized,
          left.id < right.id,
          near_name?(left_name, right_name) do
        %{
          "store_key" => store_key,
          "left" => entry_ref(left),
          "right" => entry_ref(right)
        }
      end
    end)
  end

  defp normalize_name(name),
    do: name |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]+/u, "")

  defp near_name?(left, right) do
    min(String.length(left), String.length(right)) >= 3 and
      (String.starts_with?(left, right) or String.starts_with?(right, left))
  end

  defp lint(items), do: %{"count" => length(items), "items" => items}

  defp entry_ref(entry),
    do: %{"entry_id" => entry.id, "store_key" => entry.store_key, "name" => entry.name}

  defp alerts(channels, stage_b, episodes, blocks, embedding, stuck_jobs, memo, lints) do
    []
    |> maybe_alert(
      Enum.any?(channels, &is_binary(&1["unavailable_reason"])),
      "stage_a_unavailable"
    )
    |> maybe_alert(is_binary(stage_b["unavailable_reason"]), "stage_b_unavailable")
    |> maybe_alert(episodes["pending"] > @episode_backlog_alert, "episode_embedding_backlog")
    |> maybe_alert(episodes["failed"] > 0, "episode_embedding_failures")
    |> maybe_alert(blocks["pending"] > @block_backlog_alert, "block_embedding_backlog")
    |> maybe_alert(blocks["failed"] > 0, "block_embedding_failures")
    |> maybe_alert(embedding["configuration_status"] == "error", "embedding_unavailable")
    |> maybe_alert(
      get_in(embedding, ["stale_vectors", "total"]) not in [nil, 0],
      "embedding_space_stale"
    )
    |> maybe_alert(
      Enum.any?(stage_b["retryable_jobs"], &last_curation_attempt?/1),
      "curation_jobs_failing"
    )
    |> maybe_alert(stuck_jobs != [], "stuck_curation_jobs")
    |> maybe_alert(Enum.any?(memo, & &1["over_budget"]), "memo_over_budget")
    |> maybe_alert(Enum.any?(lints, fn {_name, lint} -> lint["count"] > 0 end), "curation_lints")
    |> Enum.reverse()
  end

  defp maybe_alert(alerts, true, alert), do: [alert | alerts]
  defp maybe_alert(alerts, false, _alert), do: alerts

  defp datetime(nil), do: nil
  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
end
