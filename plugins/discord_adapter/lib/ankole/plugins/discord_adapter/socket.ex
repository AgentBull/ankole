defmodule Ankole.Plugins.DiscordAdapter.Socket do
  @moduledoc """
  Discord gateway connection.

  The struct holds one `IMTransport.WebSocket`. This module adds the gateway
  URL, the connect timeout, and the transfer to the session owner. It does not
  decide when to reconnect.
  """

  alias Ankole.Plugins.DiscordAdapter.Gateway
  alias IMTransport.WebSocket

  defstruct [:transport]

  @type t :: %__MODULE__{}

  @connect_timeout 10_000

  @spec connect(String.t(), pid()) :: {:ok, t()} | {:error, term()}
  def connect(url, owner) when is_binary(url) and is_pid(owner) do
    case WebSocket.connect(Gateway.socket_url(url),
           owner: owner,
           mint_options: [transport_opts: [timeout: @connect_timeout]]
         ) do
      {:ok, transport} -> {:ok, %__MODULE__{transport: transport}}
      {:error, _reason} = error -> error
    end
  end

  @spec stream(t(), term()) ::
          {:ok, t(), [term()]} | {:error, t(), term()} | :unknown
  def stream(%__MODULE__{transport: transport}, message) do
    case WebSocket.stream(transport, message) do
      {:ok, transport, frames} -> {:ok, %__MODULE__{transport: transport}, frames}
      {:error, transport, reason} -> {:error, %__MODULE__{transport: transport}, reason}
      :unknown -> :unknown
    end
  end

  @spec send_frame(t(), term()) :: {:ok, t()} | {:error, t(), term()}
  def send_frame(%__MODULE__{transport: transport}, frame) do
    case WebSocket.send_frame(transport, frame) do
      {:ok, transport} -> {:ok, %__MODULE__{transport: transport}}
      {:error, transport, reason} -> {:error, %__MODULE__{transport: transport}, reason}
    end
  end

  @spec close(t() | nil) :: :ok
  def close(nil), do: :ok
  def close(%__MODULE__{transport: transport}), do: WebSocket.close(transport)
end
