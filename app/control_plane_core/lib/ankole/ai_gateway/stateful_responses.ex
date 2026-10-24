defmodule Ankole.AIGateway.StatefulResponses do
  @moduledoc """
  Durable stateful Responses owner for AIGateway.

  This module sits between the AIGateway transport entry (WebSocket
  `response.create` / HTTP `POST /responses`) and the provider request build.
  For each stateful `response.create + store=true` run it:

    1. Resolves `previous_response_id` / `conversation` into a message chain.
    2. Admits the run with `start_planned_response_run/1`: one
       `ai_gateway_messages` row with `status = "generating"` is created after
       the conversation lock, the single generating run rule, and the expected
       visible leaf check pass.
    3. Returns the row so the transport can build the provider-facing input
       (expanded history + current request items) and call the provider.
    4. Publishes generic response events keyed by the owning conversation.
    5. When the provider reaches a terminal state, the transport calls
       `commit_complete/3` or `commit_error/4` to write the durable final
       `content` and flip the row to `complete` or `error`.

  The client drives the loop through one `response.create` per round;
  this module does not call the provider. Each call to
  `start_planned_response_run/1` corresponds to exactly one `response.create`
  and exactly one `ai_gateway_messages` row (see plan §3.9 step 5–10).
  """

  require Ash.Query

  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.Conversations
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Principals
  alias Ankole.Repo

  import Ankole.AIGateway.ResponseChain,
    only: [
      cast_uuid: 1,
      decode_response_id: 1,
      decode_optional_response_id: 1,
      previous_response_id: 1,
      conversation_id: 1,
      complete_message_for_active_subject: 2,
      lock_active_owned_conversation: 2,
      latest_visible_leaf_for_uuid: 1,
      insert_checkpoint_row: 5
    ]

  import Ankole.AIGateway.ToolResultJournal, only: [request_items_metadata: 1]

  import Ankole.AIGateway.ResponseCommit,
    only: [notify_ai_message_deadline: 1, lock_generating_message: 1]

  @doc """
  Admits a stateful response run and creates its `generating` message row.

  ## Parameters

    * `attrs` — a map with:
      - `subject_uid` (required) — the owning principal uid
      - `previous_response_id` — explicit "resp_{uuid}" anchor; the anchor
        must be a `complete` row in an active conversation of the subject
      - `conversation_id` — implicit anchor at the conversation's current
        visible leaf; used instead of `previous_response_id`
      - `expected_previous_response_id` — the visible leaf the caller planned
        against (implicit runs only); admission fails with
        `:response_run_in_progress` when the leaf moved
      - `compaction` (optional) — `artifact_attrs` and `checkpoint_metadata`
        from `Compaction.maybe_plan_history/7`; the checkpoint is inserted in
        the same transaction and becomes the run's anchor
      - `request_items` (optional) — initial content items, including tool outputs
      - `metadata` (optional) — extra metadata merged into the row

  An implicit run takes the conversation lock and is rejected while another
  `generating` run exists in the conversation. The returned message row's `id`
  becomes the `resp_{id}` for this run, and the caller uses the row to build
  the provider input and initiate the provider call.
  """
  @spec start_planned_response_run(map()) ::
          {:ok, Message.t()}
          | {:error,
             Ash.Error.t()
             | :invalid_compaction_plan
             | :invalid_anchor
             | :invalid_conversation
             | :response_run_in_progress
             | :stateful_anchor_conflict}
  def start_planned_response_run(attrs, opts \\ []) when is_map(attrs) do
    raw_subject_uid = Map.fetch!(attrs, :subject_uid)
    conversation_id = conversation_id(attrs)
    previous_response_id = previous_response_id(attrs)
    expected_previous_response_id = Map.get(attrs, :expected_previous_response_id)
    compaction = Map.get(attrs, :compaction)
    initial_content = response_run_request_items(attrs)

    merged_metadata =
      attrs
      |> response_run_metadata()
      |> Map.merge(request_items_metadata(initial_content))

    with {:ok, subject_uid} <- Principals.normalize_uid(raw_subject_uid),
         {:ok, selector} <-
           planned_run_selector(
             conversation_id,
             previous_response_id,
             expected_previous_response_id
           ) do
      Repo.transact_top_level(
        fn ->
          admit_run(%{
            subject_uid: subject_uid,
            selector: selector,
            compaction: compaction,
            content: initial_content,
            metadata: Map.merge(merged_metadata, Keyword.get(opts, :response_metadata, %{})),
            authorize_run: Keyword.get(opts, :authorize_run_in_tx, fn -> :ok end),
            record_response: Keyword.get(opts, :record_response_in_tx, fn _message -> :ok end)
          })
        end,
        after_commit: &Ankole.AIGateway.ResponseCommit.publish_committed/1
      )
      |> case do
        {:ok, {:publish, %Message{} = message, :response_started, _payload}} ->
          {:ok, message}

        {:error, :invalid_response_id} ->
          {:error, :invalid_anchor}

        {:error, :invalid_uuid} ->
          {:error, :invalid_conversation}

        {:error, _reason} = error ->
          error
      end
    else
      {:error, :invalid_uid} -> {:error, :invalid_conversation}
      {:error, :invalid_response_id} -> {:error, :invalid_anchor}
      {:error, :invalid_uuid} -> {:error, :invalid_conversation}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  # Runs the `:admit_run` action. The response starts only after its commit.
  def admit_run(%{authorize_run: authorize_run, record_response: record_response} = arguments) do
    with :ok <- authorize_run.(),
         {:ok, message} <-
           admit_planned_response_run(
             arguments.subject_uid,
             arguments.selector,
             arguments.compaction,
             arguments.content,
             arguments.metadata
           ),
         :ok <- record_response.(message) do
      {:ok, {:publish, message, :response_started, %{}}}
    end
  end

  @doc false
  @spec ensure_implicit_response_run_available(binary()) ::
          :ok | {:error, :invalid_conversation | :response_run_in_progress}
  def ensure_implicit_response_run_available(conversation_id) do
    with {:ok, conversation_id} <- cast_uuid(conversation_id) do
      ensure_no_generating_response(conversation_id)
    else
      {:error, _reason} -> {:error, :invalid_conversation}
    end
  end

  @doc false
  @spec merge_generating_response_metadata(Message.t(), map()) ::
          {:ok, Message.t()} | {:error, :response_not_generating | Ash.Error.t()}
  def merge_generating_response_metadata(%Message{status: :generating} = message, metadata)
      when is_map(metadata) do
    Ankole.Ash.update(message, :update_context, %{metadata: metadata})
  end

  def merge_generating_response_metadata(%Message{}, _metadata),
    do: {:error, :response_not_generating}

  @doc false
  @spec install_replay_recovery_checkpoint(Message.t(), map()) ::
          {:ok, %{checkpoint: Message.t(), message: Message.t()}}
          | {:error, :response_not_generating | :invalid_compaction_plan | term()}
  def install_replay_recovery_checkpoint(
        %Message{} = message,
        %{
          compaction: %{
            artifact_attrs: artifact_attrs,
            checkpoint_metadata: checkpoint_metadata
          },
          current_input: _current_input,
          injection: injection
        }
      )
      when is_map(artifact_attrs) and is_map(checkpoint_metadata) do
    Repo.transact_top_level(fn ->
      install_recovery_checkpoint(%{
        message: message,
        artifact_attrs: artifact_attrs,
        checkpoint_metadata: checkpoint_metadata,
        injection: injection
      })
    end)
  end

  def install_replay_recovery_checkpoint(%Message{}, _invalid_plan),
    do: {:error, :invalid_compaction_plan}

  @doc false
  # Runs the `:install_recovery_checkpoint` action.
  def install_recovery_checkpoint(%{message: message} = arguments) do
    with %Message{} = current <- lock_generating_message(message.id),
         true <-
           current.subject_uid == message.subject_uid and
             current.conversation_id == message.conversation_id,
         artifact_attrs =
           Map.merge(arguments.artifact_attrs, %{
             subject_uid: current.subject_uid,
             conversation_id: current.conversation_id
           }),
         {:ok, artifact} <- CompactionArtifacts.insert_artifact(artifact_attrs),
         {:ok, checkpoint} <-
           insert_checkpoint_row(
             current.subject_uid,
             current.conversation_id,
             current.previous_message_id,
             artifact.id,
             arguments.checkpoint_metadata
           ),
         {:ok, updated} <-
           Ankole.Ash.update(current, :update_context, %{
             previous_message_id: checkpoint.id,
             metadata: arguments.injection,
             drop_keys: ~w(brain_context_pack brain_context_pack_claimed)
           }),
         :ok <- notify_ai_message_deadline(updated) do
      {:ok, %{checkpoint: checkpoint, message: updated}}
    else
      nil -> {:error, :response_not_generating}
      false -> {:error, :response_not_generating}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_compaction_plan}
    end
  end

  defp response_run_request_items(attrs),
    do: Ankole.Attrs.get(attrs, :request_items, [])

  defp response_run_metadata(attrs) do
    case Map.take(attrs, [:metadata, "metadata"]) do
      %{metadata: metadata} when is_map(metadata) -> metadata
      %{"metadata" => metadata} when is_map(metadata) -> metadata
      _missing -> %{}
    end
  end

  defp planned_run_selector(conversation_id, nil, expected_previous_response_id)
       when not is_nil(conversation_id) do
    with {:ok, conversation_id} <- cast_uuid(conversation_id),
         {:ok, expected_previous_message_id} <-
           decode_optional_response_id(expected_previous_response_id) do
      {:ok, {:implicit, conversation_id, expected_previous_message_id}}
    end
  end

  defp planned_run_selector(nil, previous_response_id, nil)
       when not is_nil(previous_response_id) do
    with {:ok, previous_message_id} <- decode_response_id(previous_response_id) do
      {:ok, {:explicit, previous_message_id}}
    end
  end

  defp planned_run_selector(nil, nil, _expected_previous_response_id),
    do: {:error, :invalid_conversation}

  defp planned_run_selector(
         _conversation_id,
         _previous_response_id,
         _expected_previous_response_id
       ),
       do: {:error, :stateful_anchor_conflict}

  defp admit_planned_response_run(
         subject_uid,
         {:implicit, conversation_id, expected_previous_message_id},
         compaction,
         initial_content,
         merged_metadata
       ) do
    with %Conversation{} <- lock_active_owned_conversation(subject_uid, conversation_id),
         :ok <- ensure_no_generating_response(conversation_id),
         :ok <- ensure_expected_visible_leaf(conversation_id, expected_previous_message_id),
         {:ok, previous_message_id} <-
           maybe_insert_planned_compaction(
             subject_uid,
             conversation_id,
             expected_previous_message_id,
             compaction
           ),
         {:ok, message} <-
           insert_response_run(%{
             subject_uid: subject_uid,
             conversation_id: conversation_id,
             previous_message_id: previous_message_id,
             initial_content: initial_content,
             merged_metadata: merged_metadata
           }),
         :ok <- notify_ai_message_deadline(message) do
      {:ok, message}
    else
      nil -> {:error, :invalid_conversation}
      {:error, _reason} = error -> error
    end
  end

  defp admit_planned_response_run(
         subject_uid,
         {:explicit, previous_message_id},
         compaction,
         initial_content,
         merged_metadata
       ) do
    with %Message{conversation_id: conversation_id} <-
           complete_message_for_active_subject(subject_uid, previous_message_id),
         {:ok, previous_message_id} <-
           maybe_insert_planned_compaction(
             subject_uid,
             conversation_id,
             previous_message_id,
             compaction
           ),
         {:ok, message} <-
           insert_response_run(%{
             subject_uid: subject_uid,
             conversation_id: conversation_id,
             previous_message_id: previous_message_id,
             initial_content: initial_content,
             merged_metadata: merged_metadata
           }),
         :ok <- notify_ai_message_deadline(message) do
      {:ok, message}
    else
      nil -> {:error, :invalid_anchor}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_no_generating_response(conversation_id) do
    generating? =
      Message
      |> Ash.Query.filter(
        conversation_id == ^conversation_id and type == :message and status == :generating
      )
      |> Ankole.Ash.exists?()

    if generating?, do: {:error, :response_run_in_progress}, else: :ok
  end

  defp ensure_expected_visible_leaf(conversation_id, expected_previous_message_id) do
    if latest_visible_leaf_for_uuid(conversation_id) == expected_previous_message_id do
      :ok
    else
      {:error, :response_run_in_progress}
    end
  end

  defp maybe_insert_planned_compaction(
         _subject_uid,
         _conversation_id,
         previous_message_id,
         nil
       ),
       do: {:ok, previous_message_id}

  defp maybe_insert_planned_compaction(
         subject_uid,
         conversation_id,
         previous_message_id,
         %{
           artifact_attrs: artifact_attrs,
           checkpoint_metadata: checkpoint_metadata
         }
       )
       when is_map(artifact_attrs) and is_map(checkpoint_metadata) do
    artifact_attrs =
      Map.merge(artifact_attrs, %{
        subject_uid: subject_uid,
        conversation_id: conversation_id
      })

    with {:ok, artifact} <- CompactionArtifacts.insert_artifact(artifact_attrs),
         {:ok, checkpoint} <-
           insert_checkpoint_row(
             subject_uid,
             conversation_id,
             previous_message_id,
             artifact.id,
             checkpoint_metadata
           ) do
      {:ok, checkpoint.id}
    end
  end

  defp maybe_insert_planned_compaction(
         _subject_uid,
         _conversation_id,
         _previous_message_id,
         _invalid_compaction
       ),
       do: {:error, :invalid_compaction_plan}

  defp insert_response_run(%{
         subject_uid: subject_uid,
         conversation_id: conversation_id,
         previous_message_id: previous_message_id,
         initial_content: initial_content,
         merged_metadata: merged_metadata
       }) do
    with {:ok, %Message{} = message} <-
           Ankole.Ash.create(Message, :start, %{
             subject_uid: subject_uid,
             conversation_id: conversation_id,
             previous_message_id: previous_message_id,
             content: initial_content,
             metadata: merged_metadata
           }) do
      :ok = Conversations.touch_conversation_in_tx(conversation_id)
      {:ok, message}
    end
  end
end
