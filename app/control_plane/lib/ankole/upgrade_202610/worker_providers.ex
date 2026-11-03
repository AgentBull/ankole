defmodule Ankole.Upgrade202610.WorkerProviders do
  @moduledoc "Imports the bootstrap providers and assigns legacy Agents in one transaction."

  require Ash.Query
  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.Providers.YAML
  alias Ankole.Errors
  alias Ankole.Repo

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(_opts) do
    case import_file(Application.get_env(:ankole, :worker_providers_file)) do
      :ok -> :ignore
      {:error, reason} -> {:error, {:worker_providers_seed_failed, reason}}
    end
  end

  def import_file(path) do
    Repo.transact_top_level(fn -> import_in_tx(path) end)
    |> Errors.reason()
  end

  @doc "Imports the seed file in the caller's transaction when no provider exists."
  def import_in_tx(path) do
    Providers.lock_registry(:exclusive)

    cond do
      Providers.list() != [] -> :ok
      is_nil(path) -> :ok
      true -> import_entries(path)
    end
  end

  defp import_entries(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"providers" => entries} = data, _locations} when is_list(entries) <-
           YAML.parse(text),
         true <- Map.keys(data) == ["providers"],
         :ok <- validate_flags(entries),
         {:ok, legacy_id} <- insert_all(entries),
         {:ok, ^legacy_id} <- select_legacy_provider(legacy_id) do
      if legacy_id, do: assign_legacy_provider_in_tx(legacy_id), else: :ok
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_worker_providers_seed}
    end
  end

  defp select_legacy_provider(nil), do: {:ok, nil}
  defp select_legacy_provider(id), do: Providers.select_in_tx(id)

  defp validate_flags(entries) do
    valid =
      Enum.all?(entries, fn
        entry when is_map(entry) -> is_boolean(Map.get(entry, "legacy_agents", false))
        _invalid -> false
      end)

    if valid and Enum.count(entries, &(&1["legacy_agents"] == true)) <= 1 and
         Enum.count(entries, &(&1["is_default"] == true)) <= 1,
       do: :ok,
       else: {:error, :invalid_worker_providers_seed_flags}
  end

  defp insert_all(entries) do
    Enum.reduce_while(entries, {:ok, nil}, fn entry, {:ok, legacy_id} ->
      with {:ok, credentials} <- credentials(Map.get(entry, "credentials", %{})),
           attrs = entry |> Map.delete("legacy_agents") |> Map.put("credentials", credentials),
           {:ok, provider} <- Providers.create_in_tx(attrs) do
        {:cont, {:ok, if(entry["legacy_agents"], do: provider.provider_id, else: legacy_id)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp credentials(input) when is_map(input) do
    Enum.reduce_while(input, {:ok, %{}}, fn {key, source}, {:ok, acc} ->
      case secret(source) do
        {:ok, value} when is_binary(value) and value != "" ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        _missing ->
          {:halt, {:error, {:worker_provider_seed_secret_missing, key}}}
      end
    end)
  end

  defp credentials(_input), do: {:error, :invalid_worker_provider_seed_credentials}

  defp secret(%{"env" => name} = source) when map_size(source) == 1 and is_binary(name),
    do: System.fetch_env(name)

  defp secret(%{"file" => path} = source) when map_size(source) == 1 and is_binary(path),
    do: File.read(path)

  defp secret(_source), do: :error
  @spec assign_legacy_provider_in_tx(String.t()) :: :ok | {:error, term()}
  defp assign_legacy_provider_in_tx(provider_id) do
    query =
      AgentWorker
      |> Ash.Query.filter(is_nil(provider_id) and state != :deleting)
      |> Ash.Query.sort(agent_uid: :asc)
      |> Ash.Query.lock(:for_update)

    workers =
      query
      |> Ash.Query.for_read(:across_tenants)
      |> Ankole.Ash.read_across_tenants!(lock_identity: {:rows, "agent_workers", :agent_uid})

    Enum.reduce_while(workers, :ok, fn worker, :ok ->
      Repo.with_tenant(worker.tenant_id, fn ->
        Ankole.Ash.update(worker, :assign_provider, %{provider_id: provider_id})
      end)
      |> case do
        {:ok, _updated} -> {:cont, :ok}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end
end
