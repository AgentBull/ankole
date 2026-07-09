defmodule Ankole.Plugins.LarkAdapter.IMGroups.StartupSync do
  @moduledoc """
  Enqueues Lark IM group full sync jobs once at plugin startup.
  """

  alias Ankole.Logging
  alias Ankole.Plugins.LarkAdapter.IMGroups

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
    reason = Keyword.get(opts, :reason, "startup")
    source = Keyword.get(opts, :source, "startup")

    case IMGroups.enqueue_full_syncs(reason: reason, source: source) do
      {:ok, _result} = ok ->
        ok

      {:error, reason} = error ->
        Logging.warning(
          "lark_adapter.im_groups.startup_sync.enqueue_failed",
          "lark adapter startup IM group sync enqueue failed",
          %{reason: inspect(reason)}
        )

        error
    end
  end
end
