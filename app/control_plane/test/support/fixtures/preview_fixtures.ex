defmodule Ankole.PreviewFixtures do
  @moduledoc false
  alias Ankole.Repo
  alias Ankole.Conversations.Delivery.PreviewStates

  def update!(signal, attrs) do
    {preview_attrs, signal_attrs} =
      Map.split(attrs, [:checkpoint, :provider_message_id, :sequence_high_water])

    {:ok, updated} =
      Repo.transact(fn repo ->
        locked = Ankole.Signals.lock_signal_in_tx(repo, signal.id)

        action =
          cond do
            signal_attrs[:status] == :dead_letter -> :dead_letter
            signal_attrs[:completed_at] -> :complete
            true -> :update_metadata
          end

        {:ok, signal} = Ankole.Ash.update(locked, action, Map.delete(signal_attrs, :status))
        preview = PreviewStates.lock_in_tx(repo, signal)
        {:ok, preview} = Ankole.Ash.update(preview, :update_preview, preview_attrs)
        {:ok, %{signal | preview: preview}}
      end)

    updated
  end
end
