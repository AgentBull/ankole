defmodule Ankole.AIGateway.Changes.PrepareArtifact do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :payload) do
      payload when is_binary(payload) ->
        changeset
        |> Ash.Changeset.force_change_attribute(:byte_size, byte_size(payload))
        |> Ash.Changeset.force_change_attribute(:sha256, :crypto.hash(:sha256, payload))

      _invalid ->
        changeset
    end
  end
end
