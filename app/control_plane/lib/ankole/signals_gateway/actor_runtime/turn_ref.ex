defmodule Ankole.SignalsGateway.ActorRuntime.TurnRef do
  @moduledoc """
  RuntimeFabric turn fence echoed by worker-originated turn traffic.

  A turn reference is not an agent profile. It is the compact fence copied from
  runtime-owned activation state and must be interpreted through the Principal
  UID normalization path before it is used for authorization or durable writes.
  """

  alias Ankole.Principals
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation

  @enforce_keys [
    :agent_uid,
    :session_id,
    :activation_uid,
    :actor_epoch,
    :actor_event_id,
    :revision
  ]
  defstruct [:agent_uid, :session_id, :activation_uid, :actor_epoch, :actor_event_id, :revision]

  @type t :: %__MODULE__{
          agent_uid: String.t(),
          session_id: String.t(),
          activation_uid: String.t(),
          actor_epoch: pos_integer(),
          actor_event_id: String.t(),
          revision: non_neg_integer()
        }

  @spec from_activation(
          %{agent_uid: String.t(), session_id: String.t()},
          ActorSessionActivation.t()
        ) :: t()
  def from_activation(
        %{agent_uid: raw_agent_uid, session_id: session_id},
        %ActorSessionActivation{} = activation
      ) do
    {:ok, agent_uid} = Principals.normalize_uid(raw_agent_uid)

    %__MODULE__{
      agent_uid: agent_uid,
      session_id: presence(session_id),
      activation_uid: activation.activation_uid,
      actor_epoch: activation.actor_epoch,
      actor_event_id: activation.current_actor_event_id,
      revision: activation.revision
    }
  end

  @spec from_delivery(ActorEventDelivery.t()) :: t()
  def from_delivery(%ActorEventDelivery{} = delivery) do
    {:ok, agent_uid} = Principals.normalize_uid(delivery.agent_uid)

    %__MODULE__{
      agent_uid: agent_uid,
      session_id: delivery.session_id,
      activation_uid: delivery.activation_uid,
      actor_epoch: delivery.actor_epoch,
      actor_event_id: delivery.actor_event_id_fence,
      revision: delivery.revision
    }
  end

  @doc """
  Converts the generated RuntimeFabric fence into the domain fence. This is
  the single wire entry point; RPC frames and turn-lane envelopes both carry
  the generated `ActorTurnRef` message.
  """
  @spec from_proto(FabricProto.ActorTurnRef.t() | nil) :: {:ok, t()} | {:error, :invalid_turn_ref}
  def from_proto(%FabricProto.ActorTurnRef{actor: %FabricProto.ActorKey{} = actor} = turn_ref) do
    with {:ok, agent_uid} <- actor.agent_uid |> presence() |> Principals.normalize_uid(),
         session_id when is_binary(session_id) <- presence(actor.session_id),
         activation_uid when is_binary(activation_uid) <- presence(turn_ref.activation_uid),
         actor_epoch when is_integer(actor_epoch) and actor_epoch > 0 <- turn_ref.actor_epoch,
         actor_event_id when is_binary(actor_event_id) <- presence(turn_ref.actor_event_id),
         revision when is_integer(revision) and revision >= 0 <- turn_ref.revision do
      {:ok,
       %__MODULE__{
         agent_uid: agent_uid,
         session_id: session_id,
         activation_uid: activation_uid,
         actor_epoch: actor_epoch,
         actor_event_id: actor_event_id,
         revision: revision
       }}
    else
      _value -> {:error, :invalid_turn_ref}
    end
  end

  def from_proto(_turn_ref), do: {:error, :invalid_turn_ref}

  @spec to_proto(t()) :: FabricProto.ActorTurnRef.t()
  def to_proto(%__MODULE__{} = turn_ref) do
    %FabricProto.ActorTurnRef{
      actor: %FabricProto.ActorKey{
        agent_uid: turn_ref.agent_uid,
        session_id: turn_ref.session_id
      },
      activation_uid: turn_ref.activation_uid,
      actor_epoch: turn_ref.actor_epoch,
      actor_event_id: turn_ref.actor_event_id,
      revision: turn_ref.revision
    }
  end

  @spec actor_key(t()) :: %{agent_uid: String.t(), session_id: String.t()}
  def actor_key(%__MODULE__{} = turn_ref) do
    %{agent_uid: turn_ref.agent_uid, session_id: turn_ref.session_id}
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
