defmodule Ankole.E2E.FakeDingTalk.Router do
  @moduledoc false

  use Plug.Router

  alias Ankole.E2E.FakeDingTalk.{State, WebSocketHandler}

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json, :urlencoded],
    json_decoder: Ankole.JSON,
    pass: ["*/*"]
  )

  plug(:dispatch)

  @impl true
  def call(conn, opts) do
    conn = put_private(conn, :fake_dingtalk_state, Keyword.fetch!(opts, :state))
    super(conn, opts)
  end

  # WebSocket upgrade for the Stream connection. The client connects to
  # `{endpoint}/connect?ticket=...`, and `endpoint` is this server's host:port.
  get "/connect" do
    WebSockAdapter.upgrade(conn, WebSocketHandler, %{state: state(conn)}, [])
  end

  post "/v1.0/gateway/connections/open" do
    :ok = State.record_register(state(conn), conn.params)
    ticket = State.next_ticket(state(conn))
    json(conn, 200, %{"endpoint" => "ws://127.0.0.1:#{conn.port}", "ticket" => ticket})
  end

  post "/v1.0/oauth2/accessToken" do
    json(conn, 200, %{"accessToken" => "app-tok-fake", "expireIn" => 7200})
  end

  match _ do
    json(conn, 404, %{"code" => "unknown_method", "message" => conn.request_path})
  end

  defp state(conn), do: conn.private.fake_dingtalk_state

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Ankole.JSON.encode!(body))
  end
end
