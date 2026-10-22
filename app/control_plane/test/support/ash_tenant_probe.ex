defmodule TenantIsolationFixture.Published do
  @moduledoc false
  def notify(probe),
    do: send(self(), {:published, probe.global_key, Ankole.Repo.in_transaction?()})
end

defmodule TenantIsolationFixture.Flag do
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: TenantIsolationFixture.Domain

  postgres do
    table("ash_tenant_flags")
    schema("pg_temp")
    repo(Ankole.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0,
      public?: true
    )

    attribute(:key, :string, allow_nil?: false, public?: true)
    attribute(:flag, :boolean, allow_nil?: false, default: false, public?: true)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:key, :flag])
    end
  end
end

defmodule TenantIsolationFixture.Note do
  @moduledoc false
  use Ankole.Schema, tenancy: :tenant

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @schema_prefix "pg_temp"
  schema "ash_tenant_notes" do
    field :body, :string
  end
end

defmodule TenantIsolationFixture.Probe do
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    extensions: [AshStateMachine],
    domain: TenantIsolationFixture.Domain

  postgres do
    table("ash_tenant_probes")
    schema("pg_temp")
    repo(Ankole.Repo)
    migrate?(false)

    identity_index_names(
      global_key: "ash_tenant_probes_global_key_key",
      calculated_key: "ash_tenant_probes_calculated_key_index"
    )

    calculations_to_sql(lookup_key: "global_key || '/identity'")
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0,
      public?: true
    )

    attribute(:global_key, :string, allow_nil?: false, public?: true)
    attribute(:value, :string, public?: true)
    attribute(:note, :string, public?: true)
  end

  identities do
    identity(:global_key, [:global_key], all_tenants?: true)
    identity(:calculated_key, [:lookup_key], all_tenants?: true)
  end

  relationships do
    has_one :marker, TenantIsolationFixture.Flag do
      no_attributes?(true)
      filter(expr(key == parent(global_key)))
    end
  end

  calculations do
    calculate(:lookup_key, :string, expr(fragment("? || '/identity'", global_key)))
    calculate(:value_length, :integer, expr(fragment("length(?)", value)))
  end

  state_machine do
    state_attribute(:status)
    initial_states([:queued])
    default_initial_state(:queued)

    transitions do
      transition(:finish, from: :queued, to: :done)
    end
  end

  actions do
    defaults([:read])
    default_accept([:id, :global_key, :value, :note])

    create :upsert_global do
      primary?(true)
      transaction?(false)
      upsert?(true)
      upsert_identity(:global_key)
      upsert_fields([:value, :note])
    end

    create_if_absent :insert_once do
      transaction?(false)
      upsert_identity(:global_key)
    end

    create_if_absent :insert_once_calculated, upsert_fields: [:value] do
      transaction?(false)
      argument(:lookup_key, :string, allow_nil?: false)
      upsert_identity(:calculated_key)

      validate(fn changeset, _context ->
        if Ash.Changeset.get_argument(changeset, :lookup_key) ==
             Ash.Changeset.get_attribute(changeset, :global_key) <> "/identity",
           do: :ok,
           else: {:error, field: :lookup_key, message: "must match the calculated identity"}
      end)
    end

    create :upsert_id do
      transaction?(false)
      upsert?(true)
      upsert_fields([:value])
    end

    create_if_absent :insert_once_id, upsert_fields: [:value] do
      transaction?(false)
    end

    in_tx_update :finish do
      change(transition_state(:done))
    end

    atomic_in_tx_update :set_note do
      accept([:note])
    end

    update :touch do
      require_atomic?(true)
    end

    destroy :remove do
      require_atomic?(true)
    end

    action :count_rows, :integer do
      run(fn input, _context -> {:ok, Ankole.Repo.aggregate(input.resource, :count)} end)
    end

    action :commit_note, :struct do
      constraints(instance_of: __MODULE__)
      argument(:global_key, :string, allow_nil?: false)
      argument(:outcome, :atom, constraints: [one_of: [:commit, :reject, :raise]])
      after_commit({TenantIsolationFixture.Published, :notify})

      run(fn input, _context ->
        with {:ok, probe} <-
               Ankole.Ash.create(__MODULE__, :upsert_global, %{
                 global_key: input.arguments.global_key
               }) do
          case input.arguments.outcome do
            :commit -> {:ok, probe}
            :reject -> Ankole.Errors.wrap({:error, :rejected_after_write})
            :raise -> raise ArgumentError, "the probe failed after its write"
          end
        end
      end)
    end

    read :global do
      multitenancy(:allow_global)
    end
  end
end

defmodule TenantIsolationFixture.SiteProbe do
  use Ankole.Ash.Resource,
    tenancy: :site,
    domain: TenantIsolationFixture.Domain

  postgres do
    table("ash_site_probes")
    schema("pg_temp")
    repo(Ankole.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0,
      public?: true
    )

    attribute(:value, :string, allow_nil?: false, public?: true)
    attribute(:data, Ankole.Ash.Types.JSONValue, public?: true)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:value, :data])
      transaction?(false)
    end

    in_tx_update :rename do
      accept([:value])
      validate(string_length(:value, min: 3))
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(false)
      atomic_upgrade?(false)
    end
  end
end

defmodule TenantIsolationFixture.Domain do
  use Ankole.Ash.Domain

  resources do
    allow_unregistered?(true)

    resource TenantIsolationFixture.Probe do
      define(:get_probe, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_probes, action: :read)
      define(:upsert_global_probe, action: :upsert_global)
      define(:commit_note, action: :commit_note, args: [:global_key, :outcome])
    end

    resource TenantIsolationFixture.SiteProbe do
      define(:list_site_probes, action: :read)
    end
  end
end
