defmodule Ankole.IdentityProviders do
  @moduledoc """
  Identity-provider adapter catalog and provider connection configuration.

  One configured provider is one connection to an external identity platform:
  one credential set, one `provider_id`, and one external-identity namespace
  that login and directory sync both write into. `Login` and `DirectorySync`
  are the two entry surfaces over these connections; each gates on its own
  adapter capabilities, so a connection can serve login, directory sync, or
  both.
  """

  alias Ankole.AppConfigure
  alias Ankole.IdentityProviders.Config
  alias Ankole.IdentityProviders.DirectorySync
  alias Ankole.IdentityProviders.LocalPassword
  alias Ankole.Plugins
  alias Ankole.Plugins.ConfigSecrets

  @adapter_contract_id "principals.identity_provider"
  @credential_check_capability "credential_check"
  @legacy_secret_mask "********"

  @type adapter :: %{
          adapter_id: String.t(),
          plugin_id: String.t(),
          display_name: %{String.t() => String.t()},
          capabilities: [String.t()],
          fields: [map()],
          default_provider_id: String.t(),
          connection_reconciler: module() | nil
        }

  @doc """
  Lists identity-provider adapters available to setup and console configuration.
  """
  @spec list_adapters() :: [adapter()]
  def list_adapters do
    enabled_ids = enabled_plugin_ids()

    # The plugin registry applies the enabled list only when the process boots.
    # Configuration writes also honor the persisted next-start selection so
    # they cannot create a provider for a plugin that the next restart removes.
    # Built-in adapters are part of the control plane and skip that filter.
    builtin_adapters() ++
      Enum.filter(active_plugin_adapters(), &MapSet.member?(enabled_ids, &1.plugin_id))
  end

  @doc """
  Lists built-in adapters and adapters loaded by plugins active in this process.

  Setup uses this boot-time catalog and applies the current setup selection in
  the browser. This keeps a plugin adapter available when an operator clears
  and then restores its selection before the process restarts.
  """
  @spec list_active_adapters() :: [adapter()]
  def list_active_adapters do
    builtin_adapters() ++ active_plugin_adapters()
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
  Lists enabled configured provider refs for one adapter without loading secrets.
  """
  @spec list_active_provider_refs(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_active_provider_refs(adapter_id) when is_binary(adapter_id) do
    with {:ok, _adapter} <- fetch_adapter(adapter_id),
         {:ok, providers} <- Config.active_providers() do
      refs =
        providers
        |> Enum.filter(&(&1["enabled"] != false and &1["adapter_id"] == adapter_id))
        |> Enum.map(&provider_ref/1)

      {:ok, refs}
    else
      {:error, {:unknown_identity_provider_adapter, ^adapter_id}} -> {:ok, []}
      {:error, _reason} = error -> error
    end
  end

  def list_active_provider_refs(_adapter_id), do: {:ok, []}

  @doc """
  Persists one provider config and marks the connection active.
  """
  @spec save_provider(String.t(), String.t(), map(), boolean(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def save_provider(provider_id, adapter_id, config, enabled \\ true, opts \\ [])
      when is_binary(adapter_id) and is_map(config) and is_boolean(enabled) and is_list(opts) do
    with {:ok, provider_id} <- Config.normalize_provider_id(provider_id),
         {:ok, adapter} <- fetch_catalog_adapter(adapter_id),
         :ok <- ensure_single_local_provider(adapter, provider_id),
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
           DirectorySync.enqueue_initial_sync(
             provider_id,
             adapter,
             persisted_config,
             enabled,
             Keyword.get(opts, :source, "setup")
           ),
         {:ok, _reconcile} <-
           DirectorySync.reconcile_saved_provider(adapter, persisted_config, enabled, opts) do
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
  Asks the provider whether it accepts the stored credentials.

  Only the interactive setup flow uses this. It turns a provider-side rejection
  into a message next to the credential fields, instead of an error page the
  operator reaches after the browser has already left the Installation. An
  adapter that declares no credential check reports `:unsupported`.
  """
  @spec check_credentials(String.t()) :: {:ok, :checked | :unsupported} | {:error, term()}
  def check_credentials(provider_id) when is_binary(provider_id) do
    with {:ok, provider} <- fetch_active_provider(provider_id),
         {:ok, adapter} <- fetch_adapter(provider["adapter_id"]),
         {:ok, config} <- provider_config(provider),
         {:ok, module} <- adapter_module(adapter) do
      case @credential_check_capability in adapter_capabilities(adapter) do
        true -> with :ok <- module.check_credentials(config), do: {:ok, :checked}
        false -> {:ok, :unsupported}
      end
    end
  end

  @doc """
  Normalizes a caller-supplied provider id at the public context boundary.
  """
  @spec normalize_provider_id(term()) :: {:ok, String.t()} | {:error, term()}
  def normalize_provider_id(provider_id), do: Config.normalize_provider_id(provider_id)

  @doc false
  @spec validate_adapter_declaration(map()) :: :ok | {:error, term()}
  def validate_adapter_declaration(declaration) when is_map(declaration) do
    with {:ok, module} <- identity_adapter_module(declaration),
         :ok <- validate_identity_capabilities(module, declaration),
         :ok <- validate_connection_reconciler(declaration) do
      :ok
    end
  end

  def validate_adapter_declaration(declaration),
    do: {:error, {:invalid_identity_provider_declaration, declaration}}

  @doc false
  @spec fetch_adapter(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_adapter(adapter_id) do
    adapter_declarations()
    |> Enum.find(&(value(&1, :id) == adapter_id))
    |> case do
      nil -> {:error, {:unknown_identity_provider_adapter, adapter_id}}
      adapter -> {:ok, adapter}
    end
  end

  @doc false
  @spec fetch_active_provider(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_active_provider(provider_id) do
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

  @doc false
  @spec provider_config(map()) :: {:ok, map()} | :error | {:error, term()}
  def provider_config(%{"config_key" => config_key}) when is_binary(config_key) do
    AppConfigure.get_by_key(config_key)
  end

  @doc false
  @spec adapter_module(map()) :: {:ok, module()} | {:error, term()}
  def adapter_module(adapter) do
    case value(adapter, :module) do
      module when is_atom(module) and not is_nil(module) -> {:ok, module}
      value -> {:error, {:invalid_identity_provider_module, value}}
    end
  end

  @doc false
  @spec adapter_capabilities(map()) :: [String.t()]
  def adapter_capabilities(adapter) do
    adapter
    |> value(:capabilities)
    |> case do
      capabilities when is_list(capabilities) -> Enum.filter(capabilities, &is_binary/1)
      _value -> []
    end
  end

  defp enabled_plugin_ids do
    case Plugins.enabled_ids() do
      {:ok, ids} -> MapSet.new(ids)
      {:error, _reason} -> MapSet.new()
    end
  end

  # One credential table serves the whole installation, so a second local
  # provider instance would only make the retry-protection config ambiguous.
  # Saving the same instance again stays allowed.
  defp ensure_single_local_provider(%{adapter_id: adapter_id}, provider_id) do
    with true <- adapter_id == LocalPassword.adapter_id(),
         {:ok, providers} <- Config.active_providers(),
         %{"provider_id" => existing_id} <-
           Enum.find(
             providers,
             &(&1["adapter_id"] == adapter_id and &1["provider_id"] != provider_id)
           ) do
      {:error, {:local_provider_exists, existing_id}}
    else
      _no_conflict -> :ok
    end
  end

  defp active_plugin_adapters do
    Plugins.list_active()
    |> Enum.flat_map(&adapters_for_plugin/1)
    |> Enum.sort_by(& &1.adapter_id)
  end

  defp builtin_adapters do
    Enum.map(builtin_adapter_declarations(), fn declaration ->
      adapter_projection(value(declaration, :plugin_id), declaration)
    end)
  end

  defp builtin_adapter_declarations do
    [LocalPassword.adapter_declaration()]
  end

  defp adapters_for_plugin(plugin) do
    plugin.adapter_declarations
    |> Enum.filter(&contract?(&1, @adapter_contract_id))
    |> Enum.map(&adapter_projection(plugin.id, &1))
  end

  defp adapter_projection(plugin_id, declaration) do
    adapter_id = value(declaration, :id)

    %{
      adapter_id: adapter_id,
      plugin_id: plugin_id,
      display_name: value(declaration, :display_name) || default_text(adapter_id),
      capabilities: adapter_capabilities(declaration),
      fields: value(declaration, :fields) || [],
      config_key_pattern: value(declaration, :config_key_pattern),
      default_provider_id: "#{adapter_id}-main",
      module: value(declaration, :module),
      connection_reconciler: value(declaration, :connection_reconciler)
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

  defp adapter_declarations do
    builtin_adapter_declarations() ++ Plugins.adapter_declarations(@adapter_contract_id)
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

  defp ensure_exported(module, function, arity) do
    case Code.ensure_loaded?(module) and function_exported?(module, function, arity) do
      true -> :ok
      false -> {:error, {:unsupported_identity_provider_operation, module, function, arity}}
    end
  end

  defp provider_ref(provider) do
    Map.take(provider, ["provider_id", "adapter_id", "plugin_id", "config_key"])
  end

  defp provider_projection(provider) do
    with {:ok, adapter} <- fetch_adapter(provider["adapter_id"]),
         {:ok, config} <- provider_config(provider) do
      {config, stored_secret_paths} = ConfigSecrets.redact(adapter.fields, config)

      {:ok,
       %{
         "provider_id" => provider["provider_id"],
         "adapter_id" => provider["adapter_id"],
         "plugin_id" => provider["plugin_id"],
         "config_key" => provider["config_key"],
         "enabled" => provider["enabled"] != false,
         "config" => config,
         "stored_secret_paths" => stored_secret_paths
       }}
    end
  end

  defp provider_config_for_write(adapter, config_key, config) do
    case AppConfigure.get_by_key(config_key) do
      {:ok, existing} when is_map(existing) ->
        {:ok, ConfigSecrets.preserve(adapter.fields, config, existing, [@legacy_secret_mask])}

      :error ->
        {:ok, config}

      {:error, _reason} = error ->
        error
    end
  end

  defp contract?(map, contract_id), do: value(map, :contract_id) == contract_id

  defp identity_adapter_module(declaration) do
    case value(declaration, :module) do
      module when is_atom(module) and not is_nil(module) ->
        case Code.ensure_loaded(module) do
          {:module, ^module} -> {:ok, module}
          {:error, reason} -> {:error, {:identity_provider_module_not_loaded, module, reason}}
        end

      value ->
        {:error, {:invalid_identity_provider_module, value}}
    end
  end

  defp validate_identity_capabilities(module, declaration) do
    declaration
    |> adapter_capabilities()
    |> Enum.reduce_while(:ok, fn capability, :ok ->
      case validate_identity_capability(module, capability) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_identity_capability(module, "oidc_authorization"),
    do: ensure_exported(module, :authorization_url, 2)

  # upsert_user is required exactly where the host calls it: the OIDC code
  # exchange and the directory sync paths.
  defp validate_identity_capability(module, "oidc_code_exchange"),
    do: ensure_exported_all(module, [{:exchange_code, 3}, {:upsert_user, 2}])

  defp validate_identity_capability(module, "directory_full_sync"),
    do: ensure_exported_all(module, [{:sync_directory, 3}, {:upsert_user, 2}])

  defp validate_identity_capability(module, "directory_realtime_sync"),
    do: ensure_exported_all(module, [{:handle_contact_event, 3}, {:upsert_user, 2}])

  defp validate_identity_capability(module, "password_login"),
    do: ensure_exported(module, :authenticate, 3)

  defp validate_identity_capability(module, @credential_check_capability),
    do: ensure_exported(module, :check_credentials, 1)

  defp validate_identity_capability(_module, capability),
    do: {:error, {:unknown_identity_capability, capability}}

  defp ensure_exported_all(module, functions) do
    Enum.reduce_while(functions, :ok, fn {function, arity}, :ok ->
      case ensure_exported(module, function, arity) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_connection_reconciler(declaration) do
    case value(declaration, :connection_reconciler) do
      nil ->
        :ok

      module when is_atom(module) ->
        ensure_exported(module, :reconcile, 0)

      value ->
        {:error, {:invalid_identity_provider_connection_reconciler, value}}
    end
  end

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
