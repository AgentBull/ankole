defmodule BullX.AIAgent.Tools.Web do
  @moduledoc false

  alias BullX.AIAgent.Tools.Error
  alias BullX.AIAgent.Tools.Web.Adapter
  alias BullX.Config.AIAgent, as: Config
  alias BullX.Plugins.Extension

  @extension_point :"bullx.ai_agent.web_adapter"
  @builtin_adapters [
    %Adapter{id: "exa", module: BullX.AIAgent.Tools.Web.Exa, supports: [:search, :extract]},
    %Adapter{id: "tavily", module: BullX.AIAgent.Tools.Web.Tavily, supports: [:search, :extract]},
    %Adapter{id: "serpapi", module: BullX.AIAgent.Tools.Web.SerpAPI, supports: [:search]},
    %Adapter{id: "jina_reader", module: BullX.AIAgent.Tools.Web.JinaReader, supports: [:extract]}
  ]

  @spec extension_point() :: atom()
  def extension_point, do: @extension_point

  @spec search_available?(map()) :: :ok | {:error, :tool_unavailable}
  def search_available?(runtime_seed), do: availability(:search, runtime_seed)

  @spec extract_available?(map()) :: :ok | {:error, :tool_unavailable}
  def extract_available?(runtime_seed), do: availability(:extract, runtime_seed)

  @spec search(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def search(args, runtime_seed) do
    with {:ok, adapter} <- select(:search, runtime_seed) do
      adapter.module.search(args, runtime_seed)
    else
      {:error, _reason} ->
        {:error, Error.new(:tool_unavailable, "Web search is not configured.", false)}
    end
  end

  @spec extract(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def extract(args, runtime_seed) do
    with {:ok, adapter} <- select(:extract, runtime_seed) do
      adapter.module.extract(args, runtime_seed)
    else
      {:error, _reason} ->
        {:error, Error.new(:tool_unavailable, "Web extraction is not configured.", false)}
    end
  end

  @spec select(:search | :extract, map()) :: {:ok, Adapter.t()} | {:error, term()}
  def select(kind, runtime_seed \\ %{}) when kind in [:search, :extract] do
    adapters = adapters(runtime_seed)

    case configured_provider(kind) do
      nil -> first_available(adapters, kind)
      provider -> configured_adapter(adapters, kind, provider)
    end
  end

  @spec req_options(map()) :: keyword()
  def req_options(runtime_seed) when is_map(runtime_seed) do
    runtime_seed
    |> Map.get(:web_req_options, Application.get_env(:bullx, :ai_agent_web_req_options, []))
    |> normalize_req_options()
  end

  @spec api_key(atom()) :: String.t() | nil
  def api_key(:exa), do: present_string(Config.web_exa_api_key!())
  def api_key(:tavily), do: present_string(Config.web_tavily_api_key!())
  def api_key(:serpapi), do: present_string(Config.web_serpapi_api_key!())
  def api_key(:jina_reader), do: present_string(Config.web_jina_api_key!())

  def http_result({:ok, %Req.Response{status: status, body: body}})
      when status >= 200 and status < 300 and is_map(body),
      do: {:ok, body}

  def http_result({:ok, %Req.Response{status: status}}) when status >= 200 and status < 300,
    do: {:ok, %{}}

  def http_result({:ok, %Req.Response{status: status}})
      when status in [408, 425, 429, 500, 502, 503, 504],
      do: {:error, Error.new(:tool_unavailable, "Web provider is temporarily unavailable.", true)}

  def http_result({:ok, %Req.Response{}}),
    do: {:error, Error.new(:tool_unavailable, "Web provider request failed.", false)}

  def http_result({:error, %Req.TransportError{reason: :timeout}}),
    do: {:error, Error.new(:tool_timeout, "Web provider request timed out.", true)}

  def http_result({:error, _reason}),
    do: {:error, Error.new(:tool_unavailable, "Web provider request failed.", true)}

  def clamp_limit(value, default \\ 5) do
    value
    |> normalize_integer(default)
    |> min(100)
    |> max(1)
  end

  def present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def present_string(_value), do: nil

  defp availability(kind, runtime_seed) do
    case select(kind, runtime_seed) do
      {:ok, _adapter} -> :ok
      {:error, _reason} -> {:error, :tool_unavailable}
    end
  end

  defp configured_provider(:search) do
    present_string(Config.web_search_provider!()) || present_string(Config.web_provider!())
  end

  defp configured_provider(:extract) do
    present_string(Config.web_extract_provider!()) || present_string(Config.web_provider!())
  end

  defp configured_adapter(adapters, kind, provider) do
    adapters
    |> Enum.find(&(&1.id == provider and kind in &1.supports))
    |> case do
      nil -> {:error, :invalid_provider}
      %Adapter{} = adapter -> ensure_available(adapter, kind)
    end
  end

  defp first_available(adapters, kind) do
    adapters
    |> Enum.filter(&(kind in &1.supports))
    |> Enum.reduce_while({:error, :missing_provider}, fn adapter, _acc ->
      case ensure_available(adapter, kind) do
        {:ok, adapter} -> {:halt, {:ok, adapter}}
        {:error, _reason} -> {:cont, {:error, :missing_provider}}
      end
    end)
  end

  defp ensure_available(%Adapter{} = adapter, kind) do
    case adapter.module.available?(kind) do
      true -> {:ok, adapter}
      :ok -> {:ok, adapter}
      _value -> {:error, :missing_credentials}
    end
  rescue
    _error -> {:error, :adapter_unavailable}
  end

  defp adapters(runtime_seed) do
    runtime_seed
    |> plugin_adapters()
    |> Enum.reduce(@builtin_adapters, &merge_plugin_adapter/2)
  end

  defp plugin_adapters(runtime_seed) do
    server = Map.get(runtime_seed, :plugin_registry) || BullX.Plugins.Registry

    cond do
      match?(%BullX.Plugins.Registry{}, server) ->
        enabled_extensions(server)

      true ->
        BullX.Plugins.enabled_extensions_for(@extension_point, server)
    end
    |> Enum.sort_by(&{&1.plugin_id, to_string(&1.id)})
    |> Enum.flat_map(&extension_adapters/1)
  rescue
    _error -> []
  catch
    :exit, _reason -> []
  end

  defp enabled_extensions(%BullX.Plugins.Registry{} = state) do
    Enum.filter(state.extensions, fn extension ->
      extension.point == @extension_point and
        MapSet.member?(state.enabled_ids, extension.plugin_id)
    end)
  end

  defp extension_adapters(%Extension{} = extension) do
    cond do
      function_exported?(extension.module, :adapter, 0) ->
        normalize_adapter(extension.module.adapter(), extension.id)

      function_exported?(extension.module, :adapters, 0) ->
        extension.module.adapters()
        |> List.wrap()
        |> Enum.flat_map(&normalize_adapter(&1, nil))

      true ->
        []
    end
  rescue
    _error -> []
  end

  defp normalize_adapter(%Adapter{} = adapter, expected_id),
    do: accept_adapter(adapter, expected_id)

  defp normalize_adapter(%{} = data, expected_id) do
    id = Map.get(data, :id) || Map.get(data, "id") || expected_id
    module = Map.get(data, :module) || Map.get(data, "module")
    supports = Map.get(data, :supports) || Map.get(data, "supports") || []

    accept_adapter(
      %Adapter{id: to_string(id), module: module, supports: normalize_supports(supports)},
      expected_id
    )
  end

  defp normalize_adapter(_data, _expected_id), do: []

  defp normalize_supports(supports) when is_list(supports) do
    Enum.map(supports, fn
      :search -> :search
      "search" -> :search
      :extract -> :extract
      "extract" -> :extract
      other -> other
    end)
  end

  defp normalize_supports(_supports), do: []

  defp accept_adapter(%Adapter{} = adapter, expected_id) do
    cond do
      not is_nil(expected_id) and adapter.id != to_string(expected_id) ->
        []

      not valid_adapter?(adapter) ->
        []

      true ->
        [adapter]
    end
  end

  defp valid_adapter?(%Adapter{id: id, module: module, supports: supports})
       when is_binary(id) and id != "" and is_atom(module) and is_list(supports) do
    Enum.all?(supports, &(&1 in [:search, :extract])) and
      function_exported?(module, :available?, 1)
  end

  defp valid_adapter?(_adapter), do: false

  defp merge_plugin_adapter(%Adapter{} = adapter, acc) do
    case Enum.any?(acc, &(&1.id == adapter.id)) do
      true -> acc
      false -> acc ++ [adapter]
    end
  end

  defp normalize_req_options(opts) when is_list(opts), do: opts
  defp normalize_req_options(_opts), do: []

  defp normalize_integer(value, _default) when is_integer(value), do: value

  defp normalize_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> default
    end
  end

  defp normalize_integer(_value, default), do: default
end
