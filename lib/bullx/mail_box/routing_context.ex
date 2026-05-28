defmodule BullX.MailBox.RoutingContext do
  @moduledoc false

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
