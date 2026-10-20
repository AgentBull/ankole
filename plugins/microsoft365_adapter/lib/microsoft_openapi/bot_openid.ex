defmodule MicrosoftOpenAPI.BotOpenID do
  @moduledoc """
  Bot Framework OpenID metadata and JWKS retrieval with caching.

  This module only fetches and caches key documents; it performs no
  cryptography. Signature verification is a trust decision that belongs to
  the caller (Ankole's plugin verifies through the Rust kernel).

  Keys are cached per metadata URL for 24 hours. A lookup for an unknown
  `kid` forces one refetch — Bot Framework rotates keys and instructs bots to
  refresh at least daily — but no more than once per five minutes so a bad
  token cannot hammer the metadata endpoint.
  """

  alias MicrosoftOpenAPI.Cache
  alias MicrosoftOpenAPI.Error

  @default_metadata_url "https://login.botframework.com/v1/.well-known/openidconfiguration"
  @cache_ttl_ms :timer.hours(24)
  @refetch_backoff_ms :timer.minutes(5)

  @spec default_metadata_url() :: String.t()
  def default_metadata_url, do: @default_metadata_url

  @spec signing_jwk(String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t() | :unknown_kid}
  def signing_jwk(kid, opts \\ []) when is_binary(kid) do
    metadata_url = Keyword.get(opts, :metadata_url, @default_metadata_url)
    now = System.monotonic_time(:millisecond)

    case cached_keys(metadata_url, now) do
      {:fresh, keys} ->
        lookup_or_refetch(keys, kid, metadata_url, now, opts)

      :stale ->
        with {:ok, keys} <- refresh_keys(metadata_url, now, opts) do
          key_result(keys, kid)
        end
    end
  end

  defp lookup_or_refetch(keys, kid, metadata_url, now, opts) do
    case Map.fetch(keys, kid) do
      {:ok, jwk} ->
        {:ok, jwk}

      :error ->
        if refetch_allowed?(metadata_url, now) do
          with {:ok, keys} <- refresh_keys(metadata_url, now, opts) do
            key_result(keys, kid)
          end
        else
          {:error, :unknown_kid}
        end
    end
  end

  defp key_result(keys, kid) do
    case Map.fetch(keys, kid) do
      {:ok, jwk} -> {:ok, jwk}
      :error -> {:error, :unknown_kid}
    end
  end

  defp refresh_keys(metadata_url, now, opts) do
    req_options = Keyword.get(opts, :req_options, [])

    with {:ok, metadata} <- MicrosoftOpenAPI.request(:get, metadata_url, req_options: req_options),
         {:ok, jwks_uri} <- jwks_uri(metadata),
         {:ok, document} <- MicrosoftOpenAPI.request(:get, jwks_uri, req_options: req_options),
         {:ok, keys} <- index_keys(document) do
      :ets.insert(Cache.jwks_table(), {metadata_url, now, keys})
      {:ok, keys}
    end
  end

  defp jwks_uri(%{"jwks_uri" => jwks_uri}) when is_binary(jwks_uri), do: {:ok, jwks_uri}

  defp jwks_uri(metadata),
    do: {:error, %Error{reason: :unexpected_shape, raw: metadata}}

  defp index_keys(%{"keys" => keys}) when is_list(keys) do
    {:ok,
     keys
     |> Enum.filter(&(is_map(&1) and is_binary(Map.get(&1, "kid"))))
     |> Map.new(&{Map.fetch!(&1, "kid"), &1})}
  end

  defp index_keys(document),
    do: {:error, %Error{reason: :unexpected_shape, raw: document}}

  defp cached_keys(metadata_url, now) do
    case :ets.lookup(Cache.jwks_table(), metadata_url) do
      [{^metadata_url, fetched_at, keys}] when now - fetched_at < @cache_ttl_ms ->
        {:fresh, keys}

      _stale_or_missing ->
        :stale
    end
  end

  defp refetch_allowed?(metadata_url, now) do
    case :ets.lookup(Cache.jwks_table(), metadata_url) do
      [{^metadata_url, fetched_at, _keys}] -> now - fetched_at >= @refetch_backoff_ms
      [] -> true
    end
  end
end
