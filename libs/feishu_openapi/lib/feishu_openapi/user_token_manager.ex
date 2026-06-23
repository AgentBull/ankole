defmodule FeishuOpenAPI.UserTokenManager do
  @moduledoc """
  Caches OIDC `user_access_token`s and refreshes them with `refresh_token`s.

  Tokens are keyed by `{app_id, user_key}` so callers can bind a long-lived
  application user identity to the latest access token returned by the OIDC
  endpoints. Reads are lock-free through ETS. Refreshes funnel through this
  GenServer, but each refresh runs in a Task so the mailbox never blocks —
  concurrent callers on the same key share a single upstream refresh, while
  callers on different keys refresh in parallel.
  """

  use GenServer

  alias FeishuOpenAPI.{Auth, Client, Error}

  @table :feishu_openapi_user_tokens
  @expiry_delta_ms :timer.minutes(3)
  @call_timeout :timer.seconds(15)
  @default_task_supervisor FeishuOpenAPI.EventTaskSupervisor

  @type entry :: %{
          access_token: String.t(),
          access_expires_at: integer(),
          refresh_token: String.t() | nil,
          refresh_expires_at: integer() | nil,
          token_type: String.t() | nil,
          scope: String.t() | nil,
          raw: map()
        }

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Exchange an OIDC authorization code, cache the returned tokens, and return
  the normalized auth response.
  """
  @spec init_with_code(Client.t(), String.t(), String.t(), String.t()) ::
          {:ok, Auth.user_token_resp()} | {:error, Error.t()}
  def init_with_code(%Client{} = client, user_key, code, grant_type \\ "authorization_code")
      when is_binary(user_key) and is_binary(code) and is_binary(grant_type) do
    with {:ok, token_resp} <- Auth.user_access_token(client, code, grant_type) do
      :ok = put(client, user_key, token_resp)
      {:ok, token_resp}
    end
  end

  @doc """
  Cache a normalized OIDC user-token response under `user_key`.

  `token_resp` should match the map returned by `FeishuOpenAPI.Auth.user_access_token/3`
  or `FeishuOpenAPI.Auth.refresh_user_access_token/3`.
  """
  @spec put(Client.t(), String.t(), Auth.user_token_resp()) :: :ok
  def put(%Client{} = client, user_key, token_resp)
      when is_binary(user_key) and is_map(token_resp) do
    :ets.insert(@table, {cache_key(client, user_key), build_entry(token_resp)})
    :ok
  end

  @doc """
  Return a valid `user_access_token` for `user_key`.

  If the cached access token has expired, the manager refreshes it with the
  stored `refresh_token`, updates the cache, and returns the fresh token.
  """
  @spec get(Client.t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def get(%Client{} = client, user_key) when is_binary(user_key) do
    key = cache_key(client, user_key)

    case lookup(key) do
      {:ok, token} ->
        {:ok, token}

      :refresh ->
        GenServer.call(__MODULE__, {:refresh, client, user_key, key}, @call_timeout)

      :miss ->
        missing_error(user_key)
    end
  end

  @spec invalidate(Client.t(), String.t()) :: :ok
  def invalidate(%Client{} = client, user_key) when is_binary(user_key) do
    :ets.delete(@table, cache_key(client, user_key))
    :ok
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{fetches: %{}}}
  end

  @impl true
  def handle_call({:refresh, client, user_key, key}, from, state) do
    case lookup_entry(key) do
      {:ok, %{access_token: access_token, access_expires_at: access_expires_at}}
      when is_integer(access_expires_at) ->
        if fresh?(access_expires_at) do
          # Another caller refreshed between our ETS lookup and this call — reuse.
          {:reply, {:ok, access_token}, state}
        else
          {:noreply, enqueue_waiter(state, key, client, user_key, from)}
        end

      :miss ->
        {:reply, missing_error(user_key), state}
    end
  end

  @impl true
  def handle_info({:refresh_done, key, result}, state) do
    {waiters, fetches} = Map.pop(state.fetches, key, [])
    Enum.each(waiters, &GenServer.reply(&1, result))
    {:noreply, %{state | fetches: fetches}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Internal

  defp enqueue_waiter(state, key, client, user_key, from) do
    case Map.fetch(state.fetches, key) do
      {:ok, waiters} ->
        %{state | fetches: Map.put(state.fetches, key, [from | waiters])}

      :error ->
        start_fetch(state, key, client, user_key, [from])
    end
  end

  defp start_fetch(state, key, client, user_key, waiters) do
    parent = self()
    fetches = Map.put(state.fetches, key, waiters)

    case start_refresh_task(parent, key, client, user_key) do
      :ok ->
        %{state | fetches: fetches}

      {:error, reason} ->
        send(parent, {:refresh_done, key, {:error, refresh_start_failed_error(user_key, reason)}})
        %{state | fetches: fetches}
    end
  end

  defp start_refresh_task(parent, key, client, user_key) do
    try do
      case Task.Supervisor.start_child(task_supervisor(), fn ->
             result =
               try do
                 refresh_entry(client, user_key)
               rescue
                 exception -> {:error, crash_error(user_key, :error, exception, __STACKTRACE__)}
               catch
                 kind, reason -> {:error, crash_error(user_key, kind, reason, __STACKTRACE__)}
               end

             send(parent, {:refresh_done, key, result})
           end) do
        {:ok, _pid} -> :ok
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp crash_error(user_key, kind, reason, stacktrace) do
    %Error{
      code: :user_refresh_crashed,
      msg:
        "managed user_access_token #{inspect(user_key)} refresh crashed: " <>
          Exception.format(kind, reason, stacktrace),
      details: {kind, reason}
    }
  end

  defp refresh_start_failed_error(user_key, reason) do
    %Error{
      code: :user_refresh_start_failed,
      msg:
        "managed user_access_token #{inspect(user_key)} refresh could not start: #{inspect(reason)}",
      details: reason
    }
  end

  defp refresh_entry(client, user_key) do
    with {:ok, existing} <- lookup_entry(cache_key(client, user_key)),
         {:ok, refresh_token} <- require_refresh_token(user_key, existing),
         {:ok, token_resp} <- Auth.refresh_user_access_token(client, refresh_token) do
      merged = merge_refresh(existing, token_resp)
      :ets.insert(@table, {cache_key(client, user_key), merged})
      {:ok, merged.access_token}
    else
      :miss -> missing_error(user_key)
      {:error, _} = err -> err
    end
  end

  defp require_refresh_token(user_key, %{
         refresh_token: refresh_token,
         refresh_expires_at: refresh_expires_at
       })
       when is_binary(refresh_token) do
    cond do
      is_integer(refresh_expires_at) and not fresh?(refresh_expires_at) ->
        {:error,
         %Error{
           code: :user_refresh_token_expired,
           msg: "managed user_access_token #{inspect(user_key)} can no longer be refreshed"
         }}

      true ->
        {:ok, refresh_token}
    end
  end

  defp require_refresh_token(user_key, _entry) do
    {:error,
     %Error{
       code: :user_refresh_token_missing,
       msg: "managed user_access_token #{inspect(user_key)} is expired and has no refresh_token"
     }}
  end

  defp merge_refresh(existing, token_resp) do
    refresh_token = Map.get(token_resp, :refresh_token) || existing.refresh_token

    %{
      access_token: Map.fetch!(token_resp, :access_token),
      access_expires_at: expires_at(Map.get(token_resp, :expires_in)),
      refresh_token: refresh_token,
      refresh_expires_at: refresh_expires_at(existing, token_resp, refresh_token),
      token_type: Map.get(token_resp, :token_type) || existing.token_type,
      scope: Map.get(token_resp, :scope) || existing.scope,
      raw: Map.get(token_resp, :raw, %{})
    }
  end

  defp refresh_expires_at(existing, token_resp, refresh_token) do
    case Map.get(token_resp, :refresh_expires_in) do
      expires_in when is_integer(expires_in) ->
        expires_at(expires_in)

      _ when refresh_token == existing.refresh_token ->
        existing.refresh_expires_at

      _ ->
        nil
    end
  end

  defp build_entry(token_resp) do
    %{
      access_token: Map.fetch!(token_resp, :access_token),
      access_expires_at: expires_at(Map.get(token_resp, :expires_in)),
      refresh_token: Map.get(token_resp, :refresh_token),
      refresh_expires_at:
        case Map.get(token_resp, :refresh_expires_in) do
          expires_in when is_integer(expires_in) -> expires_at(expires_in)
          _ -> nil
        end,
      token_type: Map.get(token_resp, :token_type),
      scope: Map.get(token_resp, :scope),
      raw: Map.get(token_resp, :raw, %{})
    }
  end

  defp cache_key(%Client{} = client, user_key), do: {:user, client.app_id, user_key}

  defp lookup(key) do
    case lookup_entry(key) do
      {:ok, %{access_token: access_token, access_expires_at: access_expires_at}}
      when is_integer(access_expires_at) ->
        if fresh?(access_expires_at) do
          {:ok, access_token}
        else
          :refresh
        end

      :miss ->
        :miss
    end
  end

  defp lookup_entry(key) do
    case :ets.lookup(@table, key) do
      [{^key, entry}] -> {:ok, entry}
      [] -> :miss
    end
  end

  defp fresh?(expires_at), do: System.monotonic_time(:millisecond) < expires_at

  defp expires_at(expires_in) when is_integer(expires_in) do
    System.monotonic_time(:millisecond) + :timer.seconds(expires_in) - @expiry_delta_ms
  end

  defp expires_at(_), do: System.monotonic_time(:millisecond) - @expiry_delta_ms

  defp task_supervisor do
    Application.get_env(
      :feishu_openapi,
      :user_token_manager_task_supervisor,
      @default_task_supervisor
    )
  end

  defp missing_error(user_key) do
    {:error,
     %Error{
       code: :user_token_missing,
       msg:
         "managed user_access_token #{inspect(user_key)} is missing; " <>
           "initialize it with FeishuOpenAPI.UserTokenManager.init_with_code/4 or put/3"
     }}
  end
end
