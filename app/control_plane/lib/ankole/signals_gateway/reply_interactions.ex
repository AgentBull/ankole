defmodule Ankole.SignalsGateway.ReplyInteractions do
  @moduledoc """
  Authorizes and accepts actions emitted by an Ankole reply presentation.

  A CardKit button is only a signed-looking transport value, not authority. The
  durable ActorEvent checkpoint is the source of truth for which interaction is
  current, which choices exist, and whether an answer was already accepted.
  """

  import Ecto.Query, warn: false

  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.IngressFact
  alias Ankole.SignalsGateway.ReplyPresentation

  @action_protocol "ankole.interactive_output.action.v1"

  @type acceptance :: :accepted | :duplicate | :stale | :unmanaged

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
         {:ok, control_id} <- required_text(value, "controlId"),
         {:ok, selected_option_id} <- required_text(value, "selectedOptionId"),
         {:ok, option_value} <- required_text(value, "optionValue") do
      {:ok,
       %{
         source_actor_event_id: source_actor_event_id,
         interaction_id: interaction_id,
         interaction_version: interaction_version,
         control_id: control_id,
         selected_option_id: selected_option_id,
         option_value: option_value
       }}
    end
  end

  defp normalize_callback(_value), do: {:error, :invalid_reply_interaction}

  defp authorize_operator(repo, principal_uid) when is_binary(principal_uid) do
    case repo.get(Principal, principal_uid) do
      %Principal{type: :human, status: :active} -> :ok
      %Principal{} -> {:error, :reply_interaction_operator_unauthorized}
      nil -> {:error, :reply_interaction_operator_unknown}
    end
  end

  defp authorize_operator(_repo, _principal_uid),
    do: {:error, :reply_interaction_operator_missing}

  defp lock_source_event(repo, binding, fact, callback) do
    event =
      ActorEvent
      |> where([event], event.id == ^callback.source_actor_event_id)
      |> where([event], event.agent_uid == ^binding.agent_uid)
      |> where([event], event.binding_name == ^binding.name)
      |> lock("FOR UPDATE")
      |> repo.one()

    if reply_surface_entry?(event, fact.source_entry_id), do: event
  end

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
    interactions = map_value(checkpoint, "interactions")

    case map_value(interactions, callback.interaction_id) do
      %{} = accepted ->
        if same_selection?(accepted, callback), do: {:ok, :duplicate}, else: {:ok, :stale}

      nil ->
        accept_current_choice(repo, event, checkpoint, fact, callback, now)

      _invalid ->
        {:ok, :stale}
    end
  end

  defp accept_current_choice(repo, event, checkpoint, fact, callback, now) do
    presentation = ReplyPresentation.normalize(checkpoint["presentation"])

    if valid_choice?(presentation, callback) do
      updated_presentation = lock_interaction(presentation, callback)

      interaction = %{
        "interaction_id" => callback.interaction_id,
        "interaction_version" => callback.interaction_version,
        "control_id" => callback.control_id,
        "selected_option_id" => callback.selected_option_id,
        "option_value" => callback.option_value,
        "operator_principal_uid" => map_value(fact.action, "operator_principal_uid"),
        "accepted_at" => DateTime.to_iso8601(now),
        "source_event_id" => fact.source_event_id
      }

      updated_checkpoint =
        checkpoint
        |> Map.put("previous_presentation", ReplyPresentation.checkpoint(presentation))
        |> Map.put("presentation", ReplyPresentation.checkpoint(updated_presentation))
        |> Map.put("refresh_pending", true)
        |> Map.put("refresh_reason", "interaction")
        |> Map.update("interactions", %{callback.interaction_id => interaction}, fn current ->
          Map.put(
            if(is_map(current), do: current, else: %{}),
            callback.interaction_id,
            interaction
          )
        end)

      with {:ok, _updated} <-
             Actors.put_reply_preview_checkpoint_in_tx(repo, event, updated_checkpoint) do
        {:ok, :accepted}
      end
    else
      {:ok, :stale}
    end
  end

  defp valid_choice?(presentation, callback) do
    Enum.any?(presentation["actions"], fn action ->
      action["interaction_id"] == callback.interaction_id and
        action["revision"] == callback.interaction_version and
        action["control_id"] == callback.control_id and
        action["selected_option_id"] == callback.selected_option_id and
        action["option_value"] == callback.option_value and
        action["source_actor_event_id"] == callback.source_actor_event_id and
        action["disabled"] != true
    end)
  end

  defp lock_interaction(presentation, callback) do
    actions =
      Enum.map(presentation["actions"], fn action ->
        if action["interaction_id"] == callback.interaction_id do
          action
          |> Map.put("disabled", true)
          |> Map.put(
            "selected",
            action["control_id"] == callback.control_id and
              action["selected_option_id"] == callback.selected_option_id and
              action["option_value"] == callback.option_value
          )
        else
          action
        end
      end)

    presentation
    |> Map.put("actions", actions)
    |> Map.update("revision", 1, &(&1 + 1))
    |> ReplyPresentation.normalize()
  end

  defp same_selection?(accepted, callback) do
    map_value(accepted, "interaction_version") == callback.interaction_version and
      map_value(accepted, "control_id") == callback.control_id and
      map_value(accepted, "selected_option_id") == callback.selected_option_id and
      map_value(accepted, "option_value") == callback.option_value
  end

  defp required_text(map, key) do
    case map_value(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:invalid_reply_interaction, key}}
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
