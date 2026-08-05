defmodule Ankole.IdentityProviders do
  @moduledoc """
  Identity-provider adapter configuration and OIDC login boundary.
  """

  alias Ankole.AppConfigure
  alias Ankole.IdentityProviders.Config
  alias Ankole.IdentityProviders.Jobs.SyncProvider
  alias Ankole.Logging
  alias Ankole.Plugins
  alias Ankole.Plugins.ConfigSecrets

  @adapter_contract_id "principals.identity_provider"
  @credential_check_capability "credential_check"
  @directory_full_sync_capability "directory_full_sync"
  @directory_realtime_sync_capability "directory_realtime_sync"
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
    list_active_plugin_adapters()
    |> Enum.filter(&MapSet.member?(enabled_ids, &1.plugin_id))
  end

  @doc """
  Lists identity-provider adapters loaded by plugins active in this process.

  Setup uses this boot-time catalog and applies the current setup selection in
  the browser. This keeps an adapter available when an operator clears and then
  restores its selection before the process restarts.
  """
  @spec list_active_plugin_adapters() :: [adapter()]
  def list_active_plugin_adapters do
    Plugins.list_active()
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
      adapter_ids = adapter_id_set()

      {:ok, Enum.filter(providers, &login_provider?(&1, adapter_ids))}
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
           ),
         {:ok, _reconcile} <-
           maybe_reconcile_saved_provider(adapter, persisted_config, enabled, opts) do
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
         {:ok, config} <- AppConfigure.get_by_key(provider["config_key"]),
         {:ok, module} <- adapter_module(adapter) do
      case @credential_check_capability in adapter_capabilities(adapter) do
        true -> with :ok <- module.check_credentials(config), do: {:ok, :checked}
        false -> {:ok, :unsupported}
      end
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

  @doc false
  @spec validate_adapter_declaration(map()) :: :ok | {:error, term()}
  def validate_adapter_declaration(declaration) when is_map(declaration) do
    with {:ok, module} <- identity_adapter_module(declaration),
         :ok <- ensure_exported(module, :upsert_user, 2),
         :ok <- validate_identity_capabilities(module, declaration),
         :ok <- validate_connection_reconciler(declaration) do
      :ok
    end
  end

  def validate_adapter_declaration(declaration),
    do: {:error, {:invalid_identity_provider_declaration, declaration}}

  defp enabled_plugin_ids do
    case Plugins.enabled_ids() do
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

  defp fetch_adapter(adapter_id) do
    adapter_declarations()
    |> Enum.find(&(value(&1, :id) == adapter_id))
    |> case do
      nil -> {:error, {:unknown_identity_provider_adapter, adapter_id}}
      adapter -> {:ok, adapter}
    end
  end

  defp adapter_declarations do
    Plugins.adapter_declarations(@adapter_contract_id)
  end

  defp adapter_id_set do
    adapter_declarations()
    |> Enum.map(&value(&1, :id))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
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

  defp login_provider?(provider, adapter_ids) do
    provider["enabled"] != false and
      MapSet.member?(adapter_ids, provider["adapter_id"])
  end

  defp provider_config_key(%{config_key_pattern: pattern}, provider_id) when is_binary(pattern) do
    {:ok, String.replace(pattern, "<id>", provider_id)}
  end

  defp provider_config_key(%{adapter_id: adapter_id}, provider_id) do
    {:ok, "principals.identity_providers.#{adapter_id}.#{provider_id}"}
  end

  defp adapter_module(adapter) do
    case value(adapter, :module) do
      module when is_atom(module) and not is_nil(module) -> {:ok, module}
      value -> {:error, {:invalid_identity_provider_module, value}}
    end
  end

  defp ensure_exported(module, function, arity) do
    case Code.ensure_loaded?(module) and function_exported?(module, function, arity) do
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

  defp maybe_reconcile_saved_provider(_adapter, _config, false, _opts), do: {:ok, :disabled}

  defp maybe_reconcile_saved_provider(adapter, config, true, opts) do
    cond do
      not realtime_reconcile_on_save?(opts) ->
        {:ok, :disabled}

      not directory_realtime_sync_supported?(adapter) ->
        {:ok, :sync_unsupported}

      not sync_config_enabled?(config) ->
        {:ok, :sync_disabled}

      not websocket_sync_config_enabled?(config) ->
        {:ok, :websocket_disabled}

      true ->
        reconcile_realtime_directory(adapter)
    end
  end

  defp realtime_reconcile_on_save?(opts) do
    case Keyword.fetch(opts, :reconcile_realtime?) do
      {:ok, value} when is_boolean(value) ->
        value

      _other ->
        :ankole
        |> Application.get_env(:identity_provider_realtime_reconcile, [])
        |> Keyword.get(:on_save, true)
    end
  end

  defp reconcile_realtime_directory(adapter) do
    case value(adapter, :connection_reconciler) do
      module when is_atom(module) and not is_nil(module) ->
        safe_reconcile_realtime_directory(module)

      nil ->
        {:ok, :reconcile_unavailable}

      value ->
        {:error, {:invalid_identity_provider_connection_reconciler, value}}
    end
  end

  defp safe_reconcile_realtime_directory(module) do
    result = module.reconcile()
    maybe_log_reconcile_errors(module, result)
    {:ok, result}
  catch
    kind, reason ->
      Logging.warning(
        "identity_providers.realtime_reconcile.failed",
        "identity provider realtime reconcile failed",
        %{module: inspect(module), reason: inspect({kind, reason})}
      )

      {:ok, {:error, {kind, reason}}}
  end

  defp maybe_log_reconcile_errors(_module, %{errors: []}), do: :ok

  defp maybe_log_reconcile_errors(module, %{errors: errors}) when is_list(errors) do
    Logging.warning(
      "identity_providers.realtime_reconcile.completed_with_errors",
      "identity provider realtime reconcile completed with errors",
      %{module: inspect(module), errors: errors}
    )
  end

  defp maybe_log_reconcile_errors(_module, _result), do: :ok

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

  defp websocket_sync_config_enabled?(config) when is_map(config) do
    get_in(config, ["sync", "websocket"]) != false
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

    cond do
      periodic_sync?(reason, source) ->
        with {:ok, unique_opts} <- periodic_sync_unique_opts(opts) do
          {:ok, [unique: unique_opts]}
        end

      event_triggered_sync?(source) ->
        {:ok, [unique: event_triggered_sync_unique_opts()]}

      true ->
        {:ok, []}
    end
  end

  defp periodic_sync?("periodic", "cron"), do: true
  defp periodic_sync?(_reason, _source), do: false

  defp event_triggered_sync?("lark_contact_event"), do: true
  defp event_triggered_sync?("dingtalk_contact_event"), do: true
  defp event_triggered_sync?(_source), do: false

  defp event_triggered_sync_unique_opts do
    [
      fields: [:worker, :args],
      keys: [:provider_id, :source],
      period: 300
    ]
  end

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

  defp directory_realtime_sync_supported?(adapter) do
    @directory_realtime_sync_capability in adapter_capabilities(adapter)
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

  defp sync_reason(value) when is_atom(value), do: Atom.to_string(value)
  defp sync_reason(value) when is_binary(value), do: value
  defp sync_reason(value), do: inspect(value)

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

  defp validate_identity_capability(module, "oidc_code_exchange"),
    do: ensure_exported(module, :exchange_code, 3)

  defp validate_identity_capability(module, "directory_full_sync"),
    do: ensure_exported(module, :sync_directory, 3)

  defp validate_identity_capability(module, "directory_realtime_sync"),
    do: ensure_exported(module, :handle_contact_event, 3)

  defp validate_identity_capability(module, @credential_check_capability),
    do: ensure_exported(module, :check_credentials, 1)

  defp validate_identity_capability(_module, capability),
    do: {:error, {:unknown_identity_capability, capability}}

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
