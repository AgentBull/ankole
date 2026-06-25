defmodule FeishuOpenAPI.Request do
  @moduledoc """
  Turns a `FeishuOpenAPI.Client` and `FeishuOpenAPI.Spec` into final
  `Req.request/1` options.

  This module is the SDK's request assembly boundary. It resolves managed
  credentials, applies Feishu's URL conventions, merges headers and body
  encoders, and preserves the layering rule `client defaults -> request
  overrides` before the actual HTTP call happens.
  """

  alias FeishuOpenAPI.{Client, Error, Spec, TokenManager, UserTokenManager}

  @type req_opts :: keyword()

  @spec build(Client.t(), Spec.t()) :: {:ok, req_opts()} | {:error, Error.t()}
  def build(%Client{} = client, %Spec{} = spec) do
    with {:ok, auth_headers} <- resolve_auth(client, spec) do
      headers = auth_headers ++ client.headers ++ spec.headers
      url = build_url(client.base_url, spec.path)

      # Layering is deliberate: per-request overrides win over client defaults,
      # but `decode_body: false` is forced last and cannot be overridden. The
      # SDK decodes JSON itself (in FeishuOpenAPI.decode_json_body/1) so it can
      # tell a Feishu envelope / rate-limit body apart from a raw binary download
      # before interpreting it. Letting Req auto-decode would erase that signal.
      req_opts =
        [method: spec.method, url: url, headers: headers]
        |> maybe_put(:params, normalize_query(spec.query))
        |> put_body(spec)
        |> Keyword.merge(client.req_options)
        |> Keyword.merge(spec.req_options)
        |> Keyword.put(:decode_body, false)

      {:ok, req_opts}
    end
  end

  # --- auth ----------------------------------------------------------------

  defp resolve_auth(_client, %Spec{user_access_token: token}) when is_binary(token) do
    {:ok, bearer(token)}
  end

  defp resolve_auth(%Client{} = client, %Spec{user_access_token_key: key}) when is_binary(key) do
    with {:ok, token} <- UserTokenManager.get(client, key), do: {:ok, bearer(token)}
  end

  defp resolve_auth(_client, %Spec{access_token_type: :user_access_token}) do
    {:error,
     %Error{
       code: :user_access_token_missing,
       msg:
         "access_token_type: :user_access_token requires user_access_token: or user_access_token_key:"
     }}
  end

  defp resolve_auth(_client, %Spec{access_token_type: nil}), do: {:ok, []}

  defp resolve_auth(%Client{} = client, %Spec{access_token_type: :app_access_token}) do
    with {:ok, token} <- TokenManager.get_app_token(client), do: {:ok, bearer(token)}
  end

  defp resolve_auth(%Client{} = client, %Spec{
         access_token_type: :tenant_access_token,
         tenant_key: tenant_key
       }) do
    with {:ok, token} <- TokenManager.get_tenant_token(client, tenant_key),
         do: {:ok, bearer(token)}
  end

  defp bearer(token), do: [{"Authorization", "Bearer " <> token}]

  # --- URL -----------------------------------------------------------------

  defp build_url(base_url, path) when is_binary(path) do
    if String.match?(path, ~r/^https?:\/\//i) do
      path
    else
      base_url <> apply_open_apis_prefix(path)
    end
  end

  # Paths that already begin with `/` are passed through verbatim — this keeps
  # `/open-apis/...`, `/callback/ws/endpoint`, and any other absolute path
  # working. Paths that omit the leading slash but still carry the
  # `open-apis/` prefix just get normalized. Everything else (shorthand, e.g.
  # `contact/v3/users/me`) receives the `/open-apis/` prefix automatically.
  defp apply_open_apis_prefix(<<"/", _::binary>> = path), do: path
  defp apply_open_apis_prefix(<<"open-apis/", _::binary>> = path), do: "/" <> path
  defp apply_open_apis_prefix(path) when is_binary(path), do: "/open-apis/" <> path

  # --- body / query --------------------------------------------------------

  defp put_body(req_opts, %Spec{form_multipart: fm}) when fm != :unset do
    Keyword.put(req_opts, :form_multipart, fm)
  end

  # `:unset` is the sentinel for "no `:body` option was passed" — send no body
  # at all (e.g. GET/DELETE). An explicit `false`/`nil` body is different: the
  # caller asked to send that literal JSON value, so it is encoded and sent.
  defp put_body(req_opts, %Spec{body: :unset}), do: req_opts

  defp put_body(req_opts, %Spec{body: body}) when body in [false, nil] do
    req_opts
    |> Keyword.put(:body, Torque.encode!(body))
    |> ensure_json_content_type()
  end

  defp put_body(req_opts, %Spec{body: body}) do
    req_opts
    |> Keyword.put(:body, Torque.encode!(body))
    |> ensure_json_content_type()
  end

  defp ensure_json_content_type(req_opts) do
    headers = Keyword.get(req_opts, :headers, [])

    if Enum.any?(headers, &json_content_type_header?/1) do
      req_opts
    else
      Keyword.put(req_opts, :headers, headers ++ [{"content-type", "application/json"}])
    end
  end

  defp json_content_type_header?({key, _value}) when is_binary(key) do
    String.downcase(key) == "content-type"
  end

  defp json_content_type_header?(_), do: false

  defp normalize_query(nil), do: nil
  defp normalize_query(q) when is_map(q), do: Enum.to_list(q)
  defp normalize_query(q) when is_list(q), do: q

  defp maybe_put(list, _k, nil), do: list
  defp maybe_put(list, k, v), do: Keyword.put(list, k, v)
end
