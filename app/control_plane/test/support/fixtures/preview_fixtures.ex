defmodule Ankole.PreviewFixtures do
  @moduledoc false
  alias Ankole.Repo
  alias Ankole.Signals.Signal
  alias Ankole.Conversations.Delivery.PreviewState

  def update!(signal, attrs) do
    {preview_attrs, signal_attrs} =
      Map.split(attrs, [:checkpoint, :provider_message_id, :sequence_high_water])

    {:ok, updated} =
      Repo.transact(fn repo ->
        locked = Ankole.Signals.lock_signal_in_tx(repo, signal.id)
        signal = locked |> Signal.changeset(signal_attrs) |> repo.update!()
        preview = PreviewState.lock_in_tx(repo, signal)
        preview = preview |> PreviewState.changeset(preview_attrs) |> repo.update!()
        {:ok, %{signal | preview: preview}}
      end)

    updated
  end
end
