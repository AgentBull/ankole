defmodule Ankole.AIGateway.Schemas.UsageRecord do
  @moduledoc "Append-only LLM usage accounting for Agent quotas and control-plane callers."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.AIGateway

  postgres do
    table("ai_gateway_usage_records")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names(subject_uid: "ai_gateway_usage_records_subject_uid_fkey")

    check_constraints do
      check_constraint(:origin, "ai_gateway_usage_records_origin_check")
      check_constraint(:input_tokens, "ai_gateway_usage_records_input_tokens_check")
      check_constraint(:output_tokens, "ai_gateway_usage_records_output_tokens_check")
      check_constraint(:job_id, "ai_gateway_usage_records_job_id_check")
      check_constraint(:attempt, "ai_gateway_usage_records_attempt_check")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:subject_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)

    attribute(:origin, :atom,
      allow_nil?: false,
      constraints: [one_of: [:agent, :codex, :applet, :brain, :oidc_human, :compaction]]
    )

    attribute(:model, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:input_tokens, :integer, allow_nil?: false, constraints: [min: 0])
    attribute(:output_tokens, :integer, allow_nil?: false, constraints: [min: 0])
    attribute(:session_id, :string, constraints: [trim?: false])
    attribute(:signal_id, :uuid)
    attribute(:job_id, :integer, constraints: [min: 1])
    attribute(:attempt, :integer, constraints: [min: 0])
    create_timestamp(:inserted_at, type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :record_round do
      accept([
        :subject_uid,
        :origin,
        :model,
        :input_tokens,
        :output_tokens,
        :session_id,
        :signal_id,
        :job_id,
        :attempt
      ])

      validate(fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :model) do
          value when is_binary(value) ->
            if String.trim(value) == "",
              do: {:error, field: :model, message: "is required"},
              else: :ok

          _missing ->
            :ok
        end
      end)
    end
  end

  @type t :: %__MODULE__{}
end
