defmodule Ankole.Tenants.Tenant do
  @moduledoc "One organization's durable data boundary within a site."
  use Ankole.Ash.Resource,
    authorizers: [Ankole.AuthZ.Authorizer],
    tenancy: :site,
    domain: Ankole.Tenants,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  @blacklist_file Application.compile_env(:ankole, :tenant_slug_blacklist)

  if @blacklist_file do
    @external_resource @blacklist_file
    @reserved_slugs @blacklist_file |> File.read!() |> TomlElixir.decode!() |> Map.fetch!("slugs")
  else
    @reserved_slugs []
  end

  def reserved_slug?(slug), do: slug in @reserved_slugs

  authz do
    scope(:site_console)
    resolve_param(:id, :uuid)
    allow(:list, resource: "site_console:tenants", action: "read")
    allow(:brain_packs, resource: "site_console:tenants", action: "read")
    allow(:create, resource: "site_console:tenants", action: "update")
    allow(:change_profile, resource: "site_console:tenant:{id}", action: "update")
    allow(:begin_delete, resource: "site_console:tenant:{id}", action: "delete")
    allow(:suspend, resource: "site_console:tenant:{id}", action: "update")
    allow(:resume, resource: "site_console:tenant:{id}", action: "update")
    allow(:privileged, resource: "site_console:privileged_tenant", action: "read")

    allow(:transfer_site_administration,
      resource: "site_console:privileged_tenant",
      action: "update"
    )
  end

  json_api do
    type("tenant")
    derive_filter?(false)
    derive_sort?(false)

    default_fields([
      :slug,
      :display_name,
      :suspended_at,
      :deleting_at,
      :inserted_at,
      :updated_at
    ])
  end

  postgres do
    table("tenants")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(slug: "tenants_slug_index")
    unique_index_names([{[:slug], "tenants_slug_index"}])

    check_constraints do
      check_constraint(:slug, "tenants_slug_format")

      check_constraint(:display_name, "tenants_display_name_present")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:slug, :string, public?: true, allow_nil?: false, constraints: [trim?: false])
    attribute(:base_db_id, :string, public?: true, allow_nil?: false)

    attribute(:display_name, :string,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:suspended_at, :utc_datetime_usec, public?: true)
    attribute(:deleting_at, :utc_datetime_usec, public?: true)
    timestamps(type: :utc_datetime_usec, public?: true)
  end

  identities do
    identity(:slug, [:slug])
  end

  validations do
    validate(match(:slug, ~r/\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\z/))

    validate(fn changeset, _context ->
      if Ash.Changeset.changing_attribute?(changeset, :slug) and
           reserved_slug?(Ash.Changeset.get_attribute(changeset, :slug)),
         do: {:error, field: :slug, message: "is reserved"},
         else: :ok
    end)

    validate(fn changeset, _context ->
      case Ash.Changeset.get_attribute(changeset, :display_name) do
        value when is_binary(value) ->
          if String.trim(value) == "",
            do: {:error, field: :display_name, message: "is required"},
            else: :ok

        _value ->
          :ok
      end
    end)
  end

  actions do
    defaults([:read])

    read :list do
      prepare(build(sort: [inserted_at: :asc, id: :asc]))
    end

    read :privileged do
      get?(true)

      prepare(__MODULE__.Preparations)
    end

    create :create_in_tx do
      accept([:id, :slug, :display_name, :base_db_id])
    end

    update :profile_in_tx do
      accept([:slug, :display_name])
    end

    update :suspend_in_tx do
      accept([])
      change(set_attribute(:suspended_at, &DateTime.utc_now/0))
    end

    update :resume_in_tx do
      accept([])
      change(set_attribute(:suspended_at, nil))
    end

    update :begin_delete_in_tx do
      accept([])

      change(set_attribute(:deleting_at, &DateTime.utc_now/0),
        where: [attribute_equals(:deleting_at, nil)]
      )
    end

    destroy :delete_in_tx do
      validate(present(:deleting_at))
    end

    action :create, :struct do
      constraints(instance_of: __MODULE__)
      argument(:slug, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:display_name, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:brain_packs, {:array, :string}, default: [])
      argument(:base_db_id, :string)

      run(__MODULE__.Actions)
    end

    action :brain_packs, {:array, :string} do
      run(__MODULE__.Actions)
    end

    action :change_profile, :struct do
      constraints(instance_of: __MODULE__)
      argument(:id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      argument(:slug, :string, constraints: [trim?: false])
      argument(:display_name, :string, constraints: [trim?: false])

      run(__MODULE__.Actions)
    end

    action :suspend, :struct do
      constraints(instance_of: __MODULE__)
      argument(:id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)

      run(__MODULE__.Actions)
    end

    action :resume, :struct do
      constraints(instance_of: __MODULE__)
      argument(:id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)

      run(__MODULE__.Actions)
    end

    action :begin_delete, :struct do
      constraints(instance_of: __MODULE__)
      argument(:id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)

      run(__MODULE__.Actions)
    end

    action :transfer_site_administration, :struct do
      constraints(instance_of: __MODULE__)
      argument(:tenant_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      argument(:site_admin_uid, :string, allow_nil?: false, constraints: [trim?: false])
      after_commit({Ankole.Tenants, :publish_site_administration})

      run(__MODULE__.Actions)
    end
  end

  @type t :: %__MODULE__{}
end
