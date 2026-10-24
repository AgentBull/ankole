defmodule Ankole.OIDC.Client do
  @moduledoc "Operator-managed OAuth client and its authorization boundary."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.OIDC,
    extensions: [AshJsonApi.Resource]

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

    timestamps(type: :utc_datetime_usec, public?: true)
  end

  relationships do
    has_many :client_groups, Ankole.OIDC.ClientGroup do
      destination_attribute(:client_id)
    end
  end

  aggregates do
    list :allowed_group_ids, :client_groups, :group_id do
      public?(true)
      sort(group_id: :asc)
    end
  end

  # The secret ciphertext stays private.
  json_api do
    type("oidc_client")
    derive_filter?(false)
    derive_sort?(false)
    hide_fields([:secret_ciphertext])

    default_fields([
      :id,
      :name,
      :enabled,
      :client_type,
      :redirect_uris,
      :scopes,
      :allowed_group_ids,
      :model_aliases,
      :allowed_identity_provider_ids,
      :backchannel_logout_uri,
      :backchannel_logout_session_required,
      :post_logout_redirect_uris,
      :allow_insecure_local_logout,
      :inserted_at,
      :updated_at
    ])
  end

  changes do
    change(
      fn changeset, _context ->
        Enum.reduce(@lists, changeset, fn field, changeset ->
          Ash.Changeset.update_change(changeset, field, fn values ->
            (values || []) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
          end)
        end)
      end,
      only_when_valid?: true
    )
  end

  validations do
    validate(Ankole.OIDC.Validations.ClientPolicy, only_when_valid?: true)
  end

  actions do
    action :login_sources, :map do
      constraints(
        fields: [
          sources: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  provider_id: [type: :string, allow_nil?: false],
                  enabled: [type: :boolean, allow_nil?: false]
                ]
              ]
            ]
          ]
        ]
      )

      run(__MODULE__.Actions)
    end

    action :console_rotate_secret, :map do
      constraints(fields: [client_secret: [type: :string, allow_nil?: false]])
      argument(:id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      run(__MODULE__.Actions)
    end

    defaults([:read])

    read :lookup_across_tenants do
      multitenancy(:allow_global)
    end

    read :console_list do
      prepare(build(sort: [inserted_at: :asc]))
    end

    create :create_in_tx do
      accept([:id, :client_type, :secret_ciphertext] ++ @fields)
    end

    update :configure_in_tx do
      accept(@fields)
    end

    update :rotate_secret_in_tx do
      accept([:secret_ciphertext])
      validate(attribute_equals(:client_type, :confidential))
    end

    destroy(:delete_in_tx)

    # The Console writes. The create result has the plaintext secret of a
    # confidential client; no other response has it.
    action :console_create, :map do
      constraints(
        fields: [
          oidc_client: [type: :struct, allow_nil?: false, constraints: [instance_of: __MODULE__]],
          client_secret: [type: :string]
        ]
      )

      argument(:client_type, :atom,
        allow_nil?: false,
        constraints: [one_of: [:public, :confidential]]
      )

      argument(:name, :string, allow_nil?: false)
      argument(:enabled, :boolean, default: true)
      argument(:redirect_uris, {:array, :string})
      argument(:scopes, {:array, :string})
      argument(:allowed_group_ids, {:array, :string})
      argument(:model_aliases, :map)
      argument(:allowed_identity_provider_ids, {:array, :string})
      argument(:backchannel_logout_uri, :string)
      argument(:backchannel_logout_session_required, :boolean)
      argument(:post_logout_redirect_uris, {:array, :string})
      argument(:allow_insecure_local_logout, :boolean)

      run(__MODULE__.Actions)
    end

    action :console_update, :struct do
      constraints(instance_of: __MODULE__)
      argument(:id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      argument(:name, :string)
      argument(:enabled, :boolean)
      argument(:redirect_uris, {:array, :string})
      argument(:scopes, {:array, :string})
      argument(:allowed_group_ids, {:array, :string})
      argument(:model_aliases, :map)
      argument(:allowed_identity_provider_ids, {:array, :string})
      argument(:backchannel_logout_uri, :string)
      argument(:backchannel_logout_session_required, :boolean)
      argument(:post_logout_redirect_uris, {:array, :string})
      argument(:allow_insecure_local_logout, :boolean)

      run(__MODULE__.Actions)
    end

    action :console_delete, :struct do
      constraints(instance_of: __MODULE__)
      argument(:id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)

      run(__MODULE__.Actions)
    end
  end

  @type t :: %__MODULE__{}
  def supported_scopes, do: @scopes
end
