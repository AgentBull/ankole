defmodule Ankole.SignalsGateway.ActorRuntime.TurnRef do
  @moduledoc """
  RuntimeFabric turn fence echoed by worker-originated turn traffic, and the
  one place that compares that fence with the database rows.

  A turn reference is not an agent profile. It is the compact fence copied from
  runtime-owned activation state and must be interpreted through the Principal
  UID normalization path before it is used for authorization or durable writes.

  `lookup/3` reads Worker, activation, and assignment in that lock order.
  Completion and abort callers then lock the current ActorEvent and call
  `lock_live_deliveries/2`. `match/4` decides and never reads, so each rejection
  atom is a pure function of the rows, the fence, and the mode.

  Modes and what they compare:

    * `:progress` — a live, lease-alive activation with the same actor key,
      activation uid, epoch, current event, and a revision at or above the
      worker's. Renews the lease, so it needs `now:`.
    * `:abort` — the same activation fields without status or lease: an abort
      must land after the lease ended. Every live delivery under the event
      fence must carry the same static fence.
    * `:complete` — like `:progress`, plus every live delivery under the event
      fence must carry the same static fence and the main delivery must have
      reached the worker. Needs `now:`.
    * `:route_read` and `:route_write` — the worker behind the route is a
      ready or draining worker that owns a live activation and a live
      assignment for this turn. A write also needs the activation revision at
      or above the worker's. Every miss is `:worker_not_assigned_to_turn`.
    * `:terminal_retry` — a repeated terminal RPC after its commit: the static
      fence and revision rule hold on an activation that finished a turn
      (`active`/`draining`) or failed it. The caller still proves the terminal
      record (completed ActorEvent or superseded delivery).
  """

  import Ecto.Query, warn: false

  alias Ankole.Principals
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker

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

  @type rows :: %{
          worker: AgentComputerWorker.t() | nil,
          activation: ActorSessionActivation.t() | nil,
          assignment: ActorSessionWorkerAssignment.t() | nil,
          deliveries: [ActorEventDelivery.t()] | nil
        }

  @type mode :: :progress | :abort | :complete | :route_read | :route_write | :terminal_retry

  @terminal_activation_statuses ~w(active draining failed)

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

  @doc """
  Reads the rows that fence one worker turn. The worker is locked before the
  activation so worker-originated paths share one lock prefix with placement
  and admission instead of forming worker/activation lock cycles.

  Options:

    * `:lock` — take `FOR UPDATE` on each row. Default `true`.
    * `:route` — resolve the worker by its transport route instead of the
      activation's assigned worker, and also read the live assignment. This is
      the route-authorization shape.

  A row that does not exist is `nil`; a row set that was not requested is
  `nil` too. `match/4` turns those into the mode's rejection atom.
  """
  @spec lookup(module(), t(), keyword()) :: rows()
  def lookup(repo, %__MODULE__{} = turn_ref, opts \\ []) do
    lock? = Keyword.get(opts, :lock, true)
    route = Keyword.get(opts, :route)

    worker =
      case route do
        nil -> assigned_worker(repo, turn_ref, lock?)
        route -> worker_by_route(repo, route, lock?)
      end

    %{
      worker: worker,
      activation: worker && activation_for_worker(repo, turn_ref, worker.worker_id, lock?),
      assignment: worker && route && live_assignment(repo, turn_ref, worker.worker_id, lock?),
      deliveries: nil
    }
  end

  @doc """
  Locks the live deliveries after the caller locks the current ActorEvent.

  Completion and abort first use lookup/3 to lock Worker and activation,
  then lock the ActorEvent, then load these deliveries. Source retraction
  also locks the ActorEvent before its deliveries.
  """
  @spec lock_live_deliveries(module(), t()) :: [ActorEventDelivery.t()]
  def lock_live_deliveries(repo, %__MODULE__{} = turn_ref) do
    ActorEventDelivery
    |> where([delivery], delivery.actor_event_id_fence == ^turn_ref.actor_event_id)
    |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  @doc """
  Decides whether the fence rows admit the worker's turn reference in `mode`.
  `:progress` and `:complete` compare the lease with `now:`.
  """
  @spec match(rows(), t(), mode(), keyword()) :: :ok | {:error, atom()}
  def match(rows, turn_ref, mode, opts \\ [])

  def match(%{activation: nil}, %__MODULE__{}, mode, _opts)
      when mode in [:progress, :abort, :complete],
      do: {:error, :actor_runtime_fence_not_found}

  def match(%{activation: activation}, %__MODULE__{} = turn_ref, :progress, opts) do
    now = Keyword.fetch!(opts, :now)

    cond do
      not ActorSessionActivation.live?(activation) ->
        {:error, :activation_not_live}

      not ActorSessionActivation.lease_alive?(activation, now) ->
        {:error, :activation_lease_expired}

      activation.agent_uid != turn_ref.agent_uid ->
        {:error, :stale_actor_key}

      activation.session_id != turn_ref.session_id ->
        {:error, :stale_actor_key}

      activation.activation_uid != turn_ref.activation_uid ->
        {:error, :stale_activation_uid}

      activation.actor_epoch != turn_ref.actor_epoch ->
        {:error, :stale_actor_epoch}

      activation.revision < turn_ref.revision ->
        {:error, :stale_revision}

      activation.current_actor_event_id != turn_ref.actor_event_id ->
        {:error, :stale_actor_event_id}

      true ->
        :ok
    end
  end

  def match(%{activation: activation} = rows, %__MODULE__{} = turn_ref, :abort, _opts) do
    cond do
      activation.agent_uid != turn_ref.agent_uid ->
        {:error, :stale_actor_key}

      activation.session_id != turn_ref.session_id ->
        {:error, :stale_actor_key}

      activation.activation_uid != turn_ref.activation_uid ->
        {:error, :stale_activation_uid}

      activation.actor_epoch != turn_ref.actor_epoch ->
        {:error, :stale_actor_epoch}

      activation.revision < turn_ref.revision ->
        {:error, :stale_revision}

      activation.current_actor_event_id != turn_ref.actor_event_id ->
        {:error, :stale_actor_event_id}

      true ->
        match_deliveries(deliveries!(rows, :abort), turn_ref)
    end
  end

  def match(%{activation: activation} = rows, %__MODULE__{} = turn_ref, :complete, opts) do
    now = Keyword.fetch!(opts, :now)

    cond do
      not ActorSessionActivation.live?(activation) ->
        {:error, :activation_not_live}

      not ActorSessionActivation.lease_alive?(activation, now) ->
        {:error, :activation_lease_expired}

      activation.actor_epoch != turn_ref.actor_epoch ->
        {:error, :stale_actor_epoch}

      activation.revision < turn_ref.revision ->
        {:error, :stale_revision}

      activation.current_actor_event_id != turn_ref.actor_event_id ->
        {:error, :stale_actor_event_id}

      true ->
        match_completion_deliveries(deliveries!(rows, :complete), turn_ref)
    end
  end

  def match(rows, %__MODULE__{} = turn_ref, mode, _opts)
      when mode in [:route_read, :route_write] do
    %{worker: worker, activation: activation, assignment: assignment} = rows

    cond do
      is_nil(worker) or is_nil(activation) ->
        {:error, :worker_not_assigned_to_turn}

      activation.actor_epoch != turn_ref.actor_epoch ->
        {:error, :worker_not_assigned_to_turn}

      activation.current_actor_event_id != turn_ref.actor_event_id ->
        {:error, :worker_not_assigned_to_turn}

      not ActorSessionActivation.live?(activation) ->
        {:error, :worker_not_assigned_to_turn}

      is_nil(assignment) ->
        {:error, :worker_not_assigned_to_turn}

      mode == :route_write and activation.revision < turn_ref.revision ->
        {:error, :stale_revision}

      true ->
        :ok
    end
  end

  def match(
        %{worker: worker, activation: activation},
        %__MODULE__{} = turn_ref,
        :terminal_retry,
        _opts
      ) do
    cond do
      is_nil(worker) or is_nil(activation) ->
        {:error, :worker_not_assigned_to_turn}

      activation.actor_epoch != turn_ref.actor_epoch ->
        {:error, :worker_not_assigned_to_turn}

      activation.revision < turn_ref.revision ->
        {:error, :worker_not_assigned_to_turn}

      activation.status not in @terminal_activation_statuses ->
        {:error, :worker_not_assigned_to_turn}

      true ->
        :ok
    end
  end

  defp deliveries!(%{deliveries: deliveries}, _mode) when is_list(deliveries), do: deliveries

  defp deliveries!(_rows, mode) do
    raise ArgumentError,
          "TurnRef.match/4 in #{inspect(mode)} mode needs rows.deliveries; " <>
            "load them with lock_live_deliveries/2 after locking the ActorEvent"
  end

  defp match_completion_deliveries(deliveries, turn_ref) do
    with :ok <- match_deliveries(deliveries, turn_ref) do
      main_delivery_received(deliveries, turn_ref)
    end
  end

  defp match_deliveries([], _turn_ref), do: {:error, :actor_runtime_fence_not_found}

  defp match_deliveries(deliveries, turn_ref) do
    Enum.reduce_while(deliveries, :ok, fn delivery, :ok ->
      case delivery_matches(delivery, turn_ref) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # The delivery revision is not compared: a terminal Worker revision is the
  # highest input revision that it applied and can be lower than a newer
  # pending delivery.
  defp delivery_matches(%ActorEventDelivery{} = delivery, turn_ref) do
    cond do
      delivery.agent_uid != turn_ref.agent_uid -> {:error, :stale_actor_key}
      delivery.session_id != turn_ref.session_id -> {:error, :stale_actor_key}
      delivery.activation_uid != turn_ref.activation_uid -> {:error, :stale_activation_uid}
      delivery.actor_epoch != turn_ref.actor_epoch -> {:error, :stale_actor_epoch}
      delivery.actor_event_id_fence != turn_ref.actor_event_id -> {:error, :stale_actor_event_id}
      true -> :ok
    end
  end

  defp main_delivery_received(deliveries, turn_ref) do
    received? =
      Enum.any?(deliveries, fn delivery ->
        delivery.actor_event_id == turn_ref.actor_event_id and
          delivery.state in ["sent", "accepted"]
      end)

    if received?, do: :ok, else: {:error, :main_delivery_not_received}
  end

  defp assigned_worker(repo, turn_ref, lock?) do
    case activation_snapshot(repo, turn_ref) do
      %ActorSessionActivation{assigned_worker_id: worker_id} when is_binary(worker_id) ->
        worker_by_id(repo, worker_id, lock?)

      _activation ->
        nil
    end
  end

  defp activation_snapshot(repo, turn_ref) do
    turn_ref
    |> activation_query()
    |> repo.one()
  end

  defp activation_for_worker(repo, turn_ref, worker_id, lock?) do
    turn_ref
    |> activation_query()
    |> where([activation], activation.assigned_worker_id == ^worker_id)
    |> maybe_lock(lock?)
    |> repo.one()
  end

  defp activation_query(turn_ref) do
    ActorSessionActivation
    |> where([activation], activation.agent_uid == ^turn_ref.agent_uid)
    |> where([activation], activation.session_id == ^turn_ref.session_id)
    |> where([activation], activation.activation_uid == ^turn_ref.activation_uid)
  end

  defp worker_by_id(repo, worker_id, lock?) do
    AgentComputerWorker
    |> where([worker], worker.worker_id == ^worker_id)
    |> maybe_lock(lock?)
    |> repo.one()
  end

  defp worker_by_route(repo, route, lock?) do
    AgentComputerWorker
    |> where([worker], worker.transport_route == ^route)
    |> where([worker], worker.status in ["ready", "draining"])
    |> maybe_lock(lock?)
    |> repo.one()
  end

  defp live_assignment(repo, turn_ref, worker_id, lock?) do
    ActorSessionWorkerAssignment
    |> where([assignment], assignment.agent_uid == ^turn_ref.agent_uid)
    |> where([assignment], assignment.session_id == ^turn_ref.session_id)
    |> where([assignment], assignment.worker_id == ^worker_id)
    |> where([assignment], assignment.status in ["assigned", "draining"])
    |> maybe_lock(lock?)
    |> repo.one()
  end

  defp maybe_lock(query, true), do: lock(query, "FOR UPDATE")
  defp maybe_lock(query, false), do: query

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
