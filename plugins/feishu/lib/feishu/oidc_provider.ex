defmodule Feishu.OIDCProvider do
  @moduledoc """
  Principal login-provider implementation for Feishu/Lark OIDC.

  The extension id is `feishu`; the concrete Principal login provider is the
  enabled Feishu source id, so a deployment can expose several Feishu realms
  without inventing BullX tenants.
  """

  @behaviour BullX.Principals.LoginProvider

  alias Feishu.{Source, UserInfo}
  alias FeishuOpenAPI.Auth

  import BullX.Utils.Map, only: [reject_nil_values: 1]

  @impl BullX.Principals.LoginProvider
  def fetch_source(provider_id), do: fetch_oidc_source(provider_id)

  @spec provider_ids() :: [String.t()]
  def provider_ids do
    case Source.enabled_sources() do
      {:ok, sources} ->
        sources
        |> Enum.filter(&Source.oidc_enabled?/1)
        |> Enum.map(& &1.id)

      {:error, _reason} ->
        []
    end
  end

  @spec provider_options() :: [map()]
  def provider_options do
    case Source.enabled_sources() do
      {:ok, sources} ->
        sources
        |> Enum.filter(&Source.oidc_enabled?/1)
        |> Enum.map(&provider_option/1)

      {:error, _reason} ->
        []
    end
  end

  @impl BullX.Principals.LoginProvider
  def state_ttl_seconds(_source), do: Feishu.Config.oidc_state_ttl_seconds!()

  @impl BullX.Principals.LoginProvider
  def authorization_url(%Source{} = source, request) when is_map(request) do
    with :ok <- ensure_oidc_enabled(source),
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
    with :ok <- ensure_oidc_enabled(source),
         :ok <- validate_state(source, state),
         {:ok, code} <- required_param(params, "code"),
         {:ok, redirect_uri} <- redirect_uri(source, state),
         {:ok, tokens} <-
           Auth.user_access_token(Source.client!(source), code, redirect_uri: redirect_uri),
         {:ok, userinfo} <- contact_userinfo(source, tokens),
         :ok <- cache_user_token(source, userinfo, tokens),
         {:ok, subject} <- login_subject(source, userinfo) do
      {:ok, subject}
    else
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, Feishu.Error.map(reason)}
    end
  end

  def callback(source_config, params, state) when is_map(source_config) do
    with {:ok, source} <- Source.normalize(source_config) do
      callback(source, params, state)
    end
  end

  defp fetch_oidc_source(provider_id) do
    with {:ok, source} <- Source.fetch_enabled_source(provider_id),
         :ok <- ensure_oidc_enabled(source) do
      {:ok, source}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, %{} = error} -> {:error, error}
    end
  end

  defp ensure_oidc_enabled(%Source{} = source) do
    cond do
      not Source.web_login_enabled?(source) ->
        {:error, Feishu.Error.config("Feishu web login is disabled")}

      Source.oidc_enabled?(source) ->
        :ok

      true ->
        {:error, Feishu.Error.config("Feishu OIDC is disabled")}
    end
  end

  defp redirect_uri(%Source{} = source, map) do
    with :error <- string_value(map, "redirect_uri") do
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
      "provider" => source.id,
      "adapter" => "feishu",
      "source_id" => source.id,
      "return_to" => return_to,
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

  defp provider_option(%Source{} = source) do
    %{
      id: source.id,
      provider: "feishu",
      source_id: source.id,
      label: provider_label(source)
    }
  end

  defp provider_label(%Source{domain: :lark, id: id}), do: "Lark · #{id}"
  defp provider_label(%Source{id: id}), do: "Feishu · #{id}"

  defp validate_state(%Source{} = source, state) do
    cond do
      value(state, "adapter") != "feishu" ->
        {:error, Feishu.Error.payload("invalid Feishu OIDC state")}

      value(state, "provider") != source.id ->
        {:error, Feishu.Error.payload("Feishu OIDC provider mismatch")}

      value(state, "source_id") != source.id ->
        {:error, Feishu.Error.payload("Feishu OIDC source mismatch")}

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

  defp contact_userinfo(%Source{} = source, tokens) when is_map(tokens) do
    case token_user_ref(tokens) do
      {:ok, id_type, user_id, token_userinfo} ->
        fetch_contact_userinfo(source, id_type, user_id, token_userinfo)

      :error ->
        fetch_contact_userinfo_by_authn_userinfo(source, tokens)
    end
  end

  defp fetch_contact_userinfo(%Source{} = source, id_type, user_id, token_userinfo) do
    with {:ok, contact_userinfo} <- UserInfo.fetch_contact(source, user_id, id_type),
         :ok <- validate_contact_ref(contact_userinfo, id_type, user_id),
         {:ok, canonical_user_id} <- UserInfo.user_id(contact_userinfo) do
      {:ok, merge_userinfo(token_userinfo, contact_userinfo, canonical_user_id)}
    end
  end

  defp fetch_contact_userinfo_by_authn_userinfo(%Source{} = source, tokens) do
    with {:ok, authn_userinfo} <- UserInfo.fetch_authn(source, tokens.access_token),
         {:ok, id_type, user_id, authn_userinfo} <- authn_user_ref(authn_userinfo) do
      fetch_contact_userinfo(source, id_type, user_id, authn_userinfo)
    end
  end

  defp token_user_ref(tokens) do
    token_userinfo = token_userinfo(tokens)

    case present_string(value(token_userinfo, "user_id")) do
      user_id when is_binary(user_id) ->
        {:ok, "user_id", user_id, token_userinfo}

      nil ->
        token_open_id_ref(token_userinfo)
    end
  end

  defp token_open_id_ref(token_userinfo) do
    case present_string(value(token_userinfo, "open_id") || value(token_userinfo, "sub")) do
      open_id when is_binary(open_id) -> {:ok, "open_id", open_id, token_userinfo}
      nil -> :error
    end
  end

  defp authn_user_ref(userinfo) do
    case token_user_ref(%{raw: userinfo}) do
      {:ok, _id_type, _user_id, _userinfo} = ok ->
        ok

      :error ->
        {:error, Feishu.Error.payload("Feishu userinfo is missing user_id")}
    end
  end

  defp token_userinfo(tokens) do
    tokens
    |> value("raw")
    |> case do
      raw when is_map(raw) -> raw
      _other -> %{}
    end
  end

  defp merge_userinfo(identity_userinfo, contact_userinfo, user_id) do
    contact_userinfo
    |> Map.put_new("user_id", user_id)
    |> Map.put_new("tenant_key", value(identity_userinfo, "tenant_key"))
  end

  defp validate_contact_ref(userinfo, "user_id", user_id) do
    case value(userinfo, "user_id") do
      ^user_id -> :ok
      nil -> :ok
      _other_user_id -> {:error, Feishu.Error.payload("Feishu contact user mismatch")}
    end
  end

  defp validate_contact_ref(userinfo, "open_id", open_id) do
    case value(userinfo, "open_id") || value(userinfo, "sub") do
      ^open_id -> :ok
      nil -> :ok
      _other_open_id -> {:error, Feishu.Error.payload("Feishu contact user mismatch")}
    end
  end

  defp validate_contact_ref(userinfo, "union_id", union_id) do
    case value(userinfo, "union_id") do
      ^union_id -> :ok
      nil -> :ok
      _other_union_id -> {:error, Feishu.Error.payload("Feishu contact user mismatch")}
    end
  end

  defp login_subject(%Source{} = source, userinfo) when is_map(userinfo) do
    case UserInfo.user_id(userinfo) do
      {:ok, user_id} ->
        {:ok,
         %{
           "provider" => source.id,
           "external_id" => "feishu:user_id:" <> user_id,
           "profile" => UserInfo.profile(userinfo),
           "metadata" =>
             %{
               "adapter" => "feishu",
               "source_id" => source.id,
               "app_id" => source.app_id,
               "tenant_key" => Map.get(userinfo, "tenant_key") || source.tenant_key,
               "domain" => Atom.to_string(source.domain)
             }
             |> reject_nil_values()
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp cache_user_token(%Source{} = source, userinfo, tokens) do
    client = Source.client!(source)

    :ok = cache_user_id_token(client, UserInfo.user_id(userinfo), tokens)
    :ok = cache_open_id_token(client, UserInfo.open_id(userinfo), tokens)
  end

  defp cache_user_id_token(client, {:ok, user_id}, tokens) do
    :ok = FeishuOpenAPI.UserTokenManager.put(client, user_id, tokens)
    :ok = FeishuOpenAPI.UserTokenManager.put(client, "feishu:user_id:" <> user_id, tokens)
  end

  defp cache_user_id_token(_client, {:error, _error}, _tokens), do: :ok

  defp cache_open_id_token(client, {:ok, open_id}, tokens) do
    :ok = FeishuOpenAPI.UserTokenManager.put(client, open_id, tokens)
    :ok = FeishuOpenAPI.UserTokenManager.put(client, "feishu:" <> open_id, tokens)
  end

  defp cache_open_id_token(_client, {:error, _error}, _tokens), do: :ok

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

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_string(_value), do: nil

  defp string_value(map, key) do
    case value(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> :error
    end
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, known_atom_key(key))
  end

  defp value(_map, _key), do: nil

  defp known_atom_key("adapter"), do: :adapter
  defp known_atom_key("code"), do: :code
  defp known_atom_key("issued_at"), do: :issued_at
  defp known_atom_key("nonce"), do: :nonce
  defp known_atom_key("open_id"), do: :open_id
  defp known_atom_key("provider"), do: :provider
  defp known_atom_key("redirect_uri"), do: :redirect_uri
  defp known_atom_key("raw"), do: :raw
  defp known_atom_key("return_to"), do: :return_to
  defp known_atom_key("signed_state"), do: :signed_state
  defp known_atom_key("source_id"), do: :source_id
  defp known_atom_key("sub"), do: :sub
  defp known_atom_key("state"), do: :state
  defp known_atom_key("state_token"), do: :state_token
  defp known_atom_key("tenant_key"), do: :tenant_key
  defp known_atom_key("user_id"), do: :user_id
  defp known_atom_key(_key), do: nil

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
end
