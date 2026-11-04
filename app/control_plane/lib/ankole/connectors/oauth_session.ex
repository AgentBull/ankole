defmodule Ankole.Connectors.OAuthSession do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Connectors

  postgres do
    table("connector_oauth_sessions")
    repo(Ankole.Repo)
    migrate?(false)

    unique_index_names([
      {[:oauth_state_digest], "connector_oauth_sessions_oauth_state_digest_key"},
      {[:completion_code_digest], "connector_oauth_sessions_completion_code_digest_key"}
    ])
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Kernel.gen_uuid_v7/0
    )

    attribute(:auth_config_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:subject_kind, :string, allow_nil?: false)
    attribute(:actor_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
    attribute(:oauth_state_digest, :binary, allow_nil?: false, sensitive?: true)
    attribute(:completion_code_digest, :binary, sensitive?: true)
    attribute(:sealed_pkce_verifier, :string, sensitive?: true)
    attribute(:sealed_pending_tokens, :string, sensitive?: true)
    attribute(:requested_scopes, {:array, :string}, allow_nil?: false, default: [])
    attribute(:return_to, :string)
    attribute(:status, :string, allow_nil?: false, default: "pending")
    attribute(:expires_at, :utc_datetime_usec, allow_nil?: false)
    timestamps(type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    read :across_tenants do
      multitenancy(:allow_global)
    end

    create :create do
      accept([
        :id
        | [
            :auth_config_id,
            :subject_kind,
            :actor_uid,
            :oauth_state_digest,
            :completion_code_digest,
            :sealed_pkce_verifier,
            :sealed_pending_tokens,
            :requested_scopes,
            :return_to,
            :status,
            :expires_at
          ]
      ])
    end

    update :update do
      accept([
        :auth_config_id,
        :subject_kind,
        :actor_uid,
        :oauth_state_digest,
        :completion_code_digest,
        :sealed_pkce_verifier,
        :sealed_pending_tokens,
        :requested_scopes,
        :return_to,
        :status,
        :expires_at
      ])

      require_atomic?(false)
    end

    destroy :destroy do
    end
  end
end
