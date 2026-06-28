defmodule Ankole.ActorRuntime.CommitCoordinator.Fences do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.ActorRuntime.CommitCoordinator.Payload
  alias Ankole.ActorRuntime.Schemas.ActorInputDelivery
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation

  def require_turn_started(%LlmTurn{status: "started"}), do: :ok
  def require_turn_started(%LlmTurn{}), do: {:error, :llm_turn_not_started}

  def conversation_matches_turn(%Conversation{generation: generation}, %LlmTurn{
        lease_id: lease_id
      })
      when is_map(generation) do
    case generation["lease_id"] == lease_id and is_nil(generation["cancelled_at"]) do
      true -> :ok
      false -> {:error, :generation_lease_mismatch}
    end
  end

  def conversation_matches_turn(_conversation, _turn), do: {:error, :generation_lease_mismatch}

  def activation_for_turn_ref(repo, turn_ref) do
    ActorSessionActivation
    |> where([activation], activation.agent_uid == ^Payload.fetch_actor_agent_uid(turn_ref))
    |> where([activation], activation.session_id == ^Payload.fetch_actor_session_id(turn_ref))
    |> where(
      [activation],
      activation.activation_uid == ^Payload.fetch_text!(turn_ref, "activation_uid")
    )
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  def activation_accepts_turn(%ActorSessionActivation{} = activation, turn_ref, llm_turn, now) do
    case activation_matches_turn(activation, turn_ref, llm_turn) do
      :ok ->
        case DateTime.compare(activation.lease_expires_at, now) do
          :gt -> :ok
          _expired -> {:error, :activation_lease_expired}
        end

      {:error, _reason} = error ->
        error
    end
  end

  def activation_matches_turn(%ActorSessionActivation{} = activation, turn_ref, llm_turn) do
    cond do
      activation.agent_uid != Payload.fetch_actor_agent_uid(turn_ref) ->
        {:error, :stale_actor_key}

      activation.session_id != Payload.fetch_actor_session_id(turn_ref) ->
        {:error, :stale_actor_key}

      activation.activation_uid != Payload.fetch_text!(turn_ref, "activation_uid") ->
        {:error, :stale_activation_uid}

      activation.actor_epoch != Payload.fetch_int!(turn_ref, "actor_epoch") ->
        {:error, :stale_actor_epoch}

      activation.revision != Payload.fetch_int!(turn_ref, "revision") ->
        {:error, :stale_revision}

      activation.current_llm_turn_id != llm_turn.id ->
        {:error, :stale_llm_turn_id}

      true ->
        :ok
    end
  end

  def validate_deliveries_turn_ref(deliveries, turn_ref) do
    Enum.reduce_while(deliveries, :ok, fn
      delivery, :ok ->
        case delivery_matches_turn_ref(delivery, turn_ref) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end

      _delivery, {:error, _reason} = error ->
        {:halt, error}
    end)
  end

  defp delivery_matches_turn_ref(%ActorInputDelivery{} = delivery, turn_ref) do
    cond do
      delivery.agent_uid != Payload.fetch_actor_agent_uid(turn_ref) ->
        {:error, :stale_actor_key}

      delivery.session_id != Payload.fetch_actor_session_id(turn_ref) ->
        {:error, :stale_actor_key}

      delivery.activation_uid != Payload.fetch_text!(turn_ref, "activation_uid") ->
        {:error, :stale_activation_uid}

      delivery.actor_epoch != Payload.fetch_int!(turn_ref, "actor_epoch") ->
        {:error, :stale_actor_epoch}

      delivery.llm_turn_id != Payload.fetch_turn_id(turn_ref) ->
        {:error, :stale_llm_turn_id}

      # A worker echoes the revision it started with. A steer may bump only the
      # delivery revision while the turn is still valid, so reject strictly newer
      # durable delivery revisions rather than every non-equal revision.
      delivery.revision > Payload.fetch_int!(turn_ref, "revision") ->
        {:error, :stale_revision}

      true ->
        :ok
    end
  end
end
