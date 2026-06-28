defmodule Ankole.AIGateway.HttpClient do
  @moduledoc """
  Executes provider HTTP requests for AIGateway.

  Request construction and response normalization live elsewhere. This module is
  only the transport boundary: it selects injected clients for tests, encodes
  request maps with `Ankole.JSON`, chooses the configured Finch protocol, and
  returns decoded provider bodies.
  """

  alias Ankole.AIGateway.HttpProtocol

  @default_timeout_ms 60_000

  @doc """
  Returns the non-streaming HTTP client configured for this call.

  Tests inject a function through opts. Production falls back to application
  config and then to `default_http_client/1`.
  """
  @spec client(keyword()) :: (map() -> {:ok, map()} | {:error, term()})
  def client(opts) do
    Keyword.get(opts, :http_client) ||
      :ankole
      |> Application.get_env(Ankole.AIGateway, [])
      |> Keyword.get(:http_client, &default_http_client/1)
  end

  @doc """
  Returns the streaming HTTP client configured for this call.

  The streaming client pushes raw byte chunks into a handler because provider
  modules own SSE parsing and event normalization.
  """
  @spec stream_client(keyword()) ::
          (map(),
           map(),
           (binary(), map() -> {:cont, map()} | {:halt, map()} | {:halt, {:error, term()}}) ->
             {:ok, map()} | {:error, term()})
  def stream_client(opts) do
    Keyword.get(opts, :http_stream_client) ||
      :ankole
      |> Application.get_env(Ankole.AIGateway, [])
      |> Keyword.get(:http_stream_client, &default_stream_client/3)
  end

  @doc """
  Sends one non-streaming provider request.

  Req is used only as an HTTP transport here. We do not use Req's `json:` option
  or automatic decoding because all AIGateway JSON must go through
  `Ankole.JSON`.
  """
  def default_http_client(%{method: :post, url: url, headers: headers, body: body} = request) do
    timeout_ms = Map.get(request, :timeout_ms, @default_timeout_ms)

    # Do not use Req's `json:` request option or response decoding here.
    # AIGateway's JSON boundary must go through Ankole.JSON, which is the
    # Torque-backed adapter configured for the control plane.
    with {:ok, encoded} <- Ankole.JSON.encode(body),
         {:ok, protocols} <- HttpProtocol.finch_protocols(request.http_protocol),
         {:ok, response} <-
           Req.post(
             url: url,
             headers: Enum.to_list(headers),
             body: encoded,
             decode_body: false,
             retry: false,
             receive_timeout: timeout_ms,
             connect_options: [protocols: protocols, timeout: timeout_ms]
           ) do
      {:ok, %{status: response.status, body: decode_response_body(response.body)}}
    else
      {:error, :invalid_http_protocol} -> {:error, :invalid_http_protocol}
      {:error, reason} -> {:error, {:upstream_request_failed, reason}}
    end
  end

  @doc """
  Sends one streaming provider request and forwards raw chunks to the caller.

  A non-2xx streaming response is aggregated only for error reporting. A 2xx
  response remains byte-streamed so the provider-specific parser can handle SSE
  edge cases such as split UTF-8, comments, and `[DONE]`.
  """
  def default_stream_client(
        %{method: :post, url: url, headers: headers, body: body} = request,
        state,
        handler
      ) do
    timeout_ms = Map.get(request, :timeout_ms, @default_timeout_ms)

    # Streaming responses are raw SSE bytes. Req must only transport bytes; the
    # provider-specific SSE parser owns JSON decoding through Ankole.JSON.
    with {:ok, encoded} <- Ankole.JSON.encode(body),
         {:ok, protocols} <- HttpProtocol.finch_protocols(request.http_protocol),
         {:ok, response} <-
           Req.post(
             url: url,
             headers: Enum.to_list(headers),
             body: encoded,
             into: :self,
             decode_body: false,
             retry: false,
             receive_timeout: timeout_ms,
             connect_options: [protocols: protocols, timeout: timeout_ms]
           ) do
      case response.status do
        status when status in 200..299 ->
          stream_response_body(response.body, state, handler)

        status ->
          {:error, {:upstream_response_failed, status, decode_async_error_body(response.body)}}
      end
    else
      {:error, :invalid_http_protocol} -> {:error, :invalid_http_protocol}
      {:error, reason} -> {:error, {:upstream_request_failed, reason}}
    end
  end

  defp decode_response_body(body) when is_binary(body) do
    case Ankole.JSON.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:ok, decoded} -> %{"data" => decoded}
      {:error, _reason} -> %{"raw_body" => String.slice(body, 0, 8_192)}
    end
  end

  defp decode_response_body(body), do: %{"raw_body" => inspect(body)}

  # Req returns an enumerable body when `into: :self` is used. The reduce keeps
  # the caller-owned stream state explicit and lets parser errors halt early.
  defp stream_response_body(async_body, state, handler) do
    Enum.reduce_while(async_body, {:ok, state}, fn chunk, {:ok, state} ->
      case handler.(chunk, state) do
        {:cont, state} -> {:cont, {:ok, state}}
        {:halt, {:error, reason}} -> {:halt, {:error, reason}}
        {:halt, state} -> {:halt, {:ok, state}}
      end
    end)
  end

  defp decode_async_error_body(async_body) do
    async_body
    |> Enum.reduce("", &(&2 <> &1))
    |> decode_response_body()
  end
end
