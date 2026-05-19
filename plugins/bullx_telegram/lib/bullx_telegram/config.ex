defmodule BullxTelegram.Config.Credentials do
  @moduledoc false

  use Skogsra.Type

  import BullX.Utils.Map, only: [maybe_put: 3, present_string: 1]
  import BullX.Config.MapType, only: [required_string: 2]

  @impl Skogsra.Type
  def cast(value) when is_binary(value) do
    with {:ok, decoded} <- Jason.decode(value), do: cast(decoded), else: (_error -> :error)
  end

  def cast(value) when is_map(value) do
    value
    |> stringify_keys()
    |> normalize_profiles()
  end

  def cast(_value), do: :error

  defp normalize_profiles({:ok, profiles}) do
    profiles
    |> Enum.map(&normalize_profile/1)
    |> collect_profiles()
  end

  defp normalize_profiles(:error), do: :error

  defp normalize_profile({id, %{} = profile}) when is_binary(id) and id != "" do
    with {:ok, bot_token} <- required_string(profile, "bot_token") do
      {:ok, {id, maybe_put(%{"bot_token" => bot_token}, "bot_username", present_string(Map.get(profile, "bot_username")))}}
    end
  end

  defp normalize_profile(_profile), do: :error

  defp collect_profiles(profiles) do
    case Enum.all?(profiles, &match?({:ok, _profile}, &1)) do
      true -> {:ok, Map.new(profiles, fn {:ok, profile} -> profile end)}
      false -> :error
    end
  end

  defp stringify_keys(%{} = map) do
    Enum.reduce_while(map, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_atom(key) ->
        with {:ok, value} <- stringify_keys(value) do
          {:cont, {:ok, Map.put(acc, Atom.to_string(key), value)}}
        else
          :error -> {:halt, :error}
        end

      {key, value}, {:ok, acc} when is_binary(key) ->
        with {:ok, value} <- stringify_keys(value) do
          {:cont, {:ok, Map.put(acc, key, value)}}
        else
          :error -> {:halt, :error}
        end

      _entry, _acc ->
        {:halt, :error}
    end)
  end

  defp stringify_keys(value) when is_binary(value), do: {:ok, String.trim(value)}
  defp stringify_keys(_value), do: :error
end

defmodule BullxTelegram.Config.EventBusSources do
  @moduledoc false

  use Skogsra.Type

  import BullX.Config.MapType,
    only: [required_string: 2, optional_string: 3, optional_boolean: 3, optional_map: 3]

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
         {:ok, credential_id} <- optional_string(source, "credential_id", "default"),
         {:ok, enabled?} <- optional_boolean(source, "enabled", true),
         {:ok, attention} <- optional_map(source, "attention", %{}),
         {:ok, commands} <- optional_map(source, "commands", %{}) do
      {:ok,
       source
       |> Map.put("id", id)
       |> Map.put("credential_id", credential_id)
       |> Map.put("enabled", enabled?)
       |> Map.put("attention", attention)
       |> Map.put("commands", commands)}
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

defmodule BullxTelegram.Config do
  @moduledoc """
  Runtime configuration declarations owned by the Telegram plugin.

  Bot tokens are encrypted as profile maps and referenced by EventBus source
  config through `credential_id`; source config never stores bot tokens.
  """

  use BullX.Config

  @envdoc false
  bullx_env(:credentials,
    key: [:plugins, :bullx_telegram, :credentials],
    type: BullxTelegram.Config.Credentials,
    default: %{},
    secret: true
  )

  @envdoc false
  bullx_env(:eventbus_sources,
    key: [:plugins, :bullx_telegram, :eventbus_sources],
    type: BullxTelegram.Config.EventBusSources,
    default: []
  )
end
