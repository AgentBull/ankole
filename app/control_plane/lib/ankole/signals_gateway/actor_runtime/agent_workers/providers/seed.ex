defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.Seed do
  @moduledoc "Imports the bootstrap providers and assigns legacy Agents in one transaction."

  import Ecto.Query
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.{Provider, YAML}
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(_opts) do
    case import_file(Application.get_env(:ankole, :worker_providers_file)) do
      :ok -> :ignore
      {:error, reason} -> {:error, {:worker_providers_seed_failed, reason}}
    end
  end

  def import_file(path) do
    Repo.across_tenants(fn ->
      Repo.transact(fn repo ->
        Providers.lock_registry(repo, :exclusive)

        cond do
          repo.exists?(Provider) -> {:ok, :ok}
          is_nil(path) -> {:ok, :ok}
          true -> import_in_tx(repo, path)
        end
      end)
    end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  defp import_in_tx(repo, path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"providers" => entries} = data, _locations} when is_list(entries) <-
           YAML.parse(text),
         true <- Map.keys(data) == ["providers"],
         :ok <- validate_flags(entries),
         {:ok, legacy_id} <- insert_all(repo, entries) do
      if legacy_id do
        repo.update_all(
          from(w in AgentWorker, where: is_nil(w.provider_id) and w.state != "deleting"),
          set: [provider_id: legacy_id, last_error: nil, last_error_kind: nil]
        )
      end

      {:ok, :ok}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_worker_providers_seed}
    end
  end

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

  defp insert_all(repo, entries) do
    Enum.reduce_while(entries, {:ok, nil}, fn entry, {:ok, legacy_id} ->
      with {:ok, credentials} <- credentials(Map.get(entry, "credentials", %{})),
           attrs = entry |> Map.delete("legacy_agents") |> Map.put("credentials", credentials),
           {:ok, provider} <- Providers.create_in_tx(repo, attrs) do
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
end
