defmodule Ankole.Tenants.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Ankole.Tenants.Tenant)
  end
end
