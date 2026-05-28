defmodule Feishu.Config.IMGatewaySources do
  @moduledoc false

  use Skogsra.Type

  import BullX.Config.MapType,
    only: [required_string: 2, optional_boolean: 3, optional_map: 3]

  @valid_domains ~w(feishu lark)

  @impl Skogsra.Type
  def cast(value) when is_binary(value) do
    with {:ok, decoded} <- Jason.decode(value) do
      cast(decoded)
    else
      _error -> :error
    end
  end

  def cast(value) when is_list(value) do
    value
    |> Enum.map(&normalize_source/1)
    |> collect_sources()
  end

  def cast(_value), do: :error

  defp normalize_source(%{} = source) do
    with {:ok, source} <- stringify_keys(source),
         {:ok, id} <- required_string(source, "id"),
         {:ok, app_id} <- required_string(source, "app_id"),
         {:ok, app_secret} <- required_string(source, "app_secret"),
         {:ok, enabled?} <- optional_boolean(source, "enabled", true),
         {:ok, domain} <- optional_in(source, "domain", "feishu", @valid_domains),
         {:ok, oidc} <- optional_map(source, "oidc", %{}) do
      {:ok,
       source
       |> Map.put("id", id)
       |> Map.put("app_id", app_id)
       |> Map.put("app_secret", app_secret)
       |> Map.put("enabled", enabled?)
       |> Map.put("domain", domain)
       |> Map.put("oidc", oidc)}
    end
  end

  defp normalize_source(_source), do: :error

  defp collect_sources(sources) do
    case Enum.all?(sources, &match?({:ok, _source}, &1)) do
      true -> {:ok, Enum.map(sources, fn {:ok, source} -> source end)}
      false -> :error
    end
  end

  defp stringify_keys(%{} = map) do
    Enum.reduce_while(map, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_atom(key) ->
        {:cont, {:ok, Map.put(acc, Atom.to_string(key), stringify_value(value))}}

      {key, value}, {:ok, acc} when is_binary(key) ->
        {:cont, {:ok, Map.put(acc, key, stringify_value(value))}}

      _entry, _acc ->
        {:halt, :error}
    end)
  end

  defp stringify_value(%{} = map) do
    case stringify_keys(map) do
      {:ok, value} -> value
      :error -> map
    end
  end

  defp stringify_value(values) when is_list(values), do: Enum.map(values, &stringify_value/1)
  defp stringify_value(value), do: value

  defp optional_in(map, key, default, values) do
    case Map.get(map, key, default) do
      value when is_binary(value) ->
        if value in values, do: {:ok, value}, else: :error

      _value ->
        :error
    end
  end

end

defmodule Feishu.Config do
  @moduledoc """
  Runtime configuration declarations owned by the Feishu plugin.

  Each configured Feishu source is one BullX channel instance backed by one
  Feishu/Lark app credential. The source list is encrypted because it includes
  app secrets.
  """

  use BullX.Config

  @envdoc false
  bullx_env(:im_gateway_sources,
    key: [:plugins, :feishu, :im_gateway_sources],
    type: Feishu.Config.IMGatewaySources,
    default: [],
    secret: true
  )

  @envdoc false
  bullx_env(:oidc_state_ttl_seconds,
    key: [:plugins, :feishu, :oidc_state_ttl_seconds],
    type: :integer,
    default: 600,
    zoi: Zoi.integer(gte: 1)
  )
end
