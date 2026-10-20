defmodule SlackOpenAPI.Client do
  @moduledoc """
  Slack credentials and HTTP transport configuration.

  Tokens are stored as zero-arity closures so inspect output never contains a
  raw credential.
  """

  @default_base_url "https://slack.com/api"

  @type token_fn :: (-> String.t())
  @type t :: %__MODULE__{
          bot_token_fn: token_fn() | nil,
          app_token_fn: token_fn() | nil,
          base_url: String.t(),
          req_options: keyword()
        }

  @derive {Inspect, only: [:base_url]}
  defstruct bot_token_fn: nil,
            app_token_fn: nil,
            base_url: @default_base_url,
            req_options: []

  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    opts = Keyword.validate!(opts, [:bot_token, :app_token, :base_url, :req_options])

    %__MODULE__{
      bot_token_fn: wrap_token(Keyword.get(opts, :bot_token)),
      app_token_fn: wrap_token(Keyword.get(opts, :app_token)),
      base_url: normalize_base_url(Keyword.get(opts, :base_url, @default_base_url)),
      req_options: Keyword.get(opts, :req_options, [])
    }
  end

  @spec bot_token(t()) :: String.t() | nil
  def bot_token(%__MODULE__{bot_token_fn: fun}) when is_function(fun, 0), do: fun.()
  def bot_token(%__MODULE__{}), do: nil

  @spec app_token(t()) :: String.t() | nil
  def app_token(%__MODULE__{app_token_fn: fun}) when is_function(fun, 0), do: fun.()
  def app_token(%__MODULE__{}), do: nil

  defp wrap_token(nil), do: nil
  defp wrap_token(token) when is_binary(token), do: fn -> token end
  defp wrap_token(fun) when is_function(fun, 0), do: fun

  defp wrap_token(_token) do
    raise ArgumentError, "Slack token must be a string, zero-arity function, or nil"
  end

  defp normalize_base_url(url) when is_binary(url), do: String.trim_trailing(url, "/")
end
