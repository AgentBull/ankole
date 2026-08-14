defmodule Ankole.Brain.Dreaming.StageA do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.AIGateway
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.Brain.Schemas.Cursor
  alias Ankole.Brain.Config
  alias Ankole.Brain.Dreaming.ResponseFormat
  alias Ankole.Brain.Embedding
  alias Ankole.Brain.Schemas.Episode
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ChannelContext
  alias Ankole.SignalsGateway.Entry

  @model_unavailable_reason "no Agent that can see the channel has a resolvable light profile"
  @dreaming_disabled_reason "brain.dreaming disabled"

  @episode_summary_prompt """
  Brain is the long-term memory of this workspace. This call is a Stage A pass over the chat of \
  one channel: it turns one window of messages into the episodes that later work searches. The \
  messages themselves stay in place and stay searchable by keyword, so an episode does not have to \
  preserve them. It has to make the right span of chat findable and tell the reader what came out \
  of it.

  The window holds consecutive messages, oldest first, one for each line, in the form \
  `[message_N] <timestamp> [<role>] <author>: <text>`. `message_N` is the alias of that message, \
  and the response names messages only by these aliases. `role` is `human` for a person and \
  `agent` for a message an Agent of this workspace posted, so an episode can say who asked, who \
  answered, and who did the work.

  An episode is one topic thread. `topic` names the thread. `question` is what a later reader asks \
  when they look for it. `summary` is the standalone account of what happened, with the facts, \
  numbers, and names that make the episode useful before anyone opens the messages. `resolution` \
  is the outcome that closed the thread, and `resolution_message` is the message that states that \
  outcome. `systems` names the services, components, and artifacts that the thread is about. \
  `messages` holds the messages that carry the thread. `question`, `resolution`, \
  `resolution_message`, and `systems` are null when the window does not answer them. Write each \
  episode in the language of the messages it covers.

  `noise_messages` holds the messages that no episode covers and that deferral does not hold back, \
  mostly chat whose value dies with the conversation: greetings, acknowledgements, one-off \
  logistics. A window that holds nothing worth an episode is a normal result.

  Deferral holds messages back for the next run, which reads this window again together with \
  whatever arrived after it. A thread whose outcome has not arrived yet belongs there while its \
  messages are still deferrable, because an episode written now costs a second overlapping episode \
  once the outcome lands.

  Constraints:
  - Every alias in the window appears in the messages of an episode, in noise_messages, or in \
  deferred_messages. A missing alias, an alias that the window does not supply, or a deferred \
  alias outside the deferrable list makes the whole response invalid, and the window runs again \
  unchanged.
  - `deferred_messages` never covers the whole window. A response that defers everything writes \
  nothing and hands the next run the same input.
  - At most 12 episodes, each with a topic, at least one message, and a summary of at most 500 \
  characters. `resolution_message`, when it is not null, is one of that episode's own messages.
  - The whole response stays under 4,000 characters. Cut the narration of the conversation, not \
  the facts that a later reader needs.\
  """

  @doc false
  @spec enqueue_episode_summary_jobs(non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:unavailable, String.t()}
  def enqueue_episode_summary_jobs(limit \\ 50) do
    case Config.dreaming() do
      {:ok, %{"enabled" => enabled} = dreaming_config} when enabled in [nil, true] ->
        channel_ids = channels_with_unprocessed_entries(limit, dreaming_config)

        inserted =
          Enum.count(channel_ids, fn signal_channel_id ->
            job =
              Ankole.Brain.Jobs.SummarizeChannel.new(%{"signal_channel_id" => signal_channel_id})

            case Oban.insert(job) do
              {:ok, _job} -> true
              _result -> false
            end
          end)

        {:ok, inserted}

      {:ok, %{"enabled" => false}} ->
        {:unavailable, @dreaming_disabled_reason}

      {:error, reason} ->
        {:unavailable, reason}
    end
  end

  @doc false
  @spec summarize_channel(String.t()) :: :ok | {:error, term()}
  def summarize_channel(signal_channel_id) when is_binary(signal_channel_id) do
    with {:ok, %{"enabled" => enabled}} when enabled in [nil, true] <- Config.dreaming(),
         {:ok, model_agent_uid} <- processor_for_channel(signal_channel_id),
         {:ok, dreaming_config} <- Config.dreaming(),
         :ok <- seed_cold_start_cursor(signal_channel_id, dreaming_config),
         {:ok, entries} <- summary_window(signal_channel_id, dreaming_config),
         :ok <- require_non_empty_window(entries),
         deferrable_ids = deferrable_source_entry_ids(entries, dreaming_config),
         {:ok, output} <- call_episode_summarizer(model_agent_uid, entries, deferrable_ids),
         {:ok, validated} <- validate_summary_output(output, entries, deferrable_ids) do
      persist_summary_output(signal_channel_id, entries, validated, model_agent_uid)
    else
      {:ok, %{"enabled" => false}} ->
        mark_channel_unavailable(signal_channel_id, @dreaming_disabled_reason)
        :ok

      {:error, :no_visible_light_agent} ->
        mark_channel_unavailable(signal_channel_id, @model_unavailable_reason)
        :ok

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
    with {:ok, %{agent_uid: model_agent_uid, dimensions: dimensions}} <-
           Embedding.resolve_model() do
      :ok = Embedding.prepare_space(model_agent_uid, dimensions)

      episodes =
        Episode
        |> where([episode], episode.embedding_state == :pending)
        |> order_by([episode], asc: episode.inserted_at, asc: episode.id)
        |> limit(^limit)
        |> select(
          [episode],
          struct(episode, [:id, :topic, :summary, :metadata])
        )
        |> Repo.all()

      count =
        Enum.count(episodes, fn episode ->
          embed_episode(model_agent_uid, episode)
          true
        end)

      {:ok, count}
    else
      {:error, reason} ->
        {:unavailable, "episode embedding unavailable: #{inspect(reason)}"}
    end
  end

  @doc false
  @spec processor_for_channel(String.t()) :: {:ok, String.t()} | {:error, :no_visible_light_agent}
  def processor_for_channel(signal_channel_id) when is_binary(signal_channel_id) do
    Principals.list_active_agents()
    |> Enum.map(& &1.agent.uid)
    |> Enum.sort()
    |> Enum.find(fn agent_uid ->
      channel_visible =
        Enum.any?(SignalsGateway.visible_channels(agent_uid), &(&1.id == signal_channel_id))

      channel_visible and
        match?({:ok, _profile}, ModelProfiles.resolve_runtime_profile(agent_uid, "light"))
    end)
    |> case do
      nil -> {:error, :no_visible_light_agent}
      agent_uid -> {:ok, agent_uid}
    end
  end

  @doc false
  @spec mark_channel_unavailable(String.t(), String.t()) ::
          {:ok, Cursor.t()} | {:error, term()}
  def mark_channel_unavailable(signal_channel_id, reason)
      when is_binary(signal_channel_id) and is_binary(reason) do
    now = DateTime.utc_now(:microsecond)

    changeset =
      Cursor.changeset(%Cursor{}, %{
        scope_kind: :channel,
        scope_key: signal_channel_id,
        unavailable_reason: reason,
        metadata: %{},
        inserted_at: now,
        updated_at: now
      })

    # Only the availability marker changes on conflict. In particular, a transient model failure must
    # never rewind or advance the durable projection cursor.
    Repo.insert(changeset,
      on_conflict: [set: [unavailable_reason: reason, updated_at: now]],
      conflict_target: [:scope_kind, :scope_key]
    )
  end

  @doc false
  @spec skip_failed_summary_window(String.t(), term()) :: :ok | {:error, term()}
  def skip_failed_summary_window(signal_channel_id, reason) when is_binary(signal_channel_id) do
    with {:ok, dreaming_config} <- Config.dreaming(),
         :ok <- seed_cold_start_cursor(signal_channel_id, dreaming_config),
         {:ok, entries} <- summary_window(signal_channel_id, dreaming_config),
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
            [:ankole, :brain, :dreaming, :stage_a, :skipped],
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
          {:ok, Cursor.t()} | {:error, term()}
  def advance_channel_cursor(signal_channel_id, %Entry{} = entry) do
    now = DateTime.utc_now(:microsecond)
    observed_at = observed_at(entry)

    changeset =
      Cursor.changeset(%Cursor{}, %{
        scope_kind: :channel,
        scope_key: signal_channel_id,
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
      conflict_target: [:scope_kind, :scope_key]
    )
  end

  defp channels_with_unprocessed_entries(limit, dreaming_config) do
    silence_minutes = Map.fetch!(dreaming_config, "episode_silence_minutes")
    tail_guard_minutes = Map.fetch!(dreaming_config, "episode_tail_guard_minutes")
    backlog_rows = Map.fetch!(dreaming_config, "episode_backlog_rows")

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
      LEFT JOIN brain_cursors c
        ON c.scope_kind = 'channel' AND c.scope_key = e.signal_channel_id
      WHERE c.scope_key IS NULL
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

  # A channel that has no cursor yet would otherwise summarize its whole retained history, which
  # grows with the delay between the first ingested entry and the first dreaming run. The
  # configured lookback bounds that first window by seeding the cursor at the newest entry the
  # window excludes, so the existing advance path continues from a normal cursor row.
  #
  # The boundary is written once instead of filtering every read. A recomputed `now - lookback`
  # floor would move forward while Stage A cannot produce an episode, and the span it passed over
  # would never be summarized and would leave no record that it was dropped.
  defp seed_cold_start_cursor(signal_channel_id, dreaming_config) do
    lookback_days = Map.fetch!(dreaming_config, "episode_cold_start_lookback_days")
    cursor = Repo.get_by(Cursor, scope_kind: :channel, scope_key: signal_channel_id)

    if is_integer(lookback_days) and is_nil(cursor) do
      seed_channel_cursor(signal_channel_id, lookback_days)
    else
      :ok
    end
  end

  defp seed_channel_cursor(signal_channel_id, lookback_days) do
    boundary =
      DateTime.utc_now(:microsecond)
      |> DateTime.add(-lookback_days * 24 * 60 * 60, :second)

    Entry
    |> where([entry], entry.signal_channel_id == ^signal_channel_id)
    |> where(
      [entry],
      fragment(
        "COALESCE(?, ?, ?)",
        entry.provider_time,
        entry.last_seen_at,
        entry.inserted_at
      ) <= ^boundary
    )
    |> order_by([entry],
      desc:
        fragment(
          "COALESCE(?, ?, ?)",
          entry.provider_time,
          entry.last_seen_at,
          entry.inserted_at
        ),
      desc: entry.source_entry_id
    )
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> :ok
      %Entry{} = entry -> insert_cold_start_cursor(signal_channel_id, entry, lookback_days)
    end
  end

  defp insert_cold_start_cursor(signal_channel_id, %Entry{} = entry, lookback_days) do
    now = DateTime.utc_now(:microsecond)

    changeset =
      Cursor.changeset(%Cursor{}, %{
        scope_kind: :channel,
        scope_key: signal_channel_id,
        cursor_provider_time: entry.provider_time,
        cursor_source_entry_id: entry.source_entry_id,
        cursor_entry_observed_at: observed_at(entry),
        metadata: %{"cold_start_lookback_days" => lookback_days},
        inserted_at: now,
        updated_at: now
      })

    # A concurrent run that already created or advanced this cursor owns the position. Seeding must
    # never move it, in either direction.
    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:scope_kind, :scope_key]
         ) do
      {:ok, _cursor} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp summary_window(signal_channel_id, dreaming_config) do
    max_rows = Map.fetch!(dreaming_config, "episode_window_max_rows")
    max_tokens = Map.fetch!(dreaming_config, "episode_window_max_tokens")
    tail_guard_rows = Map.fetch!(dreaming_config, "episode_tail_guard_rows")
    tail_guard_minutes = Map.fetch!(dreaming_config, "episode_tail_guard_minutes")
    cursor = Repo.get_by(Cursor, scope_kind: :channel, scope_key: signal_channel_id)
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

  defp maybe_after_cursor(query, %Cursor{cursor_entry_observed_at: nil}), do: query

  defp maybe_after_cursor(query, %Cursor{
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

  defp call_episode_summarizer(model_agent_uid, entries, deferrable_ids) do
    message_refs = message_refs(entries)

    request = %{
      "model" => "light",
      "store" => false,
      # Reasoning tokens come out of this budget before the first output character, and a
      # 1,024-token cap truncated many calls while they were still reasoning.
      "max_output_tokens" => 8_192,
      "provider_options" => %{"reasoningEffort" => "medium"},
      "text" => ResponseFormat.stage_a(),
      "input" => [
        %{
          "role" => "system",
          "content" => [
            %{"type" => "input_text", "text" => @episode_summary_prompt}
          ]
        },
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "input_text",
              "text" => summary_window_text(entries, message_refs, deferrable_ids)
            }
          ]
        }
      ]
    }

    with {:ok, %{body: body}} <-
           AIGateway.create_response(model_agent_uid, request, caller: "brain.dreaming.stage_a"),
         {:ok, text} <- AIGateway.completed_output_text(body),
         {:ok, decoded} <- Ankole.JSON.decode(text),
         {:ok, translated} <- translate_summary_refs(decoded, message_refs) do
      {:ok, translated}
    else
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_summary_response, other}}
    end
  end

  defp summary_window_text(entries, message_refs, deferrable_ids) do
    lines =
      entries
      |> Enum.map(fn entry ->
        observed = entry |> observed_at() |> datetime()
        message_ref = Map.fetch!(message_refs.by_source_id, entry.source_entry_id)

        role = ChannelContext.entry_role(entry)
        speaker = ChannelContext.speaker_name(entry.author)

        "[#{message_ref}] #{observed} [#{role}] #{speaker}: #{entry_text(entry)}"
      end)
      |> Enum.join("\n")

    lines <> "\n\nDeferrable messages: " <> deferrable_line(entries, message_refs, deferrable_ids)
  end

  defp deferrable_line(entries, message_refs, deferrable_ids) do
    entries
    |> Enum.filter(&MapSet.member?(deferrable_ids, &1.source_entry_id))
    |> Enum.map(&Map.fetch!(message_refs.by_source_id, &1.source_entry_id))
    |> case do
      [] -> "none"
      refs -> Enum.join(refs, ", ")
    end
  end

  defp message_refs(entries) do
    entries
    |> Enum.with_index(1)
    |> Enum.reduce(%{by_alias: %{}, by_source_id: %{}}, fn {entry, index}, refs ->
      alias = "message_#{index}"

      %{
        by_alias: Map.put(refs.by_alias, alias, entry.source_entry_id),
        by_source_id: Map.put(refs.by_source_id, entry.source_entry_id, alias)
      }
    end)
  end

  defp translate_summary_refs(
         %{
           "episodes" => episodes,
           "noise_messages" => noise_messages,
           "deferred_messages" => deferred_messages
         },
         refs
       )
       when is_list(episodes) and is_list(noise_messages) and is_list(deferred_messages) do
    with {:ok, episodes} <- translate_episode_refs(episodes, refs.by_alias),
         {:ok, noise_ids} <- translate_message_refs(noise_messages, refs.by_alias),
         {:ok, deferred_ids} <- translate_message_refs(deferred_messages, refs.by_alias) do
      {:ok,
       %{
         "episodes" => episodes,
         "noise_source_entry_ids" => noise_ids,
         "deferred_source_entry_ids" => deferred_ids
       }}
    end
  end

  defp translate_summary_refs(_output, _refs), do: {:error, :invalid_summary_output_shape}

  defp translate_episode_refs(episodes, aliases) do
    Enum.reduce_while(episodes, {:ok, []}, fn
      %{
        "topic" => topic,
        "question" => question,
        "summary" => summary,
        "resolution" => resolution,
        "systems" => systems,
        "resolution_message" => resolution_message,
        "messages" => messages
      },
      {:ok, translated} ->
        with {:ok, source_ids} <- translate_message_refs(messages, aliases),
             {:ok, resolution_source_id} <-
               translate_optional_message_ref(resolution_message, aliases) do
          episode = %{
            "topic" => topic,
            "question" => question,
            "summary" => summary,
            "resolution" => resolution,
            "systems" => systems,
            "resolution_source_entry_id" => resolution_source_id,
            "source_entry_ids" => source_ids
          }

          {:cont, {:ok, [episode | translated]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _episode, _translated ->
        {:halt, {:error, :invalid_episode_shape}}
    end)
    |> case do
      {:ok, translated} -> {:ok, Enum.reverse(translated)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp translate_message_refs(messages, aliases) when is_list(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, source_ids} ->
      case Map.fetch(aliases, message) do
        {:ok, source_id} -> {:cont, {:ok, [source_id | source_ids]}}
        :error -> {:halt, {:error, :summary_output_references_unknown_entries}}
      end
    end)
    |> case do
      {:ok, source_ids} -> {:ok, Enum.reverse(source_ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp translate_message_refs(_messages, _aliases),
    do: {:error, :invalid_source_entry_id}

  defp translate_optional_message_ref(nil, _aliases), do: {:ok, nil}

  defp translate_optional_message_ref(message, aliases) when is_binary(message) do
    case Map.fetch(aliases, message) do
      {:ok, source_id} -> {:ok, source_id}
      :error -> {:error, :invalid_resolution_source_entry_id}
    end
  end

  defp translate_optional_message_ref(_message, _aliases),
    do: {:error, :invalid_resolution_source_entry_id}

  defp validate_summary_output(
         %{"episodes" => episodes, "noise_source_entry_ids" => noise_ids} = output,
         entries,
         deferrable_ids
       )
       when is_list(episodes) and is_list(noise_ids) do
    allowed = entries |> Enum.map(& &1.source_entry_id) |> MapSet.new()
    deferred_ids = Map.get(output, "deferred_source_entry_ids", [])

    with {:ok, validated_episodes} <- validate_episodes(episodes, allowed),
         {:ok, validated_noise} <- validate_source_ids(noise_ids, allowed),
         {:ok, validated_deferred} <-
           validate_deferred_source_ids(deferred_ids, allowed, deferrable_ids) do
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

  defp validate_summary_output(_output, _entries, _deferrable_ids),
    do: {:error, :invalid_summary_output_shape}

  defp validate_episodes(episodes, allowed) do
    if length(episodes) > 12 do
      {:error, :too_many_brain_episodes}
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
         %{
           "topic" => topic,
           "question" => question,
           "summary" => summary,
           "resolution" => resolution,
           "systems" => systems,
           "resolution_source_entry_id" => resolution_source_entry_id,
           "source_entry_ids" => source_ids
         },
         allowed
       )
       when is_binary(topic) and is_binary(summary) and is_list(source_ids) do
    with {:ok, source_ids} <- validate_source_ids(source_ids, allowed),
         {:ok, question} <- nullable_text(question, :invalid_episode_question),
         {:ok, resolution} <- nullable_text(resolution, :invalid_episode_resolution),
         {:ok, systems} <- nullable_strings(systems),
         {:ok, resolution_source_entry_id} <-
           resolution_source_id(resolution_source_entry_id, allowed),
         :ok <- non_empty_text(topic, :empty_episode_topic),
         :ok <- non_empty_text(summary, :empty_episode_summary),
         :ok <- max_text_length(summary, 500, :brain_episode_summary_too_long),
         :ok <- require_source_ids(source_ids) do
      {:ok,
       %{
         "topic" => String.trim(topic),
         "question" => question,
         "summary" => String.trim(summary),
         "resolution" => resolution,
         "systems" => systems,
         "resolution_source_entry_id" => resolution_source_entry_id,
         "source_entry_ids" => source_ids
       }}
    end
  end

  defp validate_episode(_episode, _allowed), do: {:error, :invalid_episode_shape}

  defp nullable_text(nil, _reason), do: {:ok, nil}

  defp nullable_text(text, _reason) when is_binary(text) do
    case String.trim(text) do
      "" -> {:ok, nil}
      text -> {:ok, text}
    end
  end

  defp nullable_text(_value, reason), do: {:error, reason}

  defp nullable_strings(nil), do: {:ok, []}

  defp nullable_strings(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn
      value, {:ok, acc} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:cont, {:ok, acc}}
          value -> {:cont, {:ok, [value | acc]}}
        end

      _value, _acc ->
        {:halt, {:error, :invalid_episode_systems}}
    end)
    |> case do
      {:ok, systems} -> {:ok, systems |> Enum.reverse() |> Enum.uniq()}
      {:error, _reason} = error -> error
    end
  end

  defp nullable_strings(_value), do: {:error, :invalid_episode_systems}

  defp resolution_source_id(nil, _source_ids), do: {:ok, nil}

  defp resolution_source_id(source_id, source_ids) when is_binary(source_id) do
    source_id = String.trim(source_id)

    if source_id in source_ids,
      do: {:ok, source_id},
      else: {:error, :invalid_resolution_source_entry_id}
  end

  defp resolution_source_id(_source_id, _source_ids),
    do: {:error, :invalid_resolution_source_entry_id}

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

  # Deferral is limited to the still-young configured tail. Otherwise a model could indefinitely
  # defer arbitrary old rows and prevent the durable cursor from making progress. The request names
  # this same set, so the model never has to reconstruct the budget from timestamps it cannot
  # compare against the current time.
  defp deferrable_source_entry_ids(entries, dreaming_config) do
    tail_rows = Map.fetch!(dreaming_config, "episode_tail_guard_rows")
    tail_minutes = Map.fetch!(dreaming_config, "episode_tail_guard_minutes")
    age_cutoff = DateTime.utc_now(:microsecond) |> DateTime.add(-tail_minutes * 60, :second)

    entries
    |> Enum.take(-tail_rows)
    |> Enum.filter(&(DateTime.compare(observed_at(&1), age_cutoff) == :gt))
    |> Enum.map(& &1.source_entry_id)
    |> MapSet.new()
  end

  defp validate_deferred_source_ids(source_ids, allowed, deferrable_ids)
       when is_list(source_ids) do
    with {:ok, validated} <- validate_source_ids(source_ids, allowed),
         :ok <- deferred_in_tail(validated, deferrable_ids) do
      {:ok, validated}
    end
  end

  defp validate_deferred_source_ids(_source_ids, _allowed, _deferrable_ids),
    do: {:error, :invalid_deferred_source_entry_ids}

  defp deferred_in_tail(source_ids, deferrable_ids) do
    case Enum.all?(source_ids, &MapSet.member?(deferrable_ids, &1)) do
      true -> :ok
      false -> {:error, :invalid_deferred_source_entry_ids}
    end
  end

  defp persist_summary_output(
         signal_channel_id,
         entries,
         %{
           "episodes" => episodes,
           "noise_source_entry_ids" => noise_source_entry_ids,
           "deferred_source_entry_ids" => _deferred_source_entry_ids
         },
         model_agent_uid
       ) do
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
               embedding_state: :pending,
               metadata: episode_metadata(episode)
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
                 upsert_cursor(
                   repo,
                   signal_channel_id,
                   last_processed_entry,
                   nil,
                   %{"stage_a_model_agent_uid" => model_agent_uid}
                 )

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

  defp episode_metadata(episode) do
    %{
      "version" => 2,
      "question" => episode["question"],
      "resolution" => episode["resolution"],
      "systems" => episode["systems"],
      "resolution_source_entry_id" => episode["resolution_source_entry_id"]
    }
  end

  defp episode_bounds(entries) do
    observed = Enum.map(entries, &observed_at/1)

    {Enum.min_by(observed, &DateTime.to_unix(&1, :microsecond)),
     Enum.max_by(observed, &DateTime.to_unix(&1, :microsecond))}
  end

  defp upsert_cursor(
         repo,
         signal_channel_id,
         %Entry{} = entry,
         unavailable_reason,
         metadata \\ %{}
       ) do
    now = DateTime.utc_now(:microsecond)
    observed_at = observed_at(entry)

    changeset =
      Cursor.changeset(%Cursor{}, %{
        scope_kind: :channel,
        scope_key: signal_channel_id,
        cursor_provider_time: entry.provider_time,
        cursor_source_entry_id: entry.source_entry_id,
        cursor_entry_observed_at: observed_at,
        unavailable_reason: unavailable_reason,
        metadata: metadata
      })

    repo.insert!(changeset,
      on_conflict: [
        set: [
          cursor_provider_time: entry.provider_time,
          cursor_source_entry_id: entry.source_entry_id,
          cursor_entry_observed_at: observed_at,
          unavailable_reason: unavailable_reason,
          metadata: metadata,
          updated_at: now
        ]
      ],
      conflict_target: [:scope_kind, :scope_key]
    )
  end

  defp embed_episode(model_agent_uid, %Episode{} = episode) do
    case Embedding.create(model_agent_uid, episode_embedding_text(episode)) do
      {:ok, vector, dimensions} ->
        Repo.query!(
          """
          UPDATE brain_episodes
          SET embedding = $2,
              embedding_dimensions = $3,
              embedding_model_agent_uid = $4,
              embedding_state = 'synced',
              embedding_error = NULL,
              updated_at = now()
          WHERE id = $1::text::uuid
          """,
          [episode.id, Embedding.storage_vector(vector), dimensions, model_agent_uid]
        )

      {:error, reason} ->
        Episode
        |> where([row], row.id == ^episode.id)
        |> Repo.update_all(
          set: [
            embedding: nil,
            embedding_dimensions: nil,
            embedding_model_agent_uid: nil,
            embedding_state: :failed,
            embedding_error: inspect(reason),
            updated_at: DateTime.utc_now(:microsecond)
          ]
        )
    end
  end

  defp episode_embedding_text(%Episode{} = episode) do
    metadata = episode.metadata || %{}

    [
      episode.topic,
      metadata["question"],
      episode.summary,
      metadata["resolution"],
      Enum.join(metadata["systems"] || [], ", ")
    ]
    |> Enum.reject(&(is_nil(&1) or String.trim(&1) == ""))
    |> Enum.join("\n")
  end

  defp entry_text(%Entry{} = entry) do
    entry.text || ""
  end

  defp observed_at(%Entry{} = entry),
    do: entry.provider_time || entry.last_seen_at || entry.inserted_at

  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp datetime(_value), do: nil
end
