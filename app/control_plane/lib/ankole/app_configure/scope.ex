defmodule Ankole.AppConfigure.Scope do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    scope = Ash.Changeset.get_attribute(changeset, :scope)

    valid? =
      case {changeset.resource.__tenancy__(), scope} do
        {:site, "global"} -> true
        {:tenant, "tenant:" <> tenant} -> tenant == Ankole.Repo.tenant_id!()
        {:tenant, "agent:" <> uid} -> uid != ""
        _other -> false
      end

    if valid?,
      do: :ok,
      else: {:error, field: :scope, message: "does not match the configuration scope"}
  end
end
