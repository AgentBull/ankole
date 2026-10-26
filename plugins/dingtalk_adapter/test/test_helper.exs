ExUnit.start()

unless Process.whereis(DingTalkOpenAPI.Supervisor) do
  {:ok, _supervisor} = DingTalkOpenAPI.Supervisor.start_link([])
end
