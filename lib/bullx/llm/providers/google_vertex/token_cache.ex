defmodule BullX.LLM.Providers.GoogleVertex.TokenCache do
  @moduledoc """
  OAuth2 token cache for Google Vertex AI.

  Caches access tokens per service account to avoid expensive token
  generation on every request.

  ## Lifecycle

  - Started by ReqLLM.Application supervision tree
  - One cache per node (not distributed)
  - Tokens cached for 55 minutes (5 minute safety margin)

  ## Usage

      # Provider calls this instead of Auth.get_access_token/1 directly
      {:ok, token} = TokenCache.get_or_refresh(service_account_json_path)

  ## Cache Key

  For file paths: the path string is used as the cache key.
  For JSON strings or maps: the `client_email` field is used as the cache key.

  This allows multiple service accounts to be used simultaneously with
  independent token caches.

  ## Expiry & Refresh

  Tokens are cached for 55 minutes (5 minute safety margin before 1 hour expiry).
  The GenServer serializes concurrent refresh requests to prevent duplicate token
  fetches when the cache is empty or expired.
  """

  use GenServer

  alias ReqLLM.Provider.Utils

  require Logger

  @table_name :vertex_oauth2_tokens
  @token_lifetime_seconds 3600
  @safety_margin_seconds 300
  @cache_ttl_seconds @token_lifetime_seconds - @safety_margin_seconds

  ## Client API

  @doc """
  Retrieves a cached token or fetches a fresh one if expired.

  This is the only function providers should call. It handles:
  - Cache hits (fast path)
  - Cache misses (slow path with fetch)
  - Expiry checking
  - Concurrent request deduplication

  Accepts credentials in multiple formats:
  - File path (string, if file exists) - uses path as cache key
  - JSON string (string, if not a file) - uses client_email as cache key
  - Map (already parsed) - uses client_email as cache key

  ## Examples

      iex> TokenCache.get_or_refresh("/path/to/service-account.json")
      {:ok, "ya29.c.Kl6iB..."}

      iex> TokenCache.get_or_refresh(~s({"client_email": "...", "private_key": "..."}))
      {:ok, "ya29.c.Kl6iB..."}

      iex> TokenCache.get_or_refresh("/invalid/path.json")
      {:error, :enoent}
  """
  @spec get_or_refresh(service_account :: String.t() | map()) ::
          {:ok, access_token :: String.t()} | {:error, term()}
  def get_or_refresh(service_account) do
    GenServer.call(__MODULE__, {:get_or_refresh, service_account})
  end

  @doc """
  Invalidates cached token for a service account.

  Useful for testing or when credentials are rotated.

  The cache_key should match what was used for caching:
  - File path if credentials were provided as a file path
  - client_email if credentials were provided as JSON string or map
  """
  @spec invalidate(cache_key :: String.t()) :: :ok
  def invalidate(cache_key) do
    GenServer.call(__MODULE__, {:invalidate, cache_key})
  end

  @doc """
  Clears all cached tokens.

  Useful for testing.
  """
  @spec clear_all() :: :ok
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  ## Server Implementation

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:set, :private, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:get_or_refresh, service_account}, _from, state) do
    case resolve_cache_key(service_account) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {cache_key, parsed_or_path} ->
        case lookup_token(state.table, cache_key) do
          {:ok, token} ->
            {:reply, {:ok, token}, state}

          :expired ->
            refresh_and_cache(state, cache_key, parsed_or_path)

          :not_found ->
            refresh_and_cache(state, cache_key, parsed_or_path)
        end
    end
  end

  @impl true
  def handle_call({:invalidate, cache_key}, _from, state) do
    :ets.delete(state.table, cache_key)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:clear_all, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  ## Private Helpers

  defp lookup_token(table, key) do
    case :ets.lookup(table, key) do
      [] ->
        :not_found

      [{^key, token, expires_at}] ->
        if System.system_time(:second) < expires_at do
          {:ok, token}
        else
          :expired
        end
    end
  end

  defp refresh_and_cache(state, cache_key, service_account) do
    case BullX.LLM.Providers.GoogleVertex.Auth.get_access_token(service_account) do
      {:ok, token} ->
        expires_at = System.system_time(:second) + @cache_ttl_seconds
        :ets.insert(state.table, {cache_key, token, expires_at})

        Logger.debug("Cached OAuth2 token for #{cache_key}, expires in #{@cache_ttl_seconds}s")

        {:reply, {:ok, token}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Resolve cache key based on credential type
  defp resolve_cache_key(service_account) when is_map(service_account) do
    # Already parsed map - normalize to string keys and use client_email as cache key
    normalized = Utils.stringify_keys(service_account)
    {normalized["client_email"], normalized}
  end

  defp resolve_cache_key(path_or_json) when is_binary(path_or_json) do
    # Check if it's a file path first (more reliable than checking for "{")
    if File.exists?(path_or_json) do
      # File path - use path as cache key, let Auth read the file
      {path_or_json, path_or_json}
    else
      # Not a file - try parsing as JSON string
      case Jason.decode(path_or_json) do
        {:ok, parsed} ->
          {parsed["client_email"], parsed}

        {:error, _reason} ->
          {:error,
           "Invalid service account credentials: " <>
             "not a valid file path or JSON string"}
      end
    end
  end
end
