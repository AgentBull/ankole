defmodule Discord.OAuth2Provider do
  @moduledoc """
  Principal login-provider implementation for Discord OAuth2.

  The extension id is `discord`; concrete login provider ids are enabled
  Discord source ids.
  """

  @behaviour BullX.Principals.LoginProvider

  alias Discord.Source

  import BullX.Utils.Map, only: [maybe_put: 3, reject_nil_values: 1]

  @impl BullX.Principals.LoginProvider
  def fetch_source(provider_id), do: fetch_oauth2_source(provider_id)

  @spec provider_ids() :: [String.t()]
  def provider_ids do
    case Source.enabled_sources() do
      {:ok, sources} -> sources |> Enum.filter(&Source.oauth2_enabled?/1) |> Enum.map(& &1.id)
      {:error, _reason} -> []
    end
  end

  @impl BullX.Principals.LoginProvider
  def state_ttl_seconds(_source), do: Discord.Config.oauth2_state_ttl_seconds!()

  @impl BullX.Principals.LoginProvider
  def authorization_url(%Source{} = source, request) when is_map(request) do
    with :ok <- ensure_oauth2_enabled(source),
         {:ok, redirect_uri} <- redirect_uri(source, request),
         state <- authorization_state(source, request),
         {:ok, state_param} <- state_param(request, state) do
      {:ok, %{url: build_authorization_url(source, redirect_uri, state_param), state: state}}
    end
  end

  def authorization_url(source_config, request) when is_map(source_config) and is_map(request) do
    with {:ok, source} <- Source.normalize(source_config) do
      authorization_url(source, request)
    end
  end

  @impl BullX.Principals.LoginProvider
  def callback(%Source{} = source, params, state) when is_map(params) and is_map(state) do
    with :ok <- ensure_oauth2_enabled(source),
         :ok <- validate_state(source, state),
         {:ok, code} <- required_param(params, "code"),
         {:ok, redirect_uri} <- redirect_uri(source, state),
         {:ok, tokens} <-
           Source.request(source, :exchange_oauth_code, %{"code" => code, "redirect_uri" => redirect_uri}),
         {:ok, access_token} <- required_param(tokens, "access_token"),
         {:ok, userinfo} <- Source.request(source, :fetch_userinfo, %{"access_token" => access_token}),
         {:ok, subject} <- login_subject(source, userinfo) do
      {:ok, subject}
    else
      {:error, %{} = error} -> {:error, Discord.Error.map(error)}
      {:error, reason} -> {:error, Discord.Error.map(reason)}
    end
  end

  def callback(source_config, params, state) when is_map(source_config) do
    with {:ok, source} <- Source.normalize(source_config) do
      callback(source, params, state)
    end
  end

  defp fetch_oauth2_source(provider_id) do
    with {:ok, source} <- Source.fetch_enabled_source(provider_id),
         :ok <- ensure_oauth2_enabled(source) do
      {:ok, source}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, %{} = error} -> {:error, error}
    end
  end

  defp ensure_oauth2_enabled(%Source{} = source) do
    case Source.oauth2_enabled?(source) do
      true -> :ok
      false -> {:error, Discord.Error.config("Discord OAuth2 is disabled")}
    end
  end

  defp redirect_uri(%Source{} = source, map) do
    case string_value(map, "redirect_uri") do
      {:ok, uri} ->
        {:ok, uri}

      :error ->
        case Source.oauth2_redirect_uri(source) do
          uri when is_binary(uri) and uri != "" -> {:ok, uri}
          _uri -> {:error, Discord.Error.config("Discord OAuth2 redirect_uri is required")}
        end
    end
  end

  defp authorization_state(%Source{} = source, request) do
    %{
      "provider" => source.id,
      "adapter" => "discord",
      "source_id" => source.id,
      "return_to" => request |> value("return_to") |> local_return_to(),
      "redirect_uri" => value(request, "redirect_uri"),
      "issued_at" => System.system_time(:second),
      "nonce" => nonce()
    }
    |> reject_nil_values()
  end

  defp state_param(request, state) do
    with :error <- string_value(request, "state_token"),
         :error <- string_value(request, "signed_state"),
         :error <- string_value(request, "state") do
      {:ok, state["nonce"]}
    else
      {:ok, token} -> {:ok, token}
    end
  end

  defp build_authorization_url(%Source{} = source, redirect_uri, state_param) do
    query =
      URI.encode_query(%{
        "client_id" => source.application_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => Enum.join(Source.oauth2_scopes(source), " "),
        "state" => state_param
      })

    "https://discord.com/oauth2/authorize?" <> query
  end

  defp validate_state(%Source{} = source, state) do
    cond do
      value(state, "adapter") != "discord" ->
        {:error, Discord.Error.payload("invalid Discord OAuth2 state")}

      value(state, "provider") != source.id ->
        {:error, Discord.Error.payload("Discord OAuth2 provider mismatch")}

      value(state, "source_id") != source.id ->
        {:error, Discord.Error.payload("Discord OAuth2 source mismatch")}

      not present?(value(state, "nonce")) ->
        {:error, Discord.Error.payload("invalid Discord OAuth2 state")}

      expired?(state) ->
        {:error, Discord.Error.payload("Discord OAuth2 state expired")}

      not local_return_to?(value(state, "return_to")) ->
        {:error, Discord.Error.payload("invalid Discord OAuth2 return_to")}

      true ->
        :ok
    end
  end

  defp expired?(state) do
    case value(state, "issued_at") do
      issued_at when is_integer(issued_at) ->
        System.system_time(:second) - issued_at > Discord.Config.oauth2_state_ttl_seconds!()

      _issued_at ->
        true
    end
  end

  defp login_subject(%Source{} = source, userinfo) do
    case value(userinfo, "id") do
      id when is_binary(id) and id != "" ->
        {:ok,
         %{
           "provider" => source.id,
           "external_id" => "discord:" <> id,
           "profile" => profile(userinfo, id),
           "metadata" =>
             %{
               "adapter" => "discord",
               "channel_id" => source.id,
               "application_id" => source.application_id,
               "verified_email" => value(userinfo, "verified") == true,
               "locale" => value(userinfo, "locale")
             }
             |> reject_nil_values()
         }}

      _value ->
        {:error, Discord.Error.payload("Discord userinfo is missing id")}
    end
  end

  defp profile(userinfo, id) do
    %{}
    |> maybe_put("display_name", first_present([value(userinfo, "global_name"), value(userinfo, "username"), "discord:" <> id]))
    |> maybe_put("global_name", value(userinfo, "global_name"))
    |> maybe_put("username", value(userinfo, "username"))
    |> maybe_put("email", verified_email(userinfo))
    |> maybe_put("avatar_url", avatar_url(userinfo, id))
    |> maybe_put("user_id", id)
  end

  defp verified_email(userinfo) do
    case value(userinfo, "verified") == true do
      true -> normalized_email(value(userinfo, "email"))
      false -> nil
    end
  end

  defp avatar_url(userinfo, id) do
    case value(userinfo, "avatar") do
      avatar when is_binary(avatar) and avatar != "" -> "https://cdn.discordapp.com/avatars/#{id}/#{avatar}.png"
      _value -> nil
    end
  end

  defp required_param(map, key) do
    case value(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, Discord.Error.payload("missing Discord OAuth2 #{key}")}
    end
  end

  defp string_value(map, key) do
    case value(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> :error
    end
  end

  defp value(%{} = map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
  defp value(_map, _key), do: nil
  defp nonce, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  defp local_return_to(nil), do: "/"
  defp local_return_to("/" <> _path = path), do: path
  defp local_return_to(_value), do: "/"
  defp local_return_to?("/" <> _path), do: true
  defp local_return_to?(_value), do: false
  defp present?(value), do: is_binary(value) and value != ""
  defp normalized_email(nil), do: nil
  defp normalized_email(email), do: email |> String.trim() |> String.downcase()
  defp first_present(values), do: Enum.find(values, &(is_binary(&1) and &1 != ""))
end
