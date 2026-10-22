defmodule Ankole.Principals.Changes.NormalizeContact do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset =
      case Ash.Changeset.fetch_change(changeset, :email) do
        {:ok, email} ->
          Ash.Changeset.change_attribute(
            changeset,
            :email,
            Ankole.Principals.normalize_email(email)
          )

        :error ->
          changeset
      end

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
