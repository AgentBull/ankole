defmodule Ankole.Tenants.Tenant do
  @moduledoc "One organization's durable data boundary within a site."
  use Ankole.Ash.Resource, tenancy: :site, domain: Ankole.Tenants.Domain

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
    timestamps(type: :utc_datetime_usec)
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

    create :create_in_tx do
      accept([:slug, :display_name])
      transaction?(false)
    end

    in_tx_update :profile_in_tx do
      accept([:slug, :display_name])
    end

    in_tx_update :suspend_in_tx do
      accept([])
      change(set_attribute(:suspended_at, &DateTime.utc_now/0))
    end

    in_tx_update :resume_in_tx do
      accept([])
      change(set_attribute(:suspended_at, nil))
    end

    in_tx_update :begin_delete_in_tx do
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
      transaction?(false)
      require_atomic?(false)
      atomic_upgrade?(false)
      validate(present(:deleting_at))
    end
  end

  @type t :: %__MODULE__{}
end
