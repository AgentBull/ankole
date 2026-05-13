defmodule BullX.Gateway.SourceConfig do
  @moduledoc """
  Runtime representation of one configured Gateway source.

  A source is an adapter instance for this Installation. The pair
  `{adapter, channel_id}` is the configured source identity and is case-folded
  for lookup. It is not a tenant, room, or external actor id.
  """

  alias BullX.Gateway.JSON

  @enforce_keys [:adapter, :channel_id]
  defstruct [
    :adapter,
    :channel_id,
    :adapter_module,
    enabled?: false,
    config: %{},
    outbound_retry: %{},
    connectivity: nil
  ]

  @type t :: %__MODULE__{
          adapter: String.t(),
          channel_id: String.t(),
          adapter_module: module() | nil,
          enabled?: boolean(),
          config: map(),
          outbound_retry: map(),
          connectivity: map() | nil
        }

  @spec normalize(map(), module() | nil) :: {:ok, t()} | {:error, term()}
  def normalize(%{} = source, adapter_module \\ nil) do
    with {:ok, source} <- JSON.stringify_keys(source),
         {:ok, adapter} <- required_string(source, "adapter"),
         {:ok, channel_id} <- required_string(source, "channel_id"),
         {:ok, enabled?} <- optional_boolean(source, "enabled", false),
         {:ok, config} <- optional_object(source, "config", %{}),
         {:ok, outbound_retry} <- optional_object(source, "outbound_retry", %{}),
         {:ok, connectivity} <- optional_object(source, "connectivity", nil) do
      {:ok,
       %__MODULE__{
         adapter: adapter,
         channel_id: channel_id,
         adapter_module: adapter_module,
         enabled?: enabled?,
         config: config,
         outbound_retry: outbound_retry,
         connectivity: connectivity
       }}
    end
  end

  @spec canonical_key(t() | {String.t(), String.t()} | map()) :: {String.t(), String.t()}
  def canonical_key(%__MODULE__{adapter: adapter, channel_id: channel_id}) do
    {String.downcase(adapter), String.downcase(channel_id)}
  end

  def canonical_key({adapter, channel_id}) when is_binary(adapter) and is_binary(channel_id) do
    {String.downcase(adapter), String.downcase(channel_id)}
  end

  def canonical_key(%{"adapter" => adapter, "channel_id" => channel_id}) do
    canonical_key({adapter, channel_id})
  end

  @spec source_uri(t()) :: String.t()
  def source_uri(%__MODULE__{} = source) do
    "bullx://gateway/#{URI.encode(source.adapter)}/#{URI.encode(source.channel_id)}"
  end

  @spec connectivity_fresh?(t(), DateTime.t()) :: boolean()
  def connectivity_fresh?(source, now \\ DateTime.utc_now())

  def connectivity_fresh?(%__MODULE__{connectivity: %{} = connectivity}, now) do
    with "ok" <- connectivity["status"],
         {:ok, checked_at, _offset} <- DateTime.from_iso8601(connectivity["checked_at"] || ""),
         max_age when is_integer(max_age) and max_age > 0 <- connectivity["max_age_seconds"] do
      DateTime.diff(now, checked_at, :second) <= max_age
    else
      nil -> connectivity["status"] == "ok"
      _other -> false
    end
  end

  def connectivity_fresh?(_source, _now), do: false

  defp required_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:required_string, key}}
    end
  end

  defp optional_boolean(map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      :error -> {:ok, default}
      _other -> {:error, {:optional_boolean, key}}
    end
  end

  defp optional_object(map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      :error -> {:ok, default}
      _other -> {:error, {:optional_object, key}}
    end
  end
end
