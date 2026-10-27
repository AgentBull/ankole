defmodule Ankole.Authn.Challenge do
  @moduledoc "One verification ceremony with a durable attempt limit."
  use Ankole.Ash.Resource, tenancy: :site, domain: Ankole.Authn.Domain

  postgres do
    table("authn_challenges")
    repo(Ankole.Repo)
    migrate?(false)

    check_constraints do
      check_constraint(:attempt_count, "authn_challenges_attempts")
      check_constraint(:verified_at, "authn_challenges_consumed")
      check_constraint(:target, "authn_challenges_target")
      check_constraint(:browser_session_id, "authn_challenges_anchor")
      check_constraint(:factor_stage, "authn_challenges_factor_stage")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:strategy, :string, allow_nil?: false)
    attribute(:purpose, :string, allow_nil?: false)

    attribute(:factor_stage, :atom,
      allow_nil?: false,
      default: :primary,
      constraints: [one_of: [:primary, :secondary, :step_up]]
    )

    attribute(:browser_session_id, Ankole.Ash.Types.UUIDv7)
    attribute(:tenant_id, Ankole.Ash.Types.UUIDv7)
    attribute(:principal_uid, Ankole.Ash.Types.PrincipalKey)
    attribute(:target, :string)
    attribute(:secret_digest, :binary, sensitive?: true)
    attribute(:ceremony_context, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:attempt_count, :integer, allow_nil?: false, default: 0, constraints: [min: 0])
    attribute(:max_attempts, :integer, allow_nil?: false, default: 5, constraints: [min: 1])
    attribute(:challenge_started_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:expires_at, :utc_datetime_usec)
    attribute(:verified_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :reserve_in_tx do
      accept([
        :id,
        :strategy,
        :purpose,
        :factor_stage,
        :browser_session_id,
        :tenant_id,
        :principal_uid,
        :target,
        :secret_digest,
        :ceremony_context,
        :max_attempts,
        :challenge_started_at
      ])
    end

    update :activate_in_tx do
      require_atomic?(true)
      accept([:expires_at])
      argument(:expected_digest, :binary, allow_nil?: false, sensitive?: true)
      change(filter(expr(secret_digest == ^arg(:expected_digest) and is_nil(verified_at))))
    end

    update :attempt_in_tx do
      accept([:attempt_count, :secret_digest, :expires_at, :verified_at])
    end

    update :invalidate_in_tx do
      accept([])
      change(set_attribute(:secret_digest, nil))
      change(set_attribute(:expires_at, nil))
    end

    destroy(:expire_in_tx)
  end
end
