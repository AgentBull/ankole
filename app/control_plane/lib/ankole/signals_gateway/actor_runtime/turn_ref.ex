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

  @spec from_wire(map()) :: {:ok, t()} | {:error, :invalid_turn_ref}
  def from_wire(%{} = turn_ref) do
    with %{} = actor <- map_value(turn_ref, "actor"),
         {:ok, agent_uid} <- actor |> text_value("agent_uid") |> Principals.normalize_uid(),
         session_id when is_binary(session_id) <- text_value(actor, "session_id"),
         activation_uid when is_binary(activation_uid) <- text_value(turn_ref, "activation_uid"),
         actor_epoch when is_integer(actor_epoch) and actor_epoch > 0 <-
           integer_value(turn_ref, "actor_epoch"),
         actor_event_id when is_binary(actor_event_id) <- text_value(turn_ref, "actor_event_id"),
         revision when is_integer(revision) and revision >= 0 <-
           integer_value(turn_ref, "revision") do
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

  def from_wire(_turn_ref), do: {:error, :invalid_turn_ref}

  @doc """
  Reads the turn fence echoed by worker payloads under the `turn` key.
  """
  @spec from_request(map()) :: {:ok, t()} | {:error, :missing_turn_ref | :invalid_turn_ref}
  def from_request(request) when is_map(request) do
    case map_value(request, "turn") do
      nil -> {:error, :missing_turn_ref}
      turn_ref -> from_wire(turn_ref)
    end
  end

  def from_request(_request), do: {:error, :missing_turn_ref}

  @spec from_activation(map(), ActorSessionActivation.t()) :: t()
  def from_activation(actor_key, %ActorSessionActivation{} = activation) when is_map(actor_key) do
    {:ok, agent_uid} = actor_key |> text_value("agent_uid") |> Principals.normalize_uid()

    %__MODULE__{
      agent_uid: agent_uid,
      session_id: text_value(actor_key, "session_id"),
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

  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = turn_ref) do
    %{
      "actor" => %{
        "agent_uid" => turn_ref.agent_uid,
        "session_id" => turn_ref.session_id
      },
      "activation_uid" => turn_ref.activation_uid,
      "actor_epoch" => turn_ref.actor_epoch,
      "actor_event_id" => turn_ref.actor_event_id,
      "revision" => turn_ref.revision
    }
  end

  @doc """
  Converts the generated RuntimeFabric envelope fence into the domain fence.

  This is the envelope-boundary twin of `from_wire/1`, which keeps owning the
  JSON map fence carried inside RPC `payload_json` contracts.
  """
  @spec from_proto(FabricProto.ActorTurnRef.t() | nil) :: {:ok, t()} | {:error, :invalid_turn_ref}
  def from_proto(%FabricProto.ActorTurnRef{actor: %FabricProto.ActorKey{}} = turn_ref) do
    from_wire(%{
      "actor" => %{
        "agent_uid" => turn_ref.actor.agent_uid,
        "session_id" => turn_ref.actor.session_id
      },
      "activation_uid" => turn_ref.activation_uid,
      "actor_epoch" => turn_ref.actor_epoch,
      "actor_event_id" => turn_ref.actor_event_id,
      "revision" => turn_ref.revision
    })
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

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp text_value(map, key) when is_map(map) do
    case map_value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _value ->
        nil
    end
  end

  defp integer_value(map, key) when is_map(map) do
    case map_value(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {integer, ""} -> integer
          _value -> nil
        end

      _value ->
        nil
    end
  end
end
