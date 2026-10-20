defmodule AnkoleWeb.Plugs.WebhookCallbackBodyReader do
  @moduledoc """
  Reads opaque callback bodies before the general request parsers.

  Webhook payloads do not need to be JSON. This plug applies one small,
  explicit byte limit and marks the body as fetched so Plug.Parsers does not
  reinterpret or discard it.
  """

  @behaviour Plug

  import Plug.Conn

  @max_body_bytes 1_048_576
  @private_key :webhook_callback_body

  @doc false
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @doc false
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(
        %Plug.Conn{
          method: "POST",
          path_info: ["webhooks", "v1", "event-callbacks", _token]
        } = conn,
        _opts
      ) do
    read_callback_body(conn)
  end

  def call(
        %Plug.Conn{method: "POST", path_info: ["signals", "v1", "cloudevents", _token]} = conn,
        _opts
      ),
      do: read_callback_body(conn)

  def call(conn, _opts), do: conn

  defp read_callback_body(conn) do
    case read_body(conn, length: @max_body_bytes, read_length: 64 * 1024) do
      {:ok, body, conn} when byte_size(body) <= @max_body_bytes ->
        conn
        |> put_private(@private_key, body)
        |> then(&%{&1 | body_params: %{}})

      {:ok, _body, conn} ->
        conn
        |> send_resp(413, "")
        |> halt()

      {:more, _partial, conn} ->
        conn
        |> send_resp(413, "")
        |> halt()

      {:error, _reason} ->
        conn
        |> send_resp(400, "")
        |> halt()
    end
  end

  @doc false
  @spec body(Plug.Conn.t()) :: binary()
  def body(conn), do: conn.private[@private_key] || ""
end
