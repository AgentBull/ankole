defmodule Ankole.AgentWorkerDockerHTTP do
  @moduledoc """
  Docker Engine HTTP fixture for lifecycle unit tests. It runs below the
  production Docker adapter and is not evidence of Docker persistence.
  Shapes: https://github.com/moby/moby/blob/v23.0.6/api/swagger.yaml
  """

  def install(mode \\ :success) do
    api =
      ExUnit.Callbacks.start_supervised!(
        {Agent,
         fn ->
           %{
             containers: %{},
             volumes: %{},
             calls: [],
             mode: mode,
             hidden: false,
             signals: [],
             hold_kill: false
           }
         end}
      )

    previous = Application.get_env(:ankole, :docker_api_req_options)
    Application.put_env(:ankole, :docker_api_req_options, plug: {Req.Test, __MODULE__})

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:ankole, :docker_api_req_options, previous),
        else: Application.delete_env(:ankole, :docker_api_req_options)
    end)

    Req.Test.stub(__MODULE__, &request(&1, api))
    api
  end

  def request(conn, api) do
    conn = Plug.Conn.fetch_query_params(conn)
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    body = if body == "", do: %{}, else: Ankole.JSON.decode!(body)
    path = String.replace_prefix(conn.request_path, "/v1.42", "")
    Agent.update(api, &%{&1 | calls: [{conn.method, path} | &1.calls]})
    {status, response} = response(conn.method, path, conn.query_params, body, api)

    if String.ends_with?(path, "/logs") do
      conn
      |> Plug.Conn.put_resp_content_type("application/vnd.docker.raw-stream")
      |> Plug.Conn.send_resp(status, response)
    else
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(response)
    end
  end

  defp response("GET", "/_ping", _, _, _api), do: {200, "OK"}
  defp response("GET", "/images/" <> _image, _, _, _api), do: {200, %{}}

  defp response("POST", "/volumes/create", _, body, api) do
    volume = Map.put(body, "Options", %{})
    Agent.update(api, &put_in(&1, [:volumes, body["Name"]], volume))
    {201, volume}
  end

  defp response("GET", "/containers/json", params, _, api) do
    labels = Ankole.JSON.decode!(params["filters"])["label"]

    {200,
     Agent.get(api, fn s ->
       if s.hidden,
         do: [],
         else:
           Enum.filter(Map.values(s.containers), fn container ->
             Enum.all?(labels, fn label ->
               [key, value] = String.split(label, "=", parts: 2)
               container["Labels"][key] == value
             end)
           end)
     end)}
  end

  defp response("POST", "/containers/create", %{"name" => name}, body, api) do
    Agent.update(api, &%{&1 | calls: [{"CREATE", name} | &1.calls]})
    state = Agent.get(api, & &1)

    cond do
      Map.has_key?(state.containers, name) ->
        {409, %{"message" => "name already in use"}}

      state.mode == :rejected ->
        {400, %{"message" => "invalid configuration"}}

      state.mode == :timeout ->
        {503, %{"message" => "platform unavailable"}}

      true ->
        container = %{
          "Id" => name,
          "Labels" => body["Labels"],
          "Config" => body,
          "State" => "running",
          "Status" => "Up",
          "Created" => DateTime.to_unix(DateTime.utc_now())
        }

        Agent.update(api, &put_in(&1, [:containers, name], container))

        if state.mode == :accepted_timeout,
          do: {503, %{"message" => "response lost"}},
          else: {201, %{"Id" => name, "Warnings" => []}}
    end
  end

  defp response(method, "/containers/" <> rest, params, _, api) do
    parts = String.split(rest, "/")
    name = hd(parts)

    case {method, List.last(parts)} do
      {"GET", "json"} ->
        {200, Agent.get(api, & &1.containers[name])}

      {"GET", "logs"} ->
        {200, ""}

      {"POST", "start"} ->
        {304, %{}}

      {"POST", "kill"} ->
        Agent.get_and_update(api, fn state ->
          state = %{state | signals: [{name, params["signal"]} | state.signals]}

          case state.containers[name] do
            nil ->
              {{404, %{}}, state}

            %{"State" => "exited"} ->
              {{409, %{"message" => "container is not running"}}, state}

            _running ->
              next =
                if state.hold_kill,
                  do: state,
                  else: put_in(state, [:containers, name, "State"], "exited")

              {{204, %{}}, next}
          end
        end)

      {"DELETE", ^name} ->
        Agent.update(api, &%{&1 | containers: Map.delete(&1.containers, name)})
        {204, %{}}
    end
  end

  defp response("GET", "/volumes/" <> name, _, _, api) do
    case Agent.get(api, & &1.volumes[name]) do
      nil -> {404, %{}}
      volume -> {200, volume}
    end
  end

  defp response("DELETE", "/volumes/" <> name, _, _, api) do
    Agent.update(api, &%{&1 | volumes: Map.delete(&1.volumes, name)})
    {204, %{}}
  end
end
