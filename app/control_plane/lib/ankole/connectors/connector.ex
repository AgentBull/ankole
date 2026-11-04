defmodule Ankole.Connectors.Connector do
  @moduledoc "Platform adapters own upstream protocols; Connectors owns credentials and authorization."

  @callback upstream_auth(Ankole.Connectors.ToolSpec.t(), map() | nil, map()) :: atom()
  @callback scopes_satisfied?([String.t()], [String.t()], map()) :: boolean()
  @callback tools() :: [Ankole.Connectors.ToolSpec.t()]
  @callback call(Ankole.Connectors.ToolSpec.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  @callback fetch_app_token(map(), map(), map() | nil) ::
              {:ok, %{access_token: String.t(), expires_in: non_neg_integer()}} | {:error, term()}
  @callback refresh_token(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  @callback oauth_authorize_url(map(), map(), map()) :: {:ok, String.t()} | {:error, term()}
  @callback oauth_exchange(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  @callback bound_user_id(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback webhook(map(), map(), binary(), [{String.t(), String.t()}]) ::
              {:ok, map()} | {:challenge, String.t()} | {:error, term()}
  @callback webhook_response(map()) :: map()
  @callback reconcile_trigger(map(), map(), map(), boolean()) ::
              {:ok, %{external_subscription_id: String.t() | nil}} | {:error, term()}

  @optional_callbacks upstream_auth: 3,
                      scopes_satisfied?: 3,
                      fetch_app_token: 3,
                      refresh_token: 3,
                      oauth_authorize_url: 3,
                      oauth_exchange: 3,
                      bound_user_id: 2,
                      webhook: 4,
                      webhook_response: 1,
                      reconcile_trigger: 4
end
