defmodule Ankole.Connectors.AuthWait do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Connectors

  postgres do
    table("connector_auth_waits")
    repo(Ankole.Repo)
    migrate?(false)

    identity_index_names(signal_connection: "connector_auth_waits_signal_slug_uidx")

    unique_index_names([
      {[:signal_id, :connection_slug, :subject_kind], "connector_auth_waits_signal_slug_uidx"}
    ])
  end

  identities do
    identity(:signal_connection, [:signal_id, :connection_slug, :subject_kind], pre_check?: false)
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Kernel.gen_uuid_v7/0
    )

    attribute(:signal_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
    attribute(:human_uid, Ankole.Ash.Types.PrincipalKey)
    attribute(:auth_config_id, Ankole.Ash.Types.UUIDv7)
    attribute(:connection_slug, :string, allow_nil?: false)
    attribute(:plugin_id, :string)
    attribute(:toolkit, :string, allow_nil?: false)
    attribute(:tool_name, :string)
    attribute(:subject_kind, :string, allow_nil?: false, default: "human")
    attribute(:required_scopes, {:array, :string}, allow_nil?: false, default: [])
    attribute(:authorization_url, :string, allow_nil?: false)
    attribute(:interaction_id, :string)
    attribute(:status, :string, allow_nil?: false, default: "recorded")
    timestamps(type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :record do
      transaction?(false)

      accept([
        :id,
        :signal_id,
        :conversation_id,
        :agent_uid,
        :human_uid,
        :auth_config_id,
        :connection_slug,
        :plugin_id,
        :toolkit,
        :tool_name,
        :subject_kind,
        :required_scopes,
        :authorization_url,
        :status
      ])

      upsert?(true)
      upsert_identity(:signal_connection)

      upsert_fields([
        :auth_config_id,
        :plugin_id,
        :toolkit,
        :tool_name,
        :required_scopes,
        :authorization_url,
        :updated_at
      ])
    end

    update :mark_pending do
      transaction?(false)
      accept([:interaction_id, :status, :auth_config_id])
      require_atomic?(false)
    end

    update :resolve do
      transaction?(false)
      accept([:status, :auth_config_id])
      require_atomic?(false)
    end
  end
end
