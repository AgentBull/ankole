defmodule Ankole.Principals.MappingRequest do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Principals

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

    create :observe_in_tx do
      accept([:provider, :external_id, :display_name, :email, :mobile, :metadata])
      upsert?(true)
      upsert_identity(:subject)
      upsert_fields([:display_name, :email, :mobile, :metadata, :updated_at])
    end

    destroy(:delete_in_tx)

    action :record_observation, :term do
      argument(:attrs, :map, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Repo
        |> Ankole.Principals.MappingRequests.record_observation_in_tx(input.arguments.attrs)
        |> Ankole.Errors.wrap()
      end)
    end

    action :bind_request, :map do
      argument(:id, :term, allow_nil?: false)
      argument(:principal_uid, :term, allow_nil?: false)

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
      constraints(instance_of: Ankole.Principals.ExternalIdentity)
      argument(:principal_uid, :term, allow_nil?: false)
      argument(:attrs, :map, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Principals.MappingRequests.bind_subject_in_tx(
          Ankole.Repo,
          input.arguments.principal_uid,
          input.arguments.attrs
        )
        |> Ankole.Errors.wrap()
      end)
    end
  end

  @type t :: %__MODULE__{}
end
