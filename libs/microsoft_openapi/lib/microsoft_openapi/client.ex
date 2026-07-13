defmodule MicrosoftOpenAPI.Client do
  @moduledoc """
  Microsoft app credentials and HTTP transport configuration.

  The client secret is stored as a zero-arity closure so inspect output never
  contains a raw credential. `bot_token_tenant` is the tenant segment used
  when acquiring Bot Connector tokens: the app's own tenant for single-tenant
  bots or the literal `"botframework.com"` for multi-tenant bots — the caller
  decides, this struct just carries the value.
  """

  @default_login_base_url "https://login.microsoftonline.com"
  @default_graph_base_url "https://graph.microsoft.com"

  @type secret_fn :: (-> String.t())
  @type t :: %__MODULE__{
          tenant_id: String.t() | nil,
          client_id: String.t() | nil,
          client_secret_fn: secret_fn() | nil,
          bot_token_tenant: String.t() | nil,
          login_base_url: String.t(),
          graph_base_url: String.t(),
          req_options: keyword()
        }

  @derive {Inspect, only: [:tenant_id, :client_id, :login_base_url, :graph_base_url]}
  defstruct tenant_id: nil,
            client_id: nil,
            client_secret_fn: nil,
            bot_token_tenant: nil,
            login_base_url: @default_login_base_url,
            graph_base_url: @default_graph_base_url,
            req_options: []

  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [
        :tenant_id,
        :client_id,
        :client_secret,
        :bot_token_tenant,
        :login_base_url,
        :graph_base_url,
        :req_options
      ])

    %__MODULE__{
      tenant_id: Keyword.get(opts, :tenant_id),
      client_id: Keyword.get(opts, :client_id),
      client_secret_fn: wrap_secret(Keyword.get(opts, :client_secret)),
      bot_token_tenant: Keyword.get(opts, :bot_token_tenant),
      login_base_url:
        normalize_base_url(Keyword.get(opts, :login_base_url, @default_login_base_url)),
      graph_base_url:
        normalize_base_url(Keyword.get(opts, :graph_base_url, @default_graph_base_url)),
      req_options: Keyword.get(opts, :req_options, [])
    }
  end

  @spec client_secret(t()) :: String.t() | nil
  def client_secret(%__MODULE__{client_secret_fn: fun}) when is_function(fun, 0), do: fun.()
  def client_secret(%__MODULE__{}), do: nil

  defp wrap_secret(nil), do: nil
  defp wrap_secret(secret) when is_binary(secret), do: fn -> secret end
  defp wrap_secret(fun) when is_function(fun, 0), do: fun

  defp wrap_secret(_secret) do
    raise ArgumentError, "Microsoft client secret must be a string, zero-arity function, or nil"
  end

  defp normalize_base_url(url) when is_binary(url), do: String.trim_trailing(url, "/")
end
