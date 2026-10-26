defprotocol Ankole.Authn.Strategy do
  @moduledoc "The name, scope, provider, and supported phases of an authentication strategy."
  def name(strategy)
  def scope(strategy)
  def provider_id(strategy)
  def action(strategy, phase, params, opts)
end
