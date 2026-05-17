defmodule BullX.Principals.LoginProvider do
  @moduledoc """
  Behaviour for plugin-owned Principal login providers.

  The extension id identifies the provider implementation, while the concrete
  login provider id in routes can be a plugin source id. Implementations that
  support source-scoped providers expose `fetch_source/1`.
  """

  @callback authorization_url(source :: term(), request :: map()) ::
              {:ok, %{url: String.t(), state: map()}} | {:error, map()}

  @callback callback(source :: term(), params :: map(), state :: map()) ::
              {:ok, login_subject :: map()} | {:error, map()}

  @callback fetch_source(provider_id :: String.t()) ::
              {:ok, term()} | {:error, :not_found | map()}
  @callback state_ttl_seconds(source :: term()) :: pos_integer()

  @optional_callbacks fetch_source: 1, state_ttl_seconds: 1
end
