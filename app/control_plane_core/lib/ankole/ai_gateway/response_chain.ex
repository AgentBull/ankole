defmodule Ankole.AIGateway.ResponseChain do
  @moduledoc "Tenant-scoped Response chain queries, checkpoints and visible suffix changes."
  require Ash.Query
  alias Ecto.Adapters.SQL
  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.ResponseItems
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.{Principals, Repo}
  @history_chain_max_depth 10_000
  @public_chain_max_depth 500

  @doc """
  Expands the message chain for history projection.

  Reads `complete` message rows in the conversation, following the
  `previous_message_id` chain from the given response anchor (or the latest visible
  leaf if no anchor is given). Returns a list of `%Message{}` rows in
  chronological order.

  Only `complete` rows enter normal projection. `generating` rows are never
  projected; a client continuation must reference the previous
  round's committed `complete` response.
  """
  @spec expand_history(binary(), keyword()) :: [Message.t()]
  def expand_history(conversation_id, opts \\ []) do
    with {:ok, conversation_id} <- cast_uuid(conversation_id),
         {:ok, anchor_id} <- history_anchor(conversation_id, opts) do
      if anchor_id do
        walk_message_chain(
          conversation_id,
          anchor_id,
          Keyword.get(opts, :stop_at_checkpoint, true)
        )
      else
        []
      end
    else
      {:error, _reason} -> []
    end
  end

  @doc "Reads the visible complete chain of one owned conversation."
  def visible_response_chain(subject_uid, conversation_id, opts \\ []) do
    with {:ok, conversation} <- get_conversation_for_subject(subject_uid, conversation_id) do
      {:ok, expand_history(conversation.id, opts)}
    end
  end

  @doc """
  Reads caller metadata from complete ordinary rows on the visible branch.

  Checkpoints connect the ancestry but do not contribute metadata. This read
  crosses checkpoints and returns no Response content. The raw ancestor limit
  is the same 10,000 rows used for history expansion.
  """
  @spec visible_response_metadata(String.t(), binary()) ::
          {:ok, [map()]} | {:error, :invalid_conversation}
  def visible_response_metadata(subject_uid, conversation_id) do
    with {:ok, conversation} <- get_conversation_for_subject(subject_uid, conversation_id) do
      case latest_visible_leaf(conversation.id) do
        nil -> {:ok, []}
        leaf -> {:ok, chain_metadata(conversation.id, leaf)}
      end
    end
  end

  @doc """
  Reads a visible suffix selected by one opaque caller-metadata string value.

  Rows and ordinary responses are chronological. Checkpoints and incomplete
  rows are crossed but omitted. Unmatched tool journals are also crossed; the
  first complete ordinary response that does not match ends the suffix. The
  selected visible leaf is returned even when the suffix is empty.
  """
  @spec visible_response_suffix(String.t(), binary(), {String.t(), String.t()}) ::
          {:ok,
           %{
             leaf: binary() | nil,
             rows: [Message.t()],
             responses: [Message.t()],
             recorded_call_ids: MapSet.t()
           }}
          | {:error, :invalid_conversation | :invalid_metadata_selector}
  def visible_response_suffix(subject_uid, conversation_id, {key, value})
      when is_binary(key) and key != "" and is_binary(value) do
    with {:ok, conversation} <- get_conversation_for_subject(subject_uid, conversation_id) do
      leaf = latest_visible_leaf(conversation.id)
      rows = if leaf, do: suffix_messages(conversation.id, leaf, key, value), else: []
      responses = Enum.reject(rows, &journal?/1)
      latest = List.last(responses)

      recorded_call_ids =
        rows
        |> Enum.filter(&(latest && journal?(&1) && &1.previous_message_id == latest.id))
        |> Enum.flat_map(& &1.content)
        |> Enum.filter(&ResponseItems.output_item?/1)
        |> Enum.map(& &1[ResponseItems.pair_identity_field(&1)])
        |> MapSet.new()

      {:ok, %{leaf: leaf, rows: rows, responses: responses, recorded_call_ids: recorded_call_ids}}
    end
  end

  def visible_response_suffix(_subject_uid, _conversation_id, _selector),
    do: {:error, :invalid_metadata_selector}

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
      {:ok, chain_messages(final.conversation_id, final.id, max_depth)}
    end
  end

  @doc """
  Lists Response rows for one owned conversation inside a caller transaction.

  This is a generic Response query. Callers may filter by lifecycle status, but
  AIGateway does not interpret caller metadata or choose an Actor target.
  """
  @spec list_conversation_responses_in_tx(module(), String.t(), binary(), keyword()) ::
          {:ok, [Message.t()]} | {:error, :invalid_conversation}
  def list_conversation_responses_in_tx(_repo, subject_uid, conversation_id, opts \\ []) do
    statuses = Keyword.get(opts, :statuses)

    with {:ok, subject_uid} <- Principals.normalize_uid(subject_uid),
         {:ok, conversation_id} <- cast_uuid(conversation_id),
         %Conversation{} <- lock_owned_conversation(subject_uid, conversation_id) do
      responses =
        Message
        |> Ash.Query.filter(subject_uid == ^subject_uid and conversation_id == ^conversation_id)
        |> Ash.Query.sort(inserted_at: :desc, id: :desc)
        |> maybe_filter_response_statuses(statuses)
        |> maybe_lock_response_rows(Keyword.get(opts, :lock, false))
        |> Ankole.Ash.read!()

      {:ok, responses}
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
      latest_visible_leaf_for_uuid(conversation_id)
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
        _repo,
        subject_uid,
        conversation_id,
        response_ids,
        _opts \\ []
      ) do
    with {:ok, subject_uid} <- Principals.normalize_uid(subject_uid),
         {:ok, conversation_id} <- cast_uuid(conversation_id),
         {:ok, message_ids} <- decode_response_ids(response_ids),
         %Conversation{} <- lock_owned_conversation(subject_uid, conversation_id) do
      delete_visible_suffix(conversation_id, message_ids)
    else
      nil -> {:ok, tail_delete_noop(:conversation_not_found)}
      {:error, _reason} -> {:error, :invalid_response_suffix}
    end
  end

  @doc """
  Retracts an explicitly selected, contiguous visible response suffix.

  Unlike hard deletion, retraction preserves every row as an audit fact while
  excluding it from future history expansion and automatic continuation.
  `response_ids` must be ordered newest-first and exactly match the current
  complete leaf suffix.
  """
  @spec retract_visible_suffix_in_tx(
          module(),
          String.t(),
          binary(),
          [binary()],
          keyword()
        ) ::
          {:ok,
           %{
             required(:status) => :retracted | :noop,
             required(:retracted_message_ids) => [binary()],
             required(:retracted_count) => non_neg_integer(),
             optional(:reason) => atom()
           }}
          | {:error, term()}
  def retract_visible_suffix_in_tx(_repo, subject_uid, conversation_id, response_ids, opts \\ []) do
    with {:ok, subject_uid} <- Principals.normalize_uid(subject_uid),
         {:ok, conversation_id} <- cast_uuid(conversation_id),
         {:ok, message_ids} <- decode_response_ids(response_ids),
         %Conversation{} <- lock_owned_conversation(subject_uid, conversation_id) do
      retract_visible_suffix(conversation_id, message_ids, opts)
    else
      nil -> {:ok, tail_retraction_noop(:conversation_not_found)}
      {:error, _reason} -> {:error, :invalid_response_suffix}
    end
  end

  @doc false
  def latest_visible_leaf_for_uuid(conversation_id) do
    Message
    |> Ash.Query.filter(
      conversation_id == ^conversation_id and status == :complete and
        not exists(
          Message,
          conversation_id == parent(conversation_id) and status == :complete and
            previous_message_id == parent(id)
        )
    )
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.Query.select([:id])
    |> Ankole.Ash.read_one!()
    |> case do
      %Message{id: id} -> id
      nil -> nil
    end
  end

  defp delete_visible_suffix(_conversation_id, []),
    do: {:ok, tail_delete_noop(:empty_suffix)}

  defp delete_visible_suffix(conversation_id, message_ids) do
    case validate_current_visible_suffix(conversation_id, message_ids) do
      :ok ->
        deleted =
          case Message
               |> Ash.Query.filter(id in ^message_ids)
               |> Ankole.Ash.destroy_where(:remove_suffix, %{}, select: [:id]) do
            {:ok, records} -> records
            {:error, error} -> raise error
          end

        {:ok,
         %{
           status: :deleted,
           deleted_message_ids: message_ids,
           deleted_count: length(deleted)
         }}

      {:noop, reason} ->
        {:ok, tail_delete_noop(reason)}

      {:error, _reason} = error ->
        error
    end
  end

  defp retract_visible_suffix(_conversation_id, [], _opts),
    do: {:ok, tail_retraction_noop(:empty_suffix)}

  defp retract_visible_suffix(conversation_id, message_ids, opts) do
    case validate_current_visible_suffix(conversation_id, message_ids) do
      :ok ->
        retraction = %{
          "reason" => Keyword.get(opts, :reason, "unspecified"),
          "retracted_at" =>
            opts
            |> Keyword.get(:retracted_at, DateTime.utc_now(:microsecond))
            |> DateTime.to_iso8601()
        }

        with {:ok, retracted} <- retract_response_rows(message_ids, retraction) do
          {:ok,
           %{
             status: :retracted,
             retracted_message_ids: message_ids,
             retracted_count: length(retracted)
           }}
        end

      {:noop, reason} ->
        {:ok, tail_retraction_noop(reason)}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_current_visible_suffix(conversation_id, message_ids) do
    case latest_visible_leaf_for_uuid(conversation_id) do
      nil ->
        {:noop, :no_visible_leaf}

      leaf_id ->
        visible_suffix = chain_ids(conversation_id, leaf_id, length(message_ids), false)

        cond do
          visible_suffix != message_ids ->
            {:noop, :not_visible_suffix}

          not complete_response_rows?(conversation_id, message_ids) ->
            {:error, :invalid_response_suffix}

          response_suffix_has_external_children?(conversation_id, message_ids) ->
            {:error, :response_suffix_has_descendants}

          true ->
            :ok
        end
    end
  end

  defp retract_response_rows(message_ids, retraction) do
    with {:ok, records} <-
           Message
           |> Ash.Query.filter(id in ^message_ids)
           |> Ankole.Ash.update_where(:retract, %{metadata: %{"retraction" => retraction}}) do
      by_id = Map.new(records, &{&1.id, &1})
      {:ok, Enum.map(message_ids, &Map.fetch!(by_id, &1))}
    end
  end

  @doc false
  def lock_owned_conversation(subject_uid, conversation_id) do
    Conversation
    |> Ash.Query.filter(id == ^conversation_id and subject_uid == ^subject_uid)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
  end

  @doc false
  def lock_active_owned_conversation(subject_uid, conversation_id) do
    Conversation
    |> Ash.Query.filter(
      id == ^conversation_id and subject_uid == ^subject_uid and is_nil(ended_at)
    )
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
  end

  defp complete_response_rows?(conversation_id, message_ids) do
    complete =
      Message
      |> Ash.Query.filter(
        id in ^message_ids and conversation_id == ^conversation_id and type == :message and
          status == :complete
      )
      |> Ash.Query.select([:id])
      |> Ankole.Ash.read!()

    length(complete) == length(message_ids)
  end

  defp response_suffix_has_external_children?(conversation_id, message_ids) do
    Message
    |> Ash.Query.filter(
      conversation_id == ^conversation_id and previous_message_id in ^message_ids and
        id not in ^message_ids and status == :complete
    )
    |> Ash.Query.limit(1)
    |> Ash.Query.select([:id])
    |> Ankole.Ash.read!()
    |> Enum.any?()
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

  defp tail_retraction_noop(reason) do
    %{
      status: :noop,
      reason: reason,
      retracted_message_ids: [],
      retracted_count: 0
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
      Message |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!()
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
           Message
           |> Ash.Query.filter(id == ^id and subject_uid == ^subject_uid)
           |> Ankole.Ash.read_one!() do
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
             | Ash.Error.t()}
  def create_compaction_checkpoint(attrs) when is_map(attrs) do
    raw_subject_uid = Map.fetch!(attrs, :subject_uid)
    artifact = Map.fetch!(attrs, :artifact)
    metadata = Ankole.Attrs.get(attrs, :metadata, %{})
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
  Loads a conversation by id and owning subject.

  This is used at stateful request boundaries so a caller cannot attach a new
  response run to another subject's conversation or expand another subject's history.
  """
  @spec get_conversation_for_subject(String.t(), String.t()) ::
          {:ok, Conversation.t()} | {:error, :invalid_conversation}
  def get_conversation_for_subject(subject_uid, conversation_id, opts \\ []) do
    include_ended? = Keyword.get(opts, :include_ended, false) == true

    with {:ok, normalized_uid} <- Principals.normalize_uid(subject_uid),
         {:ok, conversation_id} <- cast_uuid(conversation_id),
         %Conversation{} = conversation <-
           Conversation
           |> Ash.Query.filter(
             id == ^conversation_id and subject_uid == ^normalized_uid and
               (is_nil(ended_at) or ^include_ended?)
           )
           |> Ankole.Ash.read_one!() do
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

  # Decodes a "resp_#{uuid}" string to the raw UUID. Internal DB-facing helpers
  # may pass raw UUIDs; HTTP/WS/API boundaries enforce prefixed ids before this
  # function is reached.
  def decode_response_id("resp_" <> uuid), do: cast_uuid(uuid, :invalid_response_id)
  def decode_response_id(uuid) when is_binary(uuid), do: cast_uuid(uuid, :invalid_response_id)
  def decode_response_id(_value), do: {:error, :invalid_response_id}

  def decode_optional_response_id(nil), do: {:ok, nil}
  def decode_optional_response_id(value), do: decode_response_id(value)

  def cast_uuid(value, error_reason \\ :invalid_uuid) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, error_reason}
    end
  end

  def previous_response_id(attrs),
    do: Ankole.Attrs.get(attrs, :previous_response_id)

  def conversation_id(attrs),
    do: Ankole.Attrs.get(attrs, :conversation_id)

  @doc false
  def complete_message_for_subject(subject_uid, message_id) do
    Message
    |> Ash.Query.filter(id == ^message_id and subject_uid == ^subject_uid and status == :complete)
    |> Ankole.Ash.read_one!()
  end

  @doc false
  def complete_message_for_active_subject(subject_uid, message_id) do
    Message
    |> Ash.Query.filter(
      id == ^message_id and subject_uid == ^subject_uid and status == :complete and
        exists(
          Conversation,
          id == parent(conversation_id) and subject_uid == ^subject_uid and is_nil(ended_at)
        )
    )
    |> Ankole.Ash.read_one!()
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

  # A checkpoint is background compaction, not user activity, so this insert
  # deliberately skips Conversations.touch_conversation_in_tx: the console
  # orders conversations by activity and compaction must not reorder them.
  @doc false
  def insert_checkpoint_row(
        subject_uid,
        conversation_id,
        previous_message_id,
        artifact_id,
        metadata
      ) do
    Ankole.Ash.create(Message, :checkpoint, %{
      id: artifact_id,
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      previous_message_id: previous_message_id,
      content: [CompactionArtifacts.ref_item(artifact_id)],
      metadata: metadata
    })
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
    case Message
         |> Ash.Query.filter(
           id == ^message_id and conversation_id == ^conversation_id and status == :complete
         )
         |> Ash.Query.select([:id])
         |> Ankole.Ash.read_one!() do
      nil -> {:error, :invalid_anchor}
      %Message{} -> :ok
    end
  end

  defp walk_message_chain(conversation_id, anchor_id, stop_at_checkpoint?) do
    conversation_id
    |> chain_messages(anchor_id, @history_chain_max_depth, stop_at_checkpoint?)
    |> Enum.filter(&project_message?/1)
    |> Enum.reverse()
  end

  # The recursive ancestor walk gives ids in chain order. The rows come from
  # the Message resource.
  defp chain_messages(conversation_id, anchor_id, max_depth, stop_at_checkpoint? \\ false) do
    conversation_id
    |> chain_ids(anchor_id, max_depth, stop_at_checkpoint?)
    |> load_messages()
  end

  defp chain_ids(conversation_id, anchor_id, max_depth, stop_at_checkpoint?) do
    continue =
      if stop_at_checkpoint?,
        do: "NOT (message.status = 'complete' AND message.type = 'checkpoint')",
        else: "true"

    result =
      SQL.query!(
        Repo,
        """
        #{ancestor_chain_sql(continue)}
        SELECT chain.id::text
        FROM chain
        JOIN ai_gateway_messages AS message ON message.id = chain.id
        WHERE message.tenant_id = $4::text::uuid
        ORDER BY chain.depth ASC
        """,
        [anchor_id, conversation_id, max_depth, Repo.tenant_id!()]
      )

    Enum.map(result.rows, fn [id] -> id end)
  end

  defp chain_metadata(conversation_id, anchor_id) do
    result =
      SQL.query!(
        Repo,
        """
        #{ancestor_chain_sql("true")}
        SELECT CASE
          WHEN jsonb_typeof(message.metadata->'request_metadata') = 'object'
            THEN message.metadata->'request_metadata'
          ELSE '{}'::jsonb
        END AS caller_metadata
        FROM chain
        JOIN ai_gateway_messages AS message ON message.id = chain.id
        WHERE message.tenant_id = $4::text::uuid
          AND message.status = 'complete' AND message.type = 'message'
        ORDER BY chain.depth DESC
        """,
        [anchor_id, conversation_id, @history_chain_max_depth, Repo.tenant_id!()]
      )

    Enum.map(result.rows, fn [metadata] -> metadata end)
  end

  defp suffix_messages(conversation_id, anchor_id, key, value) do
    matches = "message.metadata->'request_metadata'->$5::text = to_jsonb($6::text)"

    continue = """
    message.status <> 'complete' OR message.type = 'checkpoint'
      OR message.metadata->'tool_result_journal' = 'true'::jsonb
      OR COALESCE(#{matches}, false)
    """

    result =
      SQL.query!(
        Repo,
        """
        #{ancestor_chain_sql(continue)}
        SELECT message.id::text
        FROM chain
        JOIN ai_gateway_messages AS message ON message.id = chain.id
        WHERE message.tenant_id = $4::text::uuid
          AND message.status = 'complete' AND message.type <> 'checkpoint'
          AND #{matches}
        ORDER BY chain.depth DESC
        """,
        [anchor_id, conversation_id, @history_chain_max_depth, Repo.tenant_id!(), key, value]
      )

    result.rows |> Enum.map(fn [id] -> id end) |> load_messages()
  end

  # Gives the Message rows of the ids in the order of the ids. A row that a
  # concurrent writer removed after the walk is left out.
  defp load_messages([]), do: []

  defp load_messages(ids) do
    by_id =
      Message
      |> Ash.Query.filter(id in ^ids)
      |> Ankole.Ash.read!()
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(ids, &List.wrap(by_id[&1]))
  end

  defp ancestor_chain_sql(continue) do
    # LIMIT 1 is redundant with the primary key but keeps each recursive step
    # a parent lookup. Without it, stale statistics can reorder the join into
    # a scan of the whole conversation for every ancestor.
    """
    WITH RECURSIVE chain AS (
      SELECT message.id, message.previous_message_id,
             ARRAY[message.id] AS path, 1 AS depth, (#{continue}) AS continue
      FROM ai_gateway_messages AS message
      WHERE message.tenant_id = $4::text::uuid AND message.id = $1::text::uuid
        AND message.conversation_id = $2::text::uuid

      UNION ALL

      SELECT message.id, message.previous_message_id,
             chain.path || message.id, chain.depth + 1, (#{continue}) AS continue
      FROM chain
      JOIN LATERAL (
        SELECT parent.id, parent.previous_message_id, parent.status, parent.type, parent.metadata
        FROM ai_gateway_messages AS parent
        WHERE parent.id = chain.previous_message_id
          AND parent.tenant_id = $4::text::uuid AND parent.conversation_id = $2::text::uuid
        LIMIT 1
      ) AS message ON true
      WHERE chain.continue
        AND NOT message.id = ANY(chain.path)
        AND chain.depth < $3
    )
    """
  end

  defp journal?(message), do: message.metadata["tool_result_journal"] == true

  defp project_message?(%Message{status: :complete}), do: true
  defp project_message?(_message), do: false

  defp maybe_filter_response_statuses(query, nil), do: query

  defp maybe_filter_response_statuses(query, statuses) when is_list(statuses),
    do: Ash.Query.filter(query, status in ^statuses)

  defp maybe_filter_response_statuses(query, _statuses), do: query

  defp maybe_lock_response_rows(query, true), do: Ash.Query.lock(query, :for_update)
  defp maybe_lock_response_rows(query, _lock?), do: query
end
