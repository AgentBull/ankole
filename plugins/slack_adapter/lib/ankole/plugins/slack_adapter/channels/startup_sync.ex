defmodule Ankole.Plugins.SlackAdapter.Channels.StartupSync do
  @moduledoc false

  alias Ankole.Logging
  alias Ankole.Plugins.SlackAdapter.Channels

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  def start_link(opts \\ []), do: Task.start_link(fn -> enqueue(opts) end)

  def enqueue(opts \\ []) do
    case Channels.enqueue_full_syncs(
           reason: Keyword.get(opts, :reason, "startup"),
           source: Keyword.get(opts, :source, "startup")
         ) do
      {:ok, _result} = ok ->
        ok

      {:error, reason} = error ->
        Logging.warning(
          "slack_adapter.channels.startup_sync_failed",
          "Slack startup channel sync enqueue failed",
          %{reason: inspect(reason)}
        )

        error
    end
  end
end
