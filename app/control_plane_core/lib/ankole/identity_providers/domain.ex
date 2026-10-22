defmodule Ankole.IdentityProviders.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Ankole.IdentityProviders.DirectoryEvent)
    resource(Ankole.IdentityProviders.DirectoryState)
  end
end
