defmodule Ankole.Principals.MappingRequest do
  @moduledoc false
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Principals,
    extensions: [AshJsonApi.Resource]

  json_api do
    type("identity_mapping_request")
    derive_filter?(false)
    derive_sort?(false)

    default_fields([
      :provider,
      :external_id,
      :display_name,
      :email,
      :mobile,
      :metadata,
      :inserted_at,
      :updated_at
    ])
  end

  postgres do
    table("identity_mapping_requests")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(subject: "identity_mapping_requests_subject_index")
    unique_index_names([{[:provider, :external_id], "identity_mapping_requests_subject_index"}])

    check_constraints do
      check_constraint(:provider, "identity_mapping_requests_provider_format")
      check_constraint(:metadata, "identity_mapping_requests_metadata_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:provider, :string, public?: true, allow_nil?: false)
    attribute(:external_id, :string, public?: true, allow_nil?: false)
    attribute(:display_name, :string, public?: true)
    attribute(:email, :string, public?: true)
    attribute(:mobile, :string, public?: true)
    attribute(:metadata, Ankole.Ash.Types.JSONMap, public?: true, allow_nil?: false, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  identities do
    identity(:subject, [:provider, :external_id])
  end

  validations do
    validate(match(:provider, ~r/\A[a-z][a-z0-9_-]*\z/))
  end

  actions do
    defaults([:read])

    read :console_list do
      prepare(build(sort: [updated_at: :desc]))
    end

    create :observe_in_tx do
      accept([:provider, :external_id, :display_name, :email, :mobile, :metadata])
      upsert?(true)
      upsert_identity(:subject)
      upsert_fields([:display_name, :email, :mobile, :metadata, :updated_at])
    end

    destroy(:delete_in_tx)

    action :bind_request, :struct do
      description("Binds a pending request to a Human and removes the request.")
      constraints(instance_of: Ankole.Principals.ExternalIdentity)
      argument(:id, :string, allow_nil?: false)
      argument(:principal_uid, :string, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Principals.MappingRequests.bind_request_in_tx(
          Ankole.Repo,
          input.arguments.id,
          input.arguments.principal_uid
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :bind_subject, :struct do
      description("Binds a provider subject to a Human and removes its pending request.")
      constraints(instance_of: Ankole.Principals.ExternalIdentity)
      argument(:principal_uid, :string, allow_nil?: false)
      argument(:provider, :string, allow_nil?: false)
      argument(:external_id, :string, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Principals.MappingRequests.bind_subject_in_tx(
          Ankole.Repo,
          input.arguments.principal_uid,
          Map.take(input.arguments, [:provider, :external_id])
        )
        |> Ankole.Errors.wrap()
      end)
    end
  end

  @type t :: %__MODULE__{}
end
