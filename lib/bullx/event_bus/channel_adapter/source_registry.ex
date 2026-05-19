defmodule BullX.EventBus.ChannelAdapter.SourceRegistry do
  @moduledoc """
  Reusable source-list helpers for IM-style channel adapters.

  Each adapter holds its enabled sources in plugin-local config and projects
  them into a per-adapter struct via a `normalize/1` callback. The traversal
  (filter `"enabled" => true` → normalize → reduce_while → reverse) is
  identical across adapters, so this module captures it once.

  Callers wire two functions:

    * `eventbus_sources` — 0-arity getter returning the raw config maps (e.g.
      `&BullxTelegram.Config.eventbus_sources!/0`).
    * `normalize` — 1-arity normalizer returning `{:ok, struct} | {:error, map}`.
  """

  @type sources_fun :: (-> [map()])
  @type normalize_fun :: (map() -> {:ok, struct()} | {:error, map()})

  @spec enabled_sources(sources_fun(), normalize_fun()) :: {:ok, [struct()]} | {:error, map()}
  def enabled_sources(eventbus_sources, normalize)
      when is_function(eventbus_sources, 0) and is_function(normalize, 1) do
    eventbus_sources.()
    |> Enum.filter(&(Map.get(&1, "enabled", true) == true))
    |> Enum.reduce_while({:ok, []}, fn config, {:ok, acc} ->
      case normalize.(config) do
        {:ok, source} -> {:cont, {:ok, [source | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, sources} -> {:ok, Enum.reverse(sources)}
      {:error, _reason} = error -> error
    end
  end

  @spec enabled_sources!(sources_fun(), normalize_fun(), String.t()) :: [struct()]
  def enabled_sources!(eventbus_sources, normalize, label) when is_binary(label) do
    case enabled_sources(eventbus_sources, normalize) do
      {:ok, sources} ->
        sources

      {:error, error} ->
        raise ArgumentError, "invalid #{label} source config: #{inspect(error)}"
    end
  end

  @spec fetch_enabled_source([struct()], term()) :: {:ok, struct()} | {:error, :not_found}
  def fetch_enabled_source(sources, source_id) when is_list(sources) do
    case Enum.find(sources, &(&1.id == source_id)) do
      nil -> {:error, :not_found}
      source -> {:ok, source}
    end
  end
end
