defmodule BullX.Principals.LoginProvider do
  @moduledoc """
  Behaviour for trusted Principal browser login providers contributed by plugins.

  The concrete provider id used for Principal `login_subject` identities may be
  a configured source slug rather than the plugin implementation id.
  """

  alias BullX.Gateway.SourceConfig

  @callback authorization_url(SourceConfig.t(), map()) ::
              {:ok, %{url: String.t(), state: map()}} | {:error, map()}

  @callback callback(SourceConfig.t(), map(), map()) :: {:ok, map()} | {:error, map()}
end
