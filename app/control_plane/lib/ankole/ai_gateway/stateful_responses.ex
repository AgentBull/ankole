defmodule Ankole.AIGateway.StatefulResponses do
  @moduledoc """
  Durable stateful Responses owner for AIGateway.

  This module sits between the AIGateway transport entry (WebSocket
  `response.create` / HTTP `POST /responses`) and the provider request build.
  For each stateful `response.create + store=true` run it:

    1. Resolves `previous_response_id` / `conversation` into a message chain.
    2. Creates one `ai_gateway_messages` row with `status = "generating"`.
    3. Returns the row so the transport can build the provider-facing input
       (expanded history + current request items) and call the provider.
    4. Publishes generic response events keyed by the owning conversation.
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
  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.Conversations
  alias Ankole.AIGateway.Events
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.RuntimeEvents

  @orphaned_generating_grace_seconds 300
  @history_chain_max_depth 10_000
  @public_chain_max_depth 500

  # ───────────────────────────────────────────────────────────────
  # Public API
  # ───────────────────────────────────────────────────────────────

  @doc """
  Starts a stateful response run: creates a `generating` message row.

  ## Parameters

    * `attrs` — a map with:
      - `subject_uid` (required) — the owning principal uid
      - `conversation_id` (required) — the ai_gateway_conversations.id
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
             | :stateful_anchor_conflict}
  def start_response_run(attrs) do
    raw_subject_uid = Map.fetch!(attrs, :subject_uid)
    conversation_id = conversation_id(attrs)
    previous_response_id = previous_response_id(attrs)

    with {:ok, subject_uid} <- Principals.normalize_uid(raw_subject_uid),
         :ok <- validate_anchor_selector(conversation_id, previous_response_id),
         {:ok, previous_message_id} <- decode_optional_response_id(previous_response_id),
         {:ok, conversation} <-
           resolve_run_conversation(subject_uid, conversation_id, previous_message_id) do
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

      insert_response_run(%{
        subject_uid: subject_uid,
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
             | :invalid_tool_results}
  def record_tool_results(attrs) when is_map(attrs) do
    raw_subject_uid = Map.fetch!(attrs, :subject_uid)
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

    with {:ok, subject_uid} <- Principals.normalize_uid(raw_subject_uid),
         :ok <- validate_tool_result_items(request_items),
         {:ok, previous_message_id} <- decode_response_id(previous_response_id),
         %Message{status: "complete"} = anchor <-
           complete_message_for_subject(subject_uid, previous_message_id) do
      idempotency_key =
        tool_result_idempotency_key(subject_uid, previous_message_id, request_items)

      merged_metadata =
        extra_metadata
        |> Map.merge(request_items_metadata(request_items))
        |> Map.merge(%{
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
         subject_uid: subject_uid,
         conversation_id: conversation_id,
         previous_message_id: previous_message_id,
         initial_content: initial_content,
         merged_metadata: merged_metadata
       }) do
    changeset =
      %Message{}
      |> Message.changeset(%{
        subject_uid: subject_uid,
        conversation_id: conversation_id,
        type: "message",
        status: "generating",
        previous_message_id: previous_message_id,
        content: initial_content,
        metadata: merged_metadata
      })

    case Repo.transact(fn repo ->
           with {:ok, message} <- repo.insert(changeset),
                :ok <- notify_ai_message_deadline(repo, message) do
             {:ok, message}
           end
         end) do
      {:ok, %Message{} = message} ->
        Events.publish(message, :response_started, %{})
        {:ok, message}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}

      {:error, _reason} = error ->
        error
    end
  end

  defp insert_tool_result_journal(
         %Message{} = anchor,
         request_items,
         merged_metadata,
         idempotency_key
       ) do
    case fetch_tool_result_journal(anchor.subject_uid, idempotency_key) do
      {:ok, %Message{} = message} ->
        publish_tool_result_events(message, request_items)
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
        subject_uid: anchor.subject_uid,
        conversation_id: anchor.conversation_id,
        type: "message",
        status: "complete",
        previous_message_id: anchor.id,
        content: request_items,
        metadata: merged_metadata
      })

    case Repo.insert(changeset) do
      {:ok, %Message{} = message} ->
        publish_tool_result_events(message, request_items)
        {:ok, message}

      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_constraint_error?(
             changeset,
             "ai_gateway_messages_tool_result_journal_key_index"
           ) do
          case fetch_tool_result_journal(anchor.subject_uid, idempotency_key) do
            {:ok, %Message{} = message} = result ->
              publish_tool_result_events(message, request_items)
              result

            {:error, _reason} = error ->
              error
          end
        else
          {:error, changeset}
        end
    end
  end

  defp fetch_tool_result_journal(subject_uid, idempotency_key) do
    case Repo.one(
           from(message in Message,
             where: message.subject_uid == ^subject_uid,
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

  defp publish_tool_result_events(%Message{} = message, request_items) do
    request_items
    |> Enum.filter(&function_call_output_item?/1)
    |> Enum.each(fn item ->
      Events.publish(
        message,
        :tool_call_completed,
        item |> Map.take(["call_id", "name", "output"]) |> Map.put_new("seq", nil)
      )
    end)
  end

  defp validate_tool_result_items(request_items) when is_list(request_items) do
    case Enum.any?(request_items, &function_call_output_item?/1) do
      true -> :ok
      false -> {:error, :invalid_tool_results}
    end
  end

  defp validate_tool_result_items(_request_items), do: {:error, :invalid_tool_results}

  defp tool_result_idempotency_key(subject_uid, previous_message_id, request_items) do
    stable_term = {subject_uid, previous_message_id, request_items}

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

  @doc false
  @spec runtime_event_snapshot() :: [{String.t(), map()}]
  def runtime_event_snapshot do
    generating_messages_query()
    |> Repo.all()
    |> Enum.map(fn message ->
      {RuntimeEvents.ai_message_deadline_channel(),
       %{
         "message_id" => message.id,
         "orphan_at" => RuntimeEvents.encode_datetime(ai_message_orphan_at(message))
       }}
    end)
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

  defp lock_generating_message_by_id(repo, message_id) do
    generating_messages_query()
    |> where([message], message.id == ^message_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  @doc """
  Refreshes a generating response lease and schedules its next orphan deadline.
  """
  @spec touch_generating_response(String.t(), binary()) ::
          {:ok, Message.t() | :already_terminal} | {:error, :not_found | term()}
  def touch_generating_response(subject_uid, response_id) do
    now = DateTime.utc_now(:microsecond)

    with {:ok, subject_uid} <- Principals.normalize_uid(subject_uid),
         {:ok, message_id} <- decode_response_id(response_id) do
      Repo.transact(fn repo ->
        case repo.update_all(
               from(message in Message,
                 where:
                   message.id == ^message_id and
                     message.subject_uid == ^subject_uid and
                     message.status == "generating",
                 select: message
               ),
               [set: [updated_at: now]],
               returning: true
             ) do
          {1, [%Message{} = message]} ->
            with :ok <- notify_ai_message_deadline(repo, message), do: {:ok, message}

          {0, []} ->
            case repo.get_by(Message, id: message_id, subject_uid: subject_uid) do
              %Message{} -> {:ok, :already_terminal}
              nil -> {:error, :not_found}
            end
        end
      end)
    else
      _invalid -> {:error, :not_found}
    end
  end

  @doc """
  Marks one explicitly identified generating response as failed.
  """
  @spec fail_generating_response(String.t(), binary(), map()) ::
          {:ok, Message.t() | :already_terminal} | {:error, :not_found | term()}
  def fail_generating_response(subject_uid, response_id, error_details)
      when is_map(error_details) do
    now = DateTime.utc_now(:microsecond)

    case Repo.transact(fn repo ->
           fail_generating_response_in_tx(
             repo,
             subject_uid,
             response_id,
             error_details,
             now
           )
         end) do
      {:ok, %Message{} = message} = ok ->
        Events.publish(message, :response_failed, %{error: error_details})
        ok

      other ->
        other
    end
  end

  @doc """
  Transactional variant of `fail_generating_response/3` for callers that own a
  wider transaction. It has no domain-specific side effects.
  """
  @spec fail_generating_response_in_tx(module(), String.t(), binary(), map(), DateTime.t()) ::
          {:ok, Message.t() | :already_terminal} | {:error, :not_found | term()}
  def fail_generating_response_in_tx(repo, subject_uid, response_id, error_details, now)
      when is_map(error_details) do
    with {:ok, subject_uid} <- Principals.normalize_uid(subject_uid),
         {:ok, message_id} <- decode_response_id(response_id) do
      case lock_response_for_subject(repo, subject_uid, message_id) do
        %Message{status: "generating"} = message ->
          metadata = Map.put(message.metadata || %{}, "error", error_details)

          case repo.update_all(
                 from(candidate in Message,
                   where: candidate.id == ^message.id and candidate.status == "generating",
                   select: candidate
                 ),
                 [set: [status: "error", metadata: metadata, updated_at: now]],
                 returning: true
               ) do
            {1, [%Message{} = updated]} -> {:ok, updated}
            {0, []} -> {:ok, :already_terminal}
          end

        %Message{} ->
          {:ok, :already_terminal}

        nil ->
          {:error, :not_found}
      end
    else
      _invalid -> {:error, :not_found}
    end
  end

  @doc """
  Reconciles one orphan deadline using only the response row's own heartbeat.
  """
  @spec reconcile_orphaned_response(binary(), keyword()) ::
          {:ok, :failed | :live | :already_terminal} | {:error, term()}
  def reconcile_orphaned_response(response_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    case Repo.transact(fn repo ->
           with {:ok, message_id} <- decode_response_id(response_id) do
             case lock_generating_message_by_id(repo, message_id) do
               %Message{} = message ->
                 if generating_message_stale?(message, now) do
                   error = %{
                     "code" => "orphaned_generating_response",
                     "reason" => "response heartbeat expired before a terminal commit",
                     "stage" => "ai_message_deadline",
                     "retryable" => true
                   }

                   with {:ok, %Message{} = failed} <-
                          fail_generating_response_in_tx(
                            repo,
                            message.subject_uid,
                            message.id,
                            error,
                            now
                          ) do
                     {:ok, {:failed, failed, error}}
                   end
                 else
                   with :ok <- notify_ai_message_deadline(repo, message), do: {:ok, :live}
                 end

               nil ->
                 {:ok, :already_terminal}
             end
           end
         end) do
      {:ok, {:failed, %Message{} = message, error}} ->
        Events.publish(message, :response_failed, %{error: error})
        {:ok, :failed}

      other ->
        other
    end
  end

  defp lock_response_for_subject(repo, subject_uid, message_id) do
    Message
    |> where([message], message.id == ^message_id)
    |> where([message], message.subject_uid == ^subject_uid)
    |> lock("FOR UPDATE")
    |> repo.one()
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
    now = DateTime.utc_now(:microsecond)

    case Repo.transact(fn repo ->
           case lock_generating_message_by_id(repo, message.id) do
             %Message{} = current_message ->
               merged_metadata = Map.merge(current_message.metadata || %{}, extra_metadata)

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
                   {:ok, updated}

                 {0, []} ->
                   {:ok, :already_terminal}
               end

             nil ->
               {:ok, :already_terminal}
           end
         end) do
      {:ok, %Message{} = updated} ->
        Events.publish(updated, complete_event_type(updated), %{content: final_content})

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
    extra_metadata = Keyword.get(opts, :metadata, %{})

    case Repo.transact(fn repo ->
           case lock_generating_message_by_id(repo, message.id) do
             %Message{} = current_message ->
               merged_metadata =
                 (current_message.metadata || %{})
                 |> Map.merge(extra_metadata)
                 |> Map.merge(%{"error" => error_details})

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
                   {:ok, updated}

                 {0, []} ->
                   {:ok, :already_terminal}
               end

             nil ->
               {:ok, :already_terminal}
           end
         end) do
      {:ok, %Message{} = updated} ->
        Events.publish(updated, :response_failed, %{error: error_details})

        {:ok, updated}

      {:ok, :already_terminal} ->
        {:ok, :already_terminal}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Publishes a terminal live event for a response row that was moved to a terminal
  state outside the normal WebSocket commit path.
  """
  @spec publish_terminal_event(
          Message.t(),
          :response_completed | :response_incomplete | :response_failed,
          map()
        ) :: :ok
  def publish_terminal_event(%Message{} = message, event_type, payload)
      when event_type in [:response_completed, :response_incomplete, :response_failed] do
    Events.publish(message, event_type, payload)
  end

  defp complete_event_type(%Message{metadata: %{"response" => %{"status" => "incomplete"}}}),
    do: :response_incomplete

  defp complete_event_type(%Message{metadata: %{"incomplete_details" => details}})
       when is_map(details),
       do: :response_incomplete

  defp complete_event_type(_message), do: :response_completed

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
        walk_message_chain(
          conversation_id,
          anchor_id,
          Keyword.get(opts, :protected_tail_items, [])
        )
      else
        []
      end
    else
      {:error, _reason} -> []
    end
  end

  @doc """
  Lists an immutable response chain from the requested response backwards.

  Rows are returned final-first and include checkpoints. Traversal is capped at
  500 rows even when a larger limit is requested.
  """
  @spec list_response_chain(String.t(), binary(), pos_integer()) ::
          {:ok, [Message.t()]} | {:error, :not_found}
  def list_response_chain(subject_uid, response_id, max_depth \\ @public_chain_max_depth) do
    max_depth = normalize_public_chain_depth(max_depth)

    with {:ok, %Message{} = final} <- get_response_for_subject(subject_uid, response_id) do
      {:ok, chain_messages(Repo, final.conversation_id, final.id, max_depth)}
    end
  end

  @doc """
  Lists Response rows for one owned conversation inside a caller transaction.

  This is a generic Response query. Callers may filter by lifecycle status, but
  AIGateway does not interpret caller metadata or choose an Actor target.
  """
  @spec list_conversation_responses_in_tx(module(), String.t(), binary(), keyword()) ::
          {:ok, [Message.t()]} | {:error, :invalid_conversation}
  def list_conversation_responses_in_tx(repo, subject_uid, conversation_id, opts \\ []) do
    statuses = Keyword.get(opts, :statuses)

    with {:ok, subject_uid} <- Principals.normalize_uid(subject_uid),
         {:ok, conversation_id} <- cast_uuid(conversation_id),
         %Conversation{} <- lock_owned_conversation(repo, subject_uid, conversation_id) do
      query =
        Message
        |> where([message], message.subject_uid == ^subject_uid)
        |> where([message], message.conversation_id == ^conversation_id)
        |> order_by([message], desc: message.inserted_at, desc: message.id)
        |> maybe_filter_response_statuses(statuses)
        |> maybe_lock_response_rows(Keyword.get(opts, :lock, false))

      {:ok, repo.all(query)}
    else
      _invalid_or_missing -> {:error, :invalid_conversation}
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
  Hard deletes an explicitly selected, contiguous visible response suffix.

  `response_ids` must be ordered newest-first and must exactly match the current
  complete leaf suffix. AIGateway never chooses the suffix from caller metadata.
  """
  @spec hard_delete_visible_suffix_in_tx(
          module(),
          String.t(),
          binary(),
          [binary()],
          keyword()
        ) ::
          {:ok,
           %{
             required(:status) => :deleted | :noop,
             required(:deleted_message_ids) => [binary()],
             required(:deleted_count) => non_neg_integer(),
             optional(:reason) => atom()
           }}
          | {:error, term()}
  def hard_delete_visible_suffix_in_tx(
        repo,
        subject_uid,
        conversation_id,
        response_ids,
        _opts \\ []
      ) do
    with {:ok, subject_uid} <- Principals.normalize_uid(subject_uid),
         {:ok, conversation_id} <- cast_uuid(conversation_id),
         {:ok, message_ids} <- decode_response_ids(response_ids),
         %Conversation{} <- lock_owned_conversation(repo, subject_uid, conversation_id) do
      delete_visible_suffix(repo, conversation_id, message_ids)
    else
      nil -> {:ok, tail_delete_noop(:conversation_not_found)}
      {:error, _reason} -> {:error, :invalid_response_suffix}
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

  defp delete_visible_suffix(_repo, _conversation_id, []),
    do: {:ok, tail_delete_noop(:empty_suffix)}

  defp delete_visible_suffix(repo, conversation_id, message_ids) do
    case latest_visible_leaf_for_uuid(repo, conversation_id) do
      nil ->
        {:ok, tail_delete_noop(:no_visible_leaf)}

      leaf_id ->
        visible_suffix =
          repo
          |> chain_messages(conversation_id, leaf_id, length(message_ids))
          |> Enum.map(& &1.id)

        cond do
          visible_suffix != message_ids ->
            {:ok, tail_delete_noop(:not_visible_suffix)}

          not deletable_response_rows?(repo, conversation_id, message_ids) ->
            {:error, :invalid_response_suffix}

          response_suffix_has_external_children?(repo, conversation_id, message_ids) ->
            {:error, :response_suffix_has_descendants}

          true ->
            {deleted_count, _} =
              Message
              |> where([message], message.id in ^message_ids)
              |> repo.delete_all()

            {:ok,
             %{
               status: :deleted,
               deleted_message_ids: message_ids,
               deleted_count: deleted_count
             }}
        end
    end
  end

  defp lock_owned_conversation(repo, subject_uid, conversation_id) do
    Conversation
    |> where([conversation], conversation.id == ^conversation_id)
    |> where([conversation], conversation.subject_uid == ^subject_uid)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp deletable_response_rows?(repo, conversation_id, message_ids) do
    count =
      Message
      |> where([message], message.id in ^message_ids)
      |> where([message], message.conversation_id == ^conversation_id)
      |> where([message], message.type == "message")
      |> where([message], message.status == "complete")
      |> repo.aggregate(:count)

    count == length(message_ids)
  end

  defp response_suffix_has_external_children?(repo, conversation_id, message_ids) do
    Message
    |> where([message], message.conversation_id == ^conversation_id)
    |> where([message], message.previous_message_id in ^message_ids)
    |> where([message], message.id not in ^message_ids)
    |> where([message], message.status == "complete")
    |> repo.exists?()
  end

  defp decode_response_ids(response_ids) when is_list(response_ids) do
    Enum.reduce_while(response_ids, {:ok, []}, fn response_id, {:ok, ids} ->
      case decode_response_id(response_id) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        {:error, _reason} -> {:halt, {:error, :invalid_response_id}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_response_ids(_response_ids), do: {:error, :invalid_response_id}

  defp normalize_public_chain_depth(depth) when is_integer(depth) and depth > 0,
    do: min(depth, @public_chain_max_depth)

  defp normalize_public_chain_depth(_depth), do: @public_chain_max_depth

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
  Returns the exact caller-supplied metadata object for a stored response.
  """
  @spec response_metadata(Message.t()) :: map()
  def response_metadata(%Message{metadata: %{"request_metadata" => metadata}})
      when is_map(metadata),
      do: metadata

  def response_metadata(%Message{}), do: %{}

  @doc """
  Retrieves a stored response row scoped to one principal subject.
  """
  @spec get_response_for_subject(String.t(), binary()) ::
          {:ok, Message.t()} | {:error, :not_found}
  def get_response_for_subject(subject_uid, resp_or_id) do
    with {:ok, subject_uid} <- Principals.normalize_uid(subject_uid),
         {:ok, id} <- decode_response_id(resp_or_id),
         %Message{} = message <-
           Repo.one(
             from(m in Message,
               where: m.id == ^id and m.subject_uid == ^subject_uid
             )
           ) do
      {:ok, message}
    else
      _not_found_or_invalid -> {:error, :not_found}
    end
  end

  @doc """
  Writes one response-chain checkpoint that points at a compaction artifact.

  The checkpoint and artifact share the same raw UUID. The checkpoint is only a
  continuation anchor; provider replay loads the artifact output from
  `ai_gateway_compaction_artifacts`.
  """
  @spec create_compaction_checkpoint(map()) ::
          {:ok, Message.t()}
          | {:error,
             :invalid_anchor
             | :invalid_conversation
             | :stateful_anchor_conflict
             | Ecto.Changeset.t()}
  def create_compaction_checkpoint(attrs) when is_map(attrs) do
    raw_subject_uid = Map.fetch!(attrs, :subject_uid)
    artifact = Map.fetch!(attrs, :artifact)
    metadata = Map.get(attrs, :metadata, Map.get(attrs, "metadata", %{}))
    conversation_id = conversation_id(attrs)
    previous_response_id = previous_response_id(attrs)

    with {:ok, subject_uid} <- Principals.normalize_uid(raw_subject_uid),
         {:ok, previous_message_id} <- decode_optional_response_id(previous_response_id),
         {:ok, conversation_id, previous_message_id} <-
           resolve_checkpoint_chain(subject_uid, conversation_id, previous_message_id, artifact) do
      insert_checkpoint_row(
        subject_uid,
        conversation_id,
        previous_message_id,
        artifact.id,
        metadata
      )
    else
      {:error, :invalid_response_id} -> {:error, :invalid_anchor}
      {:error, :invalid_uuid} -> {:error, :invalid_conversation}
      {:error, :invalid_uid} -> {:error, :invalid_conversation}
      false -> {:error, :invalid_anchor}
      nil -> {:error, :invalid_anchor}
      {:error, _reason} = error -> error
      _not_found_or_invalid -> {:error, :invalid_anchor}
    end
  end

  @doc """
  Loads an active conversation by id and owning subject.

  This is used at stateful request boundaries so a caller cannot attach a new
  response run to another subject's conversation or expand another subject's history.
  """
  @spec get_conversation_for_subject(String.t(), String.t()) ::
          {:ok, Conversation.t()} | {:error, :invalid_conversation}
  def get_conversation_for_subject(subject_uid, conversation_id) do
    with {:ok, normalized_uid} <- Principals.normalize_uid(subject_uid),
         {:ok, conversation_id} <- cast_uuid(conversation_id),
         %Conversation{} = conversation <-
           Repo.one(
             from(c in Conversation,
               where:
                 c.id == ^conversation_id and
                   c.subject_uid == ^normalized_uid and
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
  Ensures a conversation exists for the given subject + key, creating one if needed.

  This is the bootstrap entry for a stateful conversation.
  """
  @spec ensure_conversation(String.t(), String.t(), keyword()) ::
          {:ok, Conversation.t()} | {:error, term()}
  def ensure_conversation(subject_uid, conversation_key, opts \\ []) do
    Conversations.ensure_conversation(subject_uid, conversation_key, opts)
  end

  @doc """
  Creates a conversation implicitly for stateful Responses callers that start
  with `store=true` and no explicit conversation or previous response anchor.
  """
  @spec create_managed_stateful_responses_conversation(String.t(), keyword()) ::
          {:ok, Conversation.t()} | {:error, term()}
  def create_managed_stateful_responses_conversation(subject_uid, opts \\ []) do
    Conversations.create_managed_stateful_responses_conversation(subject_uid, opts)
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

  defp resolve_run_conversation(subject_uid, conversation_id, nil),
    do: get_conversation_for_subject(subject_uid, conversation_id)

  defp resolve_run_conversation(subject_uid, nil, previous_message_id) do
    case Repo.one(
           from(m in Message,
             join: c in Conversation,
             on: c.id == m.conversation_id,
             where:
               m.id == ^previous_message_id and
                 m.status == "complete" and
                 c.subject_uid == ^subject_uid and
                 is_nil(c.ended_at),
             select: c
           )
         ) do
      %Conversation{} = conversation -> {:ok, conversation}
      nil -> {:error, :invalid_anchor}
    end
  end

  defp complete_message_for_subject(subject_uid, message_id) do
    Repo.one(
      from(m in Message,
        where:
          m.id == ^message_id and
            m.subject_uid == ^subject_uid and
            m.status == "complete"
      )
    )
  end

  defp resolve_checkpoint_chain(subject_uid, conversation_id, previous_message_id, artifact) do
    case previous_message_id do
      nil ->
        with conversation_id when is_binary(conversation_id) <-
               conversation_id || artifact.conversation_id,
             {:ok, conversation} <-
               get_conversation_for_subject(subject_uid, conversation_id) do
          {:ok, conversation.id, nil}
        end

      previous_message_id ->
        with %Message{conversation_id: anchor_conversation_id} <-
               complete_message_for_subject(subject_uid, previous_message_id),
             {:ok, conversation} <-
               get_conversation_for_subject(
                 subject_uid,
                 conversation_id || anchor_conversation_id
               ),
             true <- conversation.id == anchor_conversation_id do
          {:ok, conversation.id, previous_message_id}
        end
    end
  end

  defp insert_checkpoint_row(
         subject_uid,
         conversation_id,
         previous_message_id,
         artifact_id,
         metadata
       ) do
    %Message{id: artifact_id}
    |> Message.changeset(%{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      type: "checkpoint",
      status: "complete",
      previous_message_id: previous_message_id,
      content: [CompactionArtifacts.ref_item(artifact_id)],
      metadata: metadata
    })
    |> Repo.insert()
  end

  # Terminal provider items append to the request-side items saved when the
  # generating row was created. Replacing content would erase user input and
  # function_call_output from the durable Responses history.
  defp durable_terminal_content(%Message{content: existing_content}, terminal_items)
       when is_list(existing_content) and is_list(terminal_items),
       do: existing_content ++ terminal_items

  defp durable_terminal_content(_message, terminal_items) when is_list(terminal_items),
    do: terminal_items

  defp notify_ai_message_deadline(repo, %Message{} = message) do
    RuntimeEvents.notify_ai_message_deadline(repo, message, ai_message_orphan_at(message))
  end

  defp ai_message_orphan_at(%Message{} = message) do
    base_at = message.updated_at || message.inserted_at || DateTime.utc_now(:microsecond)
    DateTime.add(base_at, orphaned_generating_grace_seconds(), :second)
  end

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
  # provider-visible rows. A checkpoint row is a hard provider-visible boundary:
  # its artifact output replaces the older prefix, while the raw chain remains
  # available to audit and function-call counting through `chain_messages/4`.
  defp walk_message_chain(conversation_id, anchor_id, protected_tail_items) do
    walk_message_chain(Repo, conversation_id, anchor_id, protected_tail_items)
  end

  defp walk_message_chain(repo, conversation_id, anchor_id, protected_tail_items) do
    messages = chain_messages(repo, conversation_id, anchor_id)
    messages_by_id = Map.new(messages, &{&1.id, &1})

    walk_chain(messages_by_id, anchor_id, [], MapSet.new(), protected_tail_items)
  end

  defp chain_messages(repo, conversation_id, anchor_id, max_depth \\ @history_chain_max_depth) do
    ids = chain_message_ids(repo, conversation_id, anchor_id, max_depth)

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

  defp chain_message_ids(repo, conversation_id, anchor_id, max_depth) do
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
        [anchor_id, conversation_id, max_depth]
      )

    Enum.map(result.rows, fn [id] -> id end)
  end

  defp walk_chain(_messages_by_id, nil, acc, _seen, _protected_tail_items), do: acc

  defp walk_chain(messages_by_id, message_id, acc, seen, protected_tail_items) do
    cond do
      MapSet.member?(seen, message_id) ->
        acc

      true ->
        case Map.fetch(messages_by_id, message_id) do
          {:ok, %Message{} = message} ->
            include? = project_message?(message)
            seen = MapSet.put(seen, message_id)

            new_acc = if include?, do: [message | acc], else: acc

            if include? and message.type == "checkpoint" do
              new_acc
            else
              walk_chain(
                messages_by_id,
                message.previous_message_id,
                new_acc,
                seen,
                protected_tail_items
              )
            end

          :error ->
            acc
        end
    end
  end

  defp project_message?(%Message{status: "complete"}), do: true
  defp project_message?(_message), do: false

  defp maybe_filter_response_statuses(query, nil), do: query

  defp maybe_filter_response_statuses(query, statuses) when is_list(statuses),
    do: where(query, [message], message.status in ^statuses)

  defp maybe_filter_response_statuses(query, _statuses), do: query

  defp maybe_lock_response_rows(query, true), do: lock(query, "FOR UPDATE")
  defp maybe_lock_response_rows(query, _lock?), do: query

  defp maybe_put_metadata(map, _key, nil), do: map
  defp maybe_put_metadata(map, _key, ""), do: map
  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  # Ensures the message is loaded from the DB if only an id was given.
  defp ensure_loaded(%Message{} = message), do: message
  defp ensure_loaded(id) when is_binary(id), do: Repo.get(Message, id)
end
