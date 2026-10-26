defmodule Ankole.BackgroundActivities.ConsoleRunCounts do
  @moduledoc "Task status counters of a Workflow run."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        cancelled: [type: :integer, allow_nil?: false],
        failed: [type: :integer, allow_nil?: false],
        queued: [type: :integer, allow_nil?: false],
        running: [type: :integer, allow_nil?: false],
        sleeping: [type: :integer, allow_nil?: false],
        succeeded: [type: :integer, allow_nil?: false],
        total: [type: :integer, allow_nil?: false]
      ]
    ]
end
