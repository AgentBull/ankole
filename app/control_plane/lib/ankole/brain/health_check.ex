defmodule Ankole.Brain.HealthCheck do
  @moduledoc "Read-only diagnostics that seed an explicitly requested human Brain review."

  import Ecto.Query, warn: false

  alias Ankole.Brain.Config
  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Schemas.Entry
  alias Ankole.Brain.Schemas.EntryBlock
  alias Ankole.Brain.Schemas.EntryRelation
  alias Ankole.Brain.Scope
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Entry, as: SignalEntry

  @stale_days 90
  @long_projection_lines 200

  @spec run(Scope.t()) :: {:ok, map()} | {:error, term()}
  def run(%Scope{} = scope) do
    with {:ok, knowledge_config} <- Config.knowledge(),
         entries = scoped_entries(scope),
         {:ok, projections} <- entry_projections(scope, entries) do
      entry_ids = Enum.map(entries, & &1.id)
      blocks = scoped_blocks(entry_ids)
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
         "failed_embeddings" => failed_embeddings(blocks),
         "unresolved_conflicts" => unresolved_conflicts(entries, blocks),
         "dreaming_blocks" => dreaming_blocks(entries, blocks)
       }}
    end
  end

  defp scoped_entries(scope) do
    Entry
    |> where([entry], entry.owner_uid == ^scope.owner_uid)
    |> maybe_stores(scope.readable_store_keys)
    |> order_by([entry], asc: entry.store_key, asc: entry.name)
    |> Repo.all()
  end

  defp scoped_blocks([]), do: []

  defp scoped_blocks(entry_ids) do
    EntryBlock
    |> where([block], block.entry_id in ^entry_ids)
    |> order_by([block], asc: block.entry_id, asc: block.position)
    |> Repo.all()
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
      |> where([relation], relation.owner_uid == ^scope.owner_uid)
      |> maybe_stores(scope.readable_store_keys)
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
    |> Enum.filter(&store_readable?(readable_stores, channel_store_key(&1)))
    |> Enum.map(& &1.id)
  end

  defp readable_stores(%Scope{readable_store_keys: :all}), do: :all
  defp readable_stores(%Scope{readable_store_keys: stores}), do: stores

  defp channel_store_key(%Channel{kind: :im_dm, metadata: metadata}) do
    case Map.get(metadata || %{}, "dm_peer_principal_uid") do
      peer_uid when is_binary(peer_uid) and peer_uid != "" -> "dm:#{String.downcase(peer_uid)}"
      _missing -> :unknown
    end
  end

  defp channel_store_key(%Channel{}), do: "public"

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
        do: [entry_ref(entry) |> Map.merge(%{"estimated_tokens" => tokens, "budget" => budget})],
        else: []
    end)
  end

  defp failed_embeddings(blocks) do
    blocks
    |> Enum.filter(&(&1.embedding_state == :failed))
    |> Enum.map(fn block ->
      %{
        "entry_id" => block.entry_id,
        "block_id" => block.id,
        "error" => block.embedding_error
      }
    end)
  end

  defp unresolved_conflicts(entries, blocks) do
    names = Map.new(entries, &{&1.id, &1.name})

    blocks
    |> Enum.filter(&String.contains?(&1.body, "未裁决"))
    |> Enum.map(fn block ->
      %{
        "entry_id" => block.entry_id,
        "entry_name" => names[block.entry_id],
        "block_id" => block.id
      }
    end)
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

  defp entry_ref(entry),
    do: %{"entry_id" => entry.id, "name" => entry.name, "store" => entry.store_key}

  defp like_terms([]), do: ["%"]
  defp like_terms(terms), do: Enum.map(terms, &"%#{escape_like(&1)}%")

  defp escape_like(term), do: String.replace(term, ["%", "_"], fn char -> "\\#{char}" end)

  defp maybe_stores(query, :all), do: query
  defp maybe_stores(query, stores), do: where(query, [row], row.store_key in ^stores)
end
