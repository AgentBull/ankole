defmodule Ankole.OIDC.Boruta.Scopes do
  @moduledoc false

  @behaviour Boruta.Oauth.Scopes

  @impl true
  def public, do: []
end
