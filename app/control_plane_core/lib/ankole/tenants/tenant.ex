defmodule Ankole.Tenants.Tenant do
  @moduledoc "One organization's durable data boundary within a site."
  use Ankole.Ash.Resource,
    tenancy: :site,
    domain: Ankole.Tenants,
    extensions: [AshJsonApi.Resource]

  require Ash.Query

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

      if Application.compile_env(:ankole, :edition, :foss) == :saas do
        check_constraint(:slug, "tenants_slug_reserved", message: "is reserved")
      end

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

      prepare(fn query, _context ->
        case Ankole.Tenants.privileged_id() do
          {:ok, id} -> Ash.Query.filter(query, id == ^id)
          _missing -> Ash.Query.filter(query, false)
        end
      end)
    end

    create :create_in_tx do
      accept([:slug, :display_name])
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

      change(fn changeset, _context ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :deleting_at,
          changeset.data.deleting_at || DateTime.utc_now()
        )
      end)
    end

    destroy :delete_in_tx do
      validate(present(:deleting_at))
    end

    action :ensure_scaffold do
      argument(:tenant, :struct, allow_nil?: false, constraints: [instance_of: __MODULE__])

      run(fn input, _context ->
        Ankole.Errors.wrap(
          Ankole.Tenants.ensure_scaffold_in_tx(Ankole.Repo, input.arguments.tenant)
        )
      end)
    end

    action :create, :struct do
      constraints(instance_of: __MODULE__)
      argument(:slug, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:display_name, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:brain_packs, {:array, :string}, default: [])

      run(fn input, _context ->
        Ankole.Repo
        |> Ankole.Tenants.create_in_tx(input.arguments)
        |> Ankole.Errors.wrap(&Ankole.Tenants.rejection/1)
      end)
    end

    action :brain_packs, {:array, :string} do
      run(fn _input, _context -> {:ok, Ankole.Brain.SchemaPacks.industry_packs()} end)
    end

    action :change_profile, :struct do
      constraints(instance_of: __MODULE__)
      argument(:id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      argument(:slug, :string, constraints: [trim?: false])
      argument(:display_name, :string, constraints: [trim?: false])

      run(fn input, _context ->
        {id, attrs} = Map.pop!(input.arguments, :id)

        Ankole.Repo
        |> Ankole.Tenants.change_profile_in_tx(id, attrs)
        |> Ankole.Errors.wrap(&Ankole.Tenants.rejection/1)
      end)
    end

    action :suspend, :struct do
      constraints(instance_of: __MODULE__)
      argument(:id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Errors.wrap(
          Ankole.Tenants.suspend_in_tx(Ankole.Repo, input.arguments.id),
          &Ankole.Tenants.rejection/1
        )
      end)
    end

    action :resume, :struct do
      constraints(instance_of: __MODULE__)
      argument(:id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Errors.wrap(
          Ankole.Tenants.resume_in_tx(Ankole.Repo, input.arguments.id),
          &Ankole.Tenants.rejection/1
        )
      end)
    end

    action :begin_delete, :struct do
      constraints(instance_of: __MODULE__)
      argument(:id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Errors.wrap(
          Ankole.Tenants.begin_delete_in_tx(Ankole.Repo, input.arguments.id),
          &Ankole.Tenants.rejection/1
        )
      end)
    end

    action :transfer_site_administration, :struct do
      constraints(instance_of: __MODULE__)
      argument(:tenant_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      argument(:site_admin_uid, :string, allow_nil?: false, constraints: [trim?: false])
      after_commit({Ankole.Tenants, :publish_site_administration})

      run(fn input, _context ->
        Ankole.Repo
        |> Ankole.Tenants.transfer_site_administration_in_tx(
          input.arguments.tenant_id,
          input.arguments.site_admin_uid
        )
        |> Ankole.Errors.wrap(&Ankole.Tenants.rejection/1)
      end)
    end
  end

  @type t :: %__MODULE__{}
end
