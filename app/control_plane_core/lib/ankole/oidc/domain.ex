defmodule Ankole.OIDC.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Ankole.OIDC.Client)
    resource(Ankole.OIDC.ClientGroup)
    resource(Ankole.OIDC.SigningKeyRecord)
    resource(Ankole.OIDC.AuthorizationCode)
    resource(Ankole.OIDC.RefreshToken)
    resource(Ankole.OIDC.RefreshTokenFamily)
    resource(Ankole.OIDC.Session)
    resource(Ankole.OIDC.LogoutRequest)
    resource(Ankole.OIDC.LogoutDelivery)
  end
end
