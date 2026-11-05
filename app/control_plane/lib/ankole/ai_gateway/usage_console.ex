defmodule Ankole.AIGateway.UsageConsole do
  @moduledoc "The Console view of one tenant's model usage over a recent window."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    domain: Ankole.AIGateway,
    extensions: [Ankole.AuthZ.Extension]

  authz do
    scope(:site_console)
    allow(:summary, resource: "site_console:ai_gateway_usage", action: "read")
  end

  @count [type: :integer, constraints: [min: 0]]

  @row_fields [
    key: [type: :string, constraints: [trim?: false, allow_empty?: true]],
    name: [type: :string, constraints: [trim?: false, allow_empty?: true]],
    rounds: [type: :integer, allow_nil?: false, constraints: [min: 0]],
    reported_rounds: [type: :integer, allow_nil?: false, constraints: [min: 0]],
    input_tokens: @count,
    output_tokens: @count,
    cached_input_tokens: @count,
    reasoning_tokens: @count
  ]

  @rows [type: {:array, :map}, allow_nil?: false, constraints: [items: [fields: @row_fields]]]

  json_api do
    type("ai_gateway_usage_summary")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :summary, :map do
      transaction?(false)

      constraints(
        fields: [
          window_started_at: [type: :string, allow_nil?: false],
          total: [type: :map, allow_nil?: false, constraints: [fields: @row_fields]],
          by_agent: @rows,
          by_human: @rows,
          by_origin: @rows
        ]
      )

      argument(:days, :integer, allow_nil?: false, default: 7, constraints: [min: 1, max: 90])
      run(__MODULE__.Actions)
    end
  end
end
