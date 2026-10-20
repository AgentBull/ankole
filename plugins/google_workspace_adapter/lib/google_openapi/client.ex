defmodule GoogleOpenAPI.Client do
  @moduledoc """
  Google app credentials and HTTP transport configuration.

  The OAuth client secret is stored as a zero-arity closure so inspect output
  never contains a raw credential. Service-account grants are signed outside
  this library: `assertion_signer` receives the grant claims and returns the
  signed JWT, so the library stays free of key material and crypto.
  `delegated_subject` is the admin the service account impersonates for
  domain-wide delegation.
  """

  @default_auth_base_url "https://accounts.google.com"
  @default_token_base_url "https://oauth2.googleapis.com"
  @default_userinfo_base_url "https://openidconnect.googleapis.com"
  @default_api_base_url "https://admin.googleapis.com"

  @type secret_fn :: (-> String.t())
  @type assertion_signer :: (map() -> {:ok, String.t()} | {:error, term()})
  @type t :: %__MODULE__{
          client_id: String.t() | nil,
          client_secret_fn: secret_fn() | nil,
          service_account_email: String.t() | nil,
          delegated_subject: String.t() | nil,
          assertion_signer: assertion_signer() | nil,
          auth_base_url: String.t(),
          token_base_url: String.t(),
          userinfo_base_url: String.t(),
          api_base_url: String.t(),
          req_options: keyword()
        }

  @derive {Inspect,
           only: [
             :client_id,
             :service_account_email,
             :delegated_subject,
             :auth_base_url,
             :token_base_url,
             :api_base_url
           ]}
  defstruct client_id: nil,
            client_secret_fn: nil,
            service_account_email: nil,
            delegated_subject: nil,
            assertion_signer: nil,
            auth_base_url: @default_auth_base_url,
            token_base_url: @default_token_base_url,
            userinfo_base_url: @default_userinfo_base_url,
            api_base_url: @default_api_base_url,
            req_options: []

  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [
        :client_id,
        :client_secret,
        :service_account_email,
        :delegated_subject,
        :assertion_signer,
        :auth_base_url,
        :token_base_url,
        :userinfo_base_url,
        :api_base_url,
        :req_options
      ])

    %__MODULE__{
      client_id: Keyword.get(opts, :client_id),
      client_secret_fn: wrap_secret(Keyword.get(opts, :client_secret)),
      service_account_email: Keyword.get(opts, :service_account_email),
      delegated_subject: Keyword.get(opts, :delegated_subject),
      assertion_signer: wrap_signer(Keyword.get(opts, :assertion_signer)),
      auth_base_url:
        normalize_base_url(Keyword.get(opts, :auth_base_url, @default_auth_base_url)),
      token_base_url:
        normalize_base_url(Keyword.get(opts, :token_base_url, @default_token_base_url)),
      userinfo_base_url:
        normalize_base_url(Keyword.get(opts, :userinfo_base_url, @default_userinfo_base_url)),
      api_base_url: normalize_base_url(Keyword.get(opts, :api_base_url, @default_api_base_url)),
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
    raise ArgumentError, "Google client secret must be a string, zero-arity function, or nil"
  end

  defp wrap_signer(nil), do: nil
  defp wrap_signer(fun) when is_function(fun, 1), do: fun

  defp wrap_signer(_signer) do
    raise ArgumentError, "Google assertion signer must be a one-arity function or nil"
  end

  defp normalize_base_url(url) when is_binary(url), do: String.trim_trailing(url, "/")
end
