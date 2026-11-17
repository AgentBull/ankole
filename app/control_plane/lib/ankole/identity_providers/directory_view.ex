defmodule Ankole.IdentityProviders.DirectoryView do
  @moduledoc "Directory sync snapshot and recent event evidence for Pod and Console administration."

  @snapshot_fields [
    provider_id: [type: :string, allow_nil?: false],
    status: [type: :string, allow_nil?: false],
    revision: [type: :integer, allow_nil?: false],
    scope_fingerprint: [type: :string],
    snapshot_fingerprint: [type: :string],
    approved_scope_fingerprint: [type: :string],
    member_uids: [type: {:array, :string}, allow_nil?: false],
    missing_uids: [type: {:array, :string}, allow_nil?: false],
    last_started_at: [type: :utc_datetime_usec],
    last_success_at: [type: :utc_datetime_usec],
    last_error: [type: :string],
    reviewed_by: [type: Ankole.Ash.Types.ActorRef],
    reviewed_at: [type: :utc_datetime_usec],
    review_reason: [type: :string]
  ]

  @event_fields [
    id: [type: :string, allow_nil?: false],
    event_id: [type: :string, allow_nil?: false],
    event_type: [type: :string, allow_nil?: false],
    external_ids: [type: {:array, :string}, allow_nil?: false],
    reason: [type: :string],
    provider_time: [type: :utc_datetime_usec],
    status: [type: :string, allow_nil?: false],
    last_error: [type: :string],
    processed_at: [type: :utc_datetime_usec],
    reviewed_by: [type: Ankole.Ash.Types.ActorRef],
    review_reason: [type: :string],
    inserted_at: [type: :utc_datetime_usec, allow_nil?: false]
  ]

  @view_fields [
    snapshot: [type: :map, constraints: [fields: @snapshot_fields]],
    events: [
      type: {:array, :map},
      allow_nil?: false,
      constraints: [items: [fields: @event_fields]]
    ]
  ]

  use Ash.Type.NewType, subtype_of: :map, constraints: [fields: @view_fields]
end
