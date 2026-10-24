defmodule Ankole.Sessions.PendingCall do
  @moduledoc false
  @enforce_keys [:call]
  defstruct [
    :call,
    :activity,
    :tool,
    :args,
    :wait,
    :worker_name,
    :worker_args,
    :continue,
    :mode,
    status: :queued,
    probe?: false,
    sequential?: false
  ]

  @type t :: %__MODULE__{}
  @parallelism 4
  alias Ankole.Sessions.Run

  def new_round(calls, probe?),
    do: Map.new(calls, &{Run.call_id(&1), %__MODULE__{call: &1, probe?: probe?}})

  def next(pending, calls) do
    active = Enum.count(pending, fn {_id, p} -> p.status != :queued end)
    call = Enum.find(calls, &match?(%{status: :queued}, pending[Run.call_id(&1)]))
    if call && active < @parallelism, do: {:ok, call, active}, else: :none
  end

  def blocked?(pending, sequential?, active),
    do:
      Enum.any?(pending, fn {_id, p} -> p.status != :queued and p.sequential? end) or
        (sequential? and active > 0)

  def start(pending, id, call, tool, args, sequential?),
    do:
      Map.update!(
        pending,
        id,
        &%{
          &1
          | call: call,
            tool: tool,
            args: args,
            sequential?: sequential?,
            status: :running
        }
      )

  def delegate(pending, id, name, args, continue),
    do:
      Map.update!(
        pending,
        id,
        &%{
          &1
          | worker_name: name,
            worker_args: args,
            continue: continue,
            tool: %{&1.tool | retry_safe: true}
        }
      )

  def await(pending, id, wait),
    do: Map.update!(pending, id, &%{&1 | status: :waiting, wait: wait})

  def wait_worker(pending, id), do: Map.update!(pending, id, &%{&1 | status: :worker_wait})

  def to_worker(pending, id) do
    entry = pending[id]
    mode = if entry.probe? and not entry.tool.retry_safe, do: "probe", else: "execute"
    entry = %{entry | status: :worker, mode: mode}
    {Map.put(pending, id, entry), entry}
  end

  def ready(pending),
    do: map(pending, fn p -> if p.status == :worker_wait, do: %{p | status: :queued}, else: p end)

  def worker_changed(pending),
    do:
      map(pending, fn p ->
        if p.status in [:worker, :worker_wait],
          do: %{p | status: :queued, probe?: p.probe? or p.status == :worker, activity: nil},
          else: p
      end)

  def worker_same(pending, sending \\ []),
    do:
      Map.new(pending, fn {id, p} ->
        {id,
         if(p.status == :worker and id not in sending,
           do: %{p | status: :queued, probe?: true},
           else: p
         )}
      end)

  def send_failed(pending, id),
    do:
      if(Map.has_key?(pending, id),
        do: Map.update!(pending, id, &%{&1 | status: :queued, probe?: true}),
        else: pending
      )

  def unknown(pending, id),
    do: Map.update!(pending, id, &%{&1 | status: :queued, probe?: false})

  def waiting_worker(pending), do: for({id, p} <- pending, p.status == :worker_wait, do: id)

  def queued(pending), do: for({id, p} <- pending, p.status == :queued, do: id)
  def on_worker(pending), do: for({id, p} <- pending, p.status == :worker, do: id)
  def waits(pending), do: for({id, p} <- pending, p.status == :waiting, do: {id, p.wait})
  defp map(pending, transform), do: Map.new(pending, fn {id, p} -> {id, transform.(p)} end)
end
