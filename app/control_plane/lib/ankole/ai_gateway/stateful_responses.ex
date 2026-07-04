defmodule Ankole.AIGateway.StatefulResponses do
  @moduledoc """
  Stateful Responses loop owner for AIGateway (new-plan.md §3.9).

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
    5. When the provider produces stable Response items or reaches a terminal
       state, the transport calls `commit_complete/3` or `commit_error/4` to
       write the durable `content` / `content_version` snapshot and flip the
       row to `complete` or `error`.

  The loop itself is driven by the worker (one `response.create` per round);
  this module does NOT call the provider internally. Each call to
  `start_response_run/2` corresponds to exactly one `response.create` and
  exactly one `ai_gateway_messages` row (see plan §3.9 step 5–10).
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Principals
  alias Ankole.Repo

  @pubsub Ankole.PubSub

  # ───────────────────────────────────────────────────────────────
  # Public API
  # ───────────────────────────────────────────────────────────────

  @doc """
  Starts a stateful response run: creates a `generating` message row.

  ## Parameters

    * `attrs` — a map with:
      - `agent_uid` (required) — the agent principal uid
      - `conversation_id` (required) — the ai_gateway_conversations.id
      - `actor_event_id` (required) — correlation key written into metadata
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
          | {:error, Ecto.Changeset.t() | :invalid_anchor | :invalid_conversation}
  def start_response_run(attrs) do
    raw_agent_uid = Map.fetch!(attrs, :agent_uid)
    conversation_id = Map.fetch!(attrs, :conversation_id)
    actor_event_id = Map.fetch!(attrs, :actor_event_id)

    with {:ok, agent_uid} <- Principals.normalize_uid(raw_agent_uid),
         {:ok, conversation} <- get_conversation_for_agent(agent_uid, conversation_id),
         {:ok, previous_message_id} <- decode_optional_response_id(previous_response_id(attrs)),
         :ok <- validate_anchor(conversation.id, previous_message_id) do
      # Build metadata: actor_event_id + model/provider refs + request refs.
      base_metadata = %{
        "actor_event_id" => actor_event_id
      }

      extra_metadata =
        attrs
        |> Map.take([:metadata, "metadata"])
        |> case do
          %{metadata: m} when is_map(m) -> m
          %{"metadata" => m} when is_map(m) -> m
          _ -> %{}
        end

      merged_metadata = Map.merge(base_metadata, extra_metadata)

      # Initial content: request-side input items (function_call_output, etc.)
      initial_content = Map.get(attrs, :request_items, Map.get(attrs, "request_items", []))

      insert_response_run(%{
        agent_uid: agent_uid,
        conversation_id: conversation.id,
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

  defp insert_response_run(%{
         agent_uid: agent_uid,
         conversation_id: conversation_id,
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
        content_version: 0,
        metadata: merged_metadata
      })

    case Repo.insert(changeset) do
      {:ok, message} ->
        # Publish a "response.started" live event so SignalsGateway knows a
        # new generating row exists. Subscribers use this to set up preview.
        publish_live_event(message, :response_started, %{})
        {:ok, message}

      {:error, changeset} ->
        {:error, changeset}
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
    current_version = message.content_version || 0
    final_content = durable_terminal_content(message, content_items)
    merged_metadata = Map.merge(message.metadata || %{}, extra_metadata)

    case Repo.update_all(
           from(m in Message,
             where: m.id == ^message.id and m.status == "generating",
             select: m
           ),
           [
             set: [
               status: "complete",
               content: final_content,
               content_version: current_version + 1,
               metadata: merged_metadata,
               updated_at: DateTime.utc_now(:microsecond)
             ]
           ],
           returning: true
         ) do
      {count, [updated]} when count > 0 ->
        publish_live_event(updated, :response_completed, %{
          content: final_content,
          response_id: "resp_#{updated.id}",
          actor_event_id: updated.metadata["actor_event_id"]
        })

        {:ok, updated}

      {0, []} ->
        {:ok, :already_terminal}
    end
  end

  @doc """
  Commits a response run as `error` with failure details.

  Same optimistic transition guard as `commit_complete`: only the first
  terminal commit wins.
  """
  @spec commit_error(Message.t() | binary(), [map()], map()) ::
          {:ok, Message.t()} | {:error, term()} | {:ok, :already_terminal}
  def commit_error(message, partial_content \\ [], error_details) do
    case ensure_loaded(message) do
      nil ->
        {:error, :message_not_found}

      %Message{} = message ->
        commit_error_loaded(message, partial_content, error_details)
    end
  end

  defp commit_error_loaded(%Message{status: status}, _partial_content, _error_details)
       when status != "generating",
       do: {:ok, :already_terminal}

  defp commit_error_loaded(%Message{} = message, partial_content, error_details) do
    current_version = message.content_version || 0
    final_content = durable_terminal_content(message, partial_content)

    merged_metadata =
      (message.metadata || %{})
      |> Map.merge(%{"error" => error_details})

    case Repo.update_all(
           from(m in Message,
             where: m.id == ^message.id and m.status == "generating",
             select: m
           ),
           [
             set: [
               status: "error",
               content: final_content,
               content_version: current_version + 1,
               metadata: merged_metadata,
               updated_at: DateTime.utc_now(:microsecond)
             ]
           ],
           returning: true
         ) do
      {count, [updated]} when count > 0 ->
        publish_live_event(updated, :response_failed, %{
          error: error_details,
          response_id: "resp_#{updated.id}",
          actor_event_id: updated.metadata["actor_event_id"]
        })

        {:ok, updated}

      {0, []} ->
        {:ok, :already_terminal}
    end
  end

  @doc """
  Publishes a live chunk event for an in-progress response run.

  Live chunks are NOT durable — they are not written to `ai_gateway_messages`.
  They are published via PubSub so SignalsGateway can render IM preview/edit.
  Only stable items or terminal states write to the database (via
  `commit_complete` / `commit_error`).

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
  `previous_message_id` chain from the given anchor (or the latest visible
  leaf if no anchor is given). Returns a list of `%Message{}` rows in
  chronological order.

  Only `complete` rows enter normal projection. `generating` rows from the
  current active actor event are excluded unless the caller explicitly passes
  `include_generating: true` (used for same-actor-event loop continuation,
  see plan §3.8).
  """
  @spec expand_history(binary(), keyword()) :: [Message.t()]
  def expand_history(conversation_id, opts \\ []) do
    with {:ok, conversation_id} <- cast_uuid(conversation_id),
         {:ok, anchor_id} <- history_anchor(conversation_id, opts) do
      include_generating = Keyword.get(opts, :include_generating, false)
      actor_event_id = Keyword.get(opts, :actor_event_id)

      if anchor_id do
        # Walk the chain backward from the anchor, collecting complete rows.
        walk_message_chain(conversation_id, anchor_id, include_generating, actor_event_id)
      else
        []
      end
    else
      {:error, _reason} -> []
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
      latest_visible_leaf_for_uuid(conversation_id)
    else
      {:error, _reason} -> nil
    end
  end

  defp latest_visible_leaf_for_uuid(conversation_id) do
    # Complete messages in this conversation.
    complete_ids =
      Message
      |> where([m], m.conversation_id == ^conversation_id and m.status == "complete")
      |> select([m], m.id)
      |> Repo.all()

    if complete_ids == [] do
      nil
    else
      # Find ids that are NOT referenced as previous_message_id by any other
      # complete message. These are the "leaves".
      referenced_ids =
        Message
        |> where(
          [m],
          m.conversation_id == ^conversation_id and
            m.status == "complete" and
            m.previous_message_id in ^complete_ids
        )
        |> select([m], m.previous_message_id)
        |> distinct(true)
        |> Repo.all()
        |> MapSet.new()

      leaf_ids = Enum.reject(complete_ids, &MapSet.member?(referenced_ids, &1))

      # Pick the latest leaf by inserted_at (deterministic for branching).
      if leaf_ids != [] do
        Message
        |> where([m], m.id in ^leaf_ids)
        |> order_by([m], desc: m.inserted_at, desc: m.id)
        |> limit(1)
        |> select([m], m.id)
        |> Repo.one()
      else
        nil
      end
    end
  end

  @doc """
  Retrieves a single message row by its "resp_{id}" or raw UUID.
  Returns `nil` if not found.
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
             from c in Conversation,
               where:
                 c.id == ^conversation_id and
                   c.agent_uid == ^normalized_uid and
                   is_nil(c.ended_at)
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

  This is the bootstrap entry for a stateful conversation. The conversation row
  holds the active generation lease (see plan §3.6).
  """
  @spec ensure_conversation(String.t(), String.t()) ::
          {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def ensure_conversation(agent_uid, conversation_key) do
    # Try to find an active (non-ended) conversation for this agent+key.
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
      case Repo.one(
             from c in Conversation,
               where:
                 c.agent_uid == ^agent_uid and
                   c.conversation_key == ^conversation_key and
                   is_nil(c.ended_at),
               lock: "FOR UPDATE"
           ) do
        %Conversation{} = conversation ->
          {:ok, conversation}

        nil ->
          %Conversation{}
          |> Conversation.changeset(%{
            agent_uid: agent_uid,
            conversation_key: conversation_key,
            generation: %{},
            metadata: %{}
          })
          |> Repo.insert()
      end
    end
  end

  # ───────────────────────────────────────────────────────────────
  # Internal helpers
  # ───────────────────────────────────────────────────────────────

  # Decodes a "resp_#{uuid}" string to the raw UUID. If already a UUID, returns
  # it as-is. This is the single decode point for previous_response_id (plan §1.4).
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

  # Terminal provider items append to the request-side items saved when the
  # generating row was created. Replacing content would erase user input and
  # function_call_output from the durable Responses history.
  defp durable_terminal_content(%Message{content: existing_content}, terminal_items)
       when is_list(existing_content) and is_list(terminal_items),
       do: existing_content ++ terminal_items

  defp durable_terminal_content(_message, terminal_items) when is_list(terminal_items),
    do: terminal_items

  defp history_anchor(conversation_id, opts) do
    case Keyword.get(opts, :previous_message_id) do
      nil -> {:ok, latest_visible_leaf(conversation_id)}
      previous_message_id -> decode_response_id(previous_message_id)
    end
  end

  # Validates that an anchor message exists, is complete, and belongs to the
  # given conversation. Per plan §3.3: only complete, non-retracted anchors.
  defp validate_anchor(_conversation_id, nil), do: :ok

  defp validate_anchor(conversation_id, message_id) do
    case Repo.one(
           from m in Message,
             where:
               m.id == ^message_id and
                 m.conversation_id == ^conversation_id and
                 m.status == "complete",
             select: m.id
         ) do
      nil -> {:error, :invalid_anchor}
      _id -> :ok
    end
  end

  # Walks the previous_message_id chain backward from the anchor, collecting
  # rows. Stops when previous_message_id is nil or the row is not found.
  # Handles compaction rows by understanding covers_range (simple v1: includes
  # compaction rows in the chain but does not de-duplicate covered ranges —
  # that logic will be added in Step 2 when full compaction is wired).
  defp walk_message_chain(conversation_id, anchor_id, include_generating, actor_event_id) do
    walk_chain(conversation_id, anchor_id, include_generating, actor_event_id, [])
  end

  defp walk_chain(_conversation_id, nil, _include_generating, _actor_event_id, acc), do: acc

  defp walk_chain(conversation_id, message_id, include_generating, actor_event_id, acc) do
    case Repo.get(Message, message_id) do
      nil ->
        acc

      %Message{} = message ->
        if message.conversation_id == conversation_id do
          # Determine if this row should be included in projection.
          include? =
            case {message.status, message.metadata["actor_event_id"]} do
              {status, _} when status in ["complete"] ->
                true

              {"generating", ae_id} when include_generating ->
                # Only include generating rows from the same actor event.
                ae_id == actor_event_id

              _ ->
                false
            end

          new_acc = if include?, do: [message | acc], else: acc

          walk_chain(
            conversation_id,
            message.previous_message_id,
            include_generating,
            actor_event_id,
            new_acc
          )
        else
          acc
        end
    end
  end

  # Publishes a live event to the PubSub topic keyed by actor_event_id.
  # This lets the preview handler subscribe once per actor event and receive
  # all loop-round events (started/chunk/completed/failed) without re-subscribing
  # on each round (each round has a different message_id but same actor_event_id).
  defp publish_live_event(%Message{} = message, event_type, payload) do
    actor_event_id = message.metadata["actor_event_id"]
    topic = live_topic(actor_event_id)

    # Include message_id in payload so the handler can correlate.
    full_payload = Map.put(payload, :message_id, message.id)

    Phoenix.PubSub.broadcast(
      @pubsub,
      topic,
      {:ai_gateway_event, event_type, message.id, full_payload}
    )
  end

  # PubSub topic keyed by actor_event_id (stable across loop rounds).
  defp live_topic(actor_event_id), do: "ai_gateway:actor_event:#{actor_event_id}"

  # Ensures the message is loaded from the DB if only an id was given.
  defp ensure_loaded(%Message{} = message), do: message
  defp ensure_loaded(id) when is_binary(id), do: Repo.get(Message, id)
end
