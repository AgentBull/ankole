defmodule BullX.IMGateway.ChannelAdapter.Outcome do
  @moduledoc """
  Builder for the outbound delivery outcome map returned by channel adapters.

  Adapters call `build/4` after a successful send/edit/recall to produce the uniform
  outcome shape consumed by callers of `BullX.IMGateway.ChannelAdapter.deliver/3`.
  The keys are stringified for direct serialization back through Phoenix /
  CloudEvents pipelines.

  Status is intentionally typed as a string (current values: `"sent"`,
  `"degraded"`, `"recalled"`). A future async-delivery adapter (e.g. DingTalk OA
  task) can extend the vocabulary without changing the shape.
  """

  @spec build(
          delivery_id :: String.t() | nil,
          status :: String.t(),
          external_ids :: [String.t()],
          warnings :: [String.t()]
        ) :: map()
  def build(delivery_id, status, external_ids, warnings)
      when is_binary(status) and is_list(external_ids) and is_list(warnings) do
    %{
      "delivery_id" => delivery_id,
      "status" => status,
      "external_message_ids" => external_ids,
      "primary_external_id" => List.first(external_ids),
      "warnings" => warnings
    }
  end
end
