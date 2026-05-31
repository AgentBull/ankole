defmodule BullX.Setup.ChannelSources do
  @moduledoc """
  Setup-step API for configuring IM channel sources from plugin adapters.

  Channel adapters expose a small setup module contract. This module discovers
  those contracts through enabled plugins, validates operator input, persists
  source config through `BullX.Config`, and asks the adapter to reconcile its
  runtime after the durable config changes.
  """

  alias BullX.Config
  alias BullX.Plugins
  alias BullX.Plugins.Extension

  @extension_point :"bullx.im_gateway.channel_adapter"

  @spec status() :: map()
  def status do
    adapters = public_projection()
    ready_sources = ready_sources(adapters)

    %{
      complete?: ready_sources != [],
      adapters: adapters,
      ready_sources: ready_sources
    }
  end

  @spec setup_extensions() :: [map()]
  def setup_extensions do
    @extension_point
    |> Plugins.enabled_extensions_for()
    |> Enum.flat_map(&setup_extension/1)
  rescue
    _error -> []
  end

  @spec public_projection() :: [map()]
  def public_projection do
    Enum.map(setup_extensions(), fn extension ->
      module = extension.setup_module

      %{
        id: extension.id,
        plugin_id: extension.plugin_id,
        adapter_module: inspect(extension.module),
        setup_module: inspect(module),
        form_schema: safe_call(module, :form_schema, []),
        projection: safe_call(module, :public_projection, [])
      }
    end)
  end

  @spec save(String.t(), map()) :: {:ok, map()} | {:error, map()}
  def save(adapter_id, payload) when is_binary(adapter_id) and is_map(payload) do
    with {:ok, extension} <- fetch_setup_extension(adapter_id),
         {:ok, source} <- extension.setup_module.cast_source(payload, %{}),
         :ok <- check_enabled_source(extension.setup_module, source),
         :ok <- persist_source_config(extension.setup_module, source),
         {:ok, runtime} <- extension.setup_module.reconcile_sources() do
      {:ok,
       %{
         adapter_id: adapter_id,
         id: source_id(source),
         runtime: runtime,
         projection: extension.setup_module.public_projection()
       }}
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  def save(_adapter_id, _payload), do: {:error, %{message: "invalid channel source payload"}}

  @spec check(String.t(), map()) :: {:ok, map()} | {:error, map()}
  def check(adapter_id, payload) when is_binary(adapter_id) and is_map(payload) do
    with {:ok, extension} <- fetch_setup_extension(adapter_id),
         {:ok, source} <- extension.setup_module.cast_source(payload, %{}),
         {:ok, result} <- extension.setup_module.connectivity_check(source) do
      {:ok, result}
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  def check(_adapter_id, _payload), do: {:error, %{message: "invalid channel source payload"}}

  @spec generated_secret(String.t(), [String.t()]) :: {:ok, map()} | {:error, map()}
  def generated_secret(adapter_id, path) when is_binary(adapter_id) and is_list(path) do
    with {:ok, extension} <- fetch_setup_extension(adapter_id),
         true <- path in extension.setup_module.generated_secret_fields() do
      {:ok, %{path: path, value: BullX.Config.GeneratedSecret.generate()}}
    else
      false -> {:error, %{field: "path", message: "unsupported generated secret field"}}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  def generated_secret(_adapter_id, _path),
    do: {:error, %{message: "invalid generated secret request"}}

  @spec first_ready_source() :: {:ok, map()} | {:error, :not_found}
  def first_ready_source do
    status()
    |> Map.fetch!(:ready_sources)
    |> case do
      [source | _rest] -> {:ok, source}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Lists every configured channel source across all enabled adapters.

  Each entry is a uniform `%{adapter_id, id, enabled, config}` map. `config` is
  the adapter's public projection of the source (secret values are masked to
  `%{"present" => bool}`), so it is always safe to return to the browser.
  """
  @spec list() :: [map()]
  def list do
    Enum.flat_map(public_projection(), fn adapter ->
      adapter
      |> projection_sources()
      |> Enum.map(&to_channel(adapter, &1))
    end)
  end

  @doc "Fetches a single channel source by its `(adapter_id, id)` identity."
  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(adapter_id, id) when is_binary(adapter_id) and is_binary(id) do
    case Enum.find(list(), &(&1.adapter_id == adapter_id and &1.id == id)) do
      nil -> {:error, :not_found}
      channel -> {:ok, channel}
    end
  end

  def get(_adapter_id, _id), do: {:error, :not_found}

  @doc """
  Removes a channel source and reconciles the adapter's runtime.

  Reads the decrypted source list from the config cache, drops the entry with
  the matching id, and writes the remainder back (re-encrypting secrets for the
  surviving sources). Returns `{:error, :not_found}` when no source matches.
  """
  @spec delete(String.t(), String.t()) :: {:ok, map()} | {:error, map()}
  def delete(adapter_id, id) when is_binary(adapter_id) and is_binary(id) do
    with {:ok, extension} <- fetch_setup_extension(adapter_id),
         %{sources: key} <- extension.setup_module.config_keys(),
         {:ok, remaining} <- drop_source(decode_sources(key), id),
         :ok <- Config.put(key, Jason.encode!(remaining)),
         {:ok, runtime} <- extension.setup_module.reconcile_sources() do
      {:ok, %{adapter_id: adapter_id, id: id, runtime: runtime}}
    else
      {:error, reason} -> {:error, normalize_error(reason)}
      _other -> {:error, %{message: "invalid channel adapter setup config keys"}}
    end
  end

  def delete(_adapter_id, _id), do: {:error, %{message: "invalid channel delete request"}}

  defp setup_extension(%Extension{} = extension) do
    case setup_module(extension.opts) do
      nil ->
        []

      module ->
        [
          %{
            id: to_string(extension.id),
            plugin_id: extension.plugin_id,
            module: extension.module,
            setup_module: module
          }
        ]
    end
  end

  defp setup_module(opts) when is_map(opts),
    do: validate_setup_module(Map.get(opts, :setup_module) || Map.get(opts, "setup_module"))

  defp setup_module(opts) when is_list(opts),
    do: validate_setup_module(Keyword.get(opts, :setup_module))

  defp setup_module(_opts), do: nil

  defp validate_setup_module(module) when is_atom(module) do
    # Setup modules are optional plugin-side companions to runtime adapters.
    # Require the full contract here so the web setup flow can treat every
    # adapter uniformly without adapter-specific controller branches.
    callbacks = [
      {:config_keys, 0},
      {:form_schema, 0},
      {:public_projection, 0},
      {:cast_source, 2},
      {:generated_secret_fields, 0},
      {:connectivity_check, 1},
      {:routing_sample, 1},
      {:reconcile_sources, 0}
    ]

    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        if Enum.all?(callbacks, fn {fun, arity} -> function_exported?(module, fun, arity) end),
          do: module

      _other ->
        nil
    end
  end

  defp validate_setup_module(_module), do: nil

  defp fetch_setup_extension(adapter_id) do
    setup_extensions()
    |> Enum.find(&(&1.id == adapter_id))
    |> case do
      nil -> {:error, :not_found}
      extension -> {:ok, extension}
    end
  end

  defp check_enabled_source(module, %{"enabled" => false}),
    do: check_disabled_source(module)

  defp check_enabled_source(module, %{enabled: false}),
    do: check_disabled_source(module)

  defp check_enabled_source(module, source) do
    case module.connectivity_check(source) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp check_disabled_source(_module), do: :ok

  defp persist_source_config(module, source) do
    case function_exported?(module, :persist_source, 2) do
      true -> module.persist_source(%{}, source)
      false -> persist_source_config_from_keys(module.config_keys(), source)
    end
  end

  defp persist_source_config_from_keys(%{sources: sources_key}, source) do
    Config.put(sources_key, Jason.encode!([source]))
  end

  defp persist_source_config_from_keys(_keys, _source) do
    {:error, %{message: "invalid channel adapter setup config keys"}}
  end

  defp ready_sources(adapters) do
    setup_modules = Map.new(setup_extensions(), &{&1.id, &1.setup_module})

    adapters
    |> Enum.flat_map(fn adapter ->
      adapter.projection
      |> Map.get(:sources, Map.get(adapter.projection, "sources", []))
      |> Enum.filter(&source_runtime_ready?/1)
      |> Enum.map(fn source ->
        %{
          adapter_id: adapter.id,
          plugin_id: adapter.plugin_id,
          source_id: Map.get(source, "id") || Map.get(source, :id),
          source: source,
          setup_module: Map.get(setup_modules, adapter.id)
        }
      end)
    end)
  end

  defp source_runtime_ready?(source) do
    runtime = Map.get(source, "runtime") || Map.get(source, :runtime) || %{}
    Map.get(runtime, "ready") == true or Map.get(runtime, :ready) == true
  end

  defp safe_call(module, fun, args) do
    apply(module, fun, args)
  rescue
    error -> %{error: Exception.message(error)}
  end

  defp projection_sources(adapter) do
    projection = adapter.projection || %{}
    Map.get(projection, :sources) || Map.get(projection, "sources") || []
  end

  defp to_channel(adapter, source) do
    %{
      adapter_id: adapter.id,
      id: source_id(source),
      enabled: source_enabled(source),
      config: source
    }
  end

  defp source_id(source), do: Map.get(source, "id") || Map.get(source, :id)

  defp source_enabled(source) do
    case Map.get(source, "enabled") do
      nil -> Map.get(source, :enabled, true)
      value -> value == true
    end
  end

  defp decode_sources(key) do
    with {:ok, raw} when is_binary(raw) <- Config.Cache.get_raw(key),
         {:ok, sources} when is_list(sources) <- Jason.decode(raw) do
      sources
    else
      _other -> []
    end
  end

  defp drop_source(sources, id) do
    case Enum.split_with(sources, &(source_id(&1) == id)) do
      {[], _remaining} -> {:error, :not_found}
      {_removed, remaining} -> {:ok, remaining}
    end
  end

  defp normalize_error(:not_found), do: %{message: "channel adapter setup module not found"}
  defp normalize_error(%{} = error), do: error
  defp normalize_error(reason), do: %{message: inspect(reason)}
end
