defmodule Ankole.Kernel.UniversalAIClient do
  @moduledoc """
  Native async streaming client for prepared AI provider requests.

  Elixir owns provider selection, auth, endpoint, headers, and transport
  preferences. The native kernel owns model request body encoding, upstream
  streaming, response normalization, downstream-ready chunk encoding, demand
  credit, and cancel.
  """

  alias Ankole.Kernel, as: NativeKernel

  defmodule Stream do
    @moduledoc false

    @enforce_keys [:resource, :ref, :owner]
    defstruct [:resource, :ref, :owner]

    @opaque t :: %__MODULE__{
              resource: reference(),
              ref: reference(),
              owner: pid()
            }
  end

  @type stream :: Stream.t()
  @type error :: map() | String.t()
  @type open_opts :: [receiver: pid()]

  @spec model_request(map(), keyword()) :: {:ok, map()} | {:error, error()}
  def model_request(spec, _opts \\ []) when is_map(spec) do
    with {:ok, encoded_spec} <- encode_spec(spec) do
      call_request_native(fn ->
        NativeKernel.universal_ai_client_model_request_nif(encoded_spec)
      end)
    end
  end

  @spec raw_get(binary() | map(), keyword()) :: {:ok, map()} | {:error, error()}
  def raw_get(request, opts \\ []), do: raw_request("GET", request, opts)

  @spec raw_head(binary() | map(), keyword()) :: {:ok, map()} | {:error, error()}
  def raw_head(request, opts \\ []), do: raw_request("HEAD", request, opts)

  @spec raw_post(binary() | map(), keyword()) :: {:ok, map()} | {:error, error()}
  def raw_post(request, opts \\ []), do: raw_request("POST", request, opts)

  @spec raw_put(binary() | map(), keyword()) :: {:ok, map()} | {:error, error()}
  def raw_put(request, opts \\ []), do: raw_request("PUT", request, opts)

  @spec raw_patch(binary() | map(), keyword()) :: {:ok, map()} | {:error, error()}
  def raw_patch(request, opts \\ []), do: raw_request("PATCH", request, opts)

  @spec raw_delete(binary() | map(), keyword()) :: {:ok, map()} | {:error, error()}
  def raw_delete(request, opts \\ []), do: raw_request("DELETE", request, opts)

  @spec open(map(), open_opts()) :: {:ok, stream()} | {:error, error()}
  def open(spec, opts \\ []) when is_map(spec) and is_list(opts) do
    receiver = Keyword.get(opts, :receiver, self())
    ref = make_ref()

    with {:ok, encoded_spec} <- encode_spec(spec),
         {:ok, resource} <- open_native(encoded_spec, receiver, ref) do
      {:ok, %Stream{resource: resource, ref: ref, owner: receiver}}
    end
  end

  @spec read(stream(), non_neg_integer()) :: :ok | {:error, error()}
  def read(stream, count \\ 1)

  def read(%Stream{resource: resource}, count) when is_integer(count) and count >= 0 do
    call_native(fn -> NativeKernel.universal_ai_client_read_nif(resource, count) end)
  end

  def read(%Stream{}, _count), do: {:error, invalid_error("count must be a non-negative integer")}

  @spec cancel(stream()) :: :ok | {:error, error()}
  def cancel(%Stream{resource: resource}) do
    call_native(fn -> NativeKernel.universal_ai_client_cancel_nif(resource) end)
  end

  defp raw_request(method, request, opts) when is_binary(request) and is_list(opts) do
    request
    |> raw_spec_from_opts(opts)
    |> Map.put(:method, method)
    |> raw_request_spec()
  end

  defp raw_request(method, request, opts) when is_map(request) and is_list(opts) do
    request
    |> Map.merge(Map.new(opts))
    |> Map.put(:method, method)
    |> raw_request_spec()
  end

  defp raw_request(_method, _request, _opts),
    do: {:error, invalid_error("raw request must be a URL or map")}

  defp raw_request_spec(request) do
    with {:ok, spec} <- raw_spec(request),
         {:ok, encoded_spec} <- encode_spec(spec) do
      call_request_native(fn ->
        NativeKernel.universal_ai_client_raw_request_nif(encoded_spec)
      end)
    end
  end

  defp raw_spec_from_opts(url, opts) do
    opts
    |> Map.new()
    |> Map.put(:url, url)
  end

  defp raw_spec(request) do
    with {:ok, url} <- required_binary(request, :url),
         {:ok, method} <- required_binary(request, :method),
         {:ok, body} <- raw_body(map_get(request, :body)) do
      {:ok,
       %{
         upstream: %{
           method: method,
           url: url,
           headers: raw_headers(map_get(request, :headers)),
           body: body,
           timeout: map_get(request, :timeout) || %{},
           transport: map_get(request, :transport) || %{}
         },
         limits: map_get(request, :limits) || %{}
       }}
    end
  end

  defp required_binary(request, key) do
    case map_get(request, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, invalid_error("raw request #{key} must be a non-empty string")}
    end
  end

  defp raw_body(nil), do: {:ok, nil}
  defp raw_body(body) when is_binary(body), do: {:ok, body}

  defp raw_body(body) when is_map(body) or is_list(body) do
    case Torque.encode(body) do
      {:ok, encoded} ->
        {:ok, encoded}

      {:error, reason} ->
        {:error, invalid_error("raw request body is not JSON-safe: #{inspect(reason)}")}
    end
  end

  defp raw_body(_body),
    do: {:error, invalid_error("raw request body must be nil, binary, map, or list")}

  defp raw_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp raw_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp raw_headers(_headers), do: []

  defp map_get(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp encode_spec(spec) do
    spec
    |> json_safe()
    |> Torque.encode()
    |> case do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, invalid_error("spec must be JSON-safe: #{inspect(reason)}")}
    end
  end

  defp open_native(encoded_spec, receiver, ref) do
    case call_open_native(fn ->
           NativeKernel.universal_ai_client_open_nif(encoded_spec, receiver, ref)
         end) do
      {:ok, resource} -> {:ok, resource}
      {:error, _reason} = error -> error
      other -> {:error, invalid_error("native stream open returned #{inspect(other)}")}
    end
  end

  defp call_open_native(fun) do
    fun.()
  catch
    kind, reason ->
      {:error,
       %{
         "code" => "native_error",
         "stage" => "beam",
         "message" => Exception.format_banner(kind, reason)
       }}
  end

  defp call_request_native(fun) do
    case fun.() do
      {:ok, response} when is_map(response) -> {:ok, response}
      {:error, _reason} = error -> error
      other -> {:error, invalid_error("native request returned #{inspect(other)}")}
    end
  catch
    kind, reason ->
      {:error,
       %{
         "code" => "native_error",
         "stage" => "beam",
         "message" => Exception.format_banner(kind, reason)
       }}
  end

  defp call_native(fun) do
    case fun.() do
      :ok -> :ok
      {:error, _reason} = error -> error
      resource -> {:ok, resource}
    end
  catch
    kind, reason ->
      {:error,
       %{
         "code" => "native_error",
         "stage" => "beam",
         "message" => Exception.format_banner(kind, reason)
       }}
  end

  defp json_safe(%{} = map) do
    Map.new(map, fn {key, value} -> {json_key(key), json_safe(value)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe({left, right}), do: [json_safe(left), json_safe(right)]
  defp json_safe(nil), do: nil
  defp json_safe(value) when is_boolean(value), do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key), do: to_string(key)

  defp invalid_error(message) do
    %{
      "code" => "invalid_spec",
      "stage" => "spec",
      "message" => message
    }
  end
end
