defmodule Ankole.AgentWorkers.BootstrapSeed do
  @moduledoc """
  Imports initial Worker providers from `ANKOLE_WORKER_PROVIDERS_FILE` on a fresh site.

  Sites without a seed file skip database access immediately; sites that already
  have at least one provider row keep their stored configuration untouched.
  """

  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.Providers.YAML
  alias Ankole.Errors
  alias Ankole.Repo

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(_opts) do
    case Application.get_env(:ankole, :worker_providers_file) do
      nil ->
        :ignore

      path ->
        case import_file(path) do
          :ok -> :ignore
          {:error, reason} -> {:error, {:worker_providers_seed_failed, reason}}
        end
    end
  end

  def import_file(nil), do: :ok

  def import_file(path) when is_binary(path) do
    Repo.transact_top_level(fn -> import_in_tx(path) end)
    |> Errors.reason()
  end

  def import_in_tx(nil), do: :ok

  def import_in_tx(path) when is_binary(path) do
    Providers.lock_registry(:exclusive)

    if Providers.list() != [] do
      :ok
    else
      with {:ok, _legacy_id} <- import_entries_in_tx(path), do: :ok
    end
  end

  @doc "Parses and inserts bootstrap provider entries inside the caller's locked registry transaction."
  def import_entries_in_tx(path, opts \\ []) when is_binary(path) do
    enforce_single_legacy? = Keyword.get(opts, :enforce_single_legacy?, false)

    with {:ok, text} <- File.read(path),
         {:ok, %{"providers" => entries} = data, _locations} when is_list(entries) <-
           YAML.parse(text),
         true <- Map.keys(data) == ["providers"],
         :ok <- validate_flags(entries, enforce_single_legacy?),
         {:ok, legacy_id} <- insert_all(entries) do
      {:ok, legacy_id}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_worker_providers_seed}
    end
  end

  defp validate_flags(entries, enforce_single_legacy?) do
    valid =
      Enum.all?(entries, fn
        entry when is_map(entry) -> is_boolean(Map.get(entry, "legacy_agents", false))
        _invalid -> false
      end)

    legacy_ok? =
      not enforce_single_legacy? or Enum.count(entries, &(&1["legacy_agents"] == true)) <= 1

    if valid and legacy_ok? and Enum.count(entries, &(&1["is_default"] == true)) <= 1,
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
end
