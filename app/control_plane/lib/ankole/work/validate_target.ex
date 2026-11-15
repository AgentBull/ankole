defmodule Ankole.Work.ValidateTarget do
  @moduledoc "Personal assistants run work under their owner's Human authorization."
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    uid = Ash.Changeset.get_attribute(changeset, :agent_uid)
    kind = Ash.Changeset.get_attribute(changeset, :authorization_kind)
    human_uid = Ash.Changeset.get_attribute(changeset, :human_uid)

    case Ankole.Principals.WorkAccess.check_execution_target(uid, %{
           authorization_kind: kind,
           human_uid: human_uid
         }) do
      :ok -> :ok
      {:error, reason} -> {:error, Ankole.Errors.Invalid.Rejected.exception(reason: reason)}
    end
  end
end
