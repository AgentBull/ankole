defmodule BullX.Gateway.Sources do
  @moduledoc """
  Runtime configured-source lookup for Gateway adapters.

  Source rows live in `BullX.Config`, not a Gateway-specific table. This module
  rebuilds lookup state from runtime config and enabled plugin extensions.
  """

  alias BullX.Config.Gateway
  alias BullX.Gateway.{Adapters, SourceConfig}

  @spec all() :: {:ok, [SourceConfig.t()]} | {:error, term()}
  def all do
    adapters = Adapters.enabled()

    Gateway.gateway_sources!()
    |> Enum.map(&normalize_source(&1, adapters))
    |> collect_sources()
  end

  @spec enabled!() :: [SourceConfig.t()]
  def enabled! do
    case all() do
      {:ok, sources} ->
        Enum.filter(sources, &enabled_and_fresh?/1)

      {:error, reason} ->
        raise ArgumentError, "invalid Gateway source configuration: #{inspect(reason)}"
    end
  end

  @spec fetch_enabled(String.t(), String.t()) ::
          {:ok, SourceConfig.t()} | {:error, :unknown_source}
  def fetch_enabled(adapter, channel_id) when is_binary(adapter) and is_binary(channel_id) do
    key = SourceConfig.canonical_key({adapter, channel_id})

    enabled!()
    |> Map.new(&{SourceConfig.canonical_key(&1), &1})
    |> Map.fetch(key)
    |> case do
      {:ok, source} -> {:ok, source}
      :error -> {:error, :unknown_source}
    end
  end

  @spec normalize_runtime_source(SourceConfig.t() | map()) ::
          {:ok, SourceConfig.t()} | {:error, term()}
  def normalize_runtime_source(%SourceConfig{} = source), do: {:ok, source}

  def normalize_runtime_source(%{} = source) do
    with {:ok, source} <- SourceConfig.normalize(source),
         {:ok, adapter_module} <- Adapters.fetch(source.adapter) do
      {:ok, %{source | adapter_module: adapter_module}}
    end
  end

  defp normalize_source(source, adapters) do
    with {:ok, source} <- SourceConfig.normalize(source),
         {:ok, adapter_module} <- fetch_adapter(adapters, source.adapter) do
      {:ok, %{source | adapter_module: adapter_module}}
    end
  end

  defp fetch_adapter(adapters, adapter) do
    case Map.fetch(adapters, String.downcase(adapter)) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_gateway_adapter, adapter}}
    end
  end

  defp collect_sources(sources) do
    case Enum.all?(sources, &match?({:ok, _source}, &1)) do
      true -> {:ok, Enum.map(sources, fn {:ok, source} -> source end)}
      false -> {:error, Enum.find(sources, &match?({:error, _reason}, &1))}
    end
  end

  defp enabled_and_fresh?(%SourceConfig{enabled?: true} = source),
    do: SourceConfig.connectivity_fresh?(source)

  defp enabled_and_fresh?(_source), do: false
end
