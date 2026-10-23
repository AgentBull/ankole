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

    action :record_provider_message, :term do
      argument(:signal_id, :term)
      argument(:provider_message_id, :term)
      argument(:provider_thread_id, :term)

      run(__MODULE__.Actions)
    end

    action :put_checkpoint, :term do
      argument(:signal_id, :term)
      argument(:checkpoint, :term)
      argument(:source, :term)

      run(__MODULE__.Actions)
    end

    action :update_checkpoint, :term do
      argument(:signal_id, :term)
      argument(:update, :term)

      run(__MODULE__.Actions)
    end

    action :prepare_mutation, :term do
      argument(:signal_id, :term)
      argument(:purpose, :term)
      argument(:actions_digest, :term)
      argument(:uuid, :term)

      run(__MODULE__.Actions)
    end

    action :claim_owner, :term do
      argument(:signal_id, :term)
      argument(:subject_uid, :term)
      argument(:conversation_id, :term)
      argument(:stream_signal_id, :term)
      argument(:opts, :term, default: [])

      run(__MODULE__.Actions)
    end

    action :authorize_owner, :term do
      argument(:opts, :term, default: [])

      run(__MODULE__.Actions)
    end

    action :switch_owner, :term do
      argument(:state, :term)
      argument(:new_owner, :term)
      argument(:handoff, :term)

      run(__MODULE__.Actions)
    end

    action :checkpoint_presentation, :term do
      argument(:state, :term)
      argument(:presentation, :term)

      run(__MODULE__.Actions)
    end

    action :wake_blocked, :term do
      argument(:agent_uid, :term)
      argument(:binding_name, :term)

      run(__MODULE__.Actions)
    end
  end
end
