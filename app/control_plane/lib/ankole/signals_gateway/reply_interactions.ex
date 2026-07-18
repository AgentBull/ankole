defmodule Ankole.SignalsGateway.ReplyInteractions do
  @moduledoc """
  Authorizes and resolves interactions emitted by an Ankole reply presentation.

  Card callbacks are transport input, not authority. The durable ActorEvent
  checkpoint decides whether an interaction is pending, answered, or superseded.
  """

  import Ecto.Query, warn: false

  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorEventTypes
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.IngressFact
  alias Ankole.SignalsGateway.ReplyInteractionState
  alias Ankole.SignalsGateway.ReplyPresentation

  @action_protocol "ankole.interactive_output.action.v1"
  @max_free_text_chars 1_000

  @type accepted_resolution :: %{String.t() => term()}
  @type acceptance :: {:accepted, accepted_resolution()} | :duplicate | :stale | :unmanaged

  @doc """
  Opens one durable reply interaction in the same transaction as its outbox.

  A later ActorEvent may already be queued by the time a slow turn asks for
  clarification. In that case the interaction starts superseded and can never
  appear as a live question after the conversation has moved on.
  """
  @spec open_in_tx(module(), ActorEvent.t(), map(), DateTime.t()) ::
          {:ok, ActorEvent.t()} | {:error, term()}
  def open_in_tx(repo, %ActorEvent{} = event, presentation, %DateTime{} = now)
      when is_map(presentation) do
    checkpoint = event.reply_preview_checkpoint || %{}
    superseded_by = first_newer_conversation_event(repo, event)

    checkpoint =
      ReplyInteractionState.initialize(checkpoint, presentation, now,
        superseded_by: superseded_by
      )

    Actors.put_reply_preview_checkpoint_in_tx(repo, event, checkpoint)
  end

  @doc """
  Supersedes pending interactions older than a newly appended conversation turn.

  The caller already owns the actor-session advisory lock used to allocate the
  new event's queue sequence. Locking older ActorEvent rows under that same lock
  gives button/form callbacks and ordinary messages one deterministic winner.
  """
  @spec supersede_older_in_tx(module(), ActorEvent.t(), DateTime.t()) ::
          {:ok, [ActorEvent.t()]} | {:error, term()}
  def supersede_older_in_tx(repo, %ActorEvent{} = newer_event, %DateTime{} = now) do
    if ActorEventTypes.supersedes_pending_interaction?(newer_event.type) do
      newer_event
      |> older_reply_interaction_events(repo)
      |> supersede_events_in_tx(repo, newer_event, now)
    else
      {:ok, []}
    end
  end

  @doc """
  Supersedes pending interactions anchored to one removed provider entry.

  Provider lifecycle events remain globally interaction-preserving. The caller
  owns the actor-session lock, so only completed source ActorEvents that contain
  the removed entry can lose their pending interaction; unrelated cards in the
  same session remain actionable.
  """
  @spec supersede_removed_source_in_tx(module(), ActorEvent.t(), DateTime.t()) ::
          {:ok, [ActorEvent.t()]} | {:error, term()}
  def supersede_removed_source_in_tx(
        repo,
        %ActorEvent{type: "signal.entry.removed", source_entry_id: source_entry_id} =
          removed_event,
        %DateTime{} = now
      )
      when is_binary(source_entry_id) and source_entry_id != "" do
    Actors.actor_events_for_entry_in_tx(
      repo,
      removed_event.agent_uid,
      removed_event.binding_name,
      removed_event.signal_channel_id,
      source_entry_id
    )
    |> Enum.filter(&(&1.session_id == removed_event.session_id))
    |> Enum.map(&Actors.lock_actor_event_in_tx(repo, &1.id))
    |> Enum.reject(&is_nil/1)
    |> supersede_events_in_tx(repo, removed_event, now)
  end

  def supersede_removed_source_in_tx(_repo, %ActorEvent{}, %DateTime{}), do: {:ok, []}

  @doc """
  Supersedes predecessor interactions when a queued reset actually rolls the session.

  Enqueuing `session.reset_due` remains interaction-preserving because the reset
  may wait behind running work. Once the reset executes, its predecessor
  conversation is no longer available to interpret an isolated card answer.
  """
  @spec supersede_for_session_reset_in_tx(module(), ActorEvent.t(), DateTime.t()) ::
          {:ok, [ActorEvent.t()]} | {:error, term()}
  def supersede_for_session_reset_in_tx(
        repo,
        %ActorEvent{type: "session.reset_due"} = reset_event,
        %DateTime{} = now
      ) do
    reset_event
    |> older_reply_interaction_events(repo)
    |> supersede_events_in_tx(repo, reset_event, now)
  end

  def supersede_for_session_reset_in_tx(_repo, %ActorEvent{}, %DateTime{}), do: {:ok, []}

  @doc """
  Validates and records a managed reply action inside the ingress transaction.

  Unknown action protocols remain ordinary adapter actions. Managed callbacks
  are accepted at most once and always re-authorize the current human Principal.
  """
  @spec accept_in_tx(module(), Binding.t(), IngressFact.t(), DateTime.t()) ::
          {:ok, acceptance()} | {:error, term()}
  def accept_in_tx(repo, %Binding{} = binding, %IngressFact{} = fact, %DateTime{} = now) do
    action = fact.action || %{}
    value = map_value(action, "value")

    if map_value(value, "version") == @action_protocol do
      accept_managed_in_tx(repo, binding, fact, action, value, now)
    else
      {:ok, :unmanaged}
    end
  end

  defp accept_managed_in_tx(repo, binding, fact, action, value, now) do
    with {:ok, callback} <- normalize_callback(value),
         :ok <- authorize_operator(repo, map_value(action, "operator_principal_uid")),
         %ActorEvent{} = source <- find_source_event(repo, binding, fact, callback),
         :ok <- Actors.lock_actor_session_in_tx(repo, source.agent_uid, source.session_id),
         %ActorEvent{} = event <- lock_source_event(repo, binding, fact, callback),
         {:ok, result} <- accept_locked_event(repo, event, fact, callback, now) do
      {:ok, result}
    else
      nil -> {:ok, :stale}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_callback(value) when is_map(value) do
    with {:ok, source_actor_event_id} <- required_text(value, "sourceActorEventId"),
         {:ok, interaction_id} <- required_text(value, "interactionId"),
         {:ok, interaction_version} <- required_non_negative_integer(value, "interactionVersion"),
         {:ok, control_id} <- required_text(value, "controlId") do
      base = %{
        source_actor_event_id: source_actor_event_id,
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

  defp authorize_operator(repo, principal_uid) when is_binary(principal_uid) do
    case repo.get(Principal, principal_uid) do
      %Principal{type: :human, status: :active} -> :ok
      %Principal{} -> {:error, :reply_interaction_operator_unauthorized}
      nil -> {:error, :reply_interaction_operator_unknown}
    end
  end

  defp authorize_operator(_repo, _principal_uid),
    do: {:error, :reply_interaction_operator_missing}

  defp find_source_event(repo, binding, fact, callback) do
    source_event_query(binding, fact, callback)
    |> repo.one()
    |> accepted_reply_surface(fact.source_entry_id)
  end

  defp lock_source_event(repo, binding, fact, callback) do
    source_event_query(binding, fact, callback)
    |> lock("FOR UPDATE")
    |> repo.one()
    |> accepted_reply_surface(fact.source_entry_id)
  end

  defp source_event_query(binding, fact, callback) do
    ActorEvent
    |> where([event], event.id == ^callback.source_actor_event_id)
    |> where([event], event.agent_uid == ^binding.agent_uid)
    |> where([event], event.binding_name == ^binding.name)
    |> where([event], event.session_id == ^fact.session_id)
  end

  defp accepted_reply_surface(%ActorEvent{} = event, source_entry_id) do
    if reply_surface_entry?(event, source_entry_id), do: event
  end

  defp accepted_reply_surface(nil, _source_entry_id), do: nil

  defp reply_surface_entry?(%ActorEvent{} = event, source_entry_id)
       when is_binary(source_entry_id) do
    event.reply_preview_source_entry_id == source_entry_id or
      Enum.any?(get_in(event.reply_preview_checkpoint || %{}, ["cards"]) || [], fn
        %{"message_id" => ^source_entry_id} -> true
        _card -> false
      end)
  end

  defp reply_surface_entry?(_event, _source_entry_id), do: false

  defp accept_locked_event(repo, event, fact, callback, now) do
    checkpoint = event.reply_preview_checkpoint || %{}

    case ReplyInteractionState.interaction(checkpoint, callback.interaction_id) do
      %{"state" => "pending"} ->
        accept_pending_answer(repo, event, checkpoint, fact, callback, now)

      %{"state" => "answered", "answer" => answer} ->
        if answer == callback.answer, do: {:ok, :duplicate}, else: {:ok, :stale}

      %{"state" => "superseded"} ->
        {:ok, :stale}

      _missing_or_invalid ->
        {:ok, :stale}
    end
  end

  defp accept_pending_answer(repo, event, checkpoint, fact, callback, now) do
    case first_newer_session_reset(repo, event) do
      %ActorEvent{} = reset_event ->
        with {:ok, _superseded} <-
               supersede_events_in_tx([event], repo, reset_event, now) do
          {:ok, :stale}
        end

      nil ->
        accept_current_answer(repo, event, checkpoint, fact, callback, now)
    end
  end

  defp accept_current_answer(repo, event, checkpoint, fact, callback, now) do
    presentation = ReplyPresentation.normalize(checkpoint["presentation"])

    if valid_callback?(presentation, callback) do
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
             ReplyInteractionState.resolve(checkpoint, callback.interaction_id, resolution),
           {:ok, _updated} <-
             Actors.put_reply_preview_checkpoint_in_tx(repo, event, updated_checkpoint) do
        {:ok, {:accepted, accepted_resolution(callback)}}
      else
        :stale -> {:ok, :stale}
        {:error, _reason} = error -> error
      end
    else
      {:ok, :stale}
    end
  end

  defp valid_callback?(presentation, %{kind: "choice"} = callback) do
    Enum.any?(presentation["actions"], fn action ->
      action["type"] == "button" and
        matching_locator?(action, callback) and
        action["selected_option_id"] == callback.selected_option_id and
        action["option_value"] == callback.option_value
    end)
  end

  defp valid_callback?(presentation, %{kind: "free_text"} = callback) do
    Enum.any?(presentation["actions"], fn action ->
      action["type"] == "form" and
        matching_locator?(action, callback) and
        Enum.any?(action["fields"] || [], fn field ->
          field["type"] == "input" and field["id"] == callback.input_name
        end)
    end)
  end

  defp matching_locator?(action, callback) do
    action["interaction_id"] == callback.interaction_id and
      action["revision"] == callback.interaction_version and
      action["control_id"] == callback.control_id and
      action["source_actor_event_id"] == callback.source_actor_event_id and
      action["disabled"] != true
  end

  defp accepted_resolution(callback) do
    %{
      "interaction_id" => callback.interaction_id,
      "source_actor_event_id" => callback.source_actor_event_id,
      "answer" => callback.answer
    }
  end

  defp older_reply_interaction_events(%ActorEvent{} = newer_event, repo) do
    ActorEvent
    |> where([event], event.agent_uid == ^newer_event.agent_uid)
    |> where([event], event.session_id == ^newer_event.session_id)
    |> where([event], event.queue_sequence < ^newer_event.queue_sequence)
    |> where([event], not is_nil(event.reply_preview_checkpoint))
    |> where(
      [event],
      fragment(
        """
        (?->'presentation'->>'state' = 'awaiting_input'
          AND COALESCE(?->'presentation'->>'interaction_status', 'pending') = 'pending'
          AND COALESCE(?->'interactions', '{}'::jsonb) = '{}'::jsonb)
        OR EXISTS (
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
        event.reply_preview_checkpoint,
        event.reply_preview_checkpoint,
        event.reply_preview_checkpoint,
        event.reply_preview_checkpoint,
        event.reply_preview_checkpoint
      )
    )
    |> order_by([event], asc: event.queue_sequence)
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  defp supersede_events_in_tx(events, repo, newer_event, now) do
    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, updated} ->
      case ReplyInteractionState.supersede(
             event.reply_preview_checkpoint || %{},
             newer_event,
             now
           ) do
        :noop ->
          {:cont, {:ok, updated}}

        {:ok, checkpoint} ->
          case Actors.put_reply_preview_checkpoint_in_tx(repo, event, checkpoint) do
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

  defp first_newer_conversation_event(repo, %ActorEvent{} = event) do
    passive_types = ActorEventTypes.interaction_preserving_turn_types()

    ActorEvent
    |> where([candidate], candidate.agent_uid == ^event.agent_uid)
    |> where([candidate], candidate.session_id == ^event.session_id)
    |> where([candidate], candidate.queue_sequence > ^event.queue_sequence)
    |> where([candidate], candidate.type not in ^passive_types)
    |> order_by([candidate], asc: candidate.queue_sequence)
    |> limit(1)
    |> repo.one()
  end

  defp first_newer_session_reset(repo, %ActorEvent{} = event) do
    ActorEvent
    |> where([candidate], candidate.agent_uid == ^event.agent_uid)
    |> where([candidate], candidate.session_id == ^event.session_id)
    |> where([candidate], candidate.queue_sequence > ^event.queue_sequence)
    |> where([candidate], candidate.type == "session.reset_due")
    |> where([candidate], candidate.input_state == "open")
    |> order_by([candidate], asc: candidate.queue_sequence)
    |> limit(1)
    |> repo.one()
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

  defp required_text(map, key) do
    case map_value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:invalid_reply_interaction, key}}
          value -> {:ok, value}
        end

      _value ->
        {:error, {:invalid_reply_interaction, key}}
    end
  end

  defp required_non_negative_integer(map, key) do
    case map_value(map, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _value -> {:error, {:invalid_reply_interaction, key}}
    end
  end

  defp map_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_existing_atom(key))
    end
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp map_value(_map, _key), do: nil
end
