defmodule Ankole.WorkerProviderHTTPBarrier do
  @moduledoc "HTTP barriers for integration tests; every request uses the real transport and response."
  defdelegate child_spec(opts), to: Req.Finch

  def run(request) do
    pause(:before, request)
    result = Req.Finch.run(request)
    pause(:after, request)
    result
  end

  defp pause(stage, request) do
    case Process.get(:worker_http_barrier) do
      {parent, ^stage, method, prefix} when method == request.method ->
        if String.starts_with?(request.url.path, prefix) do
          Process.delete(:worker_http_barrier)
          send(parent, {:paused, self()})

          receive do
            :continue -> :ok
          after
            30_000 -> raise "test did not release HTTP barrier"
          end
        end

      _other ->
        :ok
    end
  end
end
