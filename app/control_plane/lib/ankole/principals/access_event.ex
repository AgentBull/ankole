defmodule Ankole.Principals.AccessEvent do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Principals

  postgres do
    table("human_access_events")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(operation: "human_access_events_source_operation_id_principal_uid_index")
    foreign_key_names([{:principal_uid, "human_access_events_principal_uid_fkey"}])

    unique_index_names([
      {[:source, :operation_id, :principal_uid],
       "human_access_events_source_operation_id_principal_uid_index"}
    ])
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:principal_uid, Ankole.Ash.Types.PrincipalKey, public?: true, allow_nil?: false)
    attribute(:operation_id, :string, public?: true, allow_nil?: false)
    attribute(:source, :string, public?: true, allow_nil?: false)
    attribute(:action, :string, public?: true, allow_nil?: false)
    attribute(:reason, :string, public?: true, allow_nil?: false)
    attribute(:actor, Ankole.Ash.Types.ActorRef, public?: true)

    attribute(:previous_status, :atom,
      public?: true,
      allow_nil?: false,
      constraints: [one_of: [:active, :disabled]]
    )

    attribute(:status, :atom,
      public?: true,
      allow_nil?: false,
      constraints: [one_of: [:active, :disabled]]
    )

    attribute(:access_version, :integer, public?: true, allow_nil?: false, constraints: [min: 1])
    attribute(:provider_time, :utc_datetime_usec, public?: true)
    attribute(:details, Ankole.Ash.Types.JSONMap, public?: true, allow_nil?: false, default: %{})
    attribute(:released_identifiers, {:array, :string}, allow_nil?: false, default: [])
    create_timestamp(:inserted_at, type: :utc_datetime_usec)
  end

  identities do
    identity(:operation, [:source, :operation_id, :principal_uid])
  end

  actions do
    defaults([:read])

    create :record_in_tx do
      accept([
        :principal_uid,
        :operation_id,
        :source,
        :action,
        :reason,
        :actor,
        :previous_status,
        :status,
        :access_version,
        :provider_time,
        :details,
        :released_identifiers
      ])
    end

    create :record_once_in_tx do
      accept([
        :principal_uid,
        :operation_id,
        :source,
        :action,
        :reason,
        :actor,
        :previous_status,
        :status,
        :access_version,
        :provider_time,
        :details,
        :released_identifiers
      ])

      upsert?(true)
      upsert_identity(:operation)
      upsert_fields([:operation_id])
    end
  end

  @type t :: %__MODULE__{}
end
