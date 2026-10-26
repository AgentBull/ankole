ExUnit.start()

unless Process.whereis(GoogleOpenAPI.Supervisor) do
  {:ok, _supervisor} = GoogleOpenAPI.Supervisor.start_link([])
end
