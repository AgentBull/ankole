defmodule Ankole.Conversations.Delivery.PreviewState do
  @moduledoc """
  Durable provider preview state, fenced by its source Signal row.

  `Ankole.Conversations.Delivery.PreviewStates` reads and writes it.
  """
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Conversations

  postgres do
    table("delivery_previews")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:signal_id, "delivery_previews_tenant_id_signal_id_fkey"}])

    check_constraints do
      check_constraint(:checkpoint, "delivery_previews_checkpoint_check")
      check_constraint(:sequence_high_water, "delivery_previews_sequence_high_water_check")
    end
  end

  attributes do
    attribute(:signal_id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      public?: true
    )

    attribute(:provider_message_id, :string, constraints: [trim?: false], public?: true)
    attribute(:checkpoint, Ankole.Ash.Types.JSONMap, public?: true)

    attribute(:sequence_high_water, :integer,
      default: 0,
      allow_nil?: false,
      public?: true,
      constraints: [min: 0]
    )
  end

  calculations do
    calculate(
      :owner_generation,
      :integer,
      expr(fragment("COALESCE((?->>'owner_generation')::integer, 0)", checkpoint))
    )
  end

  actions do
    defaults([:read])

    create :ensure do
      primary?(true)
      accept([:signal_id])
      upsert?(true)
      upsert_fields([:signal_id])
    end

    update :update_preview do
      accept([:provider_message_id, :checkpoint, :sequence_high_water])
    end
  end
end
