ExUnit.start()

unless Process.whereis(WeComOpenAPI.Supervisor) do
  {:ok, _supervisor} = WeComOpenAPI.Supervisor.start_link([])
end
