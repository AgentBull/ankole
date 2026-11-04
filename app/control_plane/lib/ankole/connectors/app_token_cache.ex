defmodule Ankole.Connectors.AppTokenCache do
  @moduledoc "Caches reproducible application tokens without writing them to PostgreSQL."
  use GenServer
  alias Ankole.Connectors.Credentials

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_),
    do: {:ok, :ets.new(__MODULE__, [:named_table, :set, :public, read_concurrency: true])}

  def get(config, account, adapter) do
    key = {config.tenant_id, config.id, config.secret_version, account && account.account_key}

    case cached(key) do
      {:ok, token} ->
        {:ok, token}

      :miss ->
        :global.trans(
          {{__MODULE__, key}, self()},
          fn ->
            case cached(key) do
              {:ok, token} -> {:ok, token}
              :miss -> fetch(key, config, account, adapter)
            end
          end,
          [node()]
        )
    end
  end

  def invalidate(config, account, token) do
    key = {config.tenant_id, config.id, config.secret_version, account && account.account_key}
    :ets.select_delete(__MODULE__, [{{key, token, :_}, [], [true]}])
    :ok
  end

  defp cached(key) do
    now = System.monotonic_time(:second)

    case :ets.lookup(__MODULE__, key) do
      [{^key, token, expiry}] when expiry > now -> {:ok, token}
      _ -> :miss
    end
  end

  defp fetch(key, config, account, adapter) do
    with {:ok, secret} <- Credentials.secret(config),
         {:ok, %{access_token: token, expires_in: ttl}} <-
           adapter.fetch_app_token(config, secret, account) do
      expiry = System.monotonic_time(:second) + max(ttl - 60, 1)
      :ets.insert(__MODULE__, {key, token, expiry})
      {:ok, token}
    end
  end
end
