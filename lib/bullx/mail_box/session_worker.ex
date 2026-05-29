defmodule BullX.MailBox.SessionWorker do
  @moduledoc false

  alias BullX.MailBox.{Entry, Session}

  @supervisor BullX.MailBox.SessionWorkerSupervisor

  @spec start_session(Session.t(), keyword()) :: :ok
  def start_session(%Session{} = session, opts \\ []) when is_list(opts) do
    start_child(fn -> BullX.MailBox.process_session(session, opts) end)
  end

  @spec start_entry(Entry.t(), keyword()) :: :ok
  def start_entry(%Entry{} = entry, opts \\ []) when is_list(opts) do
    start_child(fn -> BullX.MailBox.process_entry(entry, opts) end)
  end

  @spec start_entry_id(String.t(), keyword()) :: :ok
  def start_entry_id(entry_id, opts \\ []) when is_binary(entry_id) and is_list(opts) do
    start_child(fn -> BullX.MailBox.process_entry_by_id(entry_id, opts) end)
  end

  defp start_child(fun) when is_function(fun, 0) do
    case Process.whereis(@supervisor) do
      nil ->
        _result = Task.start(fun)
        :ok

      _pid ->
        _result = Task.Supervisor.start_child(@supervisor, fun)
        :ok
    end
  end
end
