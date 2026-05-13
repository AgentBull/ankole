defmodule Discord.OAuth2Provider do
  @moduledoc """
  Principal login-provider implementation for Discord OAuth 2.0.

  The provider implementation id is `"discord"`; the concrete Principal
  `login_subject.provider` is the enabled Gateway source slug, so multiple
  Discord applications may coexist by configuring different sources.

  Discord OAuth2 is OAuth 2.0 not OIDC (no `id_token`). Userinfo is obtained
  from `GET /users/@me` with the access token as Bearer credential. The
  generic `BullX.Principals.LoginProvider` behaviour fits this shape because
  it returns a normalized login subject map.

  Access and refresh tokens are discarded after userinfo retrieval. Unverified
  Discord emails are dropped from the login subject.
  """

  @behaviour BullX.Principals.LoginProvider

  alias BullX.Gateway.SourceConfig
  alias Discord.{Error, Source}

  @authorize_url "https://discord.com/oauth2/authorize"
  @token_url "https://discord.com/api/oauth2/token"
  @user_url "https://discord.com/api/users/@me"

  @impl BullX.Principals.LoginProvider
  def authorization_url(%SourceConfig{} = source_config, request) when is_map(request) do
    with {:ok, source} <- Source.normalize(source_config),
         :ok <- ensure_oauth2_enabled(source),
         {:ok, redirect_uri} <- redirect_uri(source, request),
         state <- authorization_state(source, request),
         {:ok, state_param} <- state_param(request, state) do
      {:ok, %{url: build_authorization_url(source, redirect_uri, state_param), state: state}}
    end
  end

  @impl BullX.Principals.LoginProvider
  def callback(%SourceConfig{} = source_config, params, state)
      when is_map(params) and is_map(state) do
    with {:ok, source} <- Source.normalize(source_config),
         :ok <- ensure_oauth2_enabled(source),
         :ok <- validate_state(source, state),
         {:ok, code} <- required_param(params, "code"),
         {:ok, redirect_uri} <- redirect_uri(source, state),
         {:ok, tokens} <- exchange_code(source, code, redirect_uri),
         {:ok, userinfo} <- fetch_userinfo(source, tokens["access_token"]),
         {:ok, subject} <- login_subject(source, userinfo) do
      {:ok, subject}
    else
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.map(reason)}
    end
  end

  defp ensure_oauth2_enabled(%Source{} = source) do
    case Source.oauth2_enabled?(source) do
      true -> :ok
      false -> {:error, Error.config("Discord OAuth2 is disabled")}
    end
  end

  defp redirect_uri(%Source{} = source, map) do
    with :error <- string_value(map, "redirect_uri"),
         :error <- string_value(map, :redirect_uri) do
      case Source.oauth2_redirect_uri(source) do
        uri when is_binary(uri) and uri != "" -> {:ok, uri}
        _other -> {:error, Error.config("Discord OAuth2 redirect_uri is required")}
      end
    else
      {:ok, uri} -> {:ok, uri}
    end
  end

  defp authorization_state(%Source{} = source, request) do
    return_to = request |> value("return_to") |> local_return_to()

    %{
      "provider" => source.channel_id,
      "adapter" => "discord",
      "channel_id" => source.channel_id,
      "return_to" => return_to,
      "issued_at" => System.system_time(:second),
      "nonce" => nonce()
    }
  end

  defp state_param(request, state) do
    with :error <- string_value(request, "state_token"),
         :error <- string_value(request, :state_token),
         :error <- string_value(request, "signed_state"),
         :error <- string_value(request, :signed_state),
         :error <- string_value(request, "state"),
         :error <- string_value(request, :state) do
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

    @authorize_url <> "?" <> query
  end

  defp validate_state(%Source{} = source, state) do
    cond do
      value(state, "adapter") != "discord" ->
        {:error, Error.payload("invalid Discord OAuth2 state")}

      value(state, "provider") != source.channel_id ->
        {:error, Error.payload("Discord OAuth2 provider mismatch")}

      value(state, "channel_id") != source.channel_id ->
        {:error, Error.payload("Discord OAuth2 channel mismatch")}

      not present?(value(state, "nonce")) ->
        {:error, Error.payload("invalid Discord OAuth2 state")}

      expired?(state) ->
        {:error, Error.payload("Discord OAuth2 state expired")}

      not local_return_to?(value(state, "return_to")) ->
        {:error, Error.payload("invalid Discord OAuth2 return_to")}

      true ->
        :ok
    end
  end

  defp expired?(state) do
    case value(state, "issued_at") do
      issued_at when is_integer(issued_at) ->
        System.system_time(:second) - issued_at > Discord.Config.oauth2_state_ttl_seconds!()

      _other ->
        true
    end
  end

  defp exchange_code(%Source{} = source, code, redirect_uri) do
    body = %{
      "client_id" => source.application_id,
      "client_secret" => Source.secret_value(source.client_secret),
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri
    }

    [url: @token_url, form: body]
    |> Keyword.merge(source.req_options)
    |> Req.post()
    |> case do
      {:ok, %{__struct__: Req.Response, status: status, body: body}}
      when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, response} ->
        {:error, Error.map(response)}

      {:error, error} ->
        {:error, Error.map(error)}
    end
  end

  defp fetch_userinfo(%Source{}, nil), do: {:error, Error.payload("missing Discord access token")}

  defp fetch_userinfo(%Source{} = source, access_token) do
    [url: @user_url, auth: {:bearer, access_token}]
    |> Keyword.merge(source.req_options)
    |> Req.get()
    |> case do
      {:ok, %{__struct__: Req.Response, status: status, body: body}}
      when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, response} ->
        {:error, Error.map(response)}

      {:error, error} ->
        {:error, Error.map(error)}
    end
  end

  defp login_subject(%Source{} = source, userinfo) when is_map(userinfo) do
    case Map.get(userinfo, "id") do
      id when is_binary(id) and id != "" ->
        {:ok,
         %{
           "provider" => source.channel_id,
           "external_id" => "discord:" <> id,
           "profile" => profile(userinfo),
           "metadata" =>
             %{
               "adapter" => "discord",
               "channel_id" => source.channel_id,
               "application_id" => source.application_id,
               "verified_email" => verified_email?(userinfo),
               "locale" => Map.get(userinfo, "locale")
             }
             |> reject_nil_values()
         }}

      _other ->
        {:error, Error.payload("Discord userinfo is missing id")}
    end
  end

  defp profile(userinfo) do
    %{}
    |> maybe_put("display_name", first_string(userinfo, ["global_name", "username"]))
    |> maybe_put("global_name", Map.get(userinfo, "global_name"))
    |> maybe_put("username", Map.get(userinfo, "username"))
    |> maybe_put("email", verified_email(userinfo))
    |> maybe_put("avatar_url", avatar_url(userinfo))
    |> maybe_put("user_id", Map.get(userinfo, "id"))
  end

  defp verified_email(%{"verified" => true, "email" => email})
       when is_binary(email) and email != "" do
    email |> String.trim() |> String.downcase()
  end

  defp verified_email(_userinfo), do: nil

  defp verified_email?(userinfo), do: not is_nil(verified_email(userinfo))

  defp avatar_url(%{"id" => id, "avatar" => avatar}) when is_binary(id) and is_binary(avatar) do
    "https://cdn.discordapp.com/avatars/#{id}/#{avatar}.webp"
  end

  defp avatar_url(_userinfo), do: nil

  defp first_string(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) and value != "" -> value
        _other -> nil
      end
    end)
  end

  defp required_param(params, key) do
    case string_value(params, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, Error.payload("missing Discord OAuth2 callback code")}
    end
  end

  defp local_return_to(nil), do: "/"

  defp local_return_to(value) when is_binary(value) do
    case local_return_to?(value) do
      true -> value
      false -> "/"
    end
  end

  defp local_return_to?("/" <> _path), do: true
  defp local_return_to?(_value), do: false

  defp present?(value), do: is_binary(value) and value != ""

  defp string_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> :error
    end
  end

  defp value(map, key) do
    Map.get(map, key) || Map.get(map, to_atom(key))
  end

  defp to_atom(key) when is_atom(key), do: key
  defp to_atom(key) when is_binary(key), do: String.to_atom(key)

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
