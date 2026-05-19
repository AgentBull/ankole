defmodule BullX.Setup.ChannelSources do
  @moduledoc false

  alias BullX.Config
  alias BullX.Plugins
  alias BullX.Plugins.Extension

  @extension_point :"bullx.event_bus.channel_adapter"

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
         {:ok, credentials} <- extension.setup_module.cast_credentials(payload),
         {:ok, source} <- extension.setup_module.cast_source(payload, credentials),
         :ok <- check_enabled_source(extension.setup_module, source, credentials),
         :ok <- persist_source_config(extension.setup_module, credentials, source),
         {:ok, runtime} <- extension.setup_module.reconcile_sources() do
      {:ok,
       %{
         adapter_id: adapter_id,
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
         {:ok, credentials} <- extension.setup_module.cast_credentials(payload),
         {:ok, source} <- extension.setup_module.cast_source(payload, credentials),
         {:ok, result} <-
           extension.setup_module.connectivity_check(source_for_check(source, credentials)) do
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
    callbacks = [
      {:config_keys, 0},
      {:form_schema, 0},
      {:public_projection, 0},
      {:cast_credentials, 1},
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

  defp check_enabled_source(module, %{"enabled" => false}, _credentials),
    do: check_disabled_source(module)

  defp check_enabled_source(module, %{enabled: false}, _credentials),
    do: check_disabled_source(module)

  defp check_enabled_source(module, source, credentials) do
    case module.connectivity_check(source_for_check(source, credentials)) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp check_disabled_source(_module), do: :ok

  defp source_for_check(source, credentials) do
    credential_id =
      Map.get(source, "credential_id") || Map.get(source, :credential_id) || "default"

    credential = credential_profile(credentials, credential_id)

    case credential do
      %{} = credential -> Map.merge(source, credential)
      _credential -> source
    end
  end

  defp credential_profile(credentials, credential_id) when is_atom(credential_id),
    do: Map.get(credentials, credential_id) || Map.get(credentials, Atom.to_string(credential_id))

  defp credential_profile(credentials, credential_id), do: Map.get(credentials, credential_id)

  defp persist_source_config(module, credentials, source) do
    %{credentials: credentials_key, sources: sources_key} = module.config_keys()

    Config.put_many(%{
      credentials_key => Jason.encode!(credentials),
      sources_key => Jason.encode!([source])
    })
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

  defp normalize_error(:not_found), do: %{message: "channel adapter setup module not found"}
  defp normalize_error(%{} = error), do: error
  defp normalize_error(reason), do: %{message: inspect(reason)}
end
