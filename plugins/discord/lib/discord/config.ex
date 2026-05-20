defmodule Discord.Config.EventBusSources do
  @moduledoc false

  use Skogsra.Type

  import BullX.Config.MapType,
    only: [required_string: 2, optional_boolean: 3, optional_map: 3]

  @impl Skogsra.Type
  def cast(value) when is_binary(value) do
    with {:ok, decoded} <- Jason.decode(value), do: cast(decoded), else: (_error -> :error)
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
         {:ok, application_id} <- required_string(source, "application_id"),
         {:ok, bot_token} <- required_string(source, "bot_token"),
         {:ok, enabled?} <- optional_boolean(source, "enabled", true),
         {:ok, oauth2} <- optional_map(source, "oauth2", %{}),
         {:ok, attention} <- optional_map(source, "attention", %{}),
         {:ok, auto_thread} <- optional_map(source, "auto_thread", %{}),
         {:ok, application_commands} <- optional_map(source, "application_commands", %{}) do
      {:ok,
       source
       |> Map.put("id", id)
       |> Map.put("application_id", application_id)
       |> Map.put("bot_token", bot_token)
       |> Map.put("enabled", enabled?)
       |> Map.put("oauth2", oauth2)
       |> Map.put("attention", attention)
       |> Map.put("auto_thread", auto_thread)
       |> Map.put("application_commands", application_commands)}
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

  defp stringify_value(%{} = map), do: elem(stringify_keys(map), 1)
  defp stringify_value(values) when is_list(values), do: Enum.map(values, &stringify_value/1)
  defp stringify_value(value), do: value
end

defmodule Discord.Config do
  @moduledoc """
  Runtime configuration declarations owned by the Discord plugin.

  Each configured Discord source is one BullX channel instance backed by one
  Discord application/bot credential. The source list is encrypted because it
  includes bot tokens and optional OAuth2 client secrets.
  """

  use BullX.Config

  @envdoc false
  bullx_env(:eventbus_sources,
    key: [:plugins, :discord, :eventbus_sources],
    type: Discord.Config.EventBusSources,
    default: [],
    secret: true
  )

  @envdoc false
  bullx_env(:oauth2_state_ttl_seconds,
    key: [:plugins, :discord, :oauth2_state_ttl_seconds],
    type: :integer,
    default: 600,
    zoi: Zoi.integer(gte: 1)
  )
end
