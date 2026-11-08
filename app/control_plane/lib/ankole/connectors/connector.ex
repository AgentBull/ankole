defmodule Ankole.Connectors.Connector do
  @moduledoc "Platform adapters own upstream protocols; Connectors owns credentials and authorization."

  @callback upstream_auth(Ankole.Connectors.ToolSpec.t(), map() | nil, map()) :: atom()
  @callback scopes_satisfied?([String.t()], [String.t()], map()) :: boolean()
  @callback tools() :: [Ankole.Connectors.ToolSpec.t()]
  @callback platform_name(map()) :: %{String.t() => String.t()}
  @callback platform_application(map()) :: {:ok, String.t() | nil} | {:error, term()}
  @callback validate_credentials(map(), map()) :: {:ok, map()} | {:error, term()}
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
  # Database adapters run guarded read-only statements, list their catalog, and
  # mark the sensitive columns of cached tables; exporting read_query/4 makes
  # Connectors apply connection-level AuthZ.
  @callback read_query(map(), String.t(), list(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback fetch_catalog(map(), map(), keyword()) ::
              {:ok, %{String.t() => [map()] | boolean()}} | {:error, term()}
  @callback mark_catalog(map(), [map()]) :: [map()]

  @optional_callbacks upstream_auth: 3,
                      platform_name: 1,
                      platform_application: 1,
                      validate_credentials: 2,
                      scopes_satisfied?: 3,
                      fetch_app_token: 3,
                      refresh_token: 3,
                      oauth_authorize_url: 3,
                      oauth_exchange: 3,
                      bound_user_id: 2,
                      webhook: 4,
                      webhook_response: 1,
                      reconcile_trigger: 4,
                      read_query: 4,
                      fetch_catalog: 3,
                      mark_catalog: 2

  def validate_declaration(%{module: module}) when is_atom(module) and not is_nil(module) do
    with {:module, _} <- Code.ensure_loaded(module) do
      case Enum.reject([tools: 0, call: 3], fn {name, arity} ->
             function_exported?(module, name, arity)
           end) do
        [] -> :ok
        missing -> {:error, {:missing_connector_callbacks, module, missing}}
      end
    end
  end

  def validate_declaration(declaration),
    do: {:error, {:invalid_connector_declaration, declaration}}
end
