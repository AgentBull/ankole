defmodule DingTalkOpenAPI.TokenManager do
  @moduledoc """
  Per-app token fetch for DingTalk app access tokens.

  DingTalk enterprise-internal apps have a single token type: the app access
  token, obtained from `POST /v1.0/oauth2/accessToken` with `{appKey,
  appSecret}` and valid for `expireIn` seconds (nominally 7200). Both API
  domains share the same token value.

  ## Topology

  One fetch process per credential set (keyed by `Client.cache_namespace/1`),
  registered in `DingTalkOpenAPI.TokenRegistry` and supervised by
  `DingTalkOpenAPI.TokenManager.Supervisor`. Processes start lazily on the first
  token miss. The ETS table (`DingTalkOpenAPI.TokenStore`) is shared across all
  managers. Reads are lock-free. Misses go through `IMTransport.TokenCache`,
  which coalesces a concurrent burst into a single upstream fetch. This module
  owns the DingTalk token request.
  """

  alias DingTalkOpenAPI.{Client, Error, TokenStore}
  alias IMTransport.TokenCache

  @token_path "/v1.0/oauth2/accessToken"

  @type key :: {:app, Client.cache_namespace()}

  @doc false
  @spec start_link(Client.t()) :: GenServer.on_start()
  def start_link(%Client{} = client) do
    TokenCache.start_link(
      name: via_tuple(Client.cache_namespace(client)),
      client: client,
      key: app_token_key(client),
      table: TokenStore.table(),
      fetch: &do_fetch/2,
      crash_error: &crash_error/1,
      start_error: &start_error/1,
      task_supervisor: DingTalkOpenAPI.EventTaskSupervisor
    )
  end

  @doc false
  def child_spec(%Client{} = client) do
    %{
      id: {__MODULE__, Client.cache_namespace(client)},
      start: {__MODULE__, :start_link, [client]},
      restart: :transient,
      type: :worker
    }
  end

  @doc "Returns an app access token, fetching it through the per-app manager on miss."
  @spec get_app_token(Client.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def get_app_token(%Client{} = client) do
    key = app_token_key(client)

    case TokenCache.lookup(TokenStore.table(), key) do
      {:ok, token} -> {:ok, token}
      :miss -> call_manager(client, :fetch)
    end
  end

  @doc "Removes the cached app token so the next request fetches a fresh one."
  @spec invalidate(Client.t()) :: :ok
  def invalidate(%Client{} = client) do
    :ets.delete(TokenStore.table(), app_token_key(client))
    :ok
  end

  defp via_tuple(cache_namespace),
    do: {:via, Registry, {DingTalkOpenAPI.TokenRegistry, cache_namespace}}

  defp call_manager(%Client{} = client, message) do
    pid = ensure_started(client)
    GenServer.call(pid, message, TokenCache.call_timeout())
  end

  defp ensure_started(%Client{} = client) do
    cache_namespace = Client.cache_namespace(client)

    case Registry.lookup(DingTalkOpenAPI.TokenRegistry, cache_namespace) do
      [{pid, _}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(
               DingTalkOpenAPI.TokenManager.Supervisor,
               {__MODULE__, client}
             ) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  defp do_fetch(%Client{} = client, {:app, _ns} = key) do
    body = %{"appKey" => client.client_id, "appSecret" => Client.client_secret(client)}

    case DingTalkOpenAPI.post(client, @token_path, body: body, token: nil) do
      {:ok, %{"accessToken" => token, "expireIn" => expire}}
      when is_binary(token) and is_integer(expire) ->
        TokenCache.store(TokenStore.table(), key, token, expire)

      {:ok, other} ->
        {:error, %Error{reason: :unexpected_shape, raw: other}}

      {:error, _reason} = err ->
        err
    end
  end

  defp crash_error(reason), do: Error.transport({:token_fetch_crashed, reason})
  defp start_error(reason), do: Error.transport({:fetch_start_failed, reason})
  defp app_token_key(%Client{} = client), do: {:app, Client.cache_namespace(client)}
end
