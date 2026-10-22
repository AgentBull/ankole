defmodule Ankole.Conversations.Conversation do
  @moduledoc "A shared conversation hosted by Ankole or an external platform."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Conversations.Domain

  @type t :: %__MODULE__{}

  postgres do
    table("conversations")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:created_by, "conversations_created_by_fkey"},
      {:page_id, "conversations_page_fkey"},
      {:principal_group_id, "conversations_principal_group_id_fkey"}
    ])

    unique_index_names([
      {[:tenant_id, :id], "conversations_pkey"},
      {[:tenant_id, :provider_conversation_id], "conversations_external_identity_index"}
    ])

    check_constraints do
      check_constraint(:kind, "conversations_kind_check")
      check_constraint(:page_id, "conversations_page_origin_check")
      check_constraint(:title, "conversations_title_present")
      check_constraint(:provider_conversation_id, "conversations_origin_check")
      check_constraint(:sequence_high_water, "conversations_sequence_high_water_check")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false, public?: true)

    attribute(:kind, :atom,
      constraints: [one_of: [:native, :external]],
      default: :native,
      allow_nil?: false,
      public?: true
    )

    attribute(:title, :string,
      constraints: [trim?: false, match: ~r/\S/u],
      allow_nil?: false,
      public?: true
    )

    attribute(:created_by, Ankole.Ash.Types.PrincipalKey, public?: true)
    attribute(:page_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:last_activity_at, :utc_datetime_usec, allow_nil?: false, public?: true)

    attribute(:sequence_high_water, :integer,
      default: 0,
      allow_nil?: false,
      constraints: [min: 0]
    )

    attribute(:provider_conversation_id, :string,
      constraints: [trim?: false, match: ~r/\S/u],
      public?: true
    )

    attribute(:external_kind, :atom,
      constraints: [
        one_of: [:im_dm, :im_group, :webhook_endpoint, :issue, :alert_stream, :unknown]
      ],
      public?: true
    )

    attribute(:reply_mode, :atom, constraints: [one_of: [:none, :channel, :entry]], public?: true)
    attribute(:visibility, :string, constraints: [trim?: false], public?: true)
    attribute(:principal_group_id, :uuid, public?: true)

    attribute(:metadata, Ankole.Ash.Types.JSONMap,
      default: %{},
      allow_nil?: false,
      constraints: [allow_datetime?: true],
      public?: true
    )

    attribute(:raw_payload, Ankole.Ash.Types.JSONMap,
      default: %{},
      allow_nil?: false,
      constraints: [allow_datetime?: true],
      public?: true
    )

    attribute(:first_seen_at, :utc_datetime_usec, public?: true)
    attribute(:last_seen_at, :utc_datetime_usec, public?: true)
    attribute(:ambient_standing_orders, :string, constraints: [trim?: false], public?: true)

    attribute(:ambient_standing_orders_set_by, :string,
      constraints: [trim?: false],
      public?: true
    )

    attribute(:ambient_standing_orders_updated_at, :utc_datetime_usec, public?: true)
    timestamps(type: :utc_datetime_usec)
  end

  validations do
    validate(present(:created_by), where: [attribute_equals(:kind, :native)])

    validate(
      present([
        :provider_conversation_id,
        :external_kind,
        :reply_mode,
        :first_seen_at,
        :last_seen_at
      ]),
      where: [attribute_equals(:kind, :external)]
    )
  end

  actions do
    defaults([:read])

    create_if_absent :ensure_native do
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)
      accept([:id, :title, :created_by, :page_id, :last_activity_at])
      change(set_attribute(:kind, :native))
    end

    create :create_external do
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)

      accept([
        :id,
        :title,
        :last_activity_at,
        :provider_conversation_id,
        :external_kind,
        :reply_mode,
        :visibility,
        :principal_group_id,
        :metadata,
        :raw_payload,
        :first_seen_at,
        :last_seen_at
      ])

      change(set_attribute(:kind, :external))
    end

    in_tx_update :observe do
      accept([
        :title,
        :external_kind,
        :reply_mode,
        :visibility,
        :principal_group_id,
        :metadata,
        :raw_payload,
        :last_seen_at
      ])

      validate(attribute_equals(:kind, :external))
    end

    in_tx_update :put_metadata do
      accept([:metadata])
    end

    in_tx_update :touch do
      accept([:last_activity_at, :last_seen_at])
    end

    in_tx_update :advance_sequence do
      accept([])
      change(atomic_update(:sequence_high_water, expr(sequence_high_water + 1)))
    end

    update :set_standing_orders do
      transaction?(false)
      require_atomic?(true)

      accept([
        :ambient_standing_orders,
        :ambient_standing_orders_set_by,
        :ambient_standing_orders_updated_at
      ])
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
      change(Ankole.Ash.RequireTransaction.Atomic)
    end
  end
end
