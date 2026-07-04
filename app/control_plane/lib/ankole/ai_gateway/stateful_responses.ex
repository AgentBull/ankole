defmodule Ankole.AIGateway.StatefulResponses do
  @moduledoc """
  Stateful Responses loop owner for AIGateway (new-plan2.md §3.9).

  This module sits between the AIGateway transport entry (WebSocket
  `response.create` / HTTP `POST /responses`) and the provider request build.
  For each stateful `response.create + store=true` run it:

    1. Resolves `previous_response_id` / `conversation` into a message chain.
    2. Creates one `ai_gateway_messages` row with `status = "generating"` and
       `metadata.actor_event_id`.
    3. Returns the row so the transport can build the provider-facing input
       (expanded history + current request items) and call the provider.
    4. While the provider streams, live chunk events are published via
       `Ankole.PubSub` so SignalsGateway can render IM preview/edit/finalize.
    5. When the provider reaches a terminal state, the transport calls
       `commit_complete/3` or `commit_error/4` to write the durable final
       `content` and flip the row to `complete` or `error`.

  The loop itself is driven by the worker (one `response.create` per round);
  this module does NOT call the provider internally. Each call to
  `start_response_run/2` corresponds to exactly one `response.create` and
  exactly one `ai_gateway_messages` row (see plan §3.9 step 5–10).
  """

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL
  alias Ankole.AIGateway.Conversations
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Actors
  alias Ankole.Actors.ActorEvent
  alias Ankole.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.ReplyAttachment

  @pubsub Ankole.PubSub
  @orphaned_generating_grace_seconds 300
  @history_chain_max_depth 10_000

  # ───────────────────────────────────────────────────────────────
  # Public API
  # ───────────────────────────────────────────────────────────────

  @doc """
  Starts a stateful response run: creates a `generating` message row.

  ## Parameters

    * `attrs` — a map with:
      - `agent_uid` (required) — the agent principal uid
      - `conversation_id` (required) — the ai_gateway_conversations.id
      - `actor_event_id` (optional for internal callers) — worker correlation key
        written into metadata. HTTP/WS stateful entrypoints require it before
        this helper is called.
      - `previous_response_id` (optional) — "resp_{uuid}" decoded to a
        raw UUID pointing at the anchor message
      - `request_items` (optional) — initial content items (input/function_call_output)
      - `metadata` (optional) — extra metadata merged into the row

  Returns `{:ok, %Message{}}` or `{:error, changeset}`.

  The returned message row's `id` becomes the `resp_{id}` for this run.
  Its `previous_message_id` is set from the decoded anchor (or nil for a
  fresh conversation). The caller uses this row to build the provider input
  and initiate the provider call.
  """
  @spec start_response_run(map()) ::
          {:ok, Message.t()}
          | {:error,
             Ecto.Changeset.t()
             | :invalid_anchor
             | :invalid_conversation
             | :stateful_anchor_conflict
             | :response_run_in_progress}
  def start_response_run(attrs) do
    raw_agent_uid = Map.fetch!(attrs, :agent_uid)
    actor_event_id = Map.get(attrs, :actor_event_id, Map.get(attrs, "actor_event_id"))
    conversation_id = conversation_id(attrs)
    previous_response_id = previous_response_id(attrs)

    with {:ok, agent_uid} <- Principals.normalize_uid(raw_agent_uid),
         :ok <- validate_anchor_selector(conversation_id, previous_response_id),
         {:ok, previous_message_id} <- decode_optional_response_id(previous_response_id),
         {:ok, conversation} <-
           resolve_run_conversation(agent_uid, conversation_id, previous_message_id) do
      # Source table: metadata.actor_event_id stores actor_events.id as
      # correlation metadata only. Agent isolation is enforced by
      # conversation/anchor lookup scoped by agent_uid.
      base_metadata =
        %{}
        |> maybe_put_metadata("actor_event_id", actor_event_id)

      extra_metadata =
        attrs
        |> Map.take([:metadata, "metadata"])
        |> case do
          %{metadata: m} when is_map(m) -> m
          %{"metadata" => m} when is_map(m) -> m
          _ -> %{}
        end

      # Initial content: request-side input items (function_call_output, etc.)
      initial_content = Map.get(attrs, :request_items, Map.get(attrs, "request_items", []))

      merged_metadata =
        extra_metadata
        |> Map.merge(request_items_metadata(initial_content))
        |> Map.merge(base_metadata)

      insert_response_run(%{
        agent_uid: agent_uid,
        conversation_id: conversation.id,
        actor_event_id: actor_event_id,
        previous_message_id: previous_message_id,
        initial_content: initial_content,
        merged_metadata: merged_metadata
      })
    else
      {:error, :invalid_response_id} -> {:error, :invalid_anchor}
      {:error, :invalid_uuid} -> {:error, :invalid_conversation}
      {:error, :invalid_uid} -> {:error, :invalid_conversation}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Records tool results as a completed message-log row without opening a provider run.

  This closes the worker crash window after a tool side effect has happened but
  before the next `response.create` continuation reaches AIGateway. The returned
  row becomes the next `previous_response_id`; the following provider call can
  replay the durable `function_call_output` items from the normal message chain.
  """
  @spec record_tool_results(map()) ::
          {:ok, Message.t()}
          | {:error,
             Ecto.Changeset.t()
             | :invalid_anchor
             | :invalid_conversation
             | :invalid_tool_results
             | :missing_actor_event_id}
  def record_tool_results(attrs) when is_map(attrs) do
    raw_agent_uid = Map.fetch!(attrs, :agent_uid)
    actor_event_id = Map.get(attrs, :actor_event_id, Map.get(attrs, "actor_event_id"))
    previous_response_id = previous_response_id(attrs)
    request_items = Map.get(attrs, :request_items, Map.get(attrs, "request_items", []))

    extra_metadata =
      attrs
      |> Map.take([:metadata, "metadata"])
      |> case do
        %{metadata: m} when is_map(m) -> m
        %{"metadata" => m} when is_map(m) -> m
        _ -> %{}
      end

    with {:ok, agent_uid} <- Principals.normalize_uid(raw_agent_uid),
         :ok <- validate_actor_event_id(actor_event_id),
         :ok <- validate_tool_result_items(request_items),
         {:ok, previous_message_id} <- decode_response_id(previous_response_id),
         %Message{status: "complete"} = anchor <-
           complete_message_for_agent(agent_uid, previous_message_id) do
      idempotency_key =
        tool_result_idempotency_key(agent_uid, actor_event_id, previous_message_id, request_items)

      merged_metadata =
        extra_metadata
        |> Map.merge(request_items_metadata(request_items))
        |> Map.merge(%{
          "actor_event_id" => actor_event_id,
          "tool_result_journal" => true,
          "tool_result_idempotency_key" => idempotency_key
        })

      insert_tool_result_journal(anchor, request_items, merged_metadata, idempotency_key)
    else
      {:error, :invalid_response_id} -> {:error, :invalid_anchor}
      {:error, :invalid_uid} -> {:error, :invalid_conversation}
      {:error, _reason} = error -> error
      _not_found_or_invalid -> {:error, :invalid_anchor}
    end
  end

  defp insert_response_run(%{
         agent_uid: agent_uid,
         conversation_id: conversation_id,
         actor_event_id: actor_event_id,
         previous_message_id: previous_message_id,
         initial_content: initial_content,
         merged_metadata: merged_metadata
       }) do
    changeset =
      %Message{}
      |> Message.changeset(%{
        agent_uid: agent_uid,
        conversation_id: conversation_id,
        type: "message",
        status: "generating",
        previous_message_id: previous_message_id,
        content: initial_content,
        metadata: merged_metadata
      })

    case Repo.transact(fn repo ->
           with :ok <-
                  recover_stale_generating_run_in_tx(
                    repo,
                    agent_uid,
                    actor_event_id,
                    DateTime.utc_now(:microsecond)
                  ),
                {:ok, message} <- repo.insert(changeset) do
             {:ok, message}
           end
         end) do
      {:ok, %Message{} = message} ->
        # Publish a "response.started" live event so SignalsGateway knows a
        # new generating row exists. Subscribers use this to set up preview.
        publish_live_event(message, :response_started, %{})
        {:ok, message}

      {:error, %Ecto.Changeset{} = changeset} ->
        insert_response_run_changeset_error(changeset)

      {:error, _reason} = error ->
        error
    end
  end

  defp insert_response_run_changeset_error(%Ecto.Changeset{} = changeset) do
    if unique_constraint_error?(changeset, "ai_gateway_messages_generating_actor_event_index") do
      {:error, :response_run_in_progress}
    else
      {:error, changeset}
    end
  end

  defp insert_tool_result_journal(
         %Message{} = anchor,
         request_items,
         merged_metadata,
         idempotency_key
       ) do
    case fetch_tool_result_journal(anchor.agent_uid, idempotency_key) do
      {:ok, %Message{} = message} ->
        {:ok, message}

      {:error, :invalid_anchor} ->
        do_insert_tool_result_journal(anchor, request_items, merged_metadata, idempotency_key)
    end
  end

  defp do_insert_tool_result_journal(
         %Message{} = anchor,
         request_items,
         merged_metadata,
         idempotency_key
       ) do
    changeset =
      %Message{}
      |> Message.changeset(%{
        agent_uid: anchor.agent_uid,
        conversation_id: anchor.conversation_id,
        type: "message",
        status: "complete",
        previous_message_id: anchor.id,
        content: request_items,
        metadata: merged_metadata
      })

    case Repo.insert(changeset) do
      {:ok, %Message{} = message} ->
        {:ok, message}

      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_constraint_error?(
             changeset,
             "ai_gateway_messages_tool_result_journal_key_index"
           ) do
          fetch_tool_result_journal(anchor.agent_uid, idempotency_key)
        else
          {:error, changeset}
        end
    end
  end

  defp fetch_tool_result_journal(agent_uid, idempotency_key) do
    case Repo.one(
           from(message in Message,
             where: message.agent_uid == ^agent_uid,
             where:
               fragment(
                 "?->>'tool_result_idempotency_key'",
                 message.metadata
               ) == ^idempotency_key
           )
         ) do
      %Message{} = message -> {:ok, message}
      nil -> {:error, :invalid_anchor}
    end
  end

  defp request_items_metadata(request_items) when is_list(request_items) do
    %{}
    |> maybe_put_metadata("tool_results", tool_results_metadata(request_items))
  end

  defp request_items_metadata(_request_items), do: %{}

  defp tool_results_metadata(request_items) do
    request_items
    |> Enum.filter(&function_call_output_item?/1)
    |> Enum.map(fn item ->
      item
      |> Map.take(["call_id", "output"])
      |> maybe_put_metadata("id", Map.get(item, "id"))
      |> maybe_put_metadata("status", Map.get(item, "status"))
    end)
  end

  defp function_call_output_item?(%{"type" => "function_call_output"}), do: true
  defp function_call_output_item?(_item), do: false

  defp validate_actor_event_id(actor_event_id) when is_binary(actor_event_id) do
    case String.trim(actor_event_id) do
      "" -> {:error, :missing_actor_event_id}
      _value -> :ok
    end
  end

  defp validate_actor_event_id(_actor_event_id), do: {:error, :missing_actor_event_id}

  defp validate_tool_result_items(request_items) when is_list(request_items) do
    case Enum.any?(request_items, &function_call_output_item?/1) do
      true -> :ok
      false -> {:error, :invalid_tool_results}
    end
  end

  defp validate_tool_result_items(_request_items), do: {:error, :invalid_tool_results}

  defp tool_result_idempotency_key(
         agent_uid,
         actor_event_id,
         previous_message_id,
         request_items
       ) do
    stable_term = {agent_uid, actor_event_id, previous_message_id, request_items}

    stable_term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp unique_constraint_error?(%Ecto.Changeset{errors: errors}, constraint_name) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      opts[:constraint] == :unique and opts[:constraint_name] == constraint_name
    end)
  end

  defp recover_stale_generating_run_in_tx(_repo, _agent_uid, nil, _now), do: :ok
  defp recover_stale_generating_run_in_tx(_repo, _agent_uid, "", _now), do: :ok

  defp recover_stale_generating_run_in_tx(repo, agent_uid, actor_event_id, now) do
    case generating_message_for_actor_event(repo, actor_event_id, agent_uid: agent_uid) do
      nil ->
        :ok

      %Message{} = message ->
        cond do
          not generating_message_stale?(message, now) ->
            {:error, :response_run_in_progress}

          live_delivery_exists?(repo, agent_uid, actor_event_id) ->
            {:error, :response_run_in_progress}

          true ->
            fail_stale_generating_run(repo, message, now)
        end
    end
  end

  @doc """
  Returns the grace window before a generating response is treated as orphaned.
  """
  @spec orphaned_generating_grace_seconds() :: pos_integer()
  def orphaned_generating_grace_seconds, do: @orphaned_generating_grace_seconds

  @doc """
  Returns the cutoff for orphaned generating response rows.
  """
  @spec orphaned_generating_cutoff(DateTime.t()) :: DateTime.t()
  def orphaned_generating_cutoff(now),
    do: DateTime.add(now, -orphaned_generating_grace_seconds(), :second)

  @doc """
  Loads one live generating response row by the actor event fence.
  """
  @spec generating_message_for_actor_event(module(), binary() | nil, keyword()) ::
          Message.t() | nil
  def generating_message_for_actor_event(repo, actor_event_id, opts \\ [])
  def generating_message_for_actor_event(_repo, nil, _opts), do: nil
  def generating_message_for_actor_event(_repo, "", _opts), do: nil

  def generating_message_for_actor_event(repo, actor_event_id, opts) do
    query =
      generating_messages_query()
      |> where([message], fragment("?->>'actor_event_id'", message.metadata) == ^actor_event_id)
      |> maybe_scope_generating_query_to_agent(Keyword.get(opts, :agent_uid))
      |> lock("FOR UPDATE")

    repo.one(query)
  end

  @doc """
  Loads stale generating response rows for actor-runtime reconciliation.
  """
  @spec stale_generating_messages(module(), DateTime.t()) :: [Message.t()]
  def stale_generating_messages(repo, now) do
    cutoff = orphaned_generating_cutoff(now)

    generating_messages_query()
    |> where([message], message.updated_at <= ^cutoff)
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  @doc """
  Returns whether a generating row has exceeded the orphan grace window.
  """
  @spec generating_message_stale?(Message.t(), DateTime.t()) :: boolean()
  def generating_message_stale?(%Message{updated_at: updated_at}, now)
      when not is_nil(updated_at) do
    cutoff = orphaned_generating_cutoff(now)
    DateTime.compare(updated_at, cutoff) in [:lt, :eq]
  end

  def generating_message_stale?(_message, _now), do: false

  defp generating_messages_query do
    Message
    |> where([message], message.type == "message")
    |> where([message], message.status == "generating")
  end

  defp maybe_scope_generating_query_to_agent(query, nil), do: query
  defp maybe_scope_generating_query_to_agent(query, ""), do: query

  defp maybe_scope_generating_query_to_agent(query, agent_uid),
    do: where(query, [message], message.agent_uid == ^agent_uid)

  defp live_delivery_exists?(repo, agent_uid, actor_event_id) do
    ActorEventDelivery
    |> where([delivery], delivery.agent_uid == ^agent_uid)
    |> where([delivery], delivery.actor_event_id_fence == ^actor_event_id)
    |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
    |> repo.exists?()
  end

  defp fail_stale_generating_run(repo, %Message{} = message, now) do
    error_details = %{
      "code" => "stale_generating_response",
      "reason" => "stale generating response was replaced before a retry",
      "stage" => "stateful_response_start"
    }

    metadata =
      (message.metadata || %{})
      |> Map.put("error", error_details)

    case repo.update_all(
           from(m in Message,
             where: m.id == ^message.id and m.status == "generating",
             select: m
           ),
           [
             set: [
               status: "error",
               metadata: metadata,
               updated_at: now
             ]
           ],
           returning: true
         ) do
      {count, [_updated]} when count > 0 -> :ok
      {0, []} -> {:error, :response_run_in_progress}
    end
  end

  @doc """
  Commits a response run as `complete` with the final durable content.

  Uses an optimistic transition guard: `WHERE status = 'generating'` ensures
  only the first terminal commit wins. If the row is already terminal (e.g.
  a concurrent cleanup path), this is a no-op that returns the existing row.
  """
  @spec commit_complete(Message.t() | binary(), [map()], map()) ::
          {:ok, Message.t()} | {:error, term()} | {:ok, :already_terminal}
  def commit_complete(message, content_items, extra_metadata \\ %{}) do
    case ensure_loaded(message) do
      nil ->
        {:error, :message_not_found}

      %Message{} = message ->
        commit_complete_loaded(message, content_items, extra_metadata)
    end
  end

  defp commit_complete_loaded(%Message{status: status}, _content_items, _extra_metadata)
       when status != "generating",
       do: {:ok, :already_terminal}

  defp commit_complete_loaded(%Message{} = message, content_items, extra_metadata) do
    final_content = durable_terminal_content(message, content_items)
    merged_metadata = Map.merge(message.metadata || %{}, extra_metadata)
    now = DateTime.utc_now(:microsecond)

    case Repo.transact(fn repo ->
           with :ok <- ensure_message_actor_event_source_live_in_tx(repo, message, now) do
             case repo.update_all(
                    from(m in Message,
                      where: m.id == ^message.id and m.status == "generating",
                      select: m
                    ),
                    [
                      set: [
                        status: "complete",
                        content: final_content,
                        metadata: merged_metadata,
                        updated_at: now
                      ]
                    ],
                    returning: true
                  ) do
               {count, [updated]} when count > 0 ->
                 with {:ok, _attachment_outboxes} <-
                        commit_reply_attachment_outboxes_in_tx(repo, updated, final_content),
                      {:ok, _actor_event_result} <-
                        maybe_complete_actor_event_in_tx(repo, updated, final_content, now) do
                   {:ok, updated}
                 end

               {0, []} ->
                 {:ok, :already_terminal}
             end
           end
         end) do
      {:ok, %Message{} = updated} ->
        publish_live_event(updated, :response_completed, %{
          content: final_content,
          response_id: "resp_#{updated.id}",
          actor_event_id: updated.metadata["actor_event_id"]
        })

        {:ok, updated}

      {:ok, :already_terminal} ->
        {:ok, :already_terminal}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Commits a response run as `error` with failure details.

  Same optimistic transition guard as `commit_complete`: only the first
  terminal commit wins.
  """
  @spec commit_error(Message.t() | binary(), [map()], map(), keyword()) ::
          {:ok, Message.t()} | {:error, term()} | {:ok, :already_terminal}
  def commit_error(message, partial_content, error_details, opts \\ []) do
    case ensure_loaded(message) do
      nil ->
        {:error, :message_not_found}

      %Message{} = message ->
        commit_error_loaded(message, partial_content, error_details, opts)
    end
  end

  defp commit_error_loaded(%Message{status: status}, _partial_content, _error_details, _opts)
       when status != "generating",
       do: {:ok, :already_terminal}

  defp commit_error_loaded(%Message{} = message, partial_content, error_details, opts) do
    final_content = durable_terminal_content(message, partial_content)
    now = DateTime.utc_now(:microsecond)
    complete_actor_event? = Keyword.get(opts, :complete_actor_event?, true)
    extra_metadata = Keyword.get(opts, :metadata, %{})

    merged_metadata =
      (message.metadata || %{})
      |> Map.merge(extra_metadata)
      |> Map.merge(%{"error" => error_details})

    case Repo.transact(fn repo ->
           case repo.update_all(
                  from(m in Message,
                    where: m.id == ^message.id and m.status == "generating",
                    select: m
                  ),
                  [
                    set: [
                      status: "error",
                      content: final_content,
                      metadata: merged_metadata,
                      updated_at: now
                    ]
                  ],
                  returning: true
                ) do
             {count, [updated]} when count > 0 ->
               if complete_actor_event? do
                 with {:ok, _actor_event_result} <-
                        complete_actor_event_in_tx(repo, updated, now) do
                   {:ok, updated}
                 end
               else
                 {:ok, updated}
               end

             {0, []} ->
               {:ok, :already_terminal}
           end
         end) do
      {:ok, %Message{} = updated} ->
        publish_live_event(updated, :response_failed, %{
          error: error_details,
          response_id: "resp_#{updated.id}",
          actor_event_id: updated.metadata["actor_event_id"]
        })

        {:ok, updated}

      {:ok, :already_terminal} ->
        {:ok, :already_terminal}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Publishes a live chunk event for an in-progress response run.

  Live chunks are NOT durable — they are not written to `ai_gateway_messages`.
  They are published via PubSub so SignalsGateway can render IM preview/edit.
   Only terminal states write to the database (via `commit_complete` /
   `commit_error`).

  ## Parameters

    * `message` — the generating message row (or its id)
    * `chunk` — the live chunk payload (text delta, tool call delta, etc.)
    * `seq` — optional sequence number for ordering
  """
  # Publishes a typed live chunk event via PubSub.
  # The event_type is a semantic tag (e.g. :output_text_delta), not a provider
  # frame name — provider raw event names must not leak into runtime semantics.
  @spec publish_typed_event(binary(), atom(), map()) :: :ok
  def publish_typed_event(actor_event_id, event_type, payload) do
    topic = live_topic(actor_event_id)
    Phoenix.PubSub.broadcast(@pubsub, topic, {:ai_gateway_live, event_type, payload})
  end

  @doc """
  Publishes a terminal live event for a response row that was moved to a terminal
  state outside the normal WebSocket commit path.
  """
  @spec publish_terminal_event(Message.t(), :response_completed | :response_failed, map()) :: :ok
  def publish_terminal_event(%Message{} = message, event_type, payload)
      when event_type in [:response_completed, :response_failed] do
    publish_live_event(message, event_type, payload)
  end

  @doc """
  Subscribes the calling process to live events for an actor event.
  Topic is keyed by actor_event_id — stable across all loop rounds.
  """
  @spec subscribe(binary()) :: :ok
  def subscribe(actor_event_id) do
    Phoenix.PubSub.subscribe(@pubsub, live_topic(actor_event_id))
  end

  @doc """
  Unsubscribes the calling process from live events for an actor event.
  """
  @spec unsubscribe(binary()) :: :ok
  def unsubscribe(actor_event_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, live_topic(actor_event_id))
  end

  @doc """
  Expands the message chain for history projection.

  Reads `complete` message rows in the conversation, following the
  `previous_message_id` chain from the given response anchor (or the latest visible
  leaf if no anchor is given). Returns a list of `%Message{}` rows in
  chronological order.

  Only `complete` rows enter normal projection. `generating` rows are never
  projected in v1; a worker loop continuation must reference the previous
  round's committed `complete` response.
  """
  @spec expand_history(binary(), keyword()) :: [Message.t()]
  def expand_history(conversation_id, opts \\ []) do
    with {:ok, conversation_id} <- cast_uuid(conversation_id),
         {:ok, anchor_id} <- history_anchor(conversation_id, opts) do
      if anchor_id do
        # Walk the chain backward from the anchor, collecting complete rows.
        walk_message_chain(conversation_id, anchor_id)
      else
        []
      end
    else
      {:error, _reason} -> []
    end
  end

  @doc """
  Counts durable provider function_call items for one actor event on an anchor chain.

  This deliberately walks the raw `previous_message_id` chain instead of the
  projected history so compaction coverage cannot reset the tool-loop guard.
  """
  @spec count_function_calls_for_actor_event(binary(), term(), binary() | nil) ::
          non_neg_integer()
  def count_function_calls_for_actor_event(
        _conversation_id,
        _previous_response_id,
        actor_event_id
      )
      when actor_event_id in [nil, ""],
      do: 0

  def count_function_calls_for_actor_event(conversation_id, previous_response_id, actor_event_id) do
    with {:ok, conversation_id} <- cast_uuid(conversation_id),
         {:ok, anchor_id} <-
           history_anchor(conversation_id, previous_response_id: previous_response_id),
         true <- is_binary(anchor_id) do
      Repo
      |> chain_messages(conversation_id, anchor_id)
      |> Enum.filter(&function_call_count_candidate?(&1, actor_event_id))
      |> Enum.flat_map(fn
        %Message{content: content} when is_list(content) -> content
        _message -> []
      end)
      |> Enum.count(&function_call_item?/1)
    else
      _missing_or_invalid_anchor -> 0
    end
  end

  @doc """
  Finds the latest visible leaf message for a conversation.

  "Visible leaf" = a `complete` message that no other `complete` message
  references as `previous_message_id`. If there are multiple leaves (branching),
  the latest one by insertion order is returned deterministically (see plan §3.3).
  """
  @spec latest_visible_leaf(binary()) :: binary() | nil
  def latest_visible_leaf(conversation_id) do
    with {:ok, conversation_id} <- cast_uuid(conversation_id) do
      latest_visible_leaf_for_uuid(Repo, conversation_id)
    else
      {:error, _reason} -> nil
    end
  end

  @doc """
  Hard deletes the current visible tail produced by a completed actor event.

  This is intentionally narrower than historical retraction. It only deletes a
  contiguous terminal suffix of ordinary complete message rows whose
  `metadata.actor_event_id` equals the removed source event's actor event. Once
  another actor event or a compaction row has been appended, v1 leaves history
  untouched instead of rewriting derived state.
  """
  @spec hard_delete_visible_tail_for_actor_event_in_tx(module(), ActorEvent.t(), keyword()) ::
          {:ok,
           %{
             required(:status) => :deleted | :noop,
             required(:deleted_message_ids) => [binary()],
             required(:deleted_count) => non_neg_integer(),
             optional(:failed_generating_message_ids) => [binary()],
             optional(:failed_generating_count) => non_neg_integer(),
             optional(:reason) => atom()
           }}
          | {:error, term()}
  def hard_delete_visible_tail_for_actor_event_in_tx(
        repo,
        %ActorEvent{} = actor_event,
        opts \\ []
      ) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    case conversation_for_actor_event(repo, actor_event) do
      %Conversation{} = conversation ->
        delete_visible_tail_for_actor_event(repo, conversation, actor_event.id, now)

      nil ->
        {:ok, tail_delete_noop(:conversation_not_found)}
    end
  end

  defp latest_visible_leaf_for_uuid(repo, conversation_id) do
    Message
    |> where([message], message.conversation_id == ^conversation_id)
    |> where([message], message.status == "complete")
    |> where(
      [message],
      fragment(
        """
        NOT EXISTS (
          SELECT 1
          FROM ai_gateway_messages AS child
          WHERE child.conversation_id = ?
            AND child.status = 'complete'
            AND child.previous_message_id = ?
        )
        """,
        message.conversation_id,
        message.id
      )
    )
    |> order_by([message], desc: message.inserted_at, desc: message.id)
    |> limit(1)
    |> select([message], message.id)
    |> repo.one()
  end

  defp delete_visible_tail_for_actor_event(
         repo,
         %Conversation{} = conversation,
         actor_event_id,
         now
       ) do
    case latest_visible_leaf_for_uuid(repo, conversation.id) do
      nil ->
        {:ok, tail_delete_noop(:no_visible_leaf)}

      leaf_id ->
        chain = chain_messages(repo, conversation.id, leaf_id)
        tail = Enum.take_while(chain, &tail_message_for_actor_event?(&1, actor_event_id))

        case tail do
          [] ->
            reason = actor_event_tail_noop_reason(repo, conversation.id, leaf_id, actor_event_id)
            {:ok, tail_delete_noop(reason)}

          [_message | _rest] ->
            messages_to_delete = Enum.reverse(tail)
            message_ids = Enum.map(messages_to_delete, & &1.id)

            with {:ok, failed_generating_messages} <-
                   fail_generating_messages_for_actor_event(
                     repo,
                     conversation.id,
                     actor_event_id,
                     now
                   ) do
              {deleted_count, _} =
                Message
                |> where([message], message.id in ^message_ids)
                |> repo.delete_all()

              failed_generating_message_ids =
                Enum.map(failed_generating_messages, & &1.id)

              {:ok,
               %{
                 status: :deleted,
                 deleted_message_ids: message_ids,
                 deleted_count: deleted_count,
                 failed_generating_message_ids: failed_generating_message_ids,
                 failed_generating_count: length(failed_generating_message_ids)
               }}
            end
        end
    end
  end

  defp fail_generating_messages_for_actor_event(repo, conversation_id, actor_event_id, now) do
    Message
    |> where([message], message.conversation_id == ^conversation_id)
    |> where([message], message.status == "generating")
    |> where([message], fragment("?->>'actor_event_id'", message.metadata) == ^actor_event_id)
    |> lock("FOR UPDATE")
    |> repo.all()
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, failed_messages} ->
      metadata =
        (message.metadata || %{})
        |> Map.put("error", %{
          "code" => "source_entry_removed",
          "failed_at" => DateTime.to_iso8601(now),
          "reason" => "source_entry_removed_before_terminal_commit",
          "stage" => "entry_lifecycle",
          "retryable" => false
        })

      case repo.update(Message.changeset(message, %{status: "error", metadata: metadata})) do
        {:ok, failed_message} -> {:cont, {:ok, [failed_message | failed_messages]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, failed_messages} -> {:ok, Enum.reverse(failed_messages)}
      {:error, _reason} = error -> error
    end
  end

  defp conversation_for_actor_event(repo, %ActorEvent{} = actor_event) do
    Conversation
    |> where([conversation], conversation.agent_uid == ^actor_event.agent_uid)
    |> where([conversation], conversation.conversation_key == ^actor_event.session_id)
    |> where([conversation], is_nil(conversation.ended_at))
    |> repo.one()
  end

  defp tail_message_for_actor_event?(%Message{} = message, actor_event_id) do
    message.type == "message" and message.status == "complete" and
      message.metadata["actor_event_id"] == actor_event_id
  end

  defp actor_event_tail_noop_reason(repo, conversation_id, leaf_id, actor_event_id) do
    repo
    |> walk_message_chain(conversation_id, leaf_id)
    |> Enum.any?(&(&1.metadata["actor_event_id"] == actor_event_id))
    |> case do
      true -> :not_visible_tail
      false -> :actor_event_not_visible
    end
  end

  defp tail_delete_noop(reason) do
    %{
      status: :noop,
      reason: reason,
      deleted_message_ids: [],
      deleted_count: 0
    }
  end

  @doc """
  Retrieves a single message row by its "resp_{id}".

  Internal DB-facing callers may also pass a raw UUID. HTTP/WS/API boundaries
  must validate the external `resp_*` form before calling this helper.
  """
  @spec get_message(binary()) :: Message.t() | nil
  def get_message(resp_or_id) do
    with {:ok, id} <- decode_response_id(resp_or_id) do
      Repo.get(Message, id)
    else
      {:error, _reason} -> nil
    end
  end

  @doc """
  Retrieves a stored response row scoped to one agent.
  """
  @spec get_message_for_agent(String.t(), binary()) :: {:ok, Message.t()} | {:error, :not_found}
  def get_message_for_agent(agent_uid, resp_or_id) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, id} <- decode_response_id(resp_or_id),
         %Message{} = message <-
           Repo.one(
             from(m in Message,
               where: m.id == ^id and m.agent_uid == ^agent_uid
             )
           ) do
      {:ok, message}
    else
      _not_found_or_invalid -> {:error, :not_found}
    end
  end

  @doc """
  Writes one manual stateful compaction row after a completed response anchor.
  """
  @spec compact_response(String.t(), binary(), map(), map()) ::
          {:ok, Message.t()} | {:error, :invalid_anchor | Ecto.Changeset.t()}
  def compact_response(agent_uid, previous_response_id, compaction_item, metadata \\ %{}) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, previous_message_id} <- decode_response_id(previous_response_id),
         %Message{status: "complete"} = anchor <-
           complete_message_for_agent(agent_uid, previous_message_id) do
      insert_compaction_row(anchor, anchor.id, compaction_item, metadata)
    else
      _not_found_or_invalid -> {:error, :invalid_anchor}
    end
  end

  @doc """
  Writes a compaction row after an anchor while covering a prefix ending at
  `covers_until_response_id` on that anchor's own ancestor chain.
  """
  @spec compact_history_prefix(String.t(), binary(), binary(), map(), map()) ::
          {:ok, Message.t()} | {:error, :invalid_anchor | Ecto.Changeset.t()}
  def compact_history_prefix(
        agent_uid,
        previous_response_id,
        covers_until_response_id,
        compaction_item,
        metadata \\ %{}
      ) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, previous_message_id} <- decode_response_id(previous_response_id),
         {:ok, covers_until_message_id} <- decode_response_id(covers_until_response_id),
         %Message{status: "complete"} = anchor <-
           complete_message_for_agent(agent_uid, previous_message_id),
         true <- ancestor_message?(anchor, covers_until_message_id) do
      insert_compaction_row(anchor, covers_until_message_id, compaction_item, metadata)
    else
      _not_found_or_invalid -> {:error, :invalid_anchor}
    end
  end

  @doc """
  Loads an active conversation by id and owning agent.

  This is used at stateful request boundaries so a caller cannot attach a new
  response run to another agent's conversation or expand another agent's history.
  """
  @spec get_conversation_for_agent(String.t(), String.t()) ::
          {:ok, Conversation.t()} | {:error, :invalid_conversation}
  def get_conversation_for_agent(agent_uid, conversation_id) do
    with {:ok, normalized_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, conversation_id} <- cast_uuid(conversation_id),
         %Conversation{} = conversation <-
           Repo.one(
             from(c in Conversation,
               where:
                 c.id == ^conversation_id and
                   c.agent_uid == ^normalized_uid and
                   is_nil(c.ended_at)
             )
           ) do
      {:ok, conversation}
    else
      _not_found_or_invalid -> {:error, :invalid_conversation}
    end
  end

  @doc """
  Validates an optional previous response anchor for a conversation.
  """
  @spec validate_response_anchor(binary(), term()) :: :ok | {:error, :invalid_anchor}
  def validate_response_anchor(_conversation_id, nil), do: :ok

  def validate_response_anchor(conversation_id, previous_response_id) do
    with {:ok, conversation_id} <- cast_uuid(conversation_id),
         {:ok, previous_message_id} <- decode_response_id(previous_response_id) do
      validate_anchor(conversation_id, previous_message_id)
    else
      {:error, _reason} -> {:error, :invalid_anchor}
    end
  end

  @doc """
  Ensures a conversation exists for the given agent + key, creating one if needed.

  This is the bootstrap entry for a stateful conversation.
  """
  @spec ensure_conversation(String.t(), String.t()) ::
          {:ok, Conversation.t()} | {:error, term()}
  def ensure_conversation(agent_uid, conversation_key) do
    Conversations.ensure_conversation(agent_uid, conversation_key)
  end

  # ───────────────────────────────────────────────────────────────
  # Internal helpers
  # ───────────────────────────────────────────────────────────────

  # Decodes a "resp_#{uuid}" string to the raw UUID. Internal DB-facing helpers
  # may pass raw UUIDs; HTTP/WS/API boundaries enforce prefixed ids before this
  # function is reached.
  defp decode_response_id("resp_" <> uuid), do: cast_uuid(uuid, :invalid_response_id)
  defp decode_response_id(uuid) when is_binary(uuid), do: cast_uuid(uuid, :invalid_response_id)
  defp decode_response_id(_value), do: {:error, :invalid_response_id}

  defp decode_optional_response_id(nil), do: {:ok, nil}
  defp decode_optional_response_id(value), do: decode_response_id(value)

  defp cast_uuid(value, error_reason \\ :invalid_uuid) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, error_reason}
    end
  end

  defp previous_response_id(attrs),
    do: Map.get(attrs, :previous_response_id, Map.get(attrs, "previous_response_id"))

  defp conversation_id(attrs),
    do: Map.get(attrs, :conversation_id, Map.get(attrs, "conversation_id"))

  defp validate_anchor_selector(nil, nil), do: {:error, :invalid_conversation}

  defp validate_anchor_selector(conversation_id, previous_response_id)
       when not is_nil(conversation_id) and not is_nil(previous_response_id),
       do: {:error, :stateful_anchor_conflict}

  defp validate_anchor_selector(_conversation_id, _previous_response_id), do: :ok

  defp resolve_run_conversation(agent_uid, conversation_id, nil),
    do: get_conversation_for_agent(agent_uid, conversation_id)

  defp resolve_run_conversation(agent_uid, nil, previous_message_id) do
    case Repo.one(
           from(m in Message,
             join: c in Conversation,
             on: c.id == m.conversation_id,
             where:
               m.id == ^previous_message_id and
                 m.status == "complete" and
                 c.agent_uid == ^agent_uid and
                 is_nil(c.ended_at),
             select: c
           )
         ) do
      %Conversation{} = conversation -> {:ok, conversation}
      nil -> {:error, :invalid_anchor}
    end
  end

  defp complete_message_for_agent(agent_uid, message_id) do
    Repo.one(
      from(m in Message,
        where:
          m.id == ^message_id and
            m.agent_uid == ^agent_uid and
            m.status == "complete"
      )
    )
  end

  defp insert_compaction_row(
         %Message{} = anchor,
         covers_until_message_id,
         compaction_item,
         metadata
       ) do
    base_item =
      compaction_item
      |> Map.delete("id")
      |> Map.put("type", "compaction")

    Repo.transact(fn repo ->
      with {:ok, inserted} <-
             %Message{}
             |> Message.changeset(%{
               agent_uid: anchor.agent_uid,
               conversation_id: anchor.conversation_id,
               type: "compaction",
               status: "complete",
               previous_message_id: anchor.id,
               covers_until_message_id: covers_until_message_id,
               content: [base_item],
               metadata: metadata
             })
             |> repo.insert() do
        compaction_item = Map.put(base_item, "id", "cmp_#{inserted.id}")

        inserted
        |> Message.changeset(%{content: [compaction_item]})
        |> repo.update()
      end
    end)
  end

  # Terminal provider items append to the request-side items saved when the
  # generating row was created. Replacing content would erase user input and
  # function_call_output from the durable Responses history.
  defp durable_terminal_content(%Message{content: existing_content}, terminal_items)
       when is_list(existing_content) and is_list(terminal_items),
       do: existing_content ++ terminal_items

  defp durable_terminal_content(_message, terminal_items) when is_list(terminal_items),
    do: terminal_items

  defp commit_reply_attachment_outboxes_in_tx(repo, %Message{} = message, final_content) do
    with {:ok, attachments} <- ReplyAttachment.attachments_from_response_items(final_content) do
      case attachments do
        [] ->
          {:ok, []}

        [_attachment | _rest] ->
          with actor_event_id when is_binary(actor_event_id) <- message.metadata["actor_event_id"],
               %ActorEvent{} = event <- lock_actor_event(repo, message.agent_uid, actor_event_id) do
            text = final_assistant_text(final_content)

            Outbox.commit_reply_attachment_outboxes_in_tx(
              repo,
              event,
              message.id,
              text,
              attachments
            )
          else
            nil -> {:error, :reply_attachment_actor_event_not_found}
            {:error, _reason} = error -> error
          end
      end
    end
  end

  defp final_assistant_text(items) when is_list(items) do
    items
    |> Enum.flat_map(&assistant_item_text_parts/1)
    |> Enum.join("")
  end

  defp final_assistant_text(_items), do: ""

  defp assistant_item_text_parts(%{"type" => "message", "role" => role, "content" => parts})
       when role in ["assistant", nil] and is_list(parts) do
    Enum.flat_map(parts, &text_part/1)
  end

  defp assistant_item_text_parts(%{"type" => "message", "content" => parts})
       when is_list(parts) do
    Enum.flat_map(parts, &text_part/1)
  end

  defp assistant_item_text_parts(_item), do: []

  defp text_part(%{"type" => type, "text" => text})
       when type in ["output_text", "text"] and is_binary(text),
       do: [text]

  defp text_part(_part), do: []

  defp ensure_message_actor_event_source_live_in_tx(repo, %Message{} = message, now) do
    case message.metadata["actor_event_id"] do
      actor_event_id when is_binary(actor_event_id) and actor_event_id != "" ->
        case lock_actor_event(repo, message.agent_uid, actor_event_id) do
          %ActorEvent{} = actor_event ->
            Actors.ensure_event_source_live_in_tx(repo, actor_event, now)

          nil ->
            :ok
        end

      _missing ->
        :ok
    end
  end

  defp maybe_complete_actor_event_in_tx(repo, %Message{} = message, final_content, now) do
    case contains_function_call?(final_content) do
      true -> {:ok, :kept_live_for_function_call}
      false -> complete_actor_event_in_tx(repo, message, now)
    end
  end

  defp complete_actor_event_in_tx(repo, %Message{} = message, now) do
    case message.metadata["actor_event_id"] do
      actor_event_id when is_binary(actor_event_id) and actor_event_id != "" ->
        with {:ok, _actor_event} <- mark_actor_event_completed(repo, message, actor_event_id, now),
             :ok <-
               mark_fenced_delivery_events_completed(repo, message.agent_uid, actor_event_id, now) do
          cleanup_terminal_deliveries(repo, message.agent_uid, actor_event_id, now)
          {:ok, :completed}
        end

      _missing ->
        {:ok, :no_actor_event}
    end
  end

  defp mark_actor_event_completed(repo, %Message{} = message, actor_event_id, now) do
    case lock_actor_event(repo, message.agent_uid, actor_event_id) do
      %ActorEvent{completed_at: nil} = actor_event ->
        complete_provider_visible_actor_event(repo, actor_event, now)

      %ActorEvent{} = actor_event ->
        {:ok, actor_event}

      nil ->
        {:ok, :actor_event_not_found}
    end
  end

  defp mark_fenced_delivery_events_completed(repo, agent_uid, actor_event_id, now) do
    ActorEventDelivery
    |> where([delivery], delivery.actor_event_id_fence == ^actor_event_id)
    |> where([delivery], delivery.agent_uid == ^agent_uid)
    |> where([delivery], delivery.state == "accepted")
    |> select([delivery], delivery.actor_event_id)
    |> repo.all()
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn delivered_actor_event_id, :ok ->
      case lock_actor_event(repo, agent_uid, delivered_actor_event_id) do
        %ActorEvent{completed_at: nil} = delivered_event ->
          case complete_provider_visible_actor_event(repo, delivered_event, now) do
            {:ok, _event} -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end

        %ActorEvent{} ->
          {:cont, :ok}

        nil ->
          {:cont, :ok}
      end
    end)
  end

  defp complete_provider_visible_actor_event(repo, %ActorEvent{} = actor_event, now) do
    Actors.complete_actor_event_in_tx(repo, actor_event, completed_at: now)
  end

  defp lock_actor_event(repo, agent_uid, actor_event_id) do
    ActorEvent
    |> where([event], event.id == ^actor_event_id)
    |> where([event], event.agent_uid == ^agent_uid)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp cleanup_terminal_deliveries(repo, agent_uid, actor_event_id, now) do
    delete_accepted_deliveries(repo, agent_uid, actor_event_id)
    supersede_pending_deliveries(repo, agent_uid, actor_event_id, now)
  end

  defp delete_accepted_deliveries(repo, agent_uid, actor_event_id) do
    ActorEventDelivery
    |> where([delivery], delivery.actor_event_id_fence == ^actor_event_id)
    |> where([delivery], delivery.agent_uid == ^agent_uid)
    |> where([delivery], delivery.state == "accepted")
    |> repo.delete_all()
  end

  defp supersede_pending_deliveries(repo, agent_uid, actor_event_id, now) do
    ActorEventDelivery
    |> where([delivery], delivery.actor_event_id_fence == ^actor_event_id)
    |> where([delivery], delivery.agent_uid == ^agent_uid)
    |> where([delivery], delivery.state in ["created", "sent"])
    |> repo.update_all(
      set: [
        state: "superseded",
        superseded_at: now,
        error: %{"reason" => "terminal_commit_before_acceptance"},
        updated_at: now
      ]
    )
  end

  defp contains_function_call?(items) when is_list(items),
    do: Enum.any?(items, &function_call_item?/1)

  defp contains_function_call?(_items), do: false

  defp function_call_count_candidate?(%Message{} = message, actor_event_id) do
    message.type == "message" and message.status == "complete" and
      message.metadata["actor_event_id"] == actor_event_id
  end

  defp function_call_item?(%{"type" => "function_call"}), do: true
  defp function_call_item?(_item), do: false

  defp history_anchor(conversation_id, opts) do
    previous_response_id =
      Keyword.get(opts, :previous_response_id, Keyword.get(opts, :previous_message_id))

    case previous_response_id do
      nil ->
        {:ok, latest_visible_leaf(conversation_id)}

      previous_response_id ->
        with {:ok, message_id} <- decode_response_id(previous_response_id),
             :ok <- validate_anchor(conversation_id, message_id) do
          {:ok, message_id}
        end
    end
  end

  # Validates that an anchor message exists, is complete, and belongs to the
  # given conversation. Per plan §3.3: only complete, non-retracted anchors.
  defp validate_anchor(conversation_id, message_id) do
    case Repo.one(
           from(m in Message,
             where:
               m.id == ^message_id and
                 m.conversation_id == ^conversation_id and
                 m.status == "complete",
             select: m.id
           )
         ) do
      nil -> {:error, :invalid_anchor}
      _id -> :ok
    end
  end

  # Walks the previous_message_id chain backward from the anchor, collecting
  # rows. A compaction row represents a compressed prefix inside its own
  # ancestor chain; it is projected before the uncovered tail between
  # `covers_until_message_id` and the compaction row's direct anchor.
  defp walk_message_chain(conversation_id, anchor_id) do
    walk_message_chain(Repo, conversation_id, anchor_id)
  end

  defp walk_message_chain(repo, conversation_id, anchor_id) do
    messages = chain_messages(repo, conversation_id, anchor_id)
    messages_by_id = Map.new(messages, &{&1.id, &1})

    walk_chain(messages_by_id, anchor_id, [], MapSet.new())
  end

  defp chain_messages(repo, conversation_id, anchor_id) do
    ids = chain_message_ids(repo, conversation_id, anchor_id)

    if ids == [] do
      []
    else
      messages_by_id =
        Message
        |> where([message], message.id in ^ids)
        |> repo.all()
        |> Map.new(&{&1.id, &1})

      Enum.flat_map(ids, fn id ->
        case messages_by_id do
          %{^id => %Message{} = message} -> [message]
          _missing -> []
        end
      end)
    end
  end

  defp chain_message_ids(repo, conversation_id, anchor_id) do
    result =
      SQL.query!(
        repo,
        """
        WITH RECURSIVE chain AS (
          SELECT id, previous_message_id, ARRAY[id] AS path, 1 AS depth
          FROM ai_gateway_messages
          WHERE id = $1::text::uuid
            AND conversation_id = $2::text::uuid

          UNION ALL

          SELECT parent.id,
                 parent.previous_message_id,
                 chain.path || parent.id,
                 chain.depth + 1
          FROM ai_gateway_messages AS parent
          JOIN chain ON parent.id = chain.previous_message_id
          WHERE parent.conversation_id = $2::text::uuid
            AND NOT parent.id = ANY(chain.path)
            AND chain.depth < $3
        )
        SELECT id::text
        FROM chain
        ORDER BY depth ASC
        """,
        [anchor_id, conversation_id, @history_chain_max_depth]
      )

    Enum.map(result.rows, fn [id] -> id end)
  end

  defp walk_chain(_messages_by_id, nil, acc, _seen), do: acc

  defp walk_chain(messages_by_id, message_id, acc, seen) do
    cond do
      MapSet.member?(seen, message_id) ->
        acc

      true ->
        case Map.fetch(messages_by_id, message_id) do
          {:ok, %Message{} = message} ->
            include? = project_message?(message)
            seen = MapSet.put(seen, message_id)

            new_acc = if include?, do: [message | acc], else: acc

            case covered_prefix_anchor(include?, message) do
              nil ->
                walk_chain(
                  messages_by_id,
                  message.previous_message_id,
                  new_acc,
                  seen
                )

              covers_until_message_id ->
                tail =
                  uncovered_tail_after_prefix(
                    messages_by_id,
                    message.previous_message_id,
                    covers_until_message_id,
                    [],
                    seen
                  )

                [message | tail ++ acc]
            end

          :error ->
            acc
        end
    end
  end

  defp project_message?(%Message{status: "complete"}), do: true
  defp project_message?(_message), do: false

  defp uncovered_tail_after_prefix(
         _messages_by_id,
         nil,
         _covers_until_message_id,
         acc,
         _seen
       ),
       do: acc

  defp uncovered_tail_after_prefix(
         _messages_by_id,
         covers_until_message_id,
         covers_until_message_id,
         acc,
         _seen
       ),
       do: acc

  defp uncovered_tail_after_prefix(
         messages_by_id,
         message_id,
         covers_until_message_id,
         acc,
         seen
       ) do
    cond do
      MapSet.member?(seen, message_id) ->
        acc

      true ->
        case Map.fetch(messages_by_id, message_id) do
          {:ok, %Message{} = message} ->
            acc =
              if project_message?(message),
                do: [message | acc],
                else: acc

            uncovered_tail_after_prefix(
              messages_by_id,
              message.previous_message_id,
              covers_until_message_id,
              acc,
              MapSet.put(seen, message_id)
            )

          :error ->
            acc
        end
    end
  end

  defp covered_prefix_anchor(true, %Message{
         type: "compaction",
         covers_until_message_id: message_id
       })
       when is_binary(message_id),
       do: message_id

  defp covered_prefix_anchor(_include?, _message), do: nil

  defp ancestor_message?(%Message{} = anchor, target_id) do
    do_ancestor_message?(anchor.conversation_id, anchor.id, target_id, MapSet.new())
  end

  defp do_ancestor_message?(_conversation_id, nil, _target_id, _seen), do: false

  defp do_ancestor_message?(_conversation_id, message_id, message_id, _seen), do: true

  defp do_ancestor_message?(conversation_id, message_id, target_id, seen) do
    cond do
      MapSet.member?(seen, message_id) ->
        false

      true ->
        case Repo.get(Message, message_id) do
          %Message{conversation_id: ^conversation_id, status: "complete"} = message ->
            do_ancestor_message?(
              conversation_id,
              message.previous_message_id,
              target_id,
              MapSet.put(seen, message_id)
            )

          _missing_or_invalid ->
            false
        end
    end
  end

  # Publishes a live event to the PubSub topic keyed by actor_event_id.
  # This lets the preview handler subscribe once per actor event and receive
  # all loop-round events (started/chunk/completed/failed) without re-subscribing
  # on each round (each round has a different message_id but same actor_event_id).
  defp publish_live_event(%Message{} = message, event_type, payload) do
    actor_event_id = message.metadata["actor_event_id"]

    if is_binary(actor_event_id) and actor_event_id != "" do
      topic = live_topic(actor_event_id)

      # Include message_id in payload so the handler can correlate.
      full_payload = Map.put(payload, :message_id, message.id)

      Phoenix.PubSub.broadcast(
        @pubsub,
        topic,
        {:ai_gateway_event, event_type, message.id, full_payload}
      )
    else
      :ok
    end
  end

  # PubSub topic keyed by actor_event_id (stable across loop rounds).
  defp live_topic(actor_event_id), do: "ai_gateway:actor_event:#{actor_event_id}"

  defp maybe_put_metadata(map, _key, nil), do: map
  defp maybe_put_metadata(map, _key, ""), do: map
  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  # Ensures the message is loaded from the DB if only an id was given.
  defp ensure_loaded(%Message{} = message), do: message
  defp ensure_loaded(id) when is_binary(id), do: Repo.get(Message, id)
end
