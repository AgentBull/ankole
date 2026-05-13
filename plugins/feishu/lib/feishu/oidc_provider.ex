defmodule Feishu.OIDCProvider do
  @moduledoc """
  Principal login-provider implementation for Feishu/Lark OIDC.

  The provider implementation id is `feishu`; the concrete Principal
  `login_subject.provider` is the enabled Gateway source slug.
  """

  @behaviour BullX.Principals.LoginProvider

  alias BullX.Gateway.SourceConfig
  alias Feishu.Source
  alias FeishuOpenAPI.Auth

  @impl BullX.Principals.LoginProvider
  def authorization_url(%SourceConfig{} = source, request) when is_map(request) do
    with {:ok, source} <- Source.normalize(source),
         :ok <- ensure_oidc_enabled(source),
         {:ok, redirect_uri} <- redirect_uri(source, request),
         state <- authorization_state(source, request),
         {:ok, state_param} <- state_param(request, state) do
      {:ok, %{url: build_authorization_url(source, redirect_uri, state_param), state: state}}
    end
  end

  @impl BullX.Principals.LoginProvider
  def callback(%SourceConfig{} = source, params, state)
      when is_map(params) and is_map(state) do
    with {:ok, source} <- Source.normalize(source),
         :ok <- ensure_oidc_enabled(source),
         :ok <- validate_state(source, state),
         {:ok, code} <- required_param(params, "code"),
         {:ok, redirect_uri} <- redirect_uri(source, state),
         {:ok, tokens} <-
           Auth.user_access_token(Source.client!(source), code, redirect_uri: redirect_uri),
         {:ok, userinfo} <- fetch_userinfo(source, tokens.access_token),
         {:ok, subject} <- login_subject(source, userinfo) do
      {:ok, subject}
    else
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, Feishu.Error.map(reason)}
    end
  end

  defp ensure_oidc_enabled(%Source{} = source) do
    case Source.oidc_enabled?(source) do
      true -> :ok
      false -> {:error, Feishu.Error.config("Feishu OIDC is disabled")}
    end
  end

  defp redirect_uri(%Source{} = source, map) do
    with :error <- string_value(map, "redirect_uri"),
         :error <- string_value(map, :redirect_uri) do
      case Source.oidc_redirect_uri(source) do
        uri when is_binary(uri) and uri != "" -> {:ok, uri}
        _uri -> {:error, Feishu.Error.config("Feishu OIDC redirect_uri is required")}
      end
    else
      {:ok, uri} -> {:ok, uri}
    end
  end

  defp authorization_state(%Source{} = source, request) do
    return_to =
      request
      |> value("return_to")
      |> local_return_to()

    %{
      "provider" => source.channel_id,
      "adapter" => "feishu",
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
        "client_id" => source.app_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => Enum.join(Source.oidc_scopes(source), " "),
        "state" => state_param
      })

    authorize_base(source.domain) <> "/open-apis/authen/v1/authorize?" <> query
  end

  defp authorize_base(:feishu), do: "https://accounts.feishu.cn"
  defp authorize_base(:lark), do: "https://accounts.larksuite.com"

  defp validate_state(%Source{} = source, state) do
    cond do
      value(state, "adapter") != "feishu" ->
        {:error, Feishu.Error.payload("invalid Feishu OIDC state")}

      value(state, "provider") != source.channel_id ->
        {:error, Feishu.Error.payload("Feishu OIDC provider mismatch")}

      value(state, "channel_id") != source.channel_id ->
        {:error, Feishu.Error.payload("Feishu OIDC channel mismatch")}

      not present?(value(state, "nonce")) ->
        {:error, Feishu.Error.payload("invalid Feishu OIDC state")}

      expired?(state) ->
        {:error, Feishu.Error.payload("Feishu OIDC state expired")}

      not local_return_to?(value(state, "return_to")) ->
        {:error, Feishu.Error.payload("invalid Feishu OIDC return_to")}

      true ->
        :ok
    end
  end

  defp expired?(state) do
    case value(state, "issued_at") do
      issued_at when is_integer(issued_at) ->
        System.system_time(:second) - issued_at > Feishu.Config.oidc_state_ttl_seconds!()

      _issued_at ->
        true
    end
  end

  defp fetch_userinfo(%Source{} = source, access_token) do
    case FeishuOpenAPI.get(Source.client!(source), "/open-apis/authen/v1/user_info",
           user_access_token: access_token
         ) do
      {:ok, %{"data" => data}} when is_map(data) -> {:ok, data}
      {:ok, data} when is_map(data) -> {:ok, data}
      {:error, error} -> {:error, Feishu.Error.map(error)}
    end
  end

  defp login_subject(%Source{} = source, userinfo) when is_map(userinfo) do
    case Map.get(userinfo, "open_id") do
      open_id when is_binary(open_id) and open_id != "" ->
        {:ok,
         %{
           "provider" => source.channel_id,
           "external_id" => "feishu:" <> open_id,
           "profile" => profile(userinfo),
           "metadata" =>
             %{
               "adapter" => "feishu",
               "channel_id" => source.channel_id,
               "app_id" => source.app_id,
               "tenant_key" => Map.get(userinfo, "tenant_key") || source.tenant_key,
               "domain" => Atom.to_string(source.domain)
             }
             |> reject_nil_values()
         }}

      _value ->
        {:error, Feishu.Error.payload("Feishu userinfo is missing open_id")}
    end
  end

  defp profile(userinfo) do
    %{}
    |> maybe_put("display_name", first_string(userinfo, ["name", "display_name", "en_name"]))
    |> maybe_put("email", normalized_email(first_string(userinfo, ["email"])))
    |> maybe_put_phone(first_string(userinfo, ["mobile", "phone"]))
    |> maybe_put(
      "avatar_url",
      first_string(userinfo, ["avatar_url", "avatar_thumb", "avatar_middle"])
    )
    |> maybe_put("open_id", Map.get(userinfo, "open_id"))
    |> maybe_put("union_id", Map.get(userinfo, "union_id"))
    |> maybe_put("user_id", Map.get(userinfo, "user_id"))
  end

  defp first_string(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) and value != "" -> value
        _value -> nil
      end
    end)
  end

  defp normalized_email(nil), do: nil
  defp normalized_email(email), do: email |> String.trim() |> String.downcase()

  defp maybe_put_phone(map, nil), do: map

  defp maybe_put_phone(map, phone) do
    phone
    |> phone_candidates()
    |> Enum.find_value(fn candidate ->
      case BullX.Ext.phone_normalize_e164(candidate) do
        normalized when is_binary(normalized) -> normalized
        _other -> nil
      end
    end)
    |> case do
      nil -> map
      normalized -> Map.put(map, "phone", normalized)
    end
  end

  defp phone_candidates(phone) do
    trimmed = String.trim(phone)
    digits = String.replace(trimmed, ~r/\D/, "")

    case String.length(digits) == 11 and String.starts_with?(digits, "1") do
      true -> [trimmed, "+86" <> digits]
      false -> [trimmed]
    end
  end

  defp required_param(params, key) do
    case string_value(params, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, Feishu.Error.payload("missing Feishu OIDC callback code")}
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
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
