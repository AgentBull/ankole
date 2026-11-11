defmodule Ankole.Issues.Issue do
  @moduledoc """
  The work-item record of one native conversation.

  The conversation holds the title, the discussion, and the Agent's Session,
  whose Background Agent Jobs and Workflows are the Issue's runs. This row holds
  what a person decides: `todo` until the Agent receives the request, `started`
  once it has, and `done` when a person accepts the result. `description` is the
  request that starts the Agent.
  """

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Issues

  @type t :: %__MODULE__{}

  postgres do
    table("issues")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:conversation_id, "issues_conversation_fkey"},
      {:agent_uid, "issues_agent_fkey"}
    ])
  end

  attributes do
    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      public?: true
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :todo,
      constraints: [one_of: [:todo, :started, :done]],
      public?: true
    )

    attribute(:description, :string,
      allow_nil?: false,
      default: "",
      constraints: [trim?: false, allow_empty?: true, max_length: 50_000],
      public?: true
    )

    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, public?: true)

    timestamps(type: :utc_datetime_usec, public?: true)
  end

  actions do
    defaults([:read])

    create :open do
      primary?(true)
      accept([:conversation_id, :status, :description, :agent_uid])
    end

    # A task room receives its Issue once, however many runs start in it.
    create_if_absent :ensure do
      accept([:conversation_id, :status, :agent_uid])
    end

    # The request changes only while the Agent has not received it.
    update :describe do
      require_atomic?(true)
      accept([:description])
      change(filter(expr(status == :todo)))
    end

    # The Agent received the request, or new work reopened an accepted Issue.
    update :start do
      require_atomic?(true)
      accept([])
      change(filter(expr(status != :started)))
      change(set_attribute(:status, :started))
    end

    # A person reopens an accepted Issue that never started.
    update :wait do
      require_atomic?(true)
      accept([])
      change(filter(expr(status == :done)))
      change(set_attribute(:status, :todo))
    end

    update :finish do
      require_atomic?(true)
      accept([])
      change(filter(expr(status != :done)))
      change(set_attribute(:status, :done))
    end
  end
end
