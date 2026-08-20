defmodule Ankole.IdentityProviders.DirectorySync do
  @moduledoc """
  Directory-sync orchestration for configured identity providers.

  Sync applies only to adapters that declare the directory capabilities and to
  providers whose `sync.contacts` config is on; every entry point here skips or
  refuses the rest, so a login-only provider needs no sync support. The
  resulting Principal/AuthZ writes belong to
  `Ankole.IdentityProviders.Directory`.
  """

  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.Config
  alias Ankole.IdentityProviders.Jobs.SyncProvider
  alias Ankole.Logging

  @full_sync_capability "directory_full_sync"
  @realtime_sync_capability "directory_realtime_sync"

  @doc """
  Enqueues a full directory sync for one active identity provider.
  """
  @spec enqueue_sync(String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_sync(provider_id, opts \\ []) when is_binary(provider_id) and is_list(opts) do
    with {:ok, provider} <- IdentityProviders.fetch_active_provider(provider_id),
         {:ok, adapter} <- IdentityProviders.fetch_adapter(provider["adapter_id"]),
         {:ok, config} <- IdentityProviders.provider_config(provider),
         :ok <- require_full_sync(adapter),
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

    with {:ok, interval_seconds} <- full_sync_interval_seconds(opts),
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
    with {:ok, provider} <- IdentityProviders.fetch_active_provider(provider_id),
         {:ok, adapter} <- IdentityProviders.fetch_adapter(provider["adapter_id"]),
         {:ok, config} <- IdentityProviders.provider_config(provider),
         {:ok, module} <- IdentityProviders.adapter_module(adapter),
         {:ok, directory_result} <-
           maybe_sync_directory(adapter, module, provider_id, config, opts) do
      {:ok,
       %{
         provider_id: provider_id,
         directory: directory_result
       }}
    end
  end

  @doc false
  @spec enqueue_initial_sync(String.t(), map(), map(), boolean(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def enqueue_initial_sync(_provider_id, _adapter, _config, false, _source), do: {:ok, :disabled}

  def enqueue_initial_sync(provider_id, adapter, config, true, source) do
    cond do
      not full_sync_supported?(adapter) ->
        {:ok, :sync_unsupported}

      not sync_config_enabled?(config) ->
        {:ok, :sync_disabled}

      true ->
        enqueue_sync(provider_id, reason: "provider_saved", source: source)
    end
  end

  @doc false
  @spec reconcile_saved_provider(map(), map(), boolean(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def reconcile_saved_provider(_adapter, _config, false, _opts), do: {:ok, :disabled}

  def reconcile_saved_provider(adapter, config, true, opts) do
    cond do
      not realtime_reconcile_on_save?(opts) ->
        {:ok, :disabled}

      not realtime_sync_supported?(adapter) ->
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
    case Map.get(adapter, :connection_reconciler) do
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
    case full_sync_supported?(adapter) and sync_config_enabled?(config) do
      true -> module.sync_directory(provider_id, config, opts)
      false -> {:ok, :skipped}
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
    with {:ok, adapter} <- IdentityProviders.fetch_adapter(provider["adapter_id"]),
         {:ok, config} <- IdentityProviders.provider_config(provider) do
      cond do
        not full_sync_supported?(adapter) ->
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

  defp require_full_sync(adapter) do
    case full_sync_supported?(adapter) do
      true -> :ok
      false -> {:error, :sync_unsupported}
    end
  end

  defp full_sync_supported?(adapter) do
    @full_sync_capability in IdentityProviders.adapter_capabilities(adapter)
  end

  defp realtime_sync_supported?(adapter) do
    @realtime_sync_capability in IdentityProviders.adapter_capabilities(adapter)
  end

  defp full_sync_interval_seconds(opts) do
    case Keyword.fetch(opts, :directory_full_sync_interval_seconds) do
      {:ok, seconds} when is_integer(seconds) and seconds >= 1 -> {:ok, seconds}
      {:ok, seconds} -> {:error, {:invalid_directory_full_sync_interval_seconds, seconds}}
      :error -> Config.directory_full_sync_interval_seconds()
    end
  end

  defp sync_reason(value) when is_atom(value), do: Atom.to_string(value)
  defp sync_reason(value) when is_binary(value), do: value
  defp sync_reason(value), do: inspect(value)
end
