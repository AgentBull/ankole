defmodule Ankole.AppConfigure.Changes.EncodeValue do
  @moduledoc false
  use Ash.Resource.Change

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.{Codec, Registry}

  @impl true
  def change(changeset, _opts, _context) do
    scope = Ash.Changeset.get_attribute(changeset, :scope)
    key = Ash.Changeset.get_attribute(changeset, :key)
    input = Ash.Changeset.get_argument(changeset, :input)

    with {:ok, definition} <- Registry.require_key(key),
         :ok <- AppConfigure.ensure_scope(definition, scope),
         {:ok, envelope, _parsed} <- Codec.dump(definition, scope, key, input) do
      Ash.Changeset.force_change_attribute(changeset, :value, envelope)
    else
      {:error, reason} ->
        Ash.Changeset.add_error(
          changeset,
          Ankole.Errors.Invalid.Rejected.exception(reason: reason)
        )
    end
  end
end
