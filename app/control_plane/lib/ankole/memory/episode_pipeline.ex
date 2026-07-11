defmodule Ankole.Memory.EpisodePipeline do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.AIGateway
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.Memory.ChannelCursor
  alias Ankole.Memory.Config
  alias Ankole.Memory.Embedding
  alias Ankole.Memory.Episode
  alias Ankole.Principals.Agent
  alias Ankole.Repo
  alias Ankole.SignalsGateway.Entry

  @model_unavailable_reason "memory.recall.model_agent_uid 指向的 agent 无 light/embedding profile"
  @recall_disabled_reason "memory.recall disabled"

  @doc false
  @spec recall_pipeline_status() :: {:ok, map()} | {:unavailable, String.t()}
  def recall_pipeline_status do
    with {:ok, %{"enabled" => true, "model_agent_uid" => model_agent_uid}}
         when is_binary(model_agent_uid) <- Config.recall(),
         %Agent{} <- Repo.get(Agent, model_agent_uid),
         {:ok, _light} <- ModelProfiles.resolve_runtime_profile(model_agent_uid, "light"),
         {:ok, _embedding} <- ModelProfiles.resolve_runtime_profile(model_agent_uid, "embedding") do
      {:ok, %{"model_agent_uid" => model_agent_uid}}
    else
      {:ok, %{"enabled" => false}} -> {:unavailable, @recall_disabled_reason}
      _reason -> {:unavailable, @model_unavailable_reason}
    end
  end

  @doc false
  @spec enqueue_episode_summary_jobs(non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:unavailable, String.t()}
  def enqueue_episode_summary_jobs(limit \\ 50) do
    case recall_pipeline_status() do
      {:ok, _status} ->
        {:ok, recall_config} = Config.recall()
        channel_ids = channels_with_unprocessed_entries(limit, recall_config)

        inserted =
          Enum.count(channel_ids, fn signal_channel_id ->
            job =
              Ankole.Memory.Jobs.SummarizeChannel.new(%{"signal_channel_id" => signal_channel_id})

            case Oban.insert(job) do
              {:ok, _job} -> true
              _result -> false
            end
          end)

        {:ok, inserted}

      {:unavailable, @recall_disabled_reason = reason} ->
        {:unavailable, reason}

      {:unavailable, reason} ->
        # Disabled recall is an operator choice and should not create cursor noise. A configured but
        # unusable model is operationally different: recording it per pending channel makes the stall
        # visible without consuming any history.
        mark_unprocessed_channels_unavailable(reason, limit)
        {:unavailable, reason}
    end
  end

  @doc false
  @spec summarize_channel(String.t()) :: :ok | {:error, term()}
  def summarize_channel(signal_channel_id) when is_binary(signal_channel_id) do
    with {:ok, %{"model_agent_uid" => model_agent_uid}} <- recall_pipeline_status(),
         {:ok, recall_config} <- Config.recall(),
         {:ok, entries} <- summary_window(signal_channel_id, recall_config),
         :ok <- require_non_empty_window(entries),
         {:ok, output} <- call_episode_summarizer(model_agent_uid, entries),
         {:ok, validated} <- validate_summary_output(output, entries, recall_config) do
      persist_summary_output(signal_channel_id, entries, validated)
    else
      {:unavailable, reason} ->
        mark_channel_unavailable(signal_channel_id, reason)
        :ok

      :empty_window ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec embed_pending_episodes(non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:unavailable, String.t()}
  def embed_pending_episodes(limit \\ 20) do
    with {:ok, %{"model_agent_uid" => model_agent_uid}} <- recall_pipeline_status() do
      episodes =
        Episode
        |> where([episode], episode.embedding_state == "pending")
        |> order_by([episode], asc: episode.inserted_at, asc: episode.id)
        |> limit(^limit)
        |> select([episode], struct(episode, [:id, :topic, :summary]))
        |> Repo.all()

      count =
        Enum.count(episodes, fn episode ->
          embed_episode(model_agent_uid, episode)
          true
        end)

      {:ok, count}
    end
  end

  @doc false
  @spec mark_channel_unavailable(String.t(), String.t()) ::
          {:ok, ChannelCursor.t()} | {:error, term()}
  def mark_channel_unavailable(signal_channel_id, reason)
      when is_binary(signal_channel_id) and is_binary(reason) do
    now = DateTime.utc_now(:microsecond)

    changeset =
      ChannelCursor.changeset(%ChannelCursor{}, %{
        signal_channel_id: signal_channel_id,
        unavailable_reason: reason,
        metadata: %{},
        inserted_at: now,
        updated_at: now
      })

    # Only the availability marker changes on conflict. In particular, a transient model failure must
    # never rewind or advance the durable projection cursor.
    Repo.insert(changeset,
      on_conflict: [set: [unavailable_reason: reason, updated_at: now]],
      conflict_target: [:signal_channel_id]
    )
  end

  @doc false
  @spec skip_failed_summary_window(String.t(), term()) :: :ok | {:error, term()}
  def skip_failed_summary_window(signal_channel_id, reason) when is_binary(signal_channel_id) do
    with {:ok, recall_config} <- Config.recall(),
         {:ok, entries} <- summary_window(signal_channel_id, recall_config),
         [first_entry | _entries] <- entries,
         %Entry{} = last_entry <- List.last(entries) do
      case Repo.transact(fn repo ->
             # Oban stores the channel, not the candidate window. Recomputing after the final retry may
             # include a slightly larger aged-out tail if new rows arrived, so the skipped span is
             # emitted below. Raw entries remain searchable through BM25 as the durable ground truth.
             upsert_cursor(repo, signal_channel_id, last_entry, nil)
             {:ok, :ok}
           end) do
        {:ok, :ok} ->
          :telemetry.execute(
            [:ankole, :memory, :summary, :skipped],
            %{entries: length(entries)},
            %{
              signal_channel_id: signal_channel_id,
              first_source_entry_id: first_entry.source_entry_id,
              last_source_entry_id: last_entry.source_entry_id,
              reason: inspect(reason)
            }
          )

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      [] -> :ok
      :empty_window -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec advance_channel_cursor(String.t(), Entry.t()) ::
          {:ok, ChannelCursor.t()} | {:error, term()}
  def advance_channel_cursor(signal_channel_id, %Entry{} = entry) do
    now = DateTime.utc_now(:microsecond)
    observed_at = observed_at(entry)

    changeset =
      ChannelCursor.changeset(%ChannelCursor{}, %{
        signal_channel_id: signal_channel_id,
        cursor_provider_time: entry.provider_time,
        cursor_source_entry_id: entry.source_entry_id,
        cursor_entry_observed_at: observed_at,
        unavailable_reason: nil,
        metadata: %{},
        inserted_at: now,
        updated_at: now
      })

    Repo.insert(changeset,
      on_conflict: [
        set: [
          cursor_provider_time: entry.provider_time,
          cursor_source_entry_id: entry.source_entry_id,
          cursor_entry_observed_at: observed_at,
          unavailable_reason: nil,
          updated_at: now
        ]
      ],
      conflict_target: [:signal_channel_id]
    )
  end

  defp channels_with_unprocessed_entries(limit, recall_config) do
    silence_minutes = Map.fetch!(recall_config, "episode_silence_minutes")
    tail_guard_minutes = Map.fetch!(recall_config, "episode_tail_guard_minutes")
    backlog_rows = Map.fetch!(recall_config, "episode_backlog_rows")

    silence_cutoff =
      DateTime.utc_now(:microsecond)
      |> DateTime.add(-silence_minutes * 60, :second)

    tail_cutoff =
      DateTime.utc_now(:microsecond)
      |> DateTime.add(-tail_guard_minutes * 60, :second)

    # Eligibility has two independent triggers: enough backlog to force progress, or an old quiet
    # prefix that can be summarized without consuming the protected recent tail. The composite
    # observed-time/source-id comparison matches summary_window/2 and cursor writes exactly.
    sql = """
    WITH pending AS (
      SELECT
        e.signal_channel_id,
        e.source_entry_id,
        COALESCE(e.provider_time, e.last_seen_at, e.inserted_at) AS observed_at
      FROM signal_gateway_entries e
      LEFT JOIN memory_channel_cursors c ON c.signal_channel_id = e.signal_channel_id
      WHERE c.signal_channel_id IS NULL
         OR c.cursor_entry_observed_at IS NULL
         OR COALESCE(e.provider_time, e.last_seen_at, e.inserted_at) > c.cursor_entry_observed_at
         OR (
           COALESCE(e.provider_time, e.last_seen_at, e.inserted_at) = c.cursor_entry_observed_at
           AND e.source_entry_id > c.cursor_source_entry_id
         )
    )
    SELECT signal_channel_id
    FROM pending
    GROUP BY signal_channel_id
    HAVING count(*) >= $4
       OR (min(observed_at) <= $1 AND count(*) FILTER (WHERE observed_at <= $2) > 0)
    ORDER BY signal_channel_id
    LIMIT $3
    """

    case Repo.query(sql, [silence_cutoff, tail_cutoff, limit, backlog_rows]) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [channel_id] -> channel_id end)
      {:error, _reason} -> []
    end
  end

  defp mark_unprocessed_channels_unavailable(reason, limit) do
    case Config.recall() do
      {:ok, recall_config} ->
        limit
        |> channels_with_unprocessed_entries(recall_config)
        |> Enum.each(&mark_channel_unavailable(&1, reason))

      {:error, _reason} ->
        :ok
    end
  end

  defp summary_window(signal_channel_id, recall_config) do
    max_rows = Map.fetch!(recall_config, "episode_window_max_rows")
    max_tokens = Map.fetch!(recall_config, "episode_window_max_tokens")
    tail_guard_rows = Map.fetch!(recall_config, "episode_tail_guard_rows")
    tail_guard_minutes = Map.fetch!(recall_config, "episode_tail_guard_minutes")
    cursor = Repo.get(ChannelCursor, signal_channel_id)
    now = DateTime.utc_now(:microsecond)
    age_cutoff = DateTime.add(now, -tail_guard_minutes * 60, :second)

    entries =
      Entry
      |> where([entry], entry.signal_channel_id == ^signal_channel_id)
      |> maybe_after_cursor(cursor)
      |> order_by([entry],
        asc:
          fragment(
            "COALESCE(?, ?, ?)",
            entry.provider_time,
            entry.last_seen_at,
            entry.inserted_at
          ),
        asc: entry.source_entry_id
      )
      |> limit(^(max_rows + tail_guard_rows))
      |> Repo.all()
      |> drop_tail_guard(tail_guard_rows, age_cutoff)
      |> take_until_token_budget(max_rows, max_tokens)

    {:ok, entries}
  end

  defp maybe_after_cursor(query, nil), do: query

  defp maybe_after_cursor(query, %ChannelCursor{cursor_entry_observed_at: nil}), do: query

  defp maybe_after_cursor(query, %ChannelCursor{
         cursor_entry_observed_at: cursor_observed_at,
         cursor_source_entry_id: cursor_source_entry_id
       }) do
    where(
      query,
      [entry],
      fragment("COALESCE(?, ?, ?)", entry.provider_time, entry.last_seen_at, entry.inserted_at) >
        ^cursor_observed_at or
        (fragment("COALESCE(?, ?, ?)", entry.provider_time, entry.last_seen_at, entry.inserted_at) ==
           ^cursor_observed_at and entry.source_entry_id > ^cursor_source_entry_id)
    )
  end

  defp drop_tail_guard(entries, 0, _age_cutoff), do: entries

  defp drop_tail_guard(entries, tail_guard_rows, age_cutoff) do
    {young_tail_reversed, rest_reversed} =
      entries
      |> Enum.reverse()
      |> Enum.split_while(fn entry -> DateTime.compare(observed_at(entry), age_cutoff) == :gt end)

    # Protect only the newest configured count among young rows. If the whole channel is quiet and
    # old, no permanent row guard remains to starve low-volume conversations.
    kept_young_tail_reversed = Enum.drop(young_tail_reversed, tail_guard_rows)

    Enum.reverse(rest_reversed) ++ Enum.reverse(kept_young_tail_reversed)
  end

  defp take_until_token_budget(entries, max_rows, max_tokens) do
    entries
    |> Enum.take(max_rows)
    |> Enum.reduce_while({[], 0}, fn entry, {acc, total_tokens} ->
      tokens = Ankole.Kernel.estimate_o200k_base_tokens(entry_text(entry))

      case total_tokens + tokens <= max_tokens do
        true -> {:cont, {[entry | acc], total_tokens + tokens}}
        false -> {:halt, {acc, total_tokens}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp require_non_empty_window([]), do: :empty_window
  defp require_non_empty_window([_entry | _entries]), do: :ok

  defp call_episode_summarizer(model_agent_uid, entries) do
    request = %{
      "model" => "light",
      "store" => false,
      "max_output_tokens" => 1_024,
      "input" => [
        %{
          "role" => "system",
          "content" => [
            %{
              "type" => "input_text",
              "text" =>
                "Return strict JSON only: {\"episodes\":[{\"topic\":\"...\",\"summary\":\"...\",\"source_entry_ids\":[\"...\"]}],\"noise_source_entry_ids\":[\"...\"],\"deferred_source_entry_ids\":[\"...\"]}. Use only supplied source_entry_id values. Put trivial/noise entries in noise_source_entry_ids. Put only still-unfinished tail entries in deferred_source_entry_ids."
            }
          ]
        },
        %{
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => summary_window_text(entries)}]
        }
      ]
    }

    with {:ok, %{body: body}} <- AIGateway.create_response(model_agent_uid, request),
         {:ok, text} <- response_text(body),
         {:ok, decoded} <- Ankole.JSON.decode(text) do
      {:ok, decoded}
    else
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_summary_response, other}}
    end
  end

  defp summary_window_text(entries) do
    entries
    |> Enum.map(fn entry ->
      observed = entry |> observed_at() |> datetime()

      "[#{entry.source_entry_id}] #{observed} #{author_name(entry.author) || "unknown"}: #{entry_text(entry)}"
    end)
    |> Enum.join("\n")
  end

  defp validate_summary_output(
         %{"episodes" => episodes, "noise_source_entry_ids" => noise_ids} = output,
         entries,
         recall_config
       )
       when is_list(episodes) and is_list(noise_ids) do
    allowed = entries |> Enum.map(& &1.source_entry_id) |> MapSet.new()
    deferred_ids = Map.get(output, "deferred_source_entry_ids", [])

    with {:ok, validated_episodes} <- validate_episodes(episodes, allowed),
         {:ok, validated_noise} <- validate_source_ids(noise_ids, allowed),
         {:ok, validated_deferred} <-
           validate_deferred_source_ids(deferred_ids, entries, recall_config) do
      used =
        validated_episodes
        |> Enum.flat_map(& &1["source_entry_ids"])
        |> Kernel.++(validated_noise)
        |> Kernel.++(validated_deferred)
        |> MapSet.new()

      # Coverage is the safety property: every candidate row must be summarized, explicitly marked as
      # noise, or deferred. Accepting a partial model response would silently advance past raw history.
      case MapSet.equal?(used, allowed) do
        true ->
          {:ok,
           %{
             "episodes" => validated_episodes,
             "noise_source_entry_ids" => validated_noise,
             "deferred_source_entry_ids" => validated_deferred
           }}

        false ->
          {:error, :summary_output_did_not_cover_window}
      end
    end
  end

  defp validate_summary_output(_output, _entries, _recall_config),
    do: {:error, :invalid_summary_output_shape}

  defp validate_episodes(episodes, allowed) do
    if length(episodes) > 12 do
      {:error, :too_many_memory_episodes}
    else
      episodes
      |> Enum.reduce_while({:ok, []}, fn episode, {:ok, acc} ->
        case validate_episode(episode, allowed) do
          {:ok, validated} -> {:cont, {:ok, [validated | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, validated} -> {:ok, Enum.reverse(validated)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_episode(
         %{"topic" => topic, "summary" => summary, "source_entry_ids" => source_ids},
         allowed
       )
       when is_binary(topic) and is_binary(summary) and is_list(source_ids) do
    with {:ok, source_ids} <- validate_source_ids(source_ids, allowed),
         :ok <- non_empty_text(topic, :empty_episode_topic),
         :ok <- non_empty_text(summary, :empty_episode_summary),
         :ok <- max_text_length(summary, 500, :memory_episode_summary_too_long),
         :ok <- require_source_ids(source_ids) do
      {:ok,
       %{
         "topic" => String.trim(topic),
         "summary" => String.trim(summary),
         "source_entry_ids" => source_ids
       }}
    end
  end

  defp validate_episode(_episode, _allowed), do: {:error, :invalid_episode_shape}

  defp validate_source_ids(source_ids, allowed) do
    source_ids
    |> Enum.reduce_while({:ok, []}, fn
      source_id, {:ok, acc} when is_binary(source_id) ->
        source_id = String.trim(source_id)

        cond do
          source_id == "" -> {:halt, {:error, :empty_source_entry_id}}
          MapSet.member?(allowed, source_id) -> {:cont, {:ok, [source_id | acc]}}
          true -> {:halt, {:error, :summary_output_references_unknown_entries}}
        end

      _value, _acc ->
        {:halt, {:error, :invalid_source_entry_id}}
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.reverse() |> Enum.uniq()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp non_empty_text(text, reason) do
    case String.trim(text) do
      "" -> {:error, reason}
      _text -> :ok
    end
  end

  defp require_source_ids([]), do: {:error, :episode_without_sources}
  defp require_source_ids([_source_id | _source_ids]), do: :ok

  defp max_text_length(text, max_length, reason) do
    case String.length(String.trim(text)) <= max_length do
      true -> :ok
      false -> {:error, reason}
    end
  end

  defp validate_deferred_source_ids(source_ids, entries, recall_config)
       when is_list(source_ids) do
    allowed = entries |> Enum.map(& &1.source_entry_id) |> MapSet.new()
    tail_rows = Map.fetch!(recall_config, "episode_tail_guard_rows")
    tail_minutes = Map.fetch!(recall_config, "episode_tail_guard_minutes")
    age_cutoff = DateTime.utc_now(:microsecond) |> DateTime.add(-tail_minutes * 60, :second)

    # Deferral is limited to the still-young configured tail. Otherwise a model could indefinitely
    # defer arbitrary old rows and prevent the durable cursor from making progress.
    tail_allowed =
      entries
      |> Enum.take(-tail_rows)
      |> Enum.filter(&(DateTime.compare(observed_at(&1), age_cutoff) == :gt))
      |> Enum.map(& &1.source_entry_id)
      |> MapSet.new()

    with {:ok, validated} <- validate_source_ids(source_ids, allowed),
         :ok <- deferred_in_tail(validated, tail_allowed) do
      {:ok, validated}
    end
  end

  defp validate_deferred_source_ids(_source_ids, _entries, _recall_config),
    do: {:error, :invalid_deferred_source_entry_ids}

  defp deferred_in_tail(source_ids, tail_allowed) do
    case Enum.all?(source_ids, &MapSet.member?(tail_allowed, &1)) do
      true -> :ok
      false -> {:error, :invalid_deferred_source_entry_ids}
    end
  end

  defp persist_summary_output(signal_channel_id, entries, %{
         "episodes" => episodes,
         "noise_source_entry_ids" => noise_source_entry_ids,
         "deferred_source_entry_ids" => _deferred_source_entry_ids
       }) do
    allowed_ids = MapSet.new(Enum.map(entries, & &1.source_entry_id))
    noise_ids = MapSet.new(noise_source_entry_ids)

    case Repo.transact(fn repo ->
           Enum.each(episodes, fn episode ->
             source_entries =
               Enum.filter(entries, &(&1.source_entry_id in episode["source_entry_ids"]))

             {started_at, ended_at} = episode_bounds(source_entries)

             %Episode{}
             |> Episode.changeset(%{
               signal_channel_id: signal_channel_id,
               topic: episode["topic"],
               summary: episode["summary"],
               source_entry_ids: episode["source_entry_ids"],
               started_at: started_at,
               ended_at: ended_at,
               embedding_state: "pending",
               metadata: %{"version" => 1}
             })
             |> repo.insert!()
           end)

           processed_ids =
             episodes
             |> Enum.flat_map(& &1["source_entry_ids"])
             |> MapSet.new()
             |> MapSet.union(noise_ids)

           if MapSet.subset?(processed_ids, allowed_ids) do
             entries
             |> Enum.filter(&MapSet.member?(processed_ids, &1.source_entry_id))
             |> List.last()
             |> case do
               %Entry{} = last_processed_entry ->
                 upsert_cursor(repo, signal_channel_id, last_processed_entry, nil)

               nil ->
                 nil
             end
           end

           {:ok, :ok}
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp episode_bounds(entries) do
    observed = Enum.map(entries, &observed_at/1)

    {Enum.min_by(observed, &DateTime.to_unix(&1, :microsecond)),
     Enum.max_by(observed, &DateTime.to_unix(&1, :microsecond))}
  end

  defp upsert_cursor(repo, signal_channel_id, %Entry{} = entry, unavailable_reason) do
    now = DateTime.utc_now(:microsecond)
    observed_at = observed_at(entry)

    changeset =
      ChannelCursor.changeset(%ChannelCursor{}, %{
        signal_channel_id: signal_channel_id,
        cursor_provider_time: entry.provider_time,
        cursor_source_entry_id: entry.source_entry_id,
        cursor_entry_observed_at: observed_at,
        unavailable_reason: unavailable_reason,
        metadata: %{}
      })

    repo.insert!(changeset,
      on_conflict: [
        set: [
          cursor_provider_time: entry.provider_time,
          cursor_source_entry_id: entry.source_entry_id,
          cursor_entry_observed_at: observed_at,
          unavailable_reason: unavailable_reason,
          updated_at: now
        ]
      ],
      conflict_target: [:signal_channel_id]
    )
  end

  defp embed_episode(model_agent_uid, %Episode{} = episode) do
    case Embedding.create(model_agent_uid, episode_embedding_text(episode)) do
      {:ok, vector, dimensions} ->
        vector_literal = Embedding.to_pgvector(vector)

        Repo.query!(
          """
          UPDATE memory_episodes
          SET embedding = $2::text::vector,
              embedding_dimensions = $3,
              embedding_state = 'synced',
              embedding_error = NULL,
              updated_at = now()
          WHERE id = $1::text::uuid
          """,
          [episode.id, vector_literal, dimensions]
        )

      {:error, reason} ->
        Episode
        |> where([row], row.id == ^episode.id)
        |> Repo.update_all(
          set: [
            embedding_state: "failed",
            embedding_error: inspect(reason),
            updated_at: DateTime.utc_now(:microsecond)
          ]
        )
    end
  end

  defp episode_embedding_text(%Episode{} = episode) do
    [episode.topic, episode.summary]
    |> Enum.reject(&(is_nil(&1) or String.trim(&1) == ""))
    |> Enum.join("\n")
  end

  defp response_text(%{"output_text" => text}) when is_binary(text), do: {:ok, text}

  defp response_text(%{"output" => output}) when is_list(output) do
    text =
      output
      |> Enum.flat_map(fn
        %{"content" => content} when is_list(content) -> content
        _item -> []
      end)
      |> Enum.flat_map(fn
        %{"text" => text} when is_binary(text) -> [text]
        %{"type" => "output_text", "text" => text} when is_binary(text) -> [text]
        _part -> []
      end)
      |> Enum.join("\n")

    case String.trim(text) do
      "" -> {:error, :missing_response_text}
      trimmed -> {:ok, trimmed}
    end
  end

  defp response_text(_body), do: {:error, :missing_response_text}

  defp entry_text(%Entry{} = entry) do
    entry.search_text || entry.text || entry.fallback_visible_text || ""
  end

  defp observed_at(%Entry{} = entry),
    do: entry.provider_time || entry.last_seen_at || entry.inserted_at

  defp author_name(%{"display_name" => name}) when is_binary(name) and name != "", do: name
  defp author_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp author_name(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp author_name(_author), do: nil

  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp datetime(_value), do: nil
end
