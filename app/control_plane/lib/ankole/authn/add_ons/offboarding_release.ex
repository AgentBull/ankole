defmodule Ankole.Authn.AddOns.OffboardingRelease do
  @moduledoc "Releases the personal credentials and contacts of a departed Pod member."
  @behaviour Ankole.Authn.AddOn
  @impl true
  def call(:release, %{principal: principal}, _opts),
    do: Ankole.Principals.release_site_credentials_in_tx(principal)
end
