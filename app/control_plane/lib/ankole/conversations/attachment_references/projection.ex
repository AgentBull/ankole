defmodule Ankole.Conversations.AttachmentReferences.Projection do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:id]

  @impl true
  def calculate(records, _opts, _context) do
    with {:ok, loaded} <- Ankole.Conversations.AttachmentReferences.load(records, :message),
         do: {:ok, Enum.map(loaded, & &1.attachments)}
  end
end
