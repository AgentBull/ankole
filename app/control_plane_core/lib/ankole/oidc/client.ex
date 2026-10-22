defmodule Ankole.OIDC.Client do
  @moduledoc "Operator-managed OAuth client and its authorization boundary."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.OIDC.Domain

  @scopes ~w(openid profile email offline_access ai_gateway.write)
  @lists [:redirect_uris, :scopes, :allowed_identity_provider_ids, :post_logout_redirect_uris]
  @fields [
    :name,
    :enabled,
    :redirect_uris,
    :scopes,
    :model_aliases,
    :allowed_identity_provider_ids,
    :backchannel_logout_uri,
    :backchannel_logout_session_required,
    :post_logout_redirect_uris,
    :allow_insecure_local_logout
  ]

  postgres do
    table("oidc_clients")
    repo(Ankole.Repo)
    migrate?(false)

    check_constraints do
      check_constraint(:name, "oidc_clients_name_present")
      check_constraint(:client_type, "oidc_clients_type")
      check_constraint(:secret_ciphertext, "oidc_clients_secret_shape")
      check_constraint(:scopes, "oidc_clients_openid_scope")
      check_constraint(:model_aliases, "oidc_clients_gateway_models")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:enabled, :boolean, public?: true, allow_nil?: false, default: true)

    attribute(:client_type, :atom,
      public?: true,
      allow_nil?: false,
      constraints: [one_of: [:public, :confidential]]
    )

    attribute(:secret_ciphertext, :string,
      public?: true,
      sensitive?: true,
      constraints: [trim?: false]
    )

    attribute(:redirect_uris, {:array, :string},
      public?: true,
      allow_nil?: false,
      default: [],
      constraints: [min_length: 1, items: [trim?: false, allow_empty?: true]]
    )

    attribute(:scopes, {:array, :string},
      public?: true,
      allow_nil?: false,
      default: ["openid"],
      constraints: [items: [trim?: false, allow_empty?: true]]
    )

    attribute(:model_aliases, Ankole.Ash.Types.JSONMap,
      public?: true,
      allow_nil?: false,
      default: %{}
    )

    attribute(:allowed_identity_provider_ids, {:array, :string},
      public?: true,
      allow_nil?: false,
      default: [],
      constraints: [items: [trim?: false, allow_empty?: true]]
    )

    attribute(:backchannel_logout_uri, :string, public?: true)

    attribute(:backchannel_logout_session_required, :boolean,
      public?: true,
      allow_nil?: false,
      default: true
    )

    attribute(:post_logout_redirect_uris, {:array, :string},
      public?: true,
      allow_nil?: false,
      default: [],
      constraints: [items: [trim?: false, allow_empty?: true]]
    )

    attribute(:allow_insecure_local_logout, :boolean,
      public?: true,
      allow_nil?: false,
      default: false
    )

    timestamps(type: :utc_datetime_usec)
  end

  changes do
    change(
      fn changeset, _context ->
        Enum.reduce(@lists, changeset, fn field, changeset ->
          if Ash.Changeset.changing_attribute?(changeset, field) do
            values = Ash.Changeset.get_attribute(changeset, field) || []
            values = values |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
            Ash.Changeset.force_change_attribute(changeset, field, values)
          else
            changeset
          end
        end)
      end,
      only_when_valid?: true
    )
  end

  validations do
    validate(Ankole.OIDC.Validations.ClientPolicy, only_when_valid?: true)
  end

  actions do
    defaults([:read])

    read :lookup_across_tenants do
      multitenancy(:allow_global)
    end

    create :create_in_tx do
      accept([:id, :client_type, :secret_ciphertext] ++ @fields)
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)
    end

    in_tx_update :configure_in_tx do
      accept(@fields)
    end

    in_tx_update :rotate_secret_in_tx do
      accept([:secret_ciphertext])
      validate(attribute_equals(:client_type, :confidential))
    end

    destroy :delete_in_tx do
      transaction?(false)
      require_atomic?(false)
      atomic_upgrade?(false)
      change(Ankole.Ash.RequireTransaction)
    end
  end

  @type t :: %__MODULE__{}
  def supported_scopes, do: @scopes
end
