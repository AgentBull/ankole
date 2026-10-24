defmodule Ankole.AIAgent.Library.Schemas.AgentSkillLesson do
  @moduledoc "Immutable lesson content with a renewable lease and terminal retirement."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.AIAgent,
    extensions: [AshJsonApi.Resource]

  json_api do
    type("agent_skill_lesson")
    derive_filter?(false)
    derive_sort?(false)

    # The primary key names the record in the result of a generic action.
    default_fields([
      :id,
      :agent_uid,
      :skill_name,
      :content,
      :author_kind,
      :author,
      :evidence_job_ids,
      :checked_release,
      :review_after,
      :retired_at,
      :retire_reason,
      :inserted_at
    ])
  end

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
      default: &Ankole.Ecto.UUIDv7.autogenerate/0,
      public?: true
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

    create_timestamp(:inserted_at, type: :utc_datetime_usec, public?: true)
    update_timestamp(:updated_at, type: :utc_datetime_usec)
  end

  validations do
    validate(attribute_equals(:review_after, nil),
      where: [attribute_equals(:author_kind, :human)],
      message: "human lessons carry no lease"
    )

    for field <- [:review_after, :checked_release, :checked_skill_hash] do
      validate(present(field),
        where: [attribute_equals(:author_kind, :dreaming)],
        message: "is required"
      )
    end

    validate(attribute_does_not_equal(:evidence_job_ids, []),
      where: [attribute_equals(:author_kind, :dreaming)],
      message: "must contain evidence"
    )
  end

  actions do
    defaults([:read])

    read :console_list do
      argument(:agent_uid, :string, allow_nil?: false)
      filter(expr(agent_uid == ^arg(:agent_uid)))
      prepare(build(sort: [skill_name: :asc, inserted_at: :desc]))
    end

    create :teach_human do
      accept([:agent_uid, :skill_name, :content, :author])
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

      change(set_attribute(:author_kind, :dreaming))
      change(Ankole.AIAgent.Library.Changes.PrepareLesson, only_when_valid?: true)
    end

    update :renew do
      accept([:review_after, :checked_release, :checked_skill_hash])
      change(filter(expr(is_nil(retired_at) and author_kind == :dreaming)))
    end

    update :retire do
      accept([:retired_at, :retire_reason])
      validate(present([:retired_at, :retire_reason]))
      change(filter(expr(is_nil(retired_at))))
    end

    action :console_teach, :struct do
      constraints(instance_of: __MODULE__)
      argument(:agent_uid, :string, allow_nil?: false)
      argument(:skill_name, :string, allow_nil?: false)
      argument(:content, :string, allow_nil?: false, constraints: [trim?: false])

      run(__MODULE__.Actions)
    end

    action :revoke, :struct do
      constraints(instance_of: __MODULE__)
      argument(:agent_uid, :string, allow_nil?: false)
      argument(:lesson_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)

      run(__MODULE__.Actions)
    end
  end

  @type t :: %__MODULE__{}
end
