defimpl Ankole.Authn.Strategy, for: Ankole.Authn.Strategies.Oidc do
  def name(strategy), do: strategy.name
  def scope(strategy), do: strategy.scope
  def provider_id(strategy), do: strategy.provider_id

  def action(_strategy, :authorize, %{provider_id: provider_id}, opts),
    do: Ankole.IdentityProviders.Login.authorization_url(provider_id, opts)

  def action(_strategy, :callback, %{provider_id: provider_id, code: code}, opts),
    do: Ankole.IdentityProviders.Login.complete_oidc_login(provider_id, code, opts)
end
