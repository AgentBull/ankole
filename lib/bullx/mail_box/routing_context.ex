defmodule BullX.MailBox.RoutingContext do
  @moduledoc """
  Projects CloudEvents mail into the CEL-visible MailBox routing shape.

  Gateways own the raw event envelope. MailBox rules only see this normalized
  context, which keeps match expressions stable even when individual gateway
  payloads carry extra provider-specific fields.
  """

  @spec project(map()) :: map()
  def project(%{"id" => id, "source" => source, "type" => type, "time" => time, "data" => data}) do
    %{
      "source" => source,
      "type" => type,
      "time" => time,
      "event" => %{
        "id" => id,
        "identity" => %{"source" => source, "id" => id}
      },
      "channel" => data["channel"],
      "scope" => data["scope"],
      "actor" => data["actor"],
      "refs" => data["refs"],
      "reply_address" => data["reply_address"],
      "routing_facts" => data["routing_facts"]
    }
  end
end
