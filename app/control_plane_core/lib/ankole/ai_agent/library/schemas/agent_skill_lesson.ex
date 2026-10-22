defmodule Ankole.AIAgent.Library.Schemas.AgentSkillLesson do
  @moduledoc "Immutable lesson content with a renewable lease and terminal retirement."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.AIAgent.Library.Domain

  postgres do
    table("agent_skill_lessons")
    repo(Ankole.Repo)
    migrate?(false)
    storage_types(evidence_job_ids: :map)
    foreign_key_names(agent_uid: "agent_skill_lessons_agent_uid_fkey")

    check_constraints do
      check_constraint(:author_kind, "agent_skill_lessons_author_kind")
      check_constraint(:skill_name, "agent_skill_lessons_skill_name_format")
      check_constraint(:content, "agent_skill_lessons_content_present")
      check_constraint(:evidence_job_ids, "agent_skill_lessons_evidence_array")
      check_constraint(:retire_reason, "agent_skill_lessons_retire_shape")
      check_constraint(:review_after, "agent_skill_lessons_lease_shape")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false, public?: true)

    attribute(:skill_name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:content, :string,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:author_kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:dreaming, :human]]
    )

    attribute(:author, Ankole.Ash.Types.ActorRef, public?: true)

    attribute(:evidence_job_ids, {:array, :integer},
      allow_nil?: false,
      default: [],
      public?: true
    )

    attribute(:checked_release, :string, public?: true)
    attribute(:checked_skill_hash, :string, public?: true)
    attribute(:review_after, :utc_datetime_usec, public?: true)
    attribute(:retired_at, :utc_datetime_usec, public?: true)

    attribute(:retire_reason, :atom,
      public?: true,
      constraints: [one_of: [:human_revoked, :lapsed, :obsolete]]
    )

    create_timestamp(:inserted_at, type: :utc_datetime_usec)
    update_timestamp(:updated_at, type: :utc_datetime_usec)
  end

  validations do
    validate(Ankole.AIAgent.Library.Validations.LeaseShape)
  end

  actions do
    defaults([:read])

    create :teach_human do
      accept([:agent_uid, :skill_name, :content, :author])
      transaction?(false)
      change(set_attribute(:author_kind, :human))
      change(Ankole.AIAgent.Library.Changes.PrepareLesson, only_when_valid?: true)
    end

    create :teach_dreaming do
      accept([
        :agent_uid,
        :skill_name,
        :content,
        :author,
        :evidence_job_ids,
        :checked_release,
        :checked_skill_hash,
        :review_after
      ])

      transaction?(false)
      change(set_attribute(:author_kind, :dreaming))
      change(Ankole.AIAgent.Library.Changes.PrepareLesson, only_when_valid?: true)
    end

    in_tx_update :renew do
      accept([:review_after, :checked_release, :checked_skill_hash])
      change(filter(expr(is_nil(retired_at) and author_kind == :dreaming)))
    end

    in_tx_update :retire do
      accept([:retired_at, :retire_reason])
      validate(present([:retired_at, :retire_reason]))
      change(filter(expr(is_nil(retired_at))))
    end
  end

  @type t :: %__MODULE__{}
end
