defmodule Ankole.Plugins.WhatsAppAdapter.Client do
  @moduledoc false

  @default_base_url "https://graph.facebook.com"
  @default_graph_version "v25.0"
  @default_receive_timeout 30_000
  @download_receive_timeout 120_000

  defmodule Error do
    @moduledoc false

    @enforce_keys [:kind]
    defstruct [:kind, :status, :code, :message]

    @type t :: %__MODULE__{
            kind: :api | :http | :transport,
            status: integer() | nil,
            code: integer() | nil,
            message: String.t() | nil
          }
  end

  @enforce_keys [:base_url, :graph_version, :access_token, :request_options]
  defstruct [:base_url, :graph_version, :access_token, :request_options]

  @type t :: %__MODULE__{
          base_url: String.t(),
          graph_version: String.t(),
          access_token: String.t(),
          request_options: keyword()
        }

  @spec new(String.t(), keyword()) :: t()
  def new(access_token, opts \\ []) when is_binary(access_token) do
    {base_url, opts} = Keyword.pop(opts, :base_url, @default_base_url)
    {graph_version, opts} = Keyword.pop(opts, :graph_version, @default_graph_version)

    %__MODULE__{
      base_url: String.trim_trailing(base_url, "/"),
      graph_version: graph_version,
      access_token: access_token,
      request_options: opts
    }
  end

  @doc "Sends one message and returns the Graph answer."
  @spec send_message(t(), String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def send_message(%__MODULE__{} = client, phone_number_id, body)
      when is_binary(phone_number_id) and is_map(body) do
    request(client, graph_url(client, "/#{phone_number_id}/messages"), method: :post, json: body)
  end

  @doc "Uploads one file to the phone number's media store and returns its media ID."
  @spec upload_media(t(), String.t(), String.t(), String.t(), binary()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def upload_media(%__MODULE__{} = client, phone_number_id, name, mime_type, content)
      when is_binary(phone_number_id) and is_binary(name) and is_binary(mime_type) and
             is_binary(content) do
    fields = [
      {"messaging_product", "whatsapp"},
      {"type", mime_type},
      {"file", {content, filename: name, content_type: mime_type}}
    ]

    client
    |> request(graph_url(client, "/#{phone_number_id}/media"),
      method: :post,
      form_multipart: fields
    )
    |> case do
      {:ok, %{"id" => media_id}} when is_binary(media_id) -> {:ok, media_id}
      {:ok, _body} -> {:error, %Error{kind: :http, message: "media id missing"}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Reads the temporary download URL and the stored facts of one media object.

  The URL expires five minutes after this call, so the download must follow at
  once.
  """
  @spec media(t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def media(%__MODULE__{} = client, media_id) when is_binary(media_id) do
    case request(client, graph_url(client, "/#{URI.encode(media_id)}"), method: :get) do
      {:ok, %{"url" => url} = body} when is_binary(url) -> {:ok, body}
      {:ok, _body} -> {:error, %Error{kind: :http, message: "media url missing"}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Downloads media bytes from the temporary Graph URL with the Bearer token."
  @spec download(t(), String.t(), pos_integer()) ::
          {:ok, %{body: binary(), content_type: String.t() | nil}}
          | {:error, Error.t() | :provider_download_limit}
  def download(%__MODULE__{} = client, url, limit_bytes)
      when is_binary(url) and is_integer(limit_bytes) do
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

  defp graph_url(client, path), do: client.base_url <> "/" <> client.graph_version <> path

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
    error = body |> map_body() |> Map.get("error")
    error = if is_map(error), do: error, else: %{}

    {:error,
     %Error{
       kind: :api,
       status: status,
       code: integer_value(error["code"]),
       message: bounded_text(error["message"])
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

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _invalid -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp bounded_text(value) when is_binary(value), do: String.slice(value, 0, 500)
  defp bounded_text(_value), do: nil
end

defimpl Inspect, for: Ankole.Plugins.WhatsAppAdapter.Client do
  import Inspect.Algebra

  def inspect(client, opts) do
    concat([
      "#Ankole.Plugins.WhatsAppAdapter.Client<",
      to_doc(
        %{
          base_url: client.base_url,
          graph_version: client.graph_version,
          access_token: "[REDACTED]"
        },
        opts
      ),
      ">"
    ])
  end
end
