defmodule Ankole.E2E.FakeWeCom.Router do
  @moduledoc false

  use Plug.Router

  alias Ankole.E2E.FakeWeCom.WebSocketHandler

  plug(:match)
  plug(:dispatch)

  @impl true
  def call(conn, opts) do
    conn = put_private(conn, :fake_wecom_state, Keyword.fetch!(opts, :state))
    super(conn, opts)
  end

  # The bot long connection dials the bare gateway URL; every upgrade lands on
  # the root path and authenticates in-band with the subscribe frame.
  get "/" do
    WebSockAdapter.upgrade(conn, WebSocketHandler, %{state: conn.private.fake_wecom_state}, [])
  end

  match _ do
    send_resp(conn, 404, "unknown path")
  end
end
