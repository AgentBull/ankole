defmodule Ankole.IdentityProviders do
  @moduledoc """
  Identity-provider adapter configuration and OIDC login boundary.
  """

  alias Ankole.AppConfigure
  alias Ankole.IdentityProviders.Config
  alias Ankole.IdentityProviders.Jobs.SyncProvider
  alias Ankole.Plugins

  @adapter_contract_id "principals.identity_provider"
  @directory_full_sync_capability "directory_full_sync"
  @secret_mask "********"

  @type adapter :: %{
          adapter_id: String.t(),
          plugin_id: String.t(),
          display_name: %{String.t() => String.t()},
          capabilities: [String.t()],
          fields: [map()],
          default_provider_id: String.t()
        }

  @doc """
  Lists identity-provider adapters available to setup and console configuration.
  """
  @spec list_adapters() :: [adapter()]
  def list_adapters do
    disabled_ids = disabled_plugin_ids()

    # The plugin registry applies the disabled list only when the process boots:
    # active children/config registration are startup-time effects. Setup is an
    # operator-facing catalog, so it also filters the persisted disabled ids live
    # and avoids offering a plugin that will be inactive after the next restart.
    Plugins.list_active()
    |> Enum.reject(&MapSet.member?(disabled_ids, &1.id))
    |> Enum.flat_map(&adapters_for_plugin/1)
    |> Enum.sort_by(& &1.adapter_id)
  end

  @doc """
  Lists configured identity providers for the operator console.
  """
  @spec list_configured_providers() :: {:ok, [map()]} | {:error, term()}
  def list_configured_providers do
    with {:ok, providers} <- Config.active_providers() do
      providers
      |> Enum.reduce_while({:ok, []}, fn provider, {:ok, acc} ->
        case provider_projection(provider) do
          {:ok, item} -> {:cont, {:ok, [item | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, items} -> {:ok, Enum.reverse(items)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Fetches one configured identity provider for the operator console.
  """
  @spec fetch_configured_provider(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_configured_provider(provider_id) when is_binary(provider_id) do
    with {:ok, provider} <- fetch_configured_provider_entry(provider_id) do
      provider_projection(provider)
    end
  end

  @doc """
  Lists configured providers available to the login page.
  """
  @spec list_login_providers() :: {:ok, [map()]} | {:error, term()}
  def list_login_providers do
    with {:ok, providers} <- Config.active_providers() do
      {:ok, Enum.filter(providers, &(&1["enabled"] != false))}
    end
  end

  @doc """
  Persists one provider config and marks it active for login.
  """
  @spec save_provider(String.t(), String.t(), map(), boolean(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def save_provider(provider_id, adapter_id, config, enabled \\ true, opts \\ [])
      when is_binary(adapter_id) and is_map(config) and is_boolean(enabled) and is_list(opts) do
    with {:ok, provider_id} <- Config.normalize_provider_id(provider_id),
         {:ok, adapter} <- fetch_catalog_adapter(adapter_id),
         {:ok, config_key} <- provider_config_key(adapter, provider_id),
         {:ok, config} <- provider_config_for_write(adapter, config_key, config),
         {:ok, persisted_config} <- AppConfigure.put_global_by_key(config_key, config),
         {:ok, _providers} <-
           Config.upsert_active_provider(%{
             "provider_id" => provider_id,
             "adapter_id" => adapter.adapter_id,
             "plugin_id" => adapter.plugin_id,
             "config_key" => config_key,
             "enabled" => enabled
           }),
         {:ok, _job} <-
           maybe_enqueue_initial_sync(
             provider_id,
             adapter,
             persisted_config,
             enabled,
             Keyword.get(opts, :source, "setup")
           ) do
      {:ok,
       %{
         "provider_id" => provider_id,
         "adapter_id" => adapter.adapter_id,
         "plugin_id" => adapter.plugin_id,
         "config_key" => config_key,
         "enabled" => enabled,
         "config" => persisted_config
       }}
    end
  end

  @doc """
  Enqueues a full directory sync for one active identity provider.
  """
  @spec enqueue_sync(String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_sync(provider_id, opts \\ []) when is_binary(provider_id) and is_list(opts) do
    with {:ok, provider} <- fetch_active_provider(provider_id),
         {:ok, adapter} <- fetch_adapter(provider["adapter_id"]),
         {:ok, config} <- provider_config(provider),
         :ok <- require_directory_full_sync(adapter),
         true <- sync_config_enabled?(config) || {:error, :sync_disabled},
         {:ok, job_opts} <- sync_job_opts(opts) do
      %{
        "provider_id" => provider["provider_id"],
        "reason" => sync_reason(Keyword.get(opts, :reason, "manual")),
        "source" => sync_reason(Keyword.get(opts, :source, "manual"))
      }
      |> SyncProvider.new(job_opts)
      |> Oban.insert()
    end
  end

  @doc """
  Enqueues full directory sync jobs for every enabled provider with directory sync turned on.
  """
  @spec enqueue_directory_syncs(keyword()) :: {:ok, map()} | {:error, term()}
  def enqueue_directory_syncs(opts \\ []) when is_list(opts) do
    reason = sync_reason(Keyword.get(opts, :reason, "periodic"))
    source = sync_reason(Keyword.get(opts, :source, "cron"))

    with {:ok, interval_seconds} <- directory_full_sync_interval_seconds(opts),
         {:ok, providers} <- Config.active_providers() do
      providers
      |> Enum.reduce_while({:ok, %{enqueued: [], skipped: []}}, fn provider, {:ok, acc} ->
        case maybe_enqueue_directory_sync(provider, reason, source, interval_seconds) do
          {:ok, {:enqueued, job}} ->
            {:cont, {:ok, %{acc | enqueued: [job | acc.enqueued]}}}

          {:ok, {:skipped, provider_id}} ->
            {:cont, {:ok, %{acc | skipped: [provider_id | acc.skipped]}}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, result} ->
          {:ok,
           %{
             enqueued: Enum.reverse(result.enqueued),
             skipped: Enum.reverse(result.skipped)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Runs one full directory sync for an active identity provider.
  """
  @spec sync_provider(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync_provider(provider_id, opts \\ []) when is_binary(provider_id) and is_list(opts) do
    with {:ok, provider} <- fetch_active_provider(provider_id),
         {:ok, adapter} <- fetch_adapter(provider["adapter_id"]),
         {:ok, config} <- provider_config(provider),
         {:ok, module} <- adapter_module(adapter),
         {:ok, directory_result} <-
           maybe_sync_directory(adapter, module, provider_id, config, opts) do
      {:ok,
       %{
         provider_id: provider_id,
         directory: directory_result
       }}
    end
  end

  @doc """
  Builds an OIDC authorization URL for one configured provider.
  """
  @spec authorization_url(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def authorization_url(provider_id, opts) when is_binary(provider_id) and is_list(opts) do
    with {:ok, provider} <- fetch_active_provider(provider_id),
         {:ok, adapter} <- fetch_adapter(provider["adapter_id"]),
         {:ok, config} <- AppConfigure.get_by_key(provider["config_key"]),
         {:ok, module} <- adapter_module(adapter),
         :ok <- ensure_exported(module, :authorization_url, 2) do
      module.authorization_url(config, opts)
    end
  end

  @doc """
  Exchanges an OIDC authorization code and upserts the authenticated user.
  """
  @spec complete_oidc_login(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def complete_oidc_login(provider_id, code, opts)
      when is_binary(provider_id) and is_binary(code) and is_list(opts) do
    with {:ok, provider} <- fetch_active_provider(provider_id),
         {:ok, adapter} <- fetch_adapter(provider["adapter_id"]),
         {:ok, config} <- AppConfigure.get_by_key(provider["config_key"]),
         {:ok, module} <- adapter_module(adapter),
         :ok <- ensure_exported(module, :exchange_code, 3),
         :ok <- ensure_exported(module, :upsert_user, 2),
         {:ok, %{user: user}} <- module.exchange_code(config, code, opts),
         {:ok, %{principal: principal, identity: identity}} <-
           module.upsert_user(provider_id, user) do
      {:ok,
       %{
         principal_uid: principal.uid,
         provider_id: provider_id,
         external_id: identity.external_id,
         user: user
       }}
    end
  end

  @doc """
  Returns the callback path used for OIDC providers.
  """
  @spec oidc_callback_path(String.t()) :: String.t()
  def oidc_callback_path(provider_id) do
    "/sessions/oidc/#{URI.encode(provider_id)}/callback"
  end

  @doc """
  Returns the absolute redirect URI for one provider and public base URL.
  """
  @spec oidc_redirect_uri(String.t(), String.t()) :: String.t()
  def oidc_redirect_uri(public_base_url, provider_id) do
    String.trim_trailing(public_base_url, "/") <> oidc_callback_path(provider_id)
  end

  @doc """
  Normalizes a caller-supplied provider id at the public context boundary.
  """
  @spec normalize_provider_id(term()) :: {:ok, String.t()} | {:error, term()}
  def normalize_provider_id(provider_id), do: Config.normalize_provider_id(provider_id)

  defp disabled_plugin_ids do
    case Plugins.disabled_ids() do
      {:ok, ids} -> MapSet.new(ids)
      {:error, _reason} -> MapSet.new()
    end
  end

  defp adapters_for_plugin(plugin) do
    plugin.adapter_declarations
    |> Enum.filter(&contract?(&1, @adapter_contract_id))
    |> Enum.map(&adapter(plugin, &1))
  end

  defp adapter(plugin, declaration) do
    adapter_id = value(declaration, :id)

    %{
      adapter_id: adapter_id,
      plugin_id: plugin.id,
      display_name: value(declaration, :display_name) || default_text(adapter_id),
      capabilities: adapter_capabilities(declaration),
      fields: value(declaration, :fields) || [],
      config_key_pattern: value(declaration, :config_key_pattern),
      default_provider_id: "#{adapter_id}-main",
      module: value(declaration, :module)
    }
  end

  defp fetch_catalog_adapter(adapter_id) do
    list_adapters()
    |> Enum.find(&(&1.adapter_id == adapter_id))
    |> case do
      nil -> {:error, {:unknown_identity_provider_adapter, adapter_id}}
      adapter -> {:ok, adapter}
    end
  end

  defp fetch_adapter(adapter_id) do
    Plugins.adapter_declarations(@adapter_contract_id)
    |> Enum.find(&(value(&1, :id) == adapter_id))
    |> case do
      nil -> {:error, {:unknown_identity_provider_adapter, adapter_id}}
      adapter -> {:ok, adapter}
    end
  end

  defp fetch_active_provider(provider_id) do
    with {:ok, provider_id} <- Config.normalize_provider_id(provider_id),
         {:ok, providers} <- Config.active_providers() do
      providers
      |> Enum.find(&(&1["provider_id"] == provider_id and &1["enabled"] != false))
      |> case do
        nil -> {:error, {:unknown_identity_provider, provider_id}}
        provider -> {:ok, provider}
      end
    end
  end

  defp fetch_configured_provider_entry(provider_id) do
    with {:ok, provider_id} <- Config.normalize_provider_id(provider_id),
         {:ok, providers} <- Config.active_providers() do
      providers
      |> Enum.find(&(&1["provider_id"] == provider_id))
      |> case do
        nil -> {:error, {:unknown_identity_provider, provider_id}}
        provider -> {:ok, provider}
      end
    end
  end

  defp provider_config_key(%{config_key_pattern: pattern}, provider_id) when is_binary(pattern) do
    {:ok, String.replace(pattern, "<id>", provider_id)}
  end

  defp provider_config_key(%{adapter_id: adapter_id}, provider_id) do
    {:ok, "principals.identity_providers.#{adapter_id}.#{provider_id}"}
  end

  defp adapter_module(adapter) do
    case value(adapter, :module) do
      module when is_atom(module) -> {:ok, module}
      value -> {:error, {:invalid_identity_provider_module, value}}
    end
  end

  defp ensure_exported(module, function, arity) do
    case function_exported?(module, function, arity) do
      true -> :ok
      false -> {:error, {:unsupported_identity_provider_operation, module, function, arity}}
    end
  end

  defp maybe_enqueue_initial_sync(_provider_id, _adapter, _config, false, _source),
    do: {:ok, :disabled}

  defp maybe_enqueue_initial_sync(provider_id, adapter, config, true, source) do
    cond do
      not directory_full_sync_supported?(adapter) ->
        {:ok, :sync_unsupported}

      not sync_config_enabled?(config) ->
        {:ok, :sync_disabled}

      true ->
        enqueue_sync(provider_id, reason: "provider_saved", source: source)
    end
  end

  defp maybe_sync_directory(adapter, module, provider_id, config, opts) do
    case directory_full_sync_supported?(adapter) and sync_config_enabled?(config) do
      true ->
        with :ok <- ensure_exported(module, :sync_directory, 3) do
          module.sync_directory(provider_id, config, opts)
        end

      false ->
        {:ok, :skipped}
    end
  end

  defp sync_config_enabled?(config) when is_map(config) do
    get_in(config, ["sync", "contacts"]) != false
  end

  defp maybe_enqueue_directory_sync(
         %{"enabled" => false, "provider_id" => provider_id},
         _reason,
         _source,
         _interval_seconds
       ),
       do: {:ok, {:skipped, provider_id}}

  defp maybe_enqueue_directory_sync(
         %{"provider_id" => provider_id} = provider,
         reason,
         source,
         interval_seconds
       ) do
    with {:ok, adapter} <- fetch_adapter(provider["adapter_id"]),
         {:ok, config} <- provider_config(provider) do
      cond do
        not directory_full_sync_supported?(adapter) ->
          {:ok, {:skipped, provider_id}}

        not sync_config_enabled?(config) ->
          {:ok, {:skipped, provider_id}}

        true ->
          with {:ok, job} <-
                 enqueue_sync(provider_id,
                   reason: reason,
                   source: source,
                   directory_full_sync_interval_seconds: interval_seconds
                 ) do
            sync_job_result(job, provider_id)
          end
      end
    end
  end

  defp sync_job_result(%Oban.Job{conflict?: true}, provider_id),
    do: {:ok, {:skipped, provider_id}}

  defp sync_job_result(%Oban.Job{} = job, _provider_id), do: {:ok, {:enqueued, job}}

  defp sync_job_opts(opts) do
    reason = sync_reason(Keyword.get(opts, :reason, "manual"))
    source = sync_reason(Keyword.get(opts, :source, "manual"))

    case periodic_sync?(reason, source) do
      true ->
        with {:ok, unique_opts} <- periodic_sync_unique_opts(opts) do
          {:ok, [unique: unique_opts]}
        end

      false ->
        {:ok, []}
    end
  end

  defp periodic_sync?("periodic", "cron"), do: true
  defp periodic_sync?(_reason, _source), do: false

  defp periodic_sync_unique_opts(opts) do
    with {:ok, period} <- periodic_sync_unique_period(opts) do
      {:ok,
       [
         fields: [:worker, :args],
         keys: [:provider_id, :reason, :source],
         period: period,
         states: :successful
       ]}
    end
  end

  defp periodic_sync_unique_period(opts) do
    case Keyword.fetch(opts, :directory_full_sync_interval_seconds) do
      {:ok, seconds} when is_integer(seconds) and seconds >= 1 ->
        {:ok, seconds}

      {:ok, seconds} ->
        {:error, {:invalid_directory_full_sync_interval_seconds, seconds}}

      :error ->
        Config.directory_full_sync_interval_seconds()
    end
  end

  defp require_directory_full_sync(adapter) do
    case directory_full_sync_supported?(adapter) do
      true -> :ok
      false -> {:error, :sync_unsupported}
    end
  end

  defp directory_full_sync_supported?(adapter) do
    @directory_full_sync_capability in adapter_capabilities(adapter)
  end

  defp adapter_capabilities(adapter) do
    adapter
    |> value(:capabilities)
    |> case do
      capabilities when is_list(capabilities) -> Enum.filter(capabilities, &is_binary/1)
      _value -> []
    end
  end

  defp directory_full_sync_interval_seconds(opts) do
    case Keyword.fetch(opts, :directory_full_sync_interval_seconds) do
      {:ok, seconds} when is_integer(seconds) and seconds >= 1 -> {:ok, seconds}
      {:ok, seconds} -> {:error, {:invalid_directory_full_sync_interval_seconds, seconds}}
      :error -> Config.directory_full_sync_interval_seconds()
    end
  end

  defp provider_config(%{"config_key" => config_key}) when is_binary(config_key) do
    AppConfigure.get_by_key(config_key)
  end

  defp provider_projection(provider) do
    with {:ok, adapter} <- fetch_adapter(provider["adapter_id"]),
         {:ok, config} <- provider_config(provider) do
      {:ok,
       %{
         "provider_id" => provider["provider_id"],
         "adapter_id" => provider["adapter_id"],
         "plugin_id" => provider["plugin_id"],
         "config_key" => provider["config_key"],
         "enabled" => provider["enabled"] != false,
         "config" => mask_encrypted_config(adapter, config)
       }}
    end
  end

  defp provider_config_for_write(adapter, config_key, config) do
    case AppConfigure.get_by_key(config_key) do
      {:ok, existing} when is_map(existing) ->
        {:ok, preserve_encrypted_config(adapter, config, existing)}

      :error ->
        {:ok, config}

      {:error, _reason} = error ->
        error
    end
  end

  defp preserve_encrypted_config(adapter, config, existing) do
    adapter
    |> encrypted_field_paths()
    |> Enum.reduce(config, fn path, acc ->
      case {secret_placeholder?(get_path(acc, path)), get_path(existing, path)} do
        {true, value} when not is_nil(value) -> put_path(acc, path, value)
        _value -> acc
      end
    end)
  end

  defp mask_encrypted_config(adapter, config) do
    adapter
    |> encrypted_field_paths()
    |> Enum.reduce(config, fn path, acc ->
      case is_nil(get_path(acc, path)) do
        true -> acc
        false -> put_path(acc, path, @secret_mask)
      end
    end)
  end

  defp encrypted_field_paths(%{fields: fields}), do: encrypted_field_paths(fields)

  defp encrypted_field_paths(fields) when is_list(fields) do
    fields
    |> Enum.filter(&(value(&1, :encrypted) == true))
    |> Enum.map(&value(&1, :path))
    |> Enum.filter(&is_binary/1)
  end

  defp encrypted_field_paths(_fields), do: []

  defp secret_placeholder?(nil), do: true
  defp secret_placeholder?(""), do: true
  defp secret_placeholder?(@secret_mask), do: true
  defp secret_placeholder?(_value), do: false

  defp get_path(source, path) when is_map(source) and is_binary(path) do
    path
    |> String.split(".")
    |> Enum.reduce_while(source, fn segment, value ->
      case value do
        value when is_map(value) -> {:cont, Map.get(value, segment)}
        _value -> {:halt, nil}
      end
    end)
  end

  defp get_path(_source, _path), do: nil

  defp put_path(source, path, value) when is_map(source) and is_binary(path) do
    do_put_path(source, String.split(path, "."), value)
  end

  defp do_put_path(source, [segment], value), do: Map.put(source, segment, value)

  defp do_put_path(source, [segment | rest], value) do
    child =
      case Map.get(source, segment) do
        child when is_map(child) -> child
        _value -> %{}
      end

    Map.put(source, segment, do_put_path(child, rest, value))
  end

  defp sync_reason(value) when is_atom(value), do: Atom.to_string(value)
  defp sync_reason(value) when is_binary(value), do: value
  defp sync_reason(value), do: inspect(value)

  defp contract?(map, contract_id), do: value(map, :contract_id) == contract_id

  defp value(map, key) when is_map(map) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.fetch!(map, key)
      Map.has_key?(map, string_key) -> Map.fetch!(map, string_key)
      true -> nil
    end
  end

  defp default_text(value), do: %{"default" => value}
end
