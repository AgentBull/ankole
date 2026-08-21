defmodule Ankole.Plugins.TelegramAdapter.Client do
  @moduledoc false

  @default_base_url "https://api.telegram.org"
  @default_receive_timeout 40_000

  defmodule Error do
    @moduledoc false

    @enforce_keys [:kind]
    defstruct [:kind, :error_code, :description, :retry_after]

    @type t :: %__MODULE__{
            kind: :api | :http | :transport | :invalid_response,
            error_code: integer() | nil,
            description: String.t() | nil,
            retry_after: non_neg_integer() | nil
          }
  end

  @enforce_keys [:base_url, :token, :request_options]
  defstruct [:base_url, :token, :request_options]

  @type t :: %__MODULE__{
          base_url: String.t(),
          token: String.t(),
          request_options: keyword()
        }

  @spec new(String.t(), keyword()) :: t()
  def new(token, opts \\ []) when is_binary(token) do
    {base_url, request_options} = Keyword.pop(opts, :base_url, @default_base_url)

    %__MODULE__{
      base_url: String.trim_trailing(base_url, "/"),
      token: token,
      request_options: request_options
    }
  end

  @spec call(t(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def call(%__MODULE__{} = client, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_map(params) do
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)

    request(
      client,
      method,
      method: :post,
      json: params,
      receive_timeout: receive_timeout
    )
  end

  @spec call_multipart(t(), String.t(), keyword(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def call_multipart(%__MODULE__{} = client, method, fields, opts \\ [])
      when is_binary(method) and is_list(fields) do
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)

    request(
      client,
      method,
      method: :post,
      form_multipart: fields,
      receive_timeout: receive_timeout
    )
  end

  @spec get_updates(t(), integer() | nil, pos_integer()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def get_updates(client, offset, timeout_seconds) do
    body = %{
      "timeout" => timeout_seconds,
      "allowed_updates" => ["message", "callback_query", "message_reaction"]
    }

    body = if is_integer(offset), do: Map.put(body, "offset", offset), else: body

    case call(client, "getUpdates", body, receive_timeout: (timeout_seconds + 10) * 1_000) do
      {:ok, updates} when is_list(updates) -> {:ok, updates}
      {:ok, _invalid} -> {:error, %Error{kind: :invalid_response}}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @spec download(t(), String.t()) ::
          {:ok, %{body: binary(), filename: String.t() | nil}} | {:error, Error.t()}
  def download(%__MODULE__{} = client, file_path) when is_binary(file_path) do
    url = file_url(client, file_path)

    request_opts =
      [method: :get, url: url, retry: false, receive_timeout: @default_receive_timeout]
      |> Keyword.merge(client.request_options)

    case Req.request(request_opts) do
      {:ok, %Req.Response{status: status, body: body}}
      when status in 200..299 and is_binary(body) ->
        {:ok, %{body: body, filename: Path.basename(file_path)}}

      {:ok, %Req.Response{status: status}} ->
        {:error, %Error{kind: :http, error_code: status}}

      {:error, _reason} ->
        {:error, %Error{kind: :transport}}
    end
  rescue
    _exception -> {:error, %Error{kind: :transport}}
  end

  defp request(client, method, options) do
    request_opts =
      [url: method_url(client, method), retry: false]
      |> Keyword.merge(options)
      |> Keyword.merge(client.request_options)

    case Req.request(request_opts) do
      {:ok, %Req.Response{} = response} -> normalize_response(response, client.token)
      {:error, _reason} -> {:error, %Error{kind: :transport}}
    end
  rescue
    _exception -> {:error, %Error{kind: :transport}}
  end

  defp normalize_response(
         %Req.Response{
           status: status,
           body: %{"ok" => true, "result" => result}
         },
         _token
       )
       when status in 200..299,
       do: {:ok, result}

  defp normalize_response(%Req.Response{status: status, body: body}, token) when is_map(body) do
    parameters = Map.get(body, "parameters") || %{}

    {:error,
     %Error{
       kind: :api,
       error_code: integer(Map.get(body, "error_code")) || status,
       description: safe_description(Map.get(body, "description"), token),
       retry_after: integer(Map.get(parameters, "retry_after"))
     }}
  end

  defp normalize_response(%Req.Response{status: status}, _token),
    do: {:error, %Error{kind: :http, error_code: status}}

  defp method_url(client, method), do: "#{client.base_url}/bot#{client.token}/#{method}"
  defp file_url(client, file_path), do: "#{client.base_url}/file/bot#{client.token}/#{file_path}"

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp integer(_value), do: nil

  defp bounded_text(value) when is_binary(value), do: String.slice(value, 0, 500)
  defp bounded_text(_value), do: nil

  defp safe_description(value, token) do
    case bounded_text(value) do
      description when is_binary(description) -> String.replace(description, token, "[REDACTED]")
      nil -> nil
    end
  end
end

defimpl Inspect, for: Ankole.Plugins.TelegramAdapter.Client do
  import Inspect.Algebra

  def inspect(client, opts) do
    concat([
      "#Ankole.Plugins.TelegramAdapter.Client<",
      to_doc(%{base_url: client.base_url, token: "[REDACTED]"}, opts),
      ">"
    ])
  end
end
