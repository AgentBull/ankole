defmodule Ankole.Pod.PageComment do
  @moduledoc "A document comment or one-level reply, including its retained deletion and resolution facts."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Pod

  postgres do
    table("page_comments")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:page_id, "page_comments_page_fkey"},
      {:root_id, "page_comments_root_fkey"}
    ])

    unique_index_names([{[:id], "page_comments_pkey"}])

    check_constraints do
      check_constraint(:body, "page_comments_body_shape")
      check_constraint(:version, "page_comments_version")
      check_constraint(:root_id, "page_comments_root_shape")
      check_constraint(:resolved_at, "page_comments_resolution_shape")
      check_constraint(:anchor_revision, "page_comments_anchor_shape")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:page_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:root_id, Ankole.Ash.Types.UUIDv7)
    attribute(:body, :string, constraints: [trim?: false, allow_empty?: true, max_length: 20_000])
    attribute(:author, Ankole.Ash.Types.ActorRef, allow_nil?: false)
    attribute(:updated_by, Ankole.Ash.Types.ActorRef, allow_nil?: false)
    attribute(:deleted_by, Ankole.Ash.Types.ActorRef)
    attribute(:version, :integer, allow_nil?: false, default: 1, constraints: [min: 1])
    attribute(:quote, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:anchor_revision, :integer, constraints: [min: 0])
    attribute(:resolved_at, :utc_datetime_usec)
    attribute(:resolved_by, Ankole.Ash.Types.ActorRef)
    attribute(:deleted_at, :utc_datetime_usec)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:activity_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:activity_by, Ankole.Ash.Types.ActorRef, allow_nil?: false)
  end

  relationships do
    has_many :replies, __MODULE__ do
      destination_attribute(:root_id)
    end
  end

  actions do
    defaults([:read])

    read :list do
      pagination(keyset?: true, max_page_size: 100, countable: false, required?: false)
    end

    create :create_in_tx do
      accept([
        :id,
        :page_id,
        :root_id,
        :body,
        :author,
        :updated_by,
        :activity_at,
        :activity_by,
        :quote,
        :anchor_revision,
        :created_at,
        :updated_at
      ])
    end

    update :activity_in_tx do
      require_atomic?(true)
      accept([:activity_at, :activity_by])
    end

    update :change_in_tx do
      require_atomic?(true)

      accept([
        :body,
        :quote,
        :anchor_revision,
        :resolved_at,
        :resolved_by,
        :deleted_at,
        :deleted_by,
        :updated_at,
        :updated_by
      ])

      change(atomic_update(:version, expr(version + 1)))
    end

    destroy :purge do
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
