defmodule Ankole.AuthZ.ExternalBinding do
  @moduledoc "Provider-scoped external subject binding to an AuthZ group."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.AuthZ

  postgres do
    table("principal_group_external_bindings")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:group_id, "principal_group_external_bindings_group_id_fkey"}])

    check_constraints do
      check_constraint(:provider, "principal_group_external_bindings_provider_present")
      check_constraint(:provider, "principal_group_external_bindings_provider_format")
      check_constraint(:external_id, "principal_group_external_bindings_external_id_present")
      check_constraint(:metadata, "principal_group_external_bindings_metadata_object")
    end
  end

  attributes do
    attribute(:provider, :string, public?: true, primary_key?: true, allow_nil?: false)

    attribute(:external_kind, :atom,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      constraints: [one_of: [:directory_department, :im_group]]
    )

    attribute(:external_id, :string, public?: true, primary_key?: true, allow_nil?: false)
    attribute(:group_id, Ankole.Ash.Types.UUIDv7, public?: true, allow_nil?: false)
    attribute(:metadata, Ankole.Ash.Types.JSONMap, public?: true, allow_nil?: false, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  relationships do
    belongs_to(:group, Ankole.AuthZ.Group, define_attribute?: false)
  end

  changes do
    change(fn changeset, _context ->
      case Ash.Changeset.get_attribute(changeset, :provider) do
        provider when is_binary(provider) ->
          Ash.Changeset.change_attribute(changeset, :provider, String.downcase(provider))

        _provider ->
          changeset
      end
    end)
  end

  validations do
    validate(match(:provider, ~r/\A[a-z][a-z0-9_-]*\z/))
  end

  actions do
    defaults([:read])

    create :bind_in_tx do
      accept([:provider, :external_kind, :external_id, :group_id, :metadata])
      upsert?(true)
      upsert_fields([:group_id, :metadata, :updated_at])
    end

    action :upsert_binding, :struct do
      constraints(instance_of: __MODULE__)
      argument(:attrs, :map, allow_nil?: false)

      run(__MODULE__.Actions)
    end
  end

  @type t :: %__MODULE__{}
end
