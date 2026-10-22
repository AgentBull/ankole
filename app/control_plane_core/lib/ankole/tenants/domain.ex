defmodule Ankole.Tenants.Domain do
  @moduledoc false
  use Ankole.Ash.Domain

  resources do
    resource Ankole.Tenants.Tenant do
      define(:get_tenant, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_tenants, action: :read)
      define(:create_tenant, action: :create_in_tx)
      define(:profile_tenant, action: :profile_in_tx)
      define(:suspend_tenant, action: :suspend_in_tx)
      define(:resume_tenant, action: :resume_in_tx)
      define(:begin_delete_tenant, action: :begin_delete_in_tx)
      define(:delete_tenant, action: :delete_in_tx)
    end
  end
end
