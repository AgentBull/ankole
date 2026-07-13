defmodule Ankole.Plugins.Microsoft365Adapter.TeamsChannels.StartupSync do
  @moduledoc false

  alias Ankole.Logging
  alias Ankole.Plugins.Microsoft365Adapter.TeamsChannels

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  def start_link(opts \\ []), do: Task.start_link(fn -> enqueue(opts) end)

  def enqueue(opts \\ []) do
    case TeamsChannels.enqueue_full_syncs(
           reason: Keyword.get(opts, :reason, "startup"),
           source: Keyword.get(opts, :source, "startup")
         ) do
      {:ok, _result} = ok ->
        ok

      {:error, reason} = error ->
        Logging.warning(
          "microsoft365_adapter.teams_channels.startup_sync_failed",
          "Teams startup channel sync enqueue failed",
          %{reason: inspect(reason)}
        )

        error
    end
  end
end
