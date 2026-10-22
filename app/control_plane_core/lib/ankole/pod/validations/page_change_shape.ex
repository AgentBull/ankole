defmodule Ankole.Pod.Validations.PageChangeShape do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    fields = [:client_id, :client_seq, :changes]
    kind = Ash.Changeset.get_attribute(changeset, :kind)

    errors =
      Enum.flat_map(fields, fn field ->
        value = Ash.Changeset.get_attribute(changeset, field)

        case {kind, value} do
          {:change, nil} ->
            [[field: field, message: "is required"]]

          {:reset, value} when not is_nil(value) ->
            [[field: field, message: "is not part of a reset entry"]]

          _other ->
            []
        end
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end
end
