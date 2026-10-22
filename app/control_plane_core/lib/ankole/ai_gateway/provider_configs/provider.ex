defmodule Ankole.AIGateway.ProviderConfigs.Provider do
  @moduledoc "Operator-configured endpoint settings and an encrypted credential pool."

  use Ankole.Ash.Resource,
    tenancy: :site,
    domain: Ankole.AIGateway

  alias Ankole.AIGateway.ProviderConfigs

  postgres do
    table("ai_gateway_providers")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(provider_id: "ai_gateway_providers_provider_id_index")

    check_constraints do
      check_constraint(:provider_id, "ai_gateway_providers_provider_id_format")
      check_constraint(:provider_kind, "ai_gateway_providers_provider_kind_format")
      check_constraint(:base_url, "ai_gateway_providers_base_url_present")
      check_constraint(:connection_options, "ai_gateway_providers_connection_options_object")
      check_constraint(:credential_pool, "ai_gateway_providers_credential_pool_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:provider_id, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A[a-z][a-z0-9_-]{0,62}\z/]
    )

    attribute(:provider_kind, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A[a-z][a-z0-9_]{0,62}\z/]
    )

    attribute(:base_url, :string, public?: true)

    attribute(:connection_options, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      default: %{},
      public?: true
    )

    attribute(:credential_pool, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      sensitive?: true,
      default: %{"strategy" => "fill_first", "entries" => []}
    )

    attribute(:disabled_at, :utc_datetime_usec, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:provider_id, [:provider_id])
  end

  actions do
    defaults([:read])

    create :create do
      accept([])
      argument(:input, :map, allow_nil?: false, sensitive?: true)

      change(Ankole.AIGateway.ProviderConfigs.Changes.PrepareConfiguration,
        only_when_valid?: true
      )

      validate(Ankole.AIGateway.ProviderConfigs.ValidateURL)
    end

    update :configure do
      accept([])
      argument(:input, :map, allow_nil?: false, sensitive?: true)

      change(Ankole.AIGateway.ProviderConfigs.Changes.PrepareConfiguration,
        only_when_valid?: true
      )

      validate(Ankole.AIGateway.ProviderConfigs.ValidateURL)
    end

    update :enable do
      accept([])

      change({Ankole.AIGateway.ProviderConfigs.Changes.PrepareConfiguration, enable?: true},
        only_when_valid?: true
      )

      validate(Ankole.AIGateway.ProviderConfigs.ValidateURL)
    end

    update :disable do
      accept([])
      change(Ankole.AIGateway.ProviderConfigs.Changes.RequireUnused, only_when_valid?: true)
      change(set_attribute(:disabled_at, &DateTime.utc_now/0))
    end

    update :add_credential do
      accept([])
      argument(:input, :map, allow_nil?: false, sensitive?: true)

      change({Ankole.AIGateway.ProviderConfigs.Changes.Credentials, operation: :add},
        only_when_valid?: true
      )
    end

    update :replace_credential do
      accept([])
      argument(:credential_id, :string, allow_nil?: false)
      argument(:input, :map, allow_nil?: false, sensitive?: true)

      change({Ankole.AIGateway.ProviderConfigs.Changes.Credentials, operation: :replace},
        only_when_valid?: true
      )
    end

    update :remove_credential do
      accept([])
      argument(:credential_id, :string, allow_nil?: false)

      change({Ankole.AIGateway.ProviderConfigs.Changes.Credentials, operation: :remove},
        only_when_valid?: true
      )
    end

    update :select_strategy do
      accept([])
      argument(:strategy, :string, allow_nil?: false)

      change({Ankole.AIGateway.ProviderConfigs.Changes.Credentials, operation: :strategy},
        only_when_valid?: true
      )
    end

    update :refresh_credential do
      accept([])
      argument(:credential_id, :string, allow_nil?: false)
      argument(:credential, :map, allow_nil?: false, sensitive?: true)

      change({Ankole.AIGateway.ProviderConfigs.Changes.Credentials, operation: :refresh},
        only_when_valid?: true
      )
    end

    update :cooldown do
      accept([])
      argument(:credential, :map, allow_nil?: false, sensitive?: true)
      argument(:until, :struct, allow_nil?: false, constraints: [instance_of: DateTime])
      argument(:reason, :term, allow_nil?: false)

      change({Ankole.AIGateway.ProviderConfigs.Changes.Credentials, operation: :cooldown},
        only_when_valid?: true
      )
    end

    destroy :remove do
      validate(present(:disabled_at))
      change(Ankole.AIGateway.ProviderConfigs.Changes.RequireUnused, only_when_valid?: true)
    end

    action :change, :struct do
      constraints(instance_of: __MODULE__)
      argument(:provider_id, :string, allow_nil?: false)

      argument(:update, :atom,
        allow_nil?: false,
        constraints: [
          one_of: [
            :configure,
            :enable,
            :add_credential,
            :replace_credential,
            :remove_credential,
            :select_strategy
          ]
        ]
      )

      argument(:params, :map, allow_nil?: false, sensitive?: true)

      run(fn input, _context ->
        input.arguments |> ProviderConfigs.change_locked() |> Ankole.Errors.wrap()
      end)
    end

    action :retire, :struct do
      constraints(instance_of: __MODULE__)
      argument(:provider_id, :string, allow_nil?: false)

      run(fn input, _context ->
        input.arguments |> ProviderConfigs.retire() |> Ankole.Errors.wrap()
      end)
    end

    action :put_cooldown, :term do
      argument(:row_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      argument(:credential, :map, allow_nil?: false, sensitive?: true)
      argument(:until, :struct, allow_nil?: false, constraints: [instance_of: DateTime])
      argument(:reason, :term, allow_nil?: false)

      run(fn input, _context ->
        input.arguments |> ProviderConfigs.put_cooldown() |> Ankole.Errors.wrap()
      end)
    end

    action :rotate_credential, :map do
      argument(:provider_id, :string, allow_nil?: false)
      argument(:credential_id, :string, allow_nil?: false)
      argument(:callback, :function, allow_nil?: false, constraints: [arity: 3])

      run(fn input, _context ->
        input.arguments |> ProviderConfigs.rotate_credential() |> Ankole.Errors.wrap()
      end)
    end
  end

  @type t :: %__MODULE__{}

  @doc false
  def normalize_id(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  def normalize_id(value), do: value
end
