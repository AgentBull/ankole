defmodule BullX.Config.Gateway.Sources do
  @moduledoc false

  use Skogsra.Type

  @impl Skogsra.Type
  def cast(value) when is_list(value) do
    value
    |> Enum.map(&normalize_source/1)
    |> valid_sources()
  end

  def cast(value) when is_binary(value) do
    with {:ok, decoded} <- Jason.decode(value) do
      cast(decoded)
    else
      _other -> :error
    end
  end

  def cast(_value), do: :error

  defp valid_sources(sources) do
    with true <- Enum.all?(sources, &match?({:ok, _source}, &1)),
         normalized <- Enum.map(sources, fn {:ok, source} -> source end),
         :ok <- validate_unique_sources(normalized) do
      {:ok, normalized}
    else
      _other -> :error
    end
  end

  defp normalize_source(source) when is_map(source) do
    source = stringify_keys(source)

    with {:ok, adapter} <- required_string(source, "adapter"),
         {:ok, channel_id} <- required_string(source, "channel_id"),
         {:ok, enabled} <- optional_boolean(source, "enabled", false),
         {:ok, config} <- optional_object(source, "config", %{}),
         {:ok, outbound_retry} <- optional_object(source, "outbound_retry", %{}),
         {:ok, connectivity} <- optional_object(source, "connectivity", nil) do
      {:ok,
       %{
         "adapter" => adapter,
         "channel_id" => channel_id,
         "enabled" => enabled,
         "config" => config,
         "outbound_retry" => outbound_retry,
         "connectivity" => connectivity
       }}
    else
      _other -> :error
    end
  end

  defp normalize_source(_source), do: :error

  defp validate_unique_sources(sources) do
    sources
    |> Enum.map(&{String.downcase(&1["adapter"]), String.downcase(&1["channel_id"])})
    |> Enum.frequencies()
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> case do
      [] -> :ok
      _duplicates -> :error
    end
  end

  defp stringify_keys(map) do
    Enum.reduce_while(map, %{}, fn
      {key, value}, acc when is_atom(key) ->
        {:cont, Map.put(acc, Atom.to_string(key), stringify_value(value))}

      {key, value}, acc when is_binary(key) ->
        {:cont, Map.put(acc, key, stringify_value(value))}

      {_key, _value}, _acc ->
        {:halt, :error}
    end)
  end

  defp stringify_value(%{} = value), do: stringify_keys(value)
  defp stringify_value([_ | _] = value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value([]), do: []
  defp stringify_value(value), do: value

  defp required_string(source, key) do
    case Map.fetch(source, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> :error
    end
  end

  defp optional_boolean(source, key, default) do
    case Map.fetch(source, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      :error -> {:ok, default}
      _other -> :error
    end
  end

  defp optional_object(source, key, default) do
    case Map.fetch(source, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      :error -> {:ok, default}
      _other -> :error
    end
  end
end

defmodule BullX.Config.Gateway do
  @moduledoc """
  Runtime configuration declarations for the Gateway transport boundary.

  Configured sources are stored as a JSON array in `bullx.gateway.sources`.
  Secret values stay behind adapter-owned secret references; this config stores
  only source metadata, redacted public config, and freshness metadata.
  """

  use BullX.Config

  @envdoc false
  bullx_env(:gateway_sources,
    key: [:gateway, :sources],
    type: BullX.Config.Gateway.Sources,
    default: []
  )
end
