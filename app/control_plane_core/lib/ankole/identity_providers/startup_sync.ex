defmodule Ankole.IdentityProviders.StartupSync do
  @moduledoc """
  One-shot boot edge for identity-provider full directory sync.
  """

  alias Ankole.IdentityProviders.DirectorySync

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts \\ []) do
    Task.start_link(fn -> enqueue(opts) end)
  end

  @spec enqueue(keyword()) :: {:ok, map()}
  def enqueue(opts \\ []) when is_list(opts) do
    reason = Keyword.get(opts, :reason, "control_plane_started")
    source = Keyword.get(opts, :source, "startup")

    DirectorySync.enqueue_site_directory_syncs(reason: reason, source: source)
  end
end
