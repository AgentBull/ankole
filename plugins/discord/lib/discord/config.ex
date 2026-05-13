defmodule Discord.Config.Credentials do
  @moduledoc false

  use Skogsra.Type

  @impl Skogsra.Type
  def cast(value) when is_binary(value) do
    with {:ok, decoded} <- Jason.decode(value) do
      cast(decoded)
    else
      _error -> :error
    end
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
    with {:ok, application_id} <- required_string(profile, "application_id"),
         {:ok, bot_token} <- required_string(profile, "bot_token") do
      client_secret = optional_present_string(profile, "client_secret")

      normalized =
        %{
          "application_id" => application_id,
          "bot_token" => bot_token
        }
        |> maybe_put("client_secret", client_secret)

      {:ok, {id, normalized}}
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

  defp required_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> :error
    end
  end

  defp optional_present_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule Discord.Config do
  @moduledoc """
  Runtime configuration declarations owned by the Discord plugin.

  Bot tokens and OAuth2 client secrets are encrypted as one profile map and
  referenced from Gateway source config by `credential_id`; source config
  never stores the bot token or client secret.
  """

  use BullX.Config

  @envdoc false
  bullx_env(:credentials,
    key: [:plugins, :discord, :credentials],
    type: Discord.Config.Credentials,
    default: %{},
    secret: true
  )

  @envdoc false
  bullx_env(:oauth2_state_ttl_seconds,
    key: [:plugins, :discord, :oauth2_state_ttl_seconds],
    type: :integer,
    default: 600
  )
end
