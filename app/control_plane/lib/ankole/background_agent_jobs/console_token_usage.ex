defmodule Ankole.BackgroundAgentJobs.ConsoleTokenUsage do
  @moduledoc "Token counters for a Turn model call or thread total."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        cached_input_tokens: [type: :integer, allow_nil?: false],
        input_tokens: [type: :integer, allow_nil?: false],
        output_tokens: [type: :integer, allow_nil?: false],
        reasoning_output_tokens: [type: :integer, allow_nil?: false],
        total_tokens: [type: :integer, allow_nil?: false]
      ]
    ]
end
