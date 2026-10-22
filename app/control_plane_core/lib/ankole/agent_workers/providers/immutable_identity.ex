defmodule Ankole.AgentWorkers.Providers.ImmutableIdentity do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    errors =
      for field <- [:provider_id, :kind], Ash.Changeset.changing_attribute?(changeset, field) do
        Ash.Error.Changes.InvalidAttribute.exception(
          field: field,
          message: "cannot change after creation"
        )
      end

    if errors == [], do: :ok, else: {:error, errors}
  end
end
