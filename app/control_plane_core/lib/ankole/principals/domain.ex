defmodule Ankole.Principals.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Ankole.Principals.Principal)
    resource(Ankole.Principals.Agent)
    resource(Ankole.Principals.HumanUser)
    resource(Ankole.Principals.ExternalIdentity)
    resource(Ankole.Principals.LocalCredential)
    resource(Ankole.Principals.AccessRestriction)
    resource(Ankole.Principals.AccessEvent)
    resource(Ankole.Principals.MappingRequest)
  end
end
