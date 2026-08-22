defmodule Ankole.Plugins.DiscordAdapter.Client do
  @moduledoc false

  @default_base_url "https://discord.com/api/v10"
  @default_receive_timeout 30_000

  defmodule Error do
    @moduledoc false

    @enforce_keys [:kind]
    defstruct [:kind, :status, :code, :message, :retry_after]

    @type t :: %__MODULE__{
            kind: :api | :http | :transport | :invalid_response,
            status: integer() | nil,
            code: integer() | nil,
            message: String.t() | nil,
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

  @spec get(t(), String.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def get(%__MODULE__{} = client, path, opts \\ []) when is_binary(path) do
    request(client, path, Keyword.merge([method: :get], opts))
  end

  @spec post(t(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def post(%__MODULE__{} = client, path, body \\ %{}, opts \\ [])
      when is_binary(path) and is_map(body) do
    request(client, path, Keyword.merge([method: :post, json: body], opts))
  end

  @spec patch(t(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def patch(%__MODULE__{} = client, path, body, opts \\ [])
      when is_binary(path) and is_map(body) do
    request(client, path, Keyword.merge([method: :patch, json: body], opts))
  end

  @spec put(t(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def put(%__MODULE__{} = client, path, body \\ %{}, opts \\ [])
      when is_binary(path) and is_map(body) do
    request(client, path, Keyword.merge([method: :put, json: body], opts))
  end

  @spec delete(t(), String.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def delete(%__MODULE__{} = client, path, opts \\ []) when is_binary(path) do
    request(client, path, Keyword.merge([method: :delete], opts))
  end

  @doc """
  Posts a multipart message. Discord carries the JSON body in the
  `payload_json` part and each upload in an indexed `files[n]` part.
  """
  @spec post_multipart(t(), String.t(), map(), [map()], keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def post_multipart(%__MODULE__{} = client, path, payload, files, opts \\ [])
      when is_binary(path) and is_map(payload) and is_list(files) do
    parts =
      files
      |> Enum.with_index()
      |> Enum.map(fn {file, index} ->
        {"files[#{index}]",
         {file.content,
          filename: file.filename, content_type: file.content_type || "application/octet-stream"}}
      end)

    request(
      client,
      path,
      Keyword.merge(
        [
          method: :post,
          form_multipart: [{"payload_json", Torque.encode!(payload)} | parts]
        ],
        opts
      )
    )
  end

  @doc "Fetches the current bot application and user identity."
  @spec current_user(t()) :: {:ok, map()} | {:error, Error.t()}
  def current_user(%__MODULE__{} = client) do
    case get(client, "/users/@me") do
      {:ok, %{"id" => id} = user} when is_binary(id) -> {:ok, user}
      {:ok, _invalid} -> {:error, %Error{kind: :invalid_response}}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Fetches the bot's own application. The preflight reads `flags` to learn
  whether the message-content intent is allowed.
  """
  @spec current_application(t()) :: {:ok, map()} | {:error, Error.t()}
  def current_application(%__MODULE__{} = client) do
    case get(client, "/applications/@me") do
      {:ok, %{"id" => id} = application} when is_binary(id) -> {:ok, application}
      {:ok, _invalid} -> {:error, %Error{kind: :invalid_response}}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @doc "Fetches the gateway URL and recommended shard count for this bot."
  @spec gateway_bot(t()) :: {:ok, map()} | {:error, Error.t()}
  def gateway_bot(%__MODULE__{} = client) do
    case get(client, "/gateway/bot") do
      {:ok, %{"url" => url} = body} when is_binary(url) -> {:ok, body}
      {:ok, _invalid} -> {:error, %Error{kind: :invalid_response}}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @spec download(t(), String.t()) ::
          {:ok, %{body: binary(), filename: String.t() | nil}} | {:error, Error.t()}
  def download(%__MODULE__{} = client, url) when is_binary(url) do
    request_opts =
      [method: :get, url: url, retry: false, receive_timeout: @default_receive_timeout]
      |> Keyword.merge(client.request_options)

    case Req.request(request_opts) do
      {:ok, %Req.Response{status: status, body: body}}
      when status in 200..299 and is_binary(body) ->
        {:ok, %{body: body, filename: url |> URI.parse() |> Map.get(:path) |> basename()}}

      {:ok, %Req.Response{status: status}} ->
        {:error, %Error{kind: :http, status: status}}

      {:error, _reason} ->
        {:error, %Error{kind: :transport}}
    end
  rescue
    _exception -> {:error, %Error{kind: :transport}}
  end

  defp request(client, path, options) do
    request_opts =
      [url: client.base_url <> path, retry: false, receive_timeout: @default_receive_timeout]
      |> Keyword.merge(options)
      |> Keyword.merge(client.request_options)
      |> Keyword.update(
        :headers,
        default_headers(client),
        &Keyword.merge(default_headers(client), &1)
      )

    case Req.request(request_opts) do
      {:ok, %Req.Response{} = response} -> normalize_response(response, client.token)
      {:error, _reason} -> {:error, %Error{kind: :transport}}
    end
  rescue
    _exception -> {:error, %Error{kind: :transport}}
  end

  defp default_headers(client) do
    [
      authorization: "Bot " <> client.token,
      user_agent: "DiscordBot (https://github.com/AgentBull/ankole, 1.0)"
    ]
  end

  defp normalize_response(%Req.Response{status: 204}, _token), do: {:ok, %{}}

  defp normalize_response(%Req.Response{status: status, body: body}, _token)
       when status in 200..299,
       do: {:ok, body}

  defp normalize_response(%Req.Response{status: status, body: body}, token) when is_map(body) do
    {:error,
     %Error{
       kind: :api,
       status: status,
       code: integer(Map.get(body, "code")),
       message: safe_message(Map.get(body, "message"), token),
       retry_after: retry_after(Map.get(body, "retry_after"))
     }}
  end

  defp normalize_response(%Req.Response{status: status}, _token),
    do: {:error, %Error{kind: :http, status: status}}

  # Discord sends `retry_after` in fractional seconds. The adapter rounds up so
  # that a sub-second limit still waits instead of retrying immediately.
  defp retry_after(value) when is_float(value) and value > 0, do: ceil(value)
  defp retry_after(value) when is_integer(value) and value > 0, do: value
  defp retry_after(_value), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: nil

  defp basename(path) when is_binary(path), do: Path.basename(path)
  defp basename(_path), do: nil

  defp safe_message(value, token) when is_binary(value) do
    value |> String.slice(0, 500) |> String.replace(token, "[REDACTED]")
  end

  defp safe_message(_value, _token), do: nil
end

defimpl Inspect, for: Ankole.Plugins.DiscordAdapter.Client do
  import Inspect.Algebra

  def inspect(client, opts) do
    concat([
      "#Ankole.Plugins.DiscordAdapter.Client<",
      to_doc(%{base_url: client.base_url, token: "[REDACTED]"}, opts),
      ">"
    ])
  end
end
