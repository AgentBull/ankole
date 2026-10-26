ExUnit.start()

unless Process.whereis(FeishuOpenAPI.Supervisor) do
  {:ok, _supervisor} = FeishuOpenAPI.Supervisor.start_link([])
end
