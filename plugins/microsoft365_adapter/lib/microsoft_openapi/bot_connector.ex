defmodule MicrosoftOpenAPI.BotConnector do
  @moduledoc """
  Bot Framework Connector REST helpers.

  Every call targets the service URL learned from inbound activities and
  authenticates with a cached client-credentials token for the Bot Framework
  resource. The token tenant comes from `Client.bot_token_tenant`: the bot's
  own tenant for single-tenant apps or `"botframework.com"` for multi-tenant
  apps.
  """

  alias MicrosoftOpenAPI.Client
  alias MicrosoftOpenAPI.EntraAuth
  alias MicrosoftOpenAPI.Error

  @bot_framework_scope "https://api.botframework.com/.default"

  @spec post_activity(Client.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def post_activity(%Client{} = client, service_url, conversation_id, activity)
      when is_binary(service_url) and is_binary(conversation_id) and is_map(activity) do
    request(
      client,
      :post,
      conversation_url(service_url, conversation_id) <> "/activities",
      body: activity
    )
  end

  @spec update_activity(Client.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def update_activity(%Client{} = client, service_url, conversation_id, activity_id, activity)
      when is_binary(service_url) and is_binary(conversation_id) and is_binary(activity_id) and
             is_map(activity) do
    request(
      client,
      :put,
      conversation_url(service_url, conversation_id) <>
        "/activities/" <> encode_segment(activity_id),
      body: activity
    )
  end

  @spec delete_activity(Client.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def delete_activity(%Client{} = client, service_url, conversation_id, activity_id)
      when is_binary(service_url) and is_binary(conversation_id) and is_binary(activity_id) do
    request(
      client,
      :delete,
      conversation_url(service_url, conversation_id) <>
        "/activities/" <> encode_segment(activity_id),
      []
    )
  end

  @spec create_conversation(Client.t(), String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def create_conversation(%Client{} = client, service_url, params)
      when is_binary(service_url) and is_map(params) do
    request(client, :post, base_url(service_url) <> "/v3/conversations", body: params)
  end

  @spec list_team_channels(Client.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def list_team_channels(%Client{} = client, service_url, team_id)
      when is_binary(service_url) and is_binary(team_id) do
    request(
      client,
      :get,
      base_url(service_url) <> "/v3/teams/" <> encode_segment(team_id) <> "/conversations",
      []
    )
  end

  @doc """
  Lazily streams conversation members through `pagedmembers` continuation.
  """
  @spec stream_paged_members(Client.t(), String.t(), String.t(), keyword()) :: Enumerable.t()
  def stream_paged_members(%Client{} = client, service_url, conversation_id, opts \\ []) do
    page_size = Keyword.get(opts, :page_size)
    url = conversation_url(service_url, conversation_id) <> "/pagedmembers"

    Stream.resource(
      fn -> {:page, nil} end,
      fn
        :done ->
          {:halt, :done}

        {:page, continuation_token} ->
          query =
            []
            |> maybe_put(:pageSize, page_size)
            |> maybe_put(:continuationToken, continuation_token)

          case request(client, :get, url, query: query) do
            {:ok, body} ->
              members = Map.get(body, "members") || []

              next =
                case Map.get(body, "continuationToken") do
                  token when is_binary(token) and token != "" -> {:page, token}
                  _absent -> :done
                end

              {Enum.map(members, &{:ok, &1}), next}

            {:error, %Error{} = error} ->
              {[{:error, error}], :done}
          end
      end,
      fn _state -> :ok end
    )
  end

  @spec token(Client.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def token(%Client{} = client) do
    EntraAuth.client_credentials_token(client,
      scope: @bot_framework_scope,
      tenant: client.bot_token_tenant || client.tenant_id
    )
  end

  defp request(client, http_method, url, opts) do
    with {:ok, token} <- token(client) do
      MicrosoftOpenAPI.request(
        http_method,
        url,
        opts
        |> Keyword.put(:headers, MicrosoftOpenAPI.bearer_headers(token))
        |> Keyword.put(:req_options, client.req_options)
      )
    end
  end

  defp conversation_url(service_url, conversation_id),
    do: base_url(service_url) <> "/v3/conversations/" <> encode_segment(conversation_id)

  defp base_url(service_url), do: String.trim_trailing(service_url, "/")

  defp encode_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp maybe_put(query, _key, nil), do: query
  defp maybe_put(query, key, value), do: Keyword.put(query, key, value)
end
