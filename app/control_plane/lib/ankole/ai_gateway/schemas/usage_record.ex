defmodule Ankole.AIGateway.Schemas.UsageRecord do
  @moduledoc """
  One immutable row per counted provider round. `capability` names what the
  round served. A language-model round of a hosted composite Response is one
  row: the kernel runs its main-model and image rounds internally and reports
  one aggregate, from which the row keeps the language-model usage alone. The
  images that the image provider generated for that Response are a second row,
  whose `capability` is `image_generate`.

  A round that is not a language-model round records what it produced in
  `unit` and `quantity`, such as one image, the characters of a speech request,
  the seconds of transcribed audio, or the pages that an OCR model read, and
  the cost in `provider_cost` when the Provider reports one.

  A token count is `nil` when the Provider did not report it, and 0 only when
  the Provider reported zero. `model` is the requested `provider_id/model`;
  `provider_model` is the model that the Provider reported when it differs.
  """
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.AIGateway

  postgres do
    table("ai_gateway_usage_records")
    repo(Ankole.Repo)
    migrate?(false)

    check_constraints do
      check_constraint(:origin, "ai_gateway_usage_records_origin_check")
      check_constraint(:input_tokens, "ai_gateway_usage_records_input_tokens_check")
      check_constraint(:output_tokens, "ai_gateway_usage_records_output_tokens_check")

      check_constraint(
        :cached_input_tokens,
        "ai_gateway_usage_records_cached_input_tokens_check"
      )

      check_constraint(
        :cache_creation_input_tokens,
        "ai_gateway_usage_records_cache_creation_input_tokens_check"
      )

      check_constraint(:reasoning_tokens, "ai_gateway_usage_records_reasoning_tokens_check")
      check_constraint(:job_id, "ai_gateway_usage_records_job_id_check")
      check_constraint(:attempt, "ai_gateway_usage_records_attempt_check")
      check_constraint(:capability, "ai_gateway_usage_records_capability_check")
      check_constraint(:quantity, "ai_gateway_usage_records_quantity_check")
      check_constraint(:provider_cost, "ai_gateway_usage_records_provider_cost_check")
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
      constraints: [
        one_of: [:agent, :codex, :applet, :brain, :oidc_human, :compaction, :pod_files]
      ]
    )

    attribute(:model, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:provider_model, :string, constraints: [trim?: false])
    attribute(:model_profile, :string, constraints: [trim?: false])
    attribute(:served_profile, :string, constraints: [trim?: false])
    attribute(:input_tokens, :integer, constraints: [min: 0])
    attribute(:output_tokens, :integer, constraints: [min: 0])
    attribute(:cached_input_tokens, :integer, constraints: [min: 0])
    attribute(:cache_creation_input_tokens, :integer, constraints: [min: 0])
    attribute(:reasoning_tokens, :integer, constraints: [min: 0])
    attribute(:human_uid, Ankole.Ash.Types.PrincipalKey)
    attribute(:session_id, :string, constraints: [trim?: false])
    attribute(:signal_id, :uuid)
    attribute(:job_id, :integer, constraints: [min: 1])
    attribute(:attempt, :integer, constraints: [min: 0])

    attribute(:capability, :atom,
      allow_nil?: false,
      default: :llm,
      constraints: [one_of: [:llm, :image_generate, :decision, :speech, :transcription, :ocr]]
    )

    attribute(:unit, :atom, constraints: [one_of: [:image, :character, :second, :page]])
    attribute(:quantity, :integer, constraints: [min: 0])
    attribute(:provider_cost, :decimal, constraints: [min: 0])
    create_timestamp(:inserted_at, type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :record_round do
      accept([
        :subject_uid,
        :origin,
        :model,
        :provider_model,
        :model_profile,
        :served_profile,
        :input_tokens,
        :output_tokens,
        :cached_input_tokens,
        :cache_creation_input_tokens,
        :reasoning_tokens,
        :human_uid,
        :session_id,
        :signal_id,
        :job_id,
        :attempt,
        :capability,
        :unit,
        :quantity,
        :provider_cost
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
