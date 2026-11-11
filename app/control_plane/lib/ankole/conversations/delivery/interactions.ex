defmodule Ankole.Conversations.Delivery.Interactions do
  @moduledoc """
  Authorizes and resolves interactions emitted by an Ankole reply presentation.

  Provider callbacks are transport input, not authority. The durable Signal
  checkpoint decides whether an interaction is pending, answered, or superseded.
  """

  require Ash.Expr
  require Ash.Query

  alias Ankole.Conversations.Delivery.PreviewState

  alias Ankole.Conversations.Delivery.PreviewStates
  alias Ankole.Logging
  alias Ankole.Signals.Signal
  alias Ankole.Signals.Types
  alias Ankole.Signals.Binding
  alias Ankole.Conversations.Observation
  alias Ankole.Conversations.Delivery.InteractionState
  alias Ankole.Conversations.Delivery.ClarifyForm
  alias Ankole.Conversations.Delivery.ClarifyPrompt
  alias Ankole.Conversations.Delivery.ReplyPresentation
  alias Ankole.Conversations.Delivery.PreviewAdapter

  @max_free_text_chars 1_000

  @type accepted_resolution :: %{String.t() => term()}
  @type acceptance ::
          {:accepted, accepted_resolution()}
          | {:invalid_form, String.t()}
          | :duplicate
          | :stale
          | :unmanaged

  @doc """
  Opens one durable reply interaction in the same transaction as its intent.

  A later Signal may already be queued by the time a slow turn asks for
  clarification. In that case the interaction starts superseded and can never
  appear as a live question after the conversation has moved on.
  """
  @spec open_in_tx(Signal.t(), map(), DateTime.t(), keyword()) ::
          {:ok, Signal.t()} | {:error, term()}
  def open_in_tx(%Signal{} = event, presentation, %DateTime{} = now, opts \\ [])
      when is_map(presentation) do
    clarify = Keyword.get(opts, :clarify)
    checkpoint = PreviewStates.get(event).checkpoint || %{}
    superseded_by = first_newer_conversation_event(event)

    checkpoint =
      InteractionState.initialize(checkpoint, presentation, now,
        superseded_by: superseded_by,
        forms: if(is_map(clarify), do: ClarifyPrompt.forms(clarify), else: %{})
      )

    with {:ok, _superseded} <- supersede_older_clarify_in_tx(event, clarify, now),
         do: PreviewStates.put_checkpoint_in_tx(event, checkpoint)
  end

  # A new clarify replaces the asking Agent's older pending clarify in the same
  # Session; Action Cards keep their own lifecycle. The caller owns the Session lock.
  defp supersede_older_clarify_in_tx(_event, nil, _now), do: {:ok, []}

  defp supersede_older_clarify_in_tx(event, _clarify, now),
    do: event |> older_reply_interaction_events() |> supersede_events_in_tx(event, now)

  @doc """
  Supersedes pending interactions older than a newly appended conversation turn.

  The caller already owns the Session advisory lock used to allocate the
  new event's queue sequence. Locking older Signal rows under that same lock
  gives button/form callbacks and ordinary messages one deterministic winner.
  """
  @spec supersede_older_in_tx(Signal.t(), DateTime.t()) ::
          {:ok, [Signal.t()]} | {:error, term()}
  def supersede_older_in_tx(%Signal{} = newer_event, %DateTime{} = now) do
    if Types.supersedes_pending_interaction?(newer_event.type) or
         (newer_event.type == "agent.peer_message" and newer_event.data["priority"] == true) do
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
    candidates =
      Ankole.Signals.signals_for_entry_in_tx(
        removed_event.agent_uid,
        removed_event.reply_binding_id,
        removed_event.conversation_id,
        provider_message_id
      )
      |> Enum.filter(&(&1.session_id == removed_event.session_id))

    locked_cards =
      Ankole.Conversations.ActionCards.lock_prepared_for_signals_in_tx(
        Enum.map(candidates, & &1.id)
      )

    with {:ok, superseded} <-
           candidates
           |> Enum.map(&PreviewStates.load(Ankole.Signals.lock_signal_in_tx(&1.id)))
           |> Enum.reject(&is_nil/1)
           |> supersede_events_in_tx(removed_event, now),
         :ok <-
           Ankole.Conversations.ActionCards.cancel_locked_for_signals_in_tx(
             locked_cards,
             Enum.map(superseded, & &1.id),
             now
           ) do
      {:ok, superseded}
    end
  end

  def supersede_removed_source_in_tx(%Signal{}, %DateTime{}), do: {:ok, []}

  @doc false
  @spec supersede_reverted_signals_in_tx([Signal.t()], Signal.t(), list(), DateTime.t()) ::
          {:ok, [Signal.t()]} | {:error, term()}
  def supersede_reverted_signals_in_tx(signals, %Signal{} = command_event, locked_cards, now)
      when is_list(signals) do
    loaded =
      signals
      |> Enum.map(&PreviewStates.load/1)
      |> Enum.reject(&is_nil/1)

    with {:ok, superseded} <-
           supersede_events_in_tx(loaded, command_event, now, supersede_action_cards?: true),
         :ok <-
           Ankole.Conversations.ActionCards.cancel_locked_for_signals_in_tx(
             locked_cards,
             Enum.map(signals, & &1.id),
             now
           ) do
      {:ok, superseded}
    end
  end

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

  @doc """
  Supersedes predecessor reply interactions when cold-wake rotation closes the
  previous model conversation.

  Action Cards remain actionable across rotation (`InteractionState.supersedable_by?/2`
  preserves `action_card:*`), while predecessor `clarify` questions become superseded.
  """
  @spec supersede_for_wake_recycle_in_tx(Signal.t(), DateTime.t()) ::
          {:ok, [Signal.t()]} | {:error, term()}
  def supersede_for_wake_recycle_in_tx(%Signal{} = wake_event, %DateTime{} = now) do
    wake_event
    |> older_reply_interaction_events()
    |> supersede_events_in_tx(wake_event, now)
  end

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
      id = message_interaction_id(message)

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

  @doc false
  def message_interaction_id(message) do
    rich = message.rich_content || %{}

    get_in(rich, ["clarify", "interaction_id"]) ||
      get_in(rich, ["connector_auth", "interaction_id"]) ||
      get_in(rich, ["access_blocked", "interaction_id"])
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

    with false <- Ankole.Conversations.ActionCards.action_card_interaction_id?(interaction_id),
         :ok <- Ankole.Pod.lock_tree_in_tx(),
         [signal_id, id] <- String.split(interaction_id, ":", parts: 2),
         {:ok, signal_id} <- Ecto.UUID.cast(signal_id),
         {:ok, %Signal{} = source} <-
           Ankole.Signals.get_signal(signal_id),
         :ok <- answer_source_visible(actor, conversation_id, source),
         :ok <- Native.lock_session_participants_in_tx(source, [Ankole.AuthZ.Actor.uid(actor)]),
         :ok <-
           Ankole.Sessions.Queue.lock_sessions_in_tx(
             Ankole.Conversations.peer_session_keys(source)
           ),
         true <- Native.visible_conversation?(actor, conversation_id),
         :ok <- Ankole.Conversations.Peers.lock_rooms([conversation_id, source.conversation_id]),
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
           post_native_answer(actor, conversation_id, source, %{
             message_id: Ankole.Ecto.UUIDv7.autogenerate(),
             text: answer["value"],
             links: Ankole.Attrs.get(attrs, :links) || [],
             attachments: Ankole.Attrs.get(attrs, :attachments) || [],
             mentions:
               Enum.filter(Ankole.Attrs.get(attrs, :mentions) || [], fn mention ->
                 Ankole.Attrs.get(mention, :type) in [:human, "human"]
               end),
             target_agent_uid: source.agent_uid,
             answered_interaction_id: interaction_id,
             interaction_answer: if(answer["kind"] == "form", do: answer),
             delivery_mode: "steer"
           }) do
      {:ok, result}
    else
      true -> {:error, :invalid_reply_interaction}
      false -> {:error, :conversation_not_found}
      nil -> {:error, :interaction_not_pending}
      %{} -> {:error, :interaction_not_pending}
      :stale -> {:error, :interaction_not_pending}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_reply_interaction}
    end
  end

  @doc """
  Reads one form question for the standalone Pod dialog (`/?interaction=<id>`).

  `interaction_id` is the native form `<source_signal_id>:<interaction_id>`.
  A native-room question requires room visibility; a question delivered to an
  external channel requires an active Human, matching that channel's buttons.
  Every viewer sees who answered, but only room members and the Human who
  answered an external question see the answer itself.
  """
  def standalone(%Ankole.AuthZ.Actor{} = actor, interaction_id) do
    with {:ok, source, id} <- interaction_source(interaction_id),
         origin = interaction_origin(source),
         true <- standalone_visible?(actor, origin),
         %{"form" => form} = interaction <-
           InteractionState.interaction(PreviewStates.get(source).checkpoint || %{}, id) do
      {:ok,
       %{
         "interaction_id" => interaction_id,
         "conversation_id" => origin && origin.id,
         "conversation_kind" => if(origin, do: to_string(origin.kind), else: "external"),
         "agent_uid" => source.agent_uid,
         "question" => form["question"],
         "fields" => form["fields"],
         "state" => interaction["state"],
         "answered_by_uid" => interaction["answered_by_uid"],
         "answered_by_name" => interaction["answered_by_name"],
         "answer_text" =>
           if(
             match?(%{kind: :native}, origin) or
               interaction["answered_by_uid"] == Ankole.AuthZ.Actor.uid(actor),
             do: interaction["answer_text"]
           )
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Submits a form from the standalone Pod dialog.

  A native-room question takes the room answer path. An external question
  records the first valid answer on its checkpoint and wakes the asking Agent
  with a `signal.action.invoked` Signal, as an external card callback does.
  """
  def answer_standalone(%Ankole.AuthZ.Actor{} = actor, interaction_id, attrs) do
    with {:ok, _result} <-
           Ankole.Repo.transact_top_level(
             fn -> accept_standalone_in_tx(actor, interaction_id, attrs) end,
             after_commit: &publish_standalone/1
           ),
         do: standalone(actor, interaction_id)
  end

  defp accept_standalone_in_tx(actor, interaction_id, attrs) do
    with {:ok, source, id} <- interaction_source(interaction_id) do
      case interaction_origin(source) do
        %{kind: :native} = origin ->
          accept_native_in_tx(actor, origin.id, interaction_id, attrs)

        _external ->
          accept_external_form_in_tx(actor, source, id, interaction_id, attrs)
      end
    end
  end

  defp accept_external_form_in_tx(actor, source, id, interaction_id, attrs) do
    uid = Ankole.AuthZ.Actor.uid(actor)
    now = DateTime.utc_now(:microsecond)

    with :ok <- Ankole.Pod.lock_tree_in_tx(),
         :ok <- authorize_operator(uid),
         :ok <- lock_interaction_source(source, %{action: %{"operator_principal_uid" => uid}}),
         %Signal{} = source <- Ankole.Signals.lock_signal_in_tx(source.id),
         preview = PreviewStates.lock_in_tx(source),
         %{"state" => "pending", "form" => form} <-
           InteractionState.interaction(preview.checkpoint || %{}, id),
         nil <- first_newer_session_reset(source),
         {:ok, answer} <- form_answer(form, Ankole.Attrs.get(attrs, :values)),
         resolution =
           actor
           |> native_resolution(answer)
           |> Map.merge(%{
             "operator_principal_uid" => uid,
             "resolved_at" => DateTime.to_iso8601(now)
           }),
         {:ok, checkpoint} <- InteractionState.resolve(preview.checkpoint, id, resolution),
         {:ok, _source} <- PreviewStates.put_checkpoint_in_tx(source, checkpoint) do
      accepted = %{"interaction_id" => id, "source_signal_id" => source.id, "answer" => answer}

      if Ankole.Conversations.Peers.exchange(source.conversation_id),
        do:
          Ankole.Conversations.Peers.answer_external_in_tx(
            source,
            %{sender_key: uid, source_event_id: "interaction-answer:" <> interaction_id},
            accepted
          ),
        else: wake_external_answer_in_tx(source, uid, interaction_id, accepted, now)
    else
      {:error, _reason} = error -> error
      _ -> {:error, :interaction_not_pending}
    end
  end

  @doc """
  Resolves a pending external wait interaction (such as connector authorization
  or resource access grant) when the caller already holds the target Session
  advisory lock (Rank 9), locking Signal and PreviewState at Rank 11 and waking
  the session with `signal.action.invoked`.
  """
  def resolve_external_wait_in_tx(
        %Signal{} = source,
        local_id,
        actor_uid,
        actor_name,
        %{"kind" => _, "value" => value} = answer,
        %DateTime{} = now
      )
      when is_binary(local_id) and is_binary(actor_uid) and is_binary(value) do
    interaction_id = source.id <> ":" <> local_id

    with %Signal{} = locked_source <- Ankole.Signals.lock_signal_in_tx(source.id),
         preview = PreviewStates.lock_in_tx(locked_source),
         %{"state" => "pending"} <-
           InteractionState.interaction(preview.checkpoint || %{}, local_id),
         nil <- first_newer_session_reset(locked_source),
         iso_now = DateTime.to_iso8601(now),
         resolution = %{
           "state" => "answered",
           "answer" => answer,
           "answered_by_uid" => actor_uid,
           "answered_by_name" => actor_name || actor_uid,
           "answered_at" => iso_now,
           "answer_text" => value,
           "operator_principal_uid" => actor_uid,
           "resolved_at" => iso_now
         },
         {:ok, checkpoint} <- InteractionState.resolve(preview.checkpoint, local_id, resolution),
         {:ok, _source} <- PreviewStates.put_checkpoint_in_tx(locked_source, checkpoint) do
      accepted = %{
        "interaction_id" => local_id,
        "source_signal_id" => locked_source.id,
        "answer" => answer
      }

      if Ankole.Conversations.Peers.exchange(locked_source.conversation_id) do
        Ankole.Conversations.Peers.answer_external_in_tx(
          locked_source,
          %{sender_key: actor_uid, source_event_id: "interaction-answer:" <> interaction_id},
          accepted
        )
      else
        wake_external_answer_in_tx(locked_source, actor_uid, interaction_id, accepted, now)
      end
    else
      {:error, _reason} = error -> error
      _ -> {:error, :interaction_not_pending}
    end
  end

  defp wake_external_answer_in_tx(source, uid, interaction_id, accepted, now) do
    Ankole.Signals.accept_in_tx(%{
      producer: :kernel,
      source: "control-plane://reply-interactions",
      id: "interaction-answer:" <> interaction_id,
      type: "signal.action.invoked",
      subject: source.conversation_id || source.session_id,
      target: %{agent_uid: source.agent_uid, session_id: source.session_id},
      sender: uid,
      time: now,
      reply_route: %{
        binding_id: source.reply_binding_id,
        binding_name: source.reply_binding_name,
        conversation_id: source.conversation_id,
        provider_thread_id: source.provider_thread_id,
        provider_message_id: source.provider_message_id
      },
      data:
        Ankole.Attrs.maybe_put(
          %{
            "action" => %{
              "name" => "reply_interaction",
              "value" => accepted,
              "operator_principal_uid" => uid
            }
          },
          "conversation_id",
          source.conversation_id
        )
    })
  end

  defp publish_standalone(%Signal{} = signal), do: Ankole.Signals.publish_committed([signal])

  defp publish_standalone(result),
    do: Ankole.Conversations.Native.publish_native_change(result)

  defp interaction_source(interaction_id) when is_binary(interaction_id) do
    with [signal_id, id] <- String.split(interaction_id, ":", parts: 2),
         {:ok, signal_id} <- Ecto.UUID.cast(signal_id),
         {:ok, %Signal{} = source} <- Ankole.Signals.get_signal(signal_id) do
      {:ok, source, id}
    else
      _ -> {:error, :not_found}
    end
  end

  defp interaction_source(_interaction_id), do: {:error, :not_found}

  # A colleague's peer question belongs to the conversation that started the exchange.
  defp interaction_origin(%Signal{conversation_id: nil}), do: nil

  defp interaction_origin(%Signal{conversation_id: id}) do
    case Ankole.Conversations.get_conversation!(id) do
      %{native_access_scope: :agent_peer, origin_conversation_id: origin_id} ->
        Ankole.Conversations.get_conversation!(origin_id)

      conversation ->
        conversation
    end
  end

  defp standalone_visible?(actor, %{kind: :native, id: id}),
    do: Ankole.Conversations.Native.visible_conversation?(actor, id)

  defp standalone_visible?(actor, _external), do: Ankole.Conversations.Native.active_human?(actor)

  defp answer_source_visible(_actor, id, %{conversation_id: id}), do: :ok

  defp answer_source_visible(actor, id, source) do
    with {:ok, _} <- Ankole.Conversations.Peers.visible(actor, id, source.conversation_id),
         do: :ok
  end

  defp post_native_answer(actor, id, %{conversation_id: id}, attrs),
    do: Ankole.Conversations.Native.post_in_tx(actor, id, attrs)

  defp post_native_answer(actor, id, source, attrs),
    do: Ankole.Conversations.Peers.answer_in_tx(actor, id, source, attrs)

  defp native_answer(checkpoint, id, attrs) do
    presentation = ReplyPresentation.normalize(checkpoint["presentation"])
    choice_id = Ankole.Attrs.get(attrs, :choice_id)
    values = Ankole.Attrs.get(attrs, :values)
    form = InteractionState.interaction(checkpoint, id)["form"]

    answer_text = Ankole.Attrs.get(attrs, :answer_text) || ""
    has_attachments = (Ankole.Attrs.get(attrs, :attachments) || []) != []

    actions = Enum.filter(presentation["actions"], &(&1["interaction_id"] == id))

    cond do
      not is_nil(values) ->
        form_answer(form, values)

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

  defp form_answer(%{"fields" => fields}, values) do
    case ClarifyForm.answer(fields, values) do
      {:ok, typed} ->
        {:ok,
         %{"kind" => "form", "values" => typed, "value" => ClarifyForm.summary(fields, typed)}}

      {:error, errors} ->
        {:error, {:invalid_form_answer, errors}}
    end
  end

  defp form_answer(_form, _values), do: {:error, :invalid_reply_interaction}

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

  A form submission that fails `ClarifyForm.answer/2` returns
  `{:invalid_form, notice}` and leaves the question pending. The notice names
  each rejected field so the adapter can show it on the callback response; a
  channel whose adapter does not declare `action_notice`, and so has no
  callback response, also receives the notice as a reply.
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
         :ok <- lock_interaction_source(source, fact),
         %Signal{} = event <- lock_source_event(binding, fact, callback),
         {:ok, result} <- accept_locked_event(binding, event, fact, callback, now) do
      {:ok, result}
    else
      nil -> {:ok, :stale}
      {:error, _reason} = error -> error
    end
  end

  defp lock_interaction_source(source, fact) do
    case Ankole.Conversations.Peers.exchange(source.conversation_id) do
      nil ->
        Ankole.Signals.lock_target_in_tx(%{
          agent_uid: source.agent_uid,
          session_id: source.session_id
        })

      _peer ->
        uid = map_value(fact.action, "operator_principal_uid")

        with :ok <- Ankole.Conversations.Native.lock_session_participants_in_tx(source, [uid]),
             :ok <-
               Ankole.Sessions.Queue.lock_sessions_in_tx(
                 Ankole.Conversations.peer_session_keys(source)
               ),
             :ok <- Ankole.Conversations.Peers.lock_rooms([source.conversation_id]),
             {:ok, human} <- Ankole.Principals.get_principal(uid),
             do:
               Ankole.Conversations.authorize_agent(
                 Ankole.AuthZ.Actor.new(human),
                 source.agent_uid
               )
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
      "form" -> {:ok, Map.merge(base, %{kind: "form", form_value: map_value(value, "formValue")})}
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
    source = Ankole.Signals.get_signal!(callback.source_signal_id)

    if Ankole.Conversations.Peers.callback_origin(source, binding.id, fact.conversation_id) ==
         {fact.agent_uid, fact.session_id} do
      [id: source.id]
    else
      [
        id: callback.source_signal_id,
        agent_uid: fact.agent_uid,
        reply_binding_id: binding.id,
        session_id: fact.session_id
      ]
    end
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

  defp accept_locked_event(binding, event, fact, callback, now) do
    checkpoint = PreviewStates.get(event).checkpoint || %{}

    case InteractionState.interaction(checkpoint, callback.interaction_id) do
      %{"state" => "pending"} = interaction ->
        accept_pending_answer(binding, event, checkpoint, interaction, fact, callback, now)

      %{"state" => "answered", "answer" => answer} = interaction ->
        case callback_answer(callback, interaction) do
          {:ok, %{answer: ^answer}} -> {:ok, :duplicate}
          _changed_or_invalid -> {:ok, :stale}
        end

      %{"state" => "superseded"} ->
        {:ok, :stale}

      _missing_or_invalid ->
        {:ok, :stale}
    end
  end

  defp accept_pending_answer(binding, event, checkpoint, interaction, fact, callback, now) do
    case first_newer_session_reset(event) do
      %Signal{} = reset_event ->
        with {:ok, _superseded} <-
               supersede_events_in_tx([event], reset_event, now) do
          {:ok, :stale}
        end

      nil ->
        accept_current_answer(binding, event, checkpoint, interaction, fact, callback, now)
    end
  end

  defp accept_current_answer(binding, event, checkpoint, interaction, fact, callback, now) do
    presentation = ReplyPresentation.normalize(checkpoint["presentation"])

    with true <- ReplyPresentation.matches?(presentation, callback) || :stale,
         {:ok, callback} <- callback_answer(callback, interaction),
         resolution = %{
           "state" => "answered",
           "answer" => callback.answer,
           "interaction_version" => callback.interaction_version,
           "control_id" => callback.control_id,
           "operator_principal_uid" => map_value(fact.action, "operator_principal_uid"),
           "resolved_at" => DateTime.to_iso8601(now),
           "source_event_id" => fact.source_event_id
         },
         {:ok, updated_checkpoint} <-
           InteractionState.resolve(checkpoint, callback.interaction_id, resolution),
         {:ok, _updated} <- PreviewStates.put_checkpoint_in_tx(event, updated_checkpoint) do
      {:ok, {:accepted, accepted_resolution(callback)}}
    else
      :stale ->
        {:ok, :stale}

      {:error, {:invalid_form_answer, errors}} ->
        reject_form_in_tx(binding, event, fact, interaction["form"], errors)

      {:error, _reason} = error ->
        error
    end
  end

  # A card form callback carries the submitted values; the pending interaction's
  # form decides what they mean.
  defp callback_answer(%{kind: "form"} = callback, %{"form" => form}) do
    with {:ok, answer} <-
           form_answer(form, ClarifyForm.card_values(form["fields"], callback.form_value)),
         do: {:ok, Map.put(callback, :answer, answer)}
  end

  defp callback_answer(%{kind: "form"}, _interaction), do: :stale
  defp callback_answer(callback, _interaction), do: {:ok, callback}

  defp reject_form_in_tx(binding, source, fact, form, errors) do
    notice = ClarifyForm.error_text(form["fields"], errors)

    with :ok <- maybe_notify_invalid_form_in_tx(binding, source, fact, notice),
         do: {:ok, {:invalid_form, notice}}
  end

  defp maybe_notify_invalid_form_in_tx(binding, source, fact, notice) do
    if action_notice?(binding) do
      :ok
    else
      outbound_key = "interaction-form-invalid:" <> fact.source_event_id

      Ankole.Conversations.Delivery.commit_in_tx(%{
        agent_uid: source.agent_uid,
        binding_id: binding.id,
        binding_name: binding.name,
        outbound_key: outbound_key,
        operation: if(is_binary(fact.provider_message_id), do: :reply, else: :post),
        delivery_class: :generic,
        conversation_id: fact.conversation_id || source.conversation_id,
        source_signal_id: source.id,
        provider_thread_id: fact.provider_thread_id || source.provider_thread_id,
        reply_to_provider_message_id: fact.provider_message_id,
        payload: %{"text" => notice, "metadata" => %{"source" => "interaction_form_invalid"}},
        fallback_visible_text: notice,
        idempotency_key: outbound_key
      })
      |> case do
        {:ok, _intent} ->
          :ok

        {:error, reason} = error ->
          if Ankole.Conversations.Delivery.unroutable_reply_reason?(reason), do: :ok, else: error
      end
    end
  end

  defp action_notice?(binding) do
    case Ankole.Signals.Adapters.fetch_delivery(binding.adapter) do
      {:ok, adapter} ->
        MapSet.member?(
          Ankole.Conversations.Delivery.Adapter.capabilities(adapter),
          :action_notice
        )

      {:error, _unavailable} ->
        false
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

  defp supersede_events_in_tx(events, newer_event, now, opts \\ []) do
    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, updated} ->
      case InteractionState.supersede(
             PreviewStates.get(event).checkpoint || %{},
             newer_event,
             now,
             opts
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
    Ankole.Signals.list_signals!(
      query: [
        filter:
          Ash.Expr.expr(
            agent_uid == ^event.agent_uid and session_id == ^event.session_id and
              queue_sequence > ^event.queue_sequence and
              (type in ^Types.interaction_superseding_types() or
                 (type == "agent.peer_message" and fragment("?->>'priority' = 'true'", data)))
          ),
        sort: [queue_sequence: :asc],
        limit: 1
      ]
    )
    |> List.first()
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
