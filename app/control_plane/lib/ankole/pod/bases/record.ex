defmodule Ankole.Pod.Bases.Record do
  @moduledoc "The public value and concurrency facts of a runtime-defined Bases record."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        id: [type: Ankole.Ash.Types.UUIDv7, allow_nil?: false],
        data: [type: Ankole.Pod.Bases.RecordData, allow_nil?: false],
        versions: [type: Ankole.Pod.Bases.FieldVersions, allow_nil?: false],
        created_at: [type: :utc_datetime_usec, allow_nil?: false],
        updated_at: [type: :utc_datetime_usec, allow_nil?: false],
        created_by: [type: :string, allow_nil?: false],
        updated_by: [type: :string, allow_nil?: false]
      ]
    ]
end
