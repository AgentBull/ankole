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
    case read_body(conn, length: @max_body_bytes, read_length: 64 * 1024) do
      {:ok, body, conn} when byte_size(body) <= @max_body_bytes ->
        conn
        |> put_private(@private_key, body)
        |> Map.put(:body_params, %{})

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

  def call(conn, _opts), do: conn

  @doc false
  @spec body(Plug.Conn.t()) :: binary()
  def body(conn), do: conn.private[@private_key] || ""

  @doc false
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes
end
