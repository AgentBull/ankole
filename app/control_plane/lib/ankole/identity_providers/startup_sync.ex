defmodule Ankole.IdentityProviders.StartupSync do
  @moduledoc """
  One-shot boot edge for identity-provider full directory sync.
  """

  alias Ankole.IdentityProviders.DirectorySync
  alias Ankole.Logging

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

  @spec enqueue(keyword()) :: {:ok, map()} | {:error, term()}
  def enqueue(opts \\ []) when is_list(opts) do
    reason = Keyword.get(opts, :reason, "control_plane_started")
    source = Keyword.get(opts, :source, "startup")

    case DirectorySync.enqueue_directory_syncs(reason: reason, source: source) do
      {:ok, _result} = ok ->
        ok

      {:error, reason} = error ->
        Logging.warning(
          "identity_providers.startup_sync.enqueue_failed",
          "identity provider startup full sync enqueue failed",
          %{reason: inspect(reason)}
        )

        error
    end
  end
end
