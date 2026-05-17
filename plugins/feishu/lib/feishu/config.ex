defmodule Feishu.Config.Credentials do
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
    with {:ok, app_id} <- required_string(profile, "app_id"),
         {:ok, app_secret} <- required_string(profile, "app_secret"),
         {:ok, app_type} <-
           optional_in(profile, "app_type", "self_built", ~w(self_built marketplace)) do
      {:ok,
       {id,
        %{"app_id" => app_id, "app_secret" => app_secret, "app_type" => app_type}
        |> maybe_put("app_ticket", present_string(Map.get(profile, "app_ticket")))
        |> maybe_put("verification_token", present_string(Map.get(profile, "verification_token")))
        |> maybe_put("encrypt_key", present_string(Map.get(profile, "encrypt_key")))}}
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

  defp optional_in(map, key, default, values) do
    case Map.get(map, key, default) do
      value when is_binary(value) ->
        if value in values, do: {:ok, value}, else: :error

      _value ->
        :error
    end
  end

  defp present_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp present_string(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule Feishu.Config.EventBusSources do
  @moduledoc false

  use Skogsra.Type

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
         {:ok, credential_id} <- optional_string(source, "credential_id", "default"),
         {:ok, enabled?} <- optional_boolean(source, "enabled", true),
         {:ok, domain} <- optional_in(source, "domain", "feishu", @valid_domains),
         {:ok, oidc} <- optional_map(source, "oidc", %{}) do
      {:ok,
       source
       |> Map.put("id", id)
       |> Map.put("credential_id", credential_id)
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

  defp required_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> :error
    end
  end

  defp optional_string(map, key, default) do
    case Map.get(map, key, default) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> :error
    end
  end

  defp optional_in(map, key, default, values) do
    case Map.get(map, key, default) do
      value when is_binary(value) ->
        if value in values, do: {:ok, value}, else: :error

      _value ->
        :error
    end
  end

  defp optional_boolean(map, key, default) do
    case Map.get(map, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _value -> :error
    end
  end

  defp optional_map(map, key, default) do
    case Map.get(map, key, default) do
      value when is_map(value) -> {:ok, value}
      _value -> :error
    end
  end
end

defmodule Feishu.Config do
  @moduledoc """
  Runtime configuration declarations owned by the Feishu plugin.

  Credentials are encrypted as profile maps and referenced by EventBus source
  config through `credential_id`; source config never stores app secrets.
  """

  use BullX.Config

  @envdoc false
  bullx_env(:credentials,
    key: [:plugins, :feishu, :credentials],
    type: Feishu.Config.Credentials,
    default: %{},
    secret: true
  )

  @envdoc false
  bullx_env(:eventbus_sources,
    key: [:plugins, :feishu, :eventbus_sources],
    type: Feishu.Config.EventBusSources,
    default: []
  )

  @envdoc false
  bullx_env(:oidc_state_ttl_seconds,
    key: [:plugins, :feishu, :oidc_state_ttl_seconds],
    type: :integer,
    default: 600,
    zoi: Zoi.integer(gte: 1)
  )
end
