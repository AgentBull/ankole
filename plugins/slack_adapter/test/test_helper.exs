ExUnit.start()

unless Process.whereis(SlackOpenAPI.Supervisor) do
  {:ok, _supervisor} = SlackOpenAPI.Supervisor.start_link([])
end
