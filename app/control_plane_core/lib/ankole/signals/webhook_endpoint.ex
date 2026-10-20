defmodule Ankole.Signals.WebhookEndpoint do
  @moduledoc """
  One capability URL for raw task receipts or structured CloudEvents.

  The row stores only the token digest. The plaintext capability URL exists
  only in the create response and in the external system that receives it.
  """

  use Ankole.Schema, tenancy: :tenant

  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]
  import Ecto.Changeset

  alias Ankole.Ecto.JSONPayload
  alias Ankole.AutomationJobs.Schemas.Job, as: AutomationJob
  alias Ankole.Principals.Principal
  alias Ankole.Signals.Signal

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @modes ~w(one_shot standing)
  @statuses ~w(armed active fired expired cancelled)

  @type t :: %__MODULE__{}

  schema "signal_webhook_endpoints" do
    field :token_digest, :string
    field :event_format, :string, default: "raw"

    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :binding_name, :string
    field :session_id, :string
    field :conversation_id, Ankole.Ecto.UUIDv7
    field :provider_thread_id, :string

    belongs_to :source_signal, Signal,
      foreign_key: :source_signal_id,
      type: Ecto.UUID

    field :provider_message_id, :string
    field :source_provenance, :map, default: %{}
    field :label, :string
    field :mode, :string
    field :status, :string
    field :expires_at, :utc_datetime_usec
    field :fired_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec
    belongs_to :automation_job, AutomationJob, type: :id

    timestamps()
  end

  @doc """
  Builds a changeset for a webhook endpoint.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(endpoint, attrs) do
    endpoint
    |> cast(attrs, [
      :token_digest,
      :event_format,
      :agent_uid,
      :binding_name,
      :session_id,
      :conversation_id,
      :provider_thread_id,
      :source_signal_id,
      :provider_message_id,
      :source_provenance,
      :label,
      :mode,
      :status,
      :expires_at,
      :fired_at,
      :cancelled_at,
      :automation_job_id
    ])
    |> normalize_blank([
      :token_digest,
      :event_format,
      :agent_uid,
      :binding_name,
      :session_id,
      :conversation_id,
      :provider_thread_id,
      :provider_message_id,
      :label,
      :mode,
      :status
    ])
    |> validate_required([
      :token_digest,
      :source_provenance,
      :label,
      :mode,
      :status,
      :expires_at
    ])
    |> validate_route()
    |> validate_inclusion(:event_format, ~w(raw cloudevents))
    |> validate_length(:token_digest, is: 43)
    |> validate_length(:label, max: 500)
    |> validate_change(:label, fn :label, text ->
      if String.valid?(text) and not String.contains?(text, <<0>>),
        do: [],
        else: [label: "must be valid text without NUL"]
    end)
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:status, @statuses)
    |> validate_mode_status()
    |> JSONPayload.validate_map(:source_provenance)
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:source_signal_id)
    |> foreign_key_constraint(:automation_job_id)
    |> unique_constraint(:token_digest,
      name: :signal_webhook_endpoints_token_digest_index
    )
    |> check_constraint(:mode, name: :signal_webhook_endpoints_mode_check)
    |> check_constraint(:event_format, name: :signal_webhook_endpoints_event_format_check)
    |> check_constraint(:agent_uid, name: :signal_webhook_endpoints_raw_target_check)
    |> check_constraint(:status, name: :signal_webhook_endpoints_status_check)
    |> check_constraint(:token_digest,
      name: :signal_webhook_endpoints_token_digest_length
    )
    |> check_constraint(:label, name: :signal_webhook_endpoints_label_present)
    |> check_constraint(:binding_name,
      name: :signal_webhook_endpoints_binding_name_present
    )
    |> check_constraint(:session_id,
      name: :signal_webhook_endpoints_session_id_present
    )
    |> check_constraint(:source_provenance,
      name: :signal_webhook_endpoints_source_provenance_object
    )
  end

  defp validate_route(changeset) do
    if get_field(changeset, :event_format) == "raw",
      do: validate_required(changeset, [:agent_uid, :session_id]),
      else: changeset
  end

  defp validate_mode_status(changeset) do
    mode = get_field(changeset, :mode)
    status = get_field(changeset, :status)

    valid? =
      (mode == "one_shot" and status in ~w(armed fired expired cancelled)) or
        (mode == "standing" and status in ~w(active expired cancelled))

    if mode in @modes and status in @statuses and not valid? do
      add_error(changeset, :status, "is not valid for the selected mode")
    else
      changeset
    end
  end
end
