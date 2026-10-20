defmodule WeComOpenAPI.TokenManager do
  @moduledoc """
  Per-credential token fetch for a WeCom access token.

  A WeCom corp credential (`{corp_id, secret}`) has one token type: the access
  token from `GET /cgi-bin/gettoken?corpid=&corpsecret=`, valid for
  `expires_in` seconds (nominally 7200). Each secret (self-built app,
  contacts-sync) gets its own token.

  ## Topology

  One fetch process per credential set (keyed by
  `Corp.Client.cache_namespace/1`), registered in `WeComOpenAPI.TokenRegistry`
  and supervised by `WeComOpenAPI.TokenManager.Supervisor`. Processes start
  lazily on the first token miss. The ETS table (`WeComOpenAPI.TokenStore`) is
  shared across all managers. Reads are lock-free. Misses go through
  `IMTransport.TokenCache`, which coalesces a concurrent burst into a single
  upstream fetch. This module owns the WeCom token request.
  """

  alias WeComOpenAPI.{Corp.Client, Error, TokenStore}
  alias IMTransport.TokenCache

  @token_path "/cgi-bin/gettoken"

  @type key :: {:corp, Client.cache_namespace()}

  @doc false
  @spec start_link(Client.t()) :: GenServer.on_start()
  def start_link(%Client{} = client) do
    TokenCache.start_link(
      name: via_tuple(Client.cache_namespace(client)),
      client: client,
      key: corp_token_key(client),
      table: TokenStore.table(),
      fetch: &do_fetch/2,
      crash_error: &crash_error/1,
      start_error: &start_error/1,
      task_supervisor: WeComOpenAPI.EventTaskSupervisor
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

  @doc "Returns an access token, fetching it through the per-credential manager on miss."
  @spec get_corp_token(Client.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def get_corp_token(%Client{} = client) do
    key = corp_token_key(client)

    case TokenCache.lookup(TokenStore.table(), key) do
      {:ok, token} -> {:ok, token}
      :miss -> call_manager(client, :fetch)
    end
  end

  @doc "Removes the cached token so the next request fetches a fresh one."
  @spec invalidate(Client.t()) :: :ok
  def invalidate(%Client{} = client) do
    :ets.delete(TokenStore.table(), corp_token_key(client))
    :ok
  end

  defp via_tuple(cache_namespace),
    do: {:via, Registry, {WeComOpenAPI.TokenRegistry, cache_namespace}}

  defp call_manager(%Client{} = client, message) do
    pid = ensure_started(client)
    GenServer.call(pid, message, TokenCache.call_timeout())
  end

  defp ensure_started(%Client{} = client) do
    cache_namespace = Client.cache_namespace(client)

    case Registry.lookup(WeComOpenAPI.TokenRegistry, cache_namespace) do
      [{pid, _}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(
               WeComOpenAPI.TokenManager.Supervisor,
               {__MODULE__, client}
             ) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  defp do_fetch(%Client{} = client, {:corp, _ns} = key) do
    query = [corpid: client.corp_id, corpsecret: Client.secret(client)]

    case WeComOpenAPI.get(client, @token_path, query: query, token: nil) do
      {:ok, %{"access_token" => token, "expires_in" => expire}}
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
  defp corp_token_key(%Client{} = client), do: {:corp, Client.cache_namespace(client)}
end
