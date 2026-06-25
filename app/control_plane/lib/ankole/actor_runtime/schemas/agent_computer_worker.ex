defmodule Ankole.ActorRuntime.Schemas.AgentComputerWorker do
  @moduledoc """
  Live registry projection for one external agent computer worker.

  This table is scheduling state, not a feature catalog. Workers are expected
  to be equivalent because they boot from the same image; capacity and load only
  decide whether a ready worker can accept another turn.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.SignalsGateway.JsonPayload

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  # `ready` workers can be assigned turns. `stale` is set by the watchdog when
  # heartbeats stop; the worker is no longer scheduled but its row lingers until a
  # TTL sweep deletes it, so the same worker_id re-announcing can reuse the row.
  @statuses ~w(ready stale draining stopped)

  schema "agent_computer_workers" do
    field :worker_id, :string
    field :worker_instance_id, :string
    field :status, :string
    field :version, :string
    field :capacity, :map, default: %{}
    field :load, :map, default: %{}
    field :transport_route, :string
    field :last_worker_heartbeat_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :stopped_at, :utc_datetime_usec
    field :stop_reason, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc false
  def changeset(worker, attrs) do
    worker
    |> cast(attrs, [
      :worker_id,
      :worker_instance_id,
      :status,
      :version,
      :capacity,
      :load,
      :transport_route,
      :last_worker_heartbeat_at,
      :started_at,
      :stopped_at,
      :stop_reason,
      :metadata
    ])
    |> normalize_blank([
      :worker_id,
      :worker_instance_id,
      :status,
      :version,
      :transport_route,
      :stop_reason
    ])
    |> validate_required([
      :worker_id,
      :worker_instance_id,
      :status,
      :version,
      :capacity,
      :load,
      :metadata
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_runtime_metadata()
    |> JsonPayload.validate_map(:capacity, allow_datetime: true)
    |> JsonPayload.validate_map(:load, allow_datetime: true)
    |> JsonPayload.validate_map(:metadata, allow_datetime: true)
    # worker_id, worker_instance_id, and transport_route are each a distinct
    # globally-unique routing identity: worker_id is the stable logical worker,
    # worker_instance_id changes per (re)boot, and transport_route is the live
    # ZeroMQ address. Uniqueness stops two rows claiming the same route to send to.
    |> unique_constraint([:worker_id], name: :agent_computer_workers_worker_id_index)
    |> unique_constraint([:worker_instance_id], name: :agent_computer_workers_instance_id_index)
    |> unique_constraint([:transport_route], name: :agent_computer_workers_transport_route_index)
  end

  defp normalize_blank(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, &normalize_blank(&2, &1))
  end

  defp normalize_blank(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value ->
        value
    end)
  end

  # Runtime metadata is required so operators can distinguish worker families
  # while keeping placement independent from per-worker feature negotiation.
  defp validate_runtime_metadata(changeset) do
    validate_change(changeset, :metadata, fn :metadata, metadata ->
      case metadata do
        %{} ->
          case Map.get(metadata, "runtime") || Map.get(metadata, :runtime) do
            value when is_binary(value) and value != "" -> []
            _value -> [metadata: "must include runtime"]
          end

        _value ->
          []
      end
    end)
  end
end
