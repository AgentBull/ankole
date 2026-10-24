defmodule Ankole.Principals.Changes.NormalizeContact do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset =
      Ash.Changeset.update_change(changeset, :email, &Ankole.Principals.normalize_email/1)

    case Ash.Changeset.fetch_change(changeset, :mobile) do
      {:ok, nil} ->
        changeset

      {:ok, mobile} ->
        case Ankole.Kernel.phone_normalize_e164(mobile) do
          normalized when is_binary(normalized) ->
            Ash.Changeset.change_attribute(changeset, :mobile, normalized)

          {:error, _reason} ->
            Ash.Changeset.add_error(changeset, field: :mobile, message: "must be E.164")
        end

      :error ->
        changeset
    end
  end
end
