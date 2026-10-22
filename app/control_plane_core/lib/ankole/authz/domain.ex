defmodule Ankole.AuthZ.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Ankole.AuthZ.Group)
    resource(Ankole.AuthZ.Membership)
    resource(Ankole.AuthZ.Grant)
    resource(Ankole.AuthZ.ExternalBinding)
  end
end
