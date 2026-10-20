defmodule AnkoleWeb.Plugs.ProviderWebhookBodyReader do
  @moduledoc """
  Keeps the exact request bytes of a provider webhook next to its parsed form.

  `Plug.Parsers` calls `read_body/2` in place of `Plug.Conn.read_body/2`. A
  provider signs the bytes it sent, so a handler that verifies a signature
  cannot use the parsed map. Only `/webhooks/v1/:handler/:instance/:kind`
  requests keep the copy; every other request reads its body as before.
  """

  import Plug.Conn

  @private_key :provider_webhook_raw_body

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(
        %Plug.Conn{method: "POST", path_info: ["webhooks", "v1", _handler, _instance, _kind]} =
          conn,
        opts
      ) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} -> {:ok, chunk, keep(conn, chunk)}
      {:more, chunk, conn} -> {:more, chunk, keep(conn, chunk)}
      {:error, _reason} = error -> error
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)

  @spec body(Plug.Conn.t()) :: binary()
  def body(%Plug.Conn{private: private}), do: Map.get(private, @private_key, "")

  defp keep(conn, chunk), do: put_private(conn, @private_key, body(conn) <> chunk)
end
