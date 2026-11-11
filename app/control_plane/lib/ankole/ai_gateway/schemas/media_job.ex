defmodule Ankole.AIGateway.Schemas.MediaJob do
  @moduledoc """
  One video or music generation, which the Provider finishes after the gateway
  request has returned.

  `upstream_job_id` names the generation at a Provider that is asked for its
  state. `result_url` is the Provider's link to the generated file, kept from
  the moment the Provider reports it until AIGateway has saved the file.
  A completed job references the saved file through `object_id`. AIGateway
  deletes the row at `expires_at`, which releases the file.
  """
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.AIGateway

  postgres do
    table("ai_gateway_media_jobs")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names(
      subject_uid: "ai_gateway_media_jobs_subject_uid_fkey",
      object_id: "ai_gateway_media_jobs_object_fkey"
    )

    check_constraints do
      check_constraint(:capability, "ai_gateway_media_jobs_capability_check")
      check_constraint(:status, "ai_gateway_media_jobs_status_check")
      check_constraint(:object_id, "ai_gateway_media_jobs_completed_object_check")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:subject_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
    attribute(:subject_type, :string, constraints: [trim?: false])
    attribute(:capability, :atom, allow_nil?: false, constraints: [one_of: [:video, :music]])
    attribute(:provider_id, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:model, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:request, :map, allow_nil?: false)
    attribute(:request_context, :map, allow_nil?: false, default: %{})

    attribute(:status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :in_progress, :completed, :failed]]
    )

    attribute(:upstream_job_id, :string, constraints: [trim?: false])
    attribute(:result_url, :string, sensitive?: true, constraints: [trim?: false])
    attribute(:usage, :map)
    attribute(:object_id, Ankole.Ash.Types.UUIDv7)
    attribute(:content_type, :string, constraints: [trim?: false])
    attribute(:byte_size, :integer, constraints: [min: 0])
    attribute(:error, :map)
    attribute(:expires_at, :utc_datetime_usec, allow_nil?: false)
    create_timestamp(:inserted_at, type: :utc_datetime_usec)
    update_timestamp(:updated_at, type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :submit do
      accept([
        :subject_uid,
        :subject_type,
        :capability,
        :provider_id,
        :model,
        :request,
        :request_context,
        :expires_at
      ])
    end

    update :advance do
      accept([
        :status,
        :request,
        :upstream_job_id,
        :result_url,
        :usage,
        :object_id,
        :content_type,
        :byte_size,
        :error
      ])
    end

    destroy :collect do
      require_atomic?(true)
      argument(:now, :utc_datetime_usec, allow_nil?: false)
      change(filter(expr(expires_at <= ^arg(:now))))
    end
  end

  @type t :: %__MODULE__{}
end
