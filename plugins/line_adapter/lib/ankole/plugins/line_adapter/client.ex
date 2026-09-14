defmodule Ankole.Plugins.LineAdapter.Client do
  @moduledoc false

  @default_api_base_url "https://api.line.me"
  @default_data_base_url "https://api-data.line.me"
  @default_receive_timeout 30_000
  @download_receive_timeout 120_000

  defmodule Error do
    @moduledoc false

    @enforce_keys [:kind]
    defstruct [:kind, :status, :message, :details]

    @type t :: %__MODULE__{
            kind: :api | :http | :transport,
            status: integer() | nil,
            message: String.t() | nil,
            details: map() | nil
          }
  end

  @enforce_keys [:api_base_url, :data_base_url, :access_token, :request_options]
  defstruct [:api_base_url, :data_base_url, :access_token, :request_options]

  @type t :: %__MODULE__{
          api_base_url: String.t(),
          data_base_url: String.t(),
          access_token: String.t(),
          request_options: keyword()
        }

  @spec new(String.t(), keyword()) :: t()
  def new(access_token, opts \\ []) when is_binary(access_token) do
    {api_base_url, opts} = Keyword.pop(opts, :api_base_url, @default_api_base_url)
    {data_base_url, opts} = Keyword.pop(opts, :data_base_url, @default_data_base_url)

    %__MODULE__{
      api_base_url: String.trim_trailing(api_base_url, "/"),
      data_base_url: String.trim_trailing(data_base_url, "/"),
      access_token: access_token,
      request_options: opts
    }
  end

  @spec get(t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get(%__MODULE__{} = client, path) when is_binary(path) do
    request(client, client.api_base_url <> path, method: :get)
  end

  @spec post(t(), String.t(), map(), [{String.t(), String.t()}]) ::
          {:ok, map()} | {:error, Error.t()}
  def post(%__MODULE__{} = client, path, body, headers \\ [])
      when is_binary(path) and is_map(body) and is_list(headers) do
    request(client, client.api_base_url <> path, method: :post, json: body, headers: headers)
  end

  @doc """
  Reads the transcoding state of a video or audio message that a user sent.
  """
  @spec transcoding_status(t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def transcoding_status(%__MODULE__{} = client, message_id) when is_binary(message_id) do
    url =
      client.data_base_url <>
        "/v2/bot/message/" <> URI.encode(message_id) <> "/content/transcoding"

    case request(client, url, method: :get) do
      {:ok, %{"status" => status}} when is_binary(status) -> {:ok, status}
      {:ok, _body} -> {:error, %Error{kind: :http, message: "transcoding status missing"}}
      {:error, _reason} = error -> error
    end
  end

  @spec download(t(), String.t(), pos_integer()) ::
          {:ok, %{body: binary(), content_type: String.t() | nil}}
          | {:error, Error.t() | :provider_download_limit}
  def download(%__MODULE__{} = client, message_id, limit_bytes)
      when is_binary(message_id) and is_integer(limit_bytes) do
    url = client.data_base_url <> "/v2/bot/message/" <> URI.encode(message_id) <> "/content"

    request_opts =
      [
        method: :get,
        url: url,
        auth: {:bearer, client.access_token},
        retry: false,
        decode_body: false,
        receive_timeout: @download_receive_timeout
      ]
      |> Keyword.merge(client.request_options)

    case Req.request(request_opts) do
      {:ok, %Req.Response{status: status, body: body} = response}
      when status in 200..299 and is_binary(body) ->
        if byte_size(body) > limit_bytes,
          do: {:error, :provider_download_limit},
          else: {:ok, %{body: body, content_type: content_type(response)}}

      {:ok, %Req.Response{status: status}} ->
        {:error, %Error{kind: :http, status: status}}

      {:error, _reason} ->
        {:error, %Error{kind: :transport}}
    end
  rescue
    _exception -> {:error, %Error{kind: :transport}}
  end

  defp request(client, url, options) do
    request_opts =
      [url: url, auth: {:bearer, client.access_token}, retry: false]
      |> Keyword.merge(receive_timeout: @default_receive_timeout)
      |> Keyword.merge(options)
      |> Keyword.merge(client.request_options)

    case Req.request(request_opts) do
      {:ok, %Req.Response{} = response} -> normalize_response(response)
      {:error, _reason} -> {:error, %Error{kind: :transport}}
    end
  rescue
    _exception -> {:error, %Error{kind: :transport}}
  end

  defp normalize_response(%Req.Response{status: status, body: body}) when status in 200..299,
    do: {:ok, map_body(body)}

  defp normalize_response(%Req.Response{status: status, body: body}) do
    details = map_body(body)

    {:error,
     %Error{
       kind: :api,
       status: status,
       message: bounded_text(details["message"]),
       details: details
     }}
  end

  defp map_body(body) when is_map(body), do: body
  defp map_body(_body), do: %{}

  defp content_type(%Req.Response{} = response) do
    case Req.Response.get_header(response, "content-type") do
      [value | _rest] -> value |> String.split(";") |> List.first() |> String.trim()
      [] -> nil
    end
  end

  defp bounded_text(value) when is_binary(value), do: String.slice(value, 0, 500)
  defp bounded_text(_value), do: nil
end

defimpl Inspect, for: Ankole.Plugins.LineAdapter.Client do
  import Inspect.Algebra

  def inspect(client, opts) do
    concat([
      "#Ankole.Plugins.LineAdapter.Client<",
      to_doc(%{api_base_url: client.api_base_url, access_token: "[REDACTED]"}, opts),
      ">"
    ])
  end
end
