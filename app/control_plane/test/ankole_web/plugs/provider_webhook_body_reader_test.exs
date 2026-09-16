defmodule AnkoleWeb.Plugs.ProviderWebhookBodyReaderTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias AnkoleWeb.Plugs.ProviderWebhookBodyReader

  @parsers Plug.Parsers.init(
             parsers: [:json],
             pass: ["*/*"],
             json_decoder: Ankole.JSON,
             body_reader: {ProviderWebhookBodyReader, :read_body, []}
           )

  test "keeps the exact bytes of a provider webhook next to the parsed body" do
    body = ~s({"events": [],  "destination":"U1"})

    conn =
      :post
      |> conn("/webhooks/v1/line/1650000001/events", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(@parsers)

    assert conn.body_params == %{"events" => [], "destination" => "U1"}
    assert ProviderWebhookBodyReader.body(conn) == body
  end

  test "keeps no copy for requests outside the provider webhook route" do
    conn =
      :post
      |> conn("/api/v1/things", ~s({"a":1}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(@parsers)

    assert conn.body_params == %{"a" => 1}
    assert ProviderWebhookBodyReader.body(conn) == ""
  end
end
