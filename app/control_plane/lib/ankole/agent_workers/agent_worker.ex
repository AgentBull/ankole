defmodule Ankole.AgentWorkers.AgentWorker do
  @moduledoc """
  The one Worker of one Agent.

  The row records what the control plane decided for this Agent's Worker
  (`generation`, `token_digest`, `image`, `protocol_version`,
  `settings_digest`, `instance_settings`, `wanted_until`) and what
  `WorkerAdmission` observed on its connection (`incarnation_id`,
  `transport_route`, `capacity`, `load`, `last_worker_heartbeat_at`).
  `AgentWorkers` owns the decisions and
  `WorkerAdmission` owns the connection columns. Lifecycle times are database
  time.

  States: `absent` has no Worker; `starting` has a generation whose process has
  not joined; `ready` has a usable connection; `stale` joined before but its
  connection is gone; `paused` keeps the process memory and credential;
  `draining` waits for the platform instance to disappear; `deleting` waits
  for the instances and storage of a deleted Agent to disappear.
  """

  use Ankole.Schema, tenancy: :tenant

  @primary_key {:agent_uid, :string, autogenerate: false}

  schema "agent_workers" do
    field :provider_id, :string
    field :state, :string, default: "absent"
    field :generation, :string
    field :create_sent_at, :utc_datetime_usec
    field :instance_ref, :string
    field :storage_ref, :map
    field :token_digest, :binary, redact: true
    field :token_ciphertext, :binary, redact: true
    field :instance_seen_at, :utc_datetime_usec
    field :image, :string
    field :protocol_version, :integer
    field :settings_digest, :string
    field :instance_settings, :map, default: %{}
    field :wanted_until, :utc_datetime_usec
    field :last_error, :string
    field :last_error_kind, :string
    field :state_changed_at, :utc_datetime_usec, read_after_writes: true
    field :incarnation_id, :string
    field :transport_route, :string
    field :capacity, :map, default: %{}
    field :load, :map, default: %{}
    field :last_worker_heartbeat_at, :utc_datetime_usec
    field :drain_reason, :string
  end

  @type state :: String.t()
  @type t :: %__MODULE__{
          agent_uid: String.t() | nil,
          provider_id: String.t() | nil,
          state: state() | nil,
          generation: String.t() | nil,
          create_sent_at: DateTime.t() | nil,
          instance_ref: String.t() | nil,
          storage_ref: map() | nil,
          token_digest: binary() | nil,
          token_ciphertext: binary() | nil,
          instance_seen_at: DateTime.t() | nil,
          image: String.t() | nil,
          protocol_version: integer() | nil,
          settings_digest: String.t() | nil,
          instance_settings: map(),
          wanted_until: DateTime.t() | nil,
          last_error: String.t() | nil,
          last_error_kind: String.t() | nil,
          state_changed_at: DateTime.t() | nil,
          incarnation_id: String.t() | nil,
          transport_route: String.t() | nil,
          capacity: map(),
          load: map(),
          last_worker_heartbeat_at: DateTime.t() | nil,
          drain_reason: String.t() | nil
        }

  @doc "Whether a connection of this row can carry Turn traffic."
  @spec connected?(t()) :: boolean()
  def connected?(%__MODULE__{state: state, transport_route: route}),
    do: state in ["ready", "draining"] and is_binary(route)

  @doc "Free Turn slots that the Worker reported."
  @spec available_slots(t()) :: non_neg_integer()
  def available_slots(%__MODULE__{capacity: %{"available_slots" => slots}})
      when is_integer(slots) and slots > 0,
      do: slots

  def available_slots(%__MODULE__{}), do: 0

  @doc "Keeps the Console reason and its acquisition category together."
  def error_fields(nil, _kind), do: [last_error: nil, last_error_kind: nil]

  def error_fields(text, kind) when is_binary(text) and kind in ~w(rejected transient pending),
    do: [last_error: String.slice(text, -4_000, 4_000), last_error_kind: kind]
end
