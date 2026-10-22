defmodule Ankole.BackgroundAgentJobs.Schemas.TurnItem do
  @moduledoc """
  One append-only sanitized semantic thread item of a BackgroundAgentJob Turn.

  This stream is the one turn content record from the Worker. Every
  trajectory read path projects its messages from these rows at read time,
  and thread replay reads them back when a lost Codex thread must be rebuilt.
  """

  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.BackgroundAgentJobs

  postgres do
    table("background_agent_job_turn_items")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:turn_id, "background_agent_job_turn_items_turn_id_fkey"}])
    unique_index_names([{[:turn_id, :position], "background_agent_job_turn_items_pkey"}])
    identity_index_names(item_key: "background_agent_job_turn_items_item_key_index")

    check_constraints do
      check_constraint(:position, "baj_turn_items_position_nonnegative")
      check_constraint(:revision, "baj_turn_items_revision_nonnegative")
      check_constraint(:item_key, "baj_turn_items_item_key_present")
      check_constraint(:item, "baj_turn_items_item_check")
    end
  end

  attributes do
    attribute(:turn_id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      public?: true
    )

    attribute(:position, :integer,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      constraints: [min: 0]
    )

    attribute(:revision, :integer, allow_nil?: false, public?: true, constraints: [min: 0])
    attribute(:item_key, :string, allow_nil?: false, public?: true)

    attribute(:item, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      public?: true,
      constraints: [allow_datetime?: true]
    )

    create_timestamp(:inserted_at, type: :utc_datetime_usec)
  end

  identities do
    identity(:item_key, [:turn_id, :item_key], all_tenants?: true)
  end

  relationships do
    belongs_to :turn, Ankole.BackgroundAgentJobs.Schemas.Turn do
      source_attribute(:turn_id)
      attribute_type(Ankole.Ash.Types.UUIDv7)
      define_attribute?(false)
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :append do
      accept([:turn_id, :position, :revision, :item_key, :item])

      validate(fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :item) do
          %{"type" => type} when is_binary(type) and type != "" -> :ok
          _ -> {:error, field: :item, message: "must be one semantic thread item with a type"}
        end
      end)
    end
  end
end
