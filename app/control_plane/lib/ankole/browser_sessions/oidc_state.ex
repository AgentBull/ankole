defmodule Ankole.BrowserSessions.OidcState do
  @moduledoc false
  use Ankole.Ash.Resource,
    tenancy: :site,
    domain: Ankole.BrowserSessions

  postgres do
    table("browser_oidc_states")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:tenant_id, "browser_oidc_states_tenant_id_fkey"},
      {:browser_id, "browser_oidc_states_browser_id_fkey"},
      {:expected_authentication_id, "browser_oidc_states_expected_authentication_id_fkey"},
      {:oauth_request_id, "browser_oidc_states_oauth_request_id_fkey"}
    ])

    unique_index_names([{[:state], "browser_oidc_states_state_index"}])

    check_constraints do
      check_constraint(:purpose, "browser_oidc_states_purpose")
      check_constraint(:mode, "browser_oidc_states_mode")
      check_constraint(:started_revision, "browser_oidc_states_started_revision_nonnegative")
      check_constraint(:oauth_request_id, "browser_oidc_states_oauth_request")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:state, :string,
      public?: true,
      allow_nil?: false,
      sensitive?: true,
      constraints: [trim?: false]
    )

    attribute(:browser_id, Ankole.Ash.Types.UUIDv7, public?: true, allow_nil?: false)
    attribute(:tenant_id, Ankole.Ash.Types.UUIDv7, public?: true, allow_nil?: false)

    attribute(:provider_id, :string,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:purpose, :atom,
      public?: true,
      allow_nil?: false,
      constraints: [one_of: [:console, :oauth, :pod]]
    )

    attribute(:mode, :atom,
      public?: true,
      allow_nil?: false,
      default: :replace,
      constraints: [one_of: [:replace, :add]]
    )

    attribute(:started_revision, :integer,
      public?: true,
      allow_nil?: false,
      constraints: [min: 0]
    )

    attribute(:redirect_uri, :string,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:return_to, :string,
      public?: true,
      allow_nil?: false,
      default: "/",
      constraints: [trim?: false]
    )

    attribute(:prompt, {:array, :string}, public?: true, allow_nil?: false, default: [])
    attribute(:invitation_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:expected_authentication_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:reauthentication_principal_uid, Ankole.Ash.Types.PrincipalKey, public?: true)
    attribute(:oauth_request_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:expires_at, :utc_datetime_usec, public?: true, allow_nil?: false)
    attribute(:consumed_at, :utc_datetime_usec, public?: true)
    timestamps(type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :begin_in_tx do
      accept([
        :state,
        :browser_id,
        :tenant_id,
        :provider_id,
        :purpose,
        :mode,
        :started_revision,
        :redirect_uri,
        :return_to,
        :prompt,
        :invitation_id,
        :expected_authentication_id,
        :reauthentication_principal_uid,
        :oauth_request_id,
        :expires_at
      ])
    end

    update :consume_in_tx do
      require_atomic?(true)
      accept([])
      change(filter(expr(is_nil(consumed_at))))
      change(set_attribute(:consumed_at, &DateTime.utc_now/0))
    end

    destroy :expire_in_tx do
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
