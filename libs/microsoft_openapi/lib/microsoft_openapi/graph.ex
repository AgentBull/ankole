defmodule MicrosoftOpenAPI.Graph do
  @moduledoc """
  Microsoft Graph v1.0 request helpers.

  Relative paths are resolved under `{graph_base_url}/v1.0/`; absolute URLs
  (such as `@odata.nextLink`) pass through unchanged. Authentication defaults
  to a cached client-credentials token scoped to the Graph resource; pass
  `token: {:bearer, access_token}` to use a delegated token instead.
  """

  alias MicrosoftOpenAPI.Client
  alias MicrosoftOpenAPI.EntraAuth
  alias MicrosoftOpenAPI.Error

  @spec get(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get(%Client{} = client, path, opts \\ []), do: request(client, :get, path, opts)

  @spec post(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def post(%Client{} = client, path, opts \\ []), do: request(client, :post, path, opts)

  @spec patch(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def patch(%Client{} = client, path, opts \\ []), do: request(client, :patch, path, opts)

  @spec delete(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def delete(%Client{} = client, path, opts \\ []), do: request(client, :delete, path, opts)

  @spec default_scope(Client.t()) :: String.t()
  def default_scope(%Client{graph_base_url: graph_base_url}), do: graph_base_url <> "/.default"

  defp request(client, http_method, path, opts) do
    {token_opt, opts} = Keyword.pop(opts, :token)

    with {:ok, token} <- resolve_token(client, token_opt) do
      MicrosoftOpenAPI.request(
        http_method,
        build_url(client.graph_base_url, path),
        opts
        |> Keyword.put(:headers, MicrosoftOpenAPI.bearer_headers(token))
        |> Keyword.put(:req_options, merged_req_options(client, opts))
      )
    end
  end

  defp resolve_token(_client, {:bearer, token}) when is_binary(token), do: {:ok, token}

  defp resolve_token(client, nil),
    do: EntraAuth.client_credentials_token(client, scope: default_scope(client))

  defp build_url(_graph_base_url, "http://" <> _rest = url), do: url
  defp build_url(_graph_base_url, "https://" <> _rest = url), do: url

  defp build_url(graph_base_url, path),
    do: graph_base_url <> "/v1.0/" <> String.trim_leading(path, "/")

  defp merged_req_options(client, opts),
    do: Keyword.merge(client.req_options, Keyword.get(opts, :req_options, []))
end
