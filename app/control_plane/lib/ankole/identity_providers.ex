defmodule Ankole.IdentityProviders do
  @moduledoc """
  Identity-provider adapter configuration and OIDC login boundary.
  """

  alias Ankole.AppConfigure
  alias Ankole.IdentityProviders.Config
  alias Ankole.IdentityProviders.Jobs.SyncProvider
  alias Ankole.Plugins

  @setup_contract_id "principals.identity_provider.setup"
  @adapter_contract_id "principals.identity_provider"

  @type setup_adapter :: %{
          adapter_id: String.t(),
          plugin_id: String.t(),
          display_name: term(),
          fields: [map()],
          default_provider_id: String.t()
        }

  @doc """
  Lists identity-provider adapters available to first-run setup.
  """
  @spec list_setup_adapters() :: [setup_adapter()]
  def list_setup_adapters do
    disabled_ids = disabled_plugin_ids()

    Plugins.list_active()
    |> Enum.reject(&MapSet.member?(disabled_ids, &1.id))
    |> Enum.flat_map(&setup_adapters_for_plugin/1)
    |> Enum.sort_by(& &1.adapter_id)
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
  @spec save_provider(String.t(), String.t(), map(), boolean()) :: {:ok, map()} | {:error, term()}
  def save_provider(provider_id, adapter_id, config, enabled \\ true)
      when is_binary(adapter_id) and is_map(config) and is_boolean(enabled) do
    with {:ok, provider_id} <- Config.normalize_provider_id(provider_id),
         {:ok, adapter} <- fetch_setup_adapter(adapter_id),
         {:ok, config_key} <- provider_config_key(adapter, provider_id),
         {:ok, persisted_config} <- AppConfigure.put_global_by_key(config_key, config),
         {:ok, _providers} <-
           Config.upsert_active_provider(%{
             "provider_id" => provider_id,
             "adapter_id" => adapter.adapter_id,
             "plugin_id" => adapter.plugin_id,
             "config_key" => config_key,
             "enabled" => enabled
           }),
         {:ok, _job} <- maybe_enqueue_initial_sync(provider_id, persisted_config, enabled) do
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
    with {:ok, provider} <- fetch_active_provider(provider_id) do
      %{
        "provider_id" => provider["provider_id"],
        "reason" => sync_reason(Keyword.get(opts, :reason, "manual")),
        "source" => sync_reason(Keyword.get(opts, :source, "manual"))
      }
      |> SyncProvider.new()
      |> Oban.insert()
    end
  end

  @doc """
  Runs one full directory sync for an active identity provider.
  """
  @spec sync_provider(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync_provider(provider_id, opts \\ []) when is_binary(provider_id) and is_list(opts) do
    with {:ok, provider} <- fetch_active_provider(provider_id),
         {:ok, adapter} <- fetch_adapter(provider["adapter_id"]),
         {:ok, config} <- AppConfigure.get_by_key(provider["config_key"]),
         {:ok, module} <- adapter_module(adapter),
         {:ok, user_result} <- maybe_sync_users(module, provider_id, config, opts),
         {:ok, department_result} <- maybe_sync_departments(module, provider_id, config, opts) do
      {:ok,
       %{
         provider_id: provider_id,
         users: user_result,
         departments: department_result
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

  defp setup_adapters_for_plugin(plugin) do
    declarations =
      plugin.adapter_declarations
      |> Enum.filter(&contract?(&1, @adapter_contract_id))
      |> Map.new(&{value(&1, :id), &1})

    plugin.setup_metadata
    |> Enum.filter(&contract?(&1, @setup_contract_id))
    |> Enum.flat_map(&setup_adapter(plugin, &1, declarations))
  end

  defp disabled_plugin_ids do
    case Plugins.disabled_ids() do
      {:ok, ids} -> MapSet.new(ids)
      {:error, _reason} -> MapSet.new()
    end
  end

  defp setup_adapter(plugin, metadata, declarations) do
    adapter_id = value(metadata, :adapter_id)

    case Map.fetch(declarations, adapter_id) do
      {:ok, declaration} ->
        [
          %{
            adapter_id: adapter_id,
            plugin_id: plugin.id,
            display_name:
              value(metadata, :display_name) || value(declaration, :display_name) || adapter_id,
            fields: value(metadata, :fields) || [],
            config_key_pattern: value(metadata, :config_key_pattern),
            default_provider_id: "#{adapter_id}-main",
            module: value(declaration, :module)
          }
        ]

      :error ->
        []
    end
  end

  defp fetch_setup_adapter(adapter_id) do
    list_setup_adapters()
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

  defp maybe_enqueue_initial_sync(_provider_id, _config, false), do: {:ok, :disabled}

  defp maybe_enqueue_initial_sync(provider_id, config, true) do
    case sync_enabled?(config) do
      true -> enqueue_sync(provider_id, reason: "provider_saved", source: "setup")
      false -> {:ok, :sync_disabled}
    end
  end

  defp maybe_sync_users(module, provider_id, config, opts) do
    case get_in(config, ["sync", "users"]) != false do
      true ->
        with :ok <- ensure_exported(module, :sync_users, 3) do
          module.sync_users(provider_id, config, opts)
        end

      false ->
        {:ok, :skipped}
    end
  end

  defp maybe_sync_departments(module, provider_id, config, opts) do
    case get_in(config, ["sync", "departments"]) != false do
      true ->
        with :ok <- ensure_exported(module, :sync_departments, 3) do
          module.sync_departments(provider_id, config, opts)
        end

      false ->
        {:ok, :skipped}
    end
  end

  defp sync_enabled?(config) when is_map(config) do
    get_in(config, ["sync", "users"]) != false or get_in(config, ["sync", "departments"]) != false
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
end
