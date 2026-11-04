defmodule Ankole.Conversations.NextStep do
  @moduledoc """
  One next step that a personal assistant offered a Human on the chat home.

  `Ankole.Conversations.NextSteps` owns the menu that these rows form: every
  step of one menu shares `last_offered_at`, `offer_count` counts the menus
  that offered the step, and `chosen_at` records the Human's choice.
  """

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Conversations

  postgres do
    table("next_step_suggestions")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:human_uid, "next_step_suggestions_human_fkey"}])
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0,
      public?: true
    )

    attribute(:human_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false, public?: true)
    attribute(:title, :string, allow_nil?: false, public?: true)
    attribute(:outcome, :string, allow_nil?: false, public?: true)
    attribute(:effort, :string, allow_nil?: false, public?: true)
    attribute(:why_now, :string, allow_nil?: false, public?: true)
    attribute(:ambitious, :boolean, allow_nil?: false, default: false, public?: true)
    attribute(:position, :integer, allow_nil?: false, constraints: [min: 0], public?: true)

    attribute(:offer_count, :integer,
      allow_nil?: false,
      constraints: [min: 1],
      public?: true
    )

    attribute(:last_offered_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:chosen_at, :utc_datetime_usec, public?: true)
    timestamps(type: :utc_datetime_usec)
  end

  actions do
    defaults([:read, :destroy])

    create :offer do
      primary?(true)

      accept([
        :human_uid,
        :title,
        :outcome,
        :effort,
        :why_now,
        :ambitious,
        :position,
        :offer_count,
        :last_offered_at
      ])
    end

    update :reoffer do
      require_atomic?(false)

      accept([
        :title,
        :outcome,
        :effort,
        :why_now,
        :ambitious,
        :position,
        :offer_count,
        :last_offered_at
      ])
    end

    update :choose do
      require_atomic?(false)
      accept([:chosen_at])
    end
  end

  @type t :: %__MODULE__{}
end
