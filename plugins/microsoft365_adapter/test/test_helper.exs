ExUnit.start()

unless Process.whereis(MicrosoftOpenAPI.Supervisor) do
  {:ok, _supervisor} = MicrosoftOpenAPI.Supervisor.start_link([])
end
