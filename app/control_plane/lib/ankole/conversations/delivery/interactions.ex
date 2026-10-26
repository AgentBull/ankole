defmodule Ankole.Conversations.Delivery.Interactions do
  @moduledoc """
  Authorizes and resolves interactions emitted by an Ankole reply presentation.

  Provider callbacks are transport input, not authority. The durable Signal
  checkpoint decides whether an interaction is pending, answered, or superseded.
  """

  require Ash.Query

  alias Ankole.Conversations.Delivery.PreviewState

  alias Ankole.Conversations.Delivery.PreviewStates
  alias Ankole.Logging
  alias Ankole.Signals.Signal
  alias Ankole.Signals.Types
  alias Ankole.Signals.Binding
  alias Ankole.Conversations.Observation
  alias Ankole.Conversations.Delivery.InteractionState
  alias Ankole.Conversations.Delivery.ReplyPresentation
  alias Ankole.Conversations.Delivery.PreviewAdapter

  @max_free_text_chars 1_000

  @type accepted_resolution :: %{String.t() => term()}
  @type acceptance :: {:accepted, accepted_resolution()} | :duplicate | :stale | :unmanaged

  @doc """
  Opens one durable reply interaction in the same transaction as its intent.

  A later Signal may already be queued by the time a slow turn asks for
  clarification. In that case the interaction starts superseded and can never
  appear as a live question after the conversation has moved on.
  """
  @spec open_in_tx(Signal.t(), map(), DateTime.t()) ::
          {:ok, Signal.t()} | {:error, term()}
  def open_in_tx(%Signal{} = event, presentation, %DateTime{} = now)
      when is_map(presentation) do
    checkpoint = PreviewStates.get(event).checkpoint || %{}
    superseded_by = first_newer_conversation_event(event)

    checkpoint =
      InteractionState.initialize(checkpoint, presentation, now, superseded_by: superseded_by)

    PreviewStates.put_checkpoint_in_tx(event, checkpoint)
  end

  @doc """
  Supersedes pending interactions older than a newly appended conversation turn.

  The caller already owns the Session advisory lock used to allocate the
  new event's queue sequence. Locking older Signal rows under that same lock
  gives button/form callbacks and ordinary messages one deterministic winner.
  """
  @spec supersede_older_in_tx(Signal.t(), DateTime.t()) ::
          {:ok, [Signal.t()]} | {:error, term()}
  def supersede_older_in_tx(%Signal{} = newer_event, %DateTime{} = now) do
    if Types.supersedes_pending_interaction?(newer_event.type) do
      newer_event
      |> older_reply_interaction_events()
      |> supersede_events_in_tx(newer_event, now)
    else
      {:ok, []}
    end
  end

  @doc """
  Supersedes pending interactions anchored to one removed provider entry.

  Provider lifecycle events remain globally interaction-preserving. The caller
  owns the execution Session lock, so only completed source Signals that contain
  the removed entry can lose their pending interaction; unrelated cards in the
  same session remain actionable.
  """
  @spec supersede_removed_source_in_tx(Signal.t(), DateTime.t()) ::
          {:ok, [Signal.t()]} | {:error, term()}
  def supersede_removed_source_in_tx(
        %Signal{type: "conversation.message.removed", provider_message_id: provider_message_id} =
          removed_event,
        %DateTime{} = now
      )
      when is_binary(provider_message_id) and provider_message_id != "" do
    Ankole.Signals.signals_for_entry_in_tx(
      removed_event.agent_uid,
      removed_event.reply_binding_name,
      removed_event.conversation_id,
      provider_message_id
    )
    |> Enum.filter(&(&1.session_id == removed_event.session_id))
    |> Enum.map(&PreviewStates.load(Ankole.Signals.lock_signal_in_tx(&1.id)))
    |> Enum.reject(&is_nil/1)
    |> supersede_events_in_tx(removed_event, now)
  end

  def supersede_removed_source_in_tx(%Signal{}, %DateTime{}), do: {:ok, []}

  @doc """
  Supersedes predecessor interactions when a queued reset actually rolls the session.

  Enqueuing `session.reset_due` remains interaction-preserving because the reset
  may wait behind running work. Once the reset executes, its predecessor
  conversation is no longer available to interpret an isolated card answer.
  """
  @spec supersede_for_session_reset_in_tx(Signal.t(), DateTime.t()) ::
          {:ok, [Signal.t()]} | {:error, term()}
  def supersede_for_session_reset_in_tx(
        %Signal{type: "session.reset_due"} = reset_event,
        %DateTime{} = now
      ) do
    reset_event
    |> older_reply_interaction_events()
    |> supersede_events_in_tx(reset_event, now)
  end

  def supersede_for_session_reset_in_tx(%Signal{}, %DateTime{}), do: {:ok, []}

  @doc "Projects a native card's durable result for the room timeline."
  def native_interaction(signal_id, interaction_id) when is_binary(signal_id) do
    checkpoint = PreviewStates.get(signal_id).checkpoint || %{}
    native_interaction(signal_id, interaction_id, checkpoint)
  end

  def native_interaction(_signal_id, _interaction_id), do: %{"state" => "superseded"}

  @doc "Projects native cards from one read of their durable checkpoints."
  def native_interactions(messages) do
    signal_ids = messages |> Enum.map(& &1.signal_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    checkpoints =
      PreviewState
      |> Ash.Query.filter(signal_id in ^signal_ids)
      |> Ankole.Ash.read!()
      |> Map.new(&{&1.signal_id, &1.checkpoint || %{}})

    Map.new(messages, fn message ->
      id = get_in(message.rich_content, ["clarify", "interaction_id"])

      value =
        if is_binary(message.signal_id) and is_binary(id),
          do:
            native_interaction(
              message.signal_id,
              id,
              Map.get(checkpoints, message.signal_id, %{})
            ),
          else: %{"state" => "superseded"}

      {message.id, value}
    end)
  end

  defp native_interaction(signal_id, interaction_id, checkpoint) do
    id = String.replace_prefix(interaction_id, signal_id <> ":", "")

    case InteractionState.interaction(checkpoint, id) do
      nil ->
        %{"state" => "superseded"}

      interaction ->
        interaction
        |> Map.take([
          "answered_by_uid",
          "answered_by_name",
          "answered_at",
          "choice_id",
          "answer_text"
        ])
        |> Map.put("state", interaction["state"])
    end
  end

  @doc "Answers a native room question and publishes its committed message."
  def answer_native(actor, conversation_id, interaction_id, attrs) do
    Ankole.Repo.transact_top_level(
      fn -> accept_native_in_tx(actor, conversation_id, interaction_id, attrs) end,
      after_commit: &Ankole.Conversations.Native.publish_native_change/1
    )
    |> Ankole.Conversations.Native.committed(actor)
  end

  @doc "Records the first native room answer and submits it to the Agent that asked."
  def accept_native_in_tx(actor, conversation_id, interaction_id, attrs) do
    alias Ankole.Conversations.{Native, Queries}

    with [signal_id, id] <- String.split(interaction_id, ":", parts: 2),
         {:ok, signal_id} <- Ecto.UUID.cast(signal_id),
         {:ok, %Signal{conversation_id: ^conversation_id} = source} <-
           Ankole.Signals.get_signal(signal_id),
         :ok <- Native.lock_participants_in_tx(actor, source.agent_uid, conversation_id),
         :ok <-
           Ankole.Signals.lock_target_in_tx(%{
             agent_uid: source.agent_uid,
             session_id: source.session_id
           }),
         true <- Native.visible_conversation?(actor, conversation_id),
         %{} <- Queries.lock_conversation(conversation_id),
         %Signal{} = source <- Ankole.Signals.lock_signal_in_tx(source.id),
         preview = PreviewStates.lock_in_tx(source),
         %{"state" => "pending"} <- InteractionState.interaction(preview.checkpoint || %{}, id),
         {:ok, answer} <- native_answer(preview.checkpoint, id, attrs),
         :ok <-
           Ankole.AuthZ.authorize(
             actor,
             "agent:#{source.agent_uid}",
             "chat",
             Ankole.AuthZ.Actor.request_context(actor)
           ),
         resolution = native_resolution(actor, answer),
         {:ok, checkpoint} <- InteractionState.resolve(preview.checkpoint, id, resolution),
         {:ok, _source} <- PreviewStates.put_checkpoint_in_tx(source, checkpoint),
         {:ok, result} <-
           Native.post_in_tx(actor, conversation_id, %{
             message_id: Ankole.Ecto.UUIDv7.autogenerate(),
             text: answer["value"],
             links: Ankole.Attrs.get(attrs, :links) || [],
             attachments: Ankole.Attrs.get(attrs, :attachments) || [],
             mentions:
               Enum.filter(Ankole.Attrs.get(attrs, :mentions) || [], fn mention ->
                 Ankole.Attrs.get(mention, :type) in [:human, "human"]
               end),
             target_agent_uid: source.agent_uid,
             delivery_mode: "steer"
           }) do
      {:ok, result}
    else
      false -> {:error, :conversation_not_found}
      nil -> {:error, :interaction_not_pending}
      %{} -> {:error, :interaction_not_pending}
      :stale -> {:error, :interaction_not_pending}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_reply_interaction}
    end
  end

  defp native_answer(checkpoint, id, attrs) do
    presentation = ReplyPresentation.normalize(checkpoint["presentation"])
    choice_id = Ankole.Attrs.get(attrs, :choice_id)

    answer_text = Ankole.Attrs.get(attrs, :answer_text) || ""
    has_attachments = (Ankole.Attrs.get(attrs, :attachments) || []) != []

    actions = Enum.filter(presentation["actions"], &(&1["interaction_id"] == id))

    cond do
      is_binary(choice_id) ->
        case Enum.find(
               actions,
               &(&1["type"] == "button" and &1["selected_option_id"] == choice_id)
             ) do
          nil ->
            {:error, :invalid_reply_interaction}

          action ->
            {:ok,
             %{"kind" => "choice", "option_id" => choice_id, "value" => action["option_value"]}}
        end

      is_binary(answer_text) and (String.trim(answer_text) != "" or has_attachments) ->
        if Enum.any?(actions, &(&1["type"] == "form")),
          do: {:ok, %{"kind" => "free_text", "value" => answer_text}},
          else: {:error, :invalid_reply_interaction}

      true ->
        {:error, :invalid_reply_interaction}
    end
  end

  defp native_resolution(actor, answer) do
    %{
      "state" => "answered",
      "answer" => answer,
      "answered_by_uid" => Ankole.AuthZ.Actor.uid(actor),
      "answered_by_name" => actor.principal.display_name,
      "answered_at" => DateTime.to_iso8601(DateTime.utc_now(:microsecond)),
      "choice_id" => answer["option_id"],
      "answer_text" => answer["value"]
    }
  end

  @doc """
  Validates and records a managed reply action inside the ingress transaction.

  Unknown action protocols remain ordinary adapter actions. Managed callbacks
  are accepted at most once and always re-authorize the current human Principal.
  """
  @spec accept_in_tx(Binding.t(), Observation.t(), DateTime.t()) ::
          {:ok, acceptance()} | {:error, term()}
  def accept_in_tx(%Binding{} = binding, %Observation{} = fact, %DateTime{} = now) do
    action = fact.action || %{}
    value = map_value(action, "value")
    protocol = ReplyPresentation.action_protocol()

    case map_value(value, "version") do
      ^protocol ->
        accept_managed_in_tx(binding, fact, action, value, now)

      nil ->
        {:ok, :unmanaged}

      version ->
        Logging.warning(
          "conversations.delivery.interactions.protocol_unmanaged",
          "reply action protocol is not managed",
          %{
            binding_name: binding.name,
            source_event_id: fact.source_event_id,
            version: inspect(version, limit: 20)
          }
        )

        {:ok, :unmanaged}
    end
  end

  defp accept_managed_in_tx(binding, fact, action, value, now) do
    with {:ok, callback} <- normalize_callback(value),
         :ok <- authorize_operator(map_value(action, "operator_principal_uid")),
         %Signal{} = source <- find_source_event(binding, fact, callback),
         :ok <-
           Ankole.Signals.lock_target_in_tx(%{
             agent_uid: source.agent_uid,
             session_id: source.session_id
           }),
         %Signal{} = event <- lock_source_event(binding, fact, callback),
         {:ok, result} <- accept_locked_event(event, fact, callback, now) do
      {:ok, result}
    else
      nil -> {:ok, :stale}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_callback(value) when is_map(value) do
    with {:ok, source_signal_id} <- required_text(value, "sourceSignalId"),
         {:ok, interaction_id} <- required_text(value, "interactionId"),
         {:ok, interaction_version} <- required_non_negative_integer(value, "interactionVersion"),
         {:ok, control_id} <- required_text(value, "controlId") do
      base = %{
        source_signal_id: source_signal_id,
        interaction_id: interaction_id,
        interaction_version: interaction_version,
        control_id: control_id
      }

      normalize_answer_callback(base, value)
    end
  end

  defp normalize_callback(_value), do: {:error, :invalid_reply_interaction}

  defp normalize_answer_callback(base, value) do
    case map_value(value, "answerKind") do
      "free_text" -> normalize_free_text_callback(base, value)
      kind when kind in [nil, "choice"] -> normalize_choice_callback(base, value)
      _kind -> {:error, {:invalid_reply_interaction, "answerKind"}}
    end
  end

  defp normalize_choice_callback(base, value) do
    with {:ok, selected_option_id} <- required_text(value, "selectedOptionId"),
         {:ok, option_value} <- required_text(value, "optionValue") do
      {:ok,
       Map.merge(base, %{
         kind: "choice",
         selected_option_id: selected_option_id,
         option_value: option_value,
         answer: %{
           "kind" => "choice",
           "value" => option_value,
           "option_id" => selected_option_id
         }
       })}
    end
  end

  defp normalize_free_text_callback(base, value) do
    with {:ok, input_name} <- required_text(value, "inputName"),
         %{} = form_value <- map_value(value, "formValue"),
         {:ok, answer} <- required_free_text(form_value, input_name) do
      {:ok,
       Map.merge(base, %{
         kind: "free_text",
         input_name: input_name,
         answer: %{"kind" => "free_text", "value" => answer}
       })}
    else
      nil -> {:error, {:invalid_reply_interaction, "formValue"}}
      {:error, _reason} = error -> error
    end
  end

  defp authorize_operator(""), do: {:error, :reply_interaction_operator_unknown}

  defp authorize_operator(principal_uid) when is_binary(principal_uid) do
    case Ankole.Principals.get_principal_record!(principal_uid) do
      %{type: :human, status: :active} -> :ok
      %{} -> {:error, :reply_interaction_operator_unauthorized}
      nil -> {:error, :reply_interaction_operator_unknown}
    end
  end

  defp authorize_operator(_principal_uid),
    do: {:error, :reply_interaction_operator_missing}

  defp find_source_event(binding, fact, callback) do
    Ankole.Signals.list_signals!(query: [filter: source_event_filter(binding, fact, callback)])
    |> List.first()
    |> accepted_reply_surface(fact.provider_message_id, binding)
  end

  defp lock_source_event(binding, fact, callback) do
    Ankole.Signals.lock_signals_in_tx(source_event_filter(binding, fact, callback))
    |> List.first()
    |> accepted_reply_surface(fact.provider_message_id, binding)
  end

  defp source_event_filter(binding, fact, callback) do
    [
      id: callback.source_signal_id,
      agent_uid: binding.agent_uid,
      reply_binding_name: binding.name,
      session_id: fact.session_id
    ]
  end

  defp accepted_reply_surface(%Signal{} = event, provider_message_id, binding) do
    if reply_surface_entry?(event, provider_message_id, binding), do: event
  end

  defp accepted_reply_surface(nil, _provider_message_id, _binding), do: nil

  # The callback names the provider entry it came from; the adapter that owns
  # the checkpoint says which provider entries the reply surface holds.
  defp reply_surface_entry?(%Signal{} = event, provider_message_id, binding)
       when is_binary(provider_message_id) do
    PreviewStates.get(event).provider_message_id ==
      provider_message_id or
      provider_message_id in PreviewAdapter.surface_entry_ids(
        PreviewAdapter.for_binding(binding),
        PreviewStates.get(event).checkpoint || %{}
      )
  end

  defp reply_surface_entry?(_event, _provider_message_id, _binding), do: false

  defp accept_locked_event(event, fact, callback, now) do
    checkpoint = PreviewStates.get(event).checkpoint || %{}

    case InteractionState.interaction(checkpoint, callback.interaction_id) do
      %{"state" => "pending"} ->
        accept_pending_answer(event, checkpoint, fact, callback, now)

      %{"state" => "answered", "answer" => answer} ->
        if answer == callback.answer, do: {:ok, :duplicate}, else: {:ok, :stale}

      %{"state" => "superseded"} ->
        {:ok, :stale}

      _missing_or_invalid ->
        {:ok, :stale}
    end
  end

  defp accept_pending_answer(event, checkpoint, fact, callback, now) do
    case first_newer_session_reset(event) do
      %Signal{} = reset_event ->
        with {:ok, _superseded} <-
               supersede_events_in_tx([event], reset_event, now) do
          {:ok, :stale}
        end

      nil ->
        accept_current_answer(event, checkpoint, fact, callback, now)
    end
  end

  defp accept_current_answer(event, checkpoint, fact, callback, now) do
    presentation = ReplyPresentation.normalize(checkpoint["presentation"])

    if ReplyPresentation.matches?(presentation, callback) do
      resolution = %{
        "state" => "answered",
        "answer" => callback.answer,
        "interaction_version" => callback.interaction_version,
        "control_id" => callback.control_id,
        "operator_principal_uid" => map_value(fact.action, "operator_principal_uid"),
        "resolved_at" => DateTime.to_iso8601(now),
        "source_event_id" => fact.source_event_id
      }

      with {:ok, updated_checkpoint} <-
             InteractionState.resolve(checkpoint, callback.interaction_id, resolution),
           {:ok, _updated} <-
             PreviewStates.put_checkpoint_in_tx(
               event,
               updated_checkpoint
             ) do
        {:ok, {:accepted, accepted_resolution(callback)}}
      else
        :stale -> {:ok, :stale}
        {:error, _reason} = error -> error
      end
    else
      {:ok, :stale}
    end
  end

  defp accepted_resolution(callback) do
    %{
      "interaction_id" => callback.interaction_id,
      "source_signal_id" => callback.source_signal_id,
      "answer" => callback.answer
    }
  end

  # The older Signals of the session whose preview has a pending interaction.
  # Queue sequences start at 1, so the first Signal of a Session has no older
  # Signal.
  defp older_reply_interaction_events(%Signal{queue_sequence: sequence}) when sequence <= 1,
    do: []

  defp older_reply_interaction_events(%Signal{} = newer_event) do
    signal_ids =
      PreviewState
      |> Ash.Query.filter(
        not is_nil(checkpoint) and
          fragment(
            """
            EXISTS (
              SELECT 1
              FROM jsonb_each(
                CASE
                  WHEN jsonb_typeof(?->'interactions') = 'object' THEN ?->'interactions'
                  ELSE '{}'::jsonb
                END
              ) AS interaction
              WHERE interaction.value->>'state' = 'pending'
            )
            """,
            checkpoint,
            checkpoint
          ) and
          exists(
            Signal,
            id == parent(signal_id) and agent_uid == ^newer_event.agent_uid and
              session_id == ^newer_event.session_id and
              queue_sequence < ^newer_event.queue_sequence
          )
      )
      |> Ash.Query.select([:signal_id])
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.signal_id)

    if signal_ids == [] do
      []
    else
      Ankole.Signals.lock_signals_in_tx(
        id: [in: signal_ids],
        agent_uid: newer_event.agent_uid,
        session_id: newer_event.session_id,
        queue_sequence: [less_than: newer_event.queue_sequence]
      )
    end
  end

  defp supersede_events_in_tx(events, newer_event, now) do
    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, updated} ->
      case InteractionState.supersede(
             PreviewStates.get(event).checkpoint || %{},
             newer_event,
             now
           ) do
        :noop ->
          {:cont, {:ok, updated}}

        {:ok, checkpoint} ->
          case PreviewStates.put_checkpoint_in_tx(
                 event,
                 checkpoint
               ) do
            {:ok, event} -> {:cont, {:ok, [event | updated]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, Enum.reverse(updated)}
      {:error, _reason} = error -> error
    end
  end

  defp first_newer_conversation_event(%Signal{} = event) do
    first_newer_signal(event, type: [in: Types.interaction_superseding_types()])
  end

  defp first_newer_session_reset(%Signal{} = event) do
    first_newer_signal(event,
      type: "session.reset_due",
      producer: :kernel,
      status: [in: [:queued, :running]]
    )
  end

  defp first_newer_signal(event, filter) do
    Ankole.Signals.list_signals!(
      query: [
        filter:
          [
            agent_uid: event.agent_uid,
            session_id: event.session_id,
            queue_sequence: [greater_than: event.queue_sequence]
          ] ++ filter,
        sort: [queue_sequence: :asc],
        limit: 1
      ]
    )
    |> List.first()
  end

  defp required_free_text(map, key) do
    case map_value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" ->
            {:error, {:invalid_reply_interaction, key}}

          value ->
            if String.length(value) <= @max_free_text_chars do
              {:ok, value}
            else
              {:error, {:reply_interaction_too_long, @max_free_text_chars}}
            end
        end

      _value ->
        {:error, {:invalid_reply_interaction, key}}
    end
  end

  defp required_text(map, key),
    do: Ankole.Attrs.required_text(map_value(map, key), {:invalid_reply_interaction, key})

  defp required_non_negative_integer(map, key) do
    case map_value(map, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _value -> {:error, {:invalid_reply_interaction, key}}
    end
  end

  defp map_value(map, key) when is_map(map) and is_binary(key), do: Map.get(map, key)

  defp map_value(_map, _key), do: nil
end
