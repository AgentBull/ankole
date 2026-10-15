defmodule Ankole.Conversations.Conversation do
  @moduledoc "A shared conversation hosted by Ankole or an external platform."
  use Ankole.Schema, tenancy: :tenant, tenant_in_primary_key: true
  import Ecto.Changeset

  @primary_key {:id, Ankole.Ecto.UUIDv7, []}
  @type t :: %__MODULE__{}

  schema "conversations" do
    field :kind, Ecto.Enum, values: [:native, :external], default: :native
    field :title, :string
    field :created_by, Ankole.Ecto.PrincipalKey
    field :last_activity_at, :utc_datetime_usec
    field :sequence_high_water, :integer, default: 0
    field :provider_conversation_id, :string

    field :external_kind, Ecto.Enum,
      values: [:im_dm, :im_group, :webhook_endpoint, :issue, :alert_stream, :unknown]

    field :reply_mode, Ecto.Enum, values: [:none, :channel, :entry]
    field :visibility, :string
    field :principal_group_id, Ecto.UUID
    field :metadata, :map, default: %{}
    field :raw_payload, :map, default: %{}
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :ambient_standing_orders, :string
    field :ambient_standing_orders_set_by, :string
    field :ambient_standing_orders_updated_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [
      :id,
      :kind,
      :title,
      :created_by,
      :last_activity_at,
      :sequence_high_water,
      :provider_conversation_id,
      :external_kind,
      :reply_mode,
      :visibility,
      :principal_group_id,
      :metadata,
      :raw_payload,
      :first_seen_at,
      :last_seen_at,
      :ambient_standing_orders,
      :ambient_standing_orders_set_by,
      :ambient_standing_orders_updated_at
    ])
    |> validate_required([:id, :kind, :title, :last_activity_at])
    |> validate_origin()
    |> validate_number(:sequence_high_water, greater_than_or_equal_to: 0)
    |> Ankole.Ecto.JSONPayload.validate_map(:metadata, allow_datetime: true)
    |> Ankole.Ecto.JSONPayload.validate_map(:raw_payload, allow_datetime: true)
    |> unique_constraint([:tenant_id, :id], name: :conversations_pkey)
    |> foreign_key_constraint(:created_by)
    |> foreign_key_constraint(:principal_group_id)
    |> unique_constraint([:tenant_id, :provider_conversation_id],
      name: :conversations_external_identity_index
    )
    |> check_constraint(:kind, name: :conversations_kind_check)
    |> check_constraint(:title, name: :conversations_title_present)
    |> check_constraint(:provider_conversation_id, name: :conversations_origin_check)
  end

  defp validate_origin(changeset) do
    case get_field(changeset, :kind) do
      :native ->
        validate_required(changeset, [:created_by])

      :external ->
        validate_required(changeset, [
          :provider_conversation_id,
          :external_kind,
          :reply_mode,
          :first_seen_at,
          :last_seen_at
        ])

      _ ->
        changeset
    end
  end
end
