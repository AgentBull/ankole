defmodule Ankole.BrowserSessions.Validations.TargetScope do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    site? = Ash.Changeset.get_attribute(changeset, :purpose) == :site
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)

    if site? == is_nil(tenant_id),
      do: :ok,
      else: {:error, field: :tenant_id, message: "must match the login purpose"}
  end
end
