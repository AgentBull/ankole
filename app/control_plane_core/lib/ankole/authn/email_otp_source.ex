defmodule Ankole.Authn.EmailOtpSource do
  @moduledoc false
  @behaviour Ankole.IdentityProviders.SiteSources
  @impl true
  defdelegate authenticate(proof), to: Ankole.Authn.Domain, as: :verified_proof
  @impl true
  def login_path, do: "/sessions/new"
  @impl true
  def display_name, do: "Email verification code"
  @impl true
  def fresh_authentication?, do: true
  def enabled?, do: Ankole.Authn.Mailer.configured?()
end
