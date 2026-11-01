defmodule Ankole.AgentWorkers.DockerAPITest do
  use ExUnit.Case, async: false

  alias Ankole.AgentWorkers.Docker
  alias Ankole.AgentWorkers.ProviderKind

  @agent "agent-a"
  @generation "gen0000001"

  # Request paths, response fields, and status meanings come from Docker Engine
  # 1.42: https://github.com/moby/moby/blob/v23.0.6/api/swagger.yaml
  setup do
    Ankole.Repo.put_tenant_id(Ecto.UUID.generate())
    Application.put_env(:ankole, :docker_api_req_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:ankole, :docker_api_req_options) end)

    %{
      provider: %{
        provider_id: "local",
        runtime: %{installation: "prod"},
        settings: %{"socket" => "/var/run/docker.sock"}
      }
    }
  end

  test "termination only removes a container after Engine reports it is not running", %{
    provider: provider
  } do
    for {mode, signal} <- [graceful: "SIGTERM", now: "SIGKILL"] do
      for status <- [204, 404] do
        stub(fn conn ->
          assert {conn.method, conn.request_path} == {"POST", "/v1.42/containers/#{name()}/kill"}
          assert conn.query_params["signal"] == signal
          Plug.Conn.send_resp(conn, status, "")
        end)

        assert :ok = Docker.delete_instance(provider, instance(), mode)
      end

      parent = self()

      stub(fn conn ->
        case conn.method do
          "POST" ->
            assert conn.request_path == "/v1.42/containers/#{name()}/kill"
            send(parent, :signalled)
            Plug.Conn.send_resp(conn, 409, ~s({"message":"container is not running"}))

          "DELETE" ->
            assert_received :signalled
            assert conn.request_path == "/v1.42/containers/#{name()}"
            assert conn.query_params["force"] == "false"
            Plug.Conn.send_resp(conn, 204, "")
        end
      end)

      assert :ok = Docker.delete_instance(provider, instance(), mode)
    end
  end

  test "a removal conflict remains a failure", %{provider: provider} do
    stub(fn conn ->
      case conn.method do
        "POST" ->
          Plug.Conn.send_resp(conn, 409, ~s({"message":"container is not running"}))

        "DELETE" ->
          assert conn.query_params["force"] == "false"

          conn
          |> Plug.Conn.put_status(409)
          |> Req.Test.json(%{"message" => "removal is already in progress"})
      end
    end)

    assert {:error, {:docker_api, 409, "removal is already in progress"}} =
             Docker.delete_instance(provider, instance(), :now)

    stub(fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "daemon busy"})
    end)

    assert {:error, {:docker_api, 500, "daemon busy"}} =
             Docker.delete_instance(provider, instance(), :now)
  end

  test "lists all states only in this provider and includes the last log lines", %{
    provider: provider
  } do
    stub(fn conn ->
      case conn.request_path do
        "/v1.42/containers/json" ->
          assert conn.query_params["all"] == "true"

          assert Ankole.JSON.decode!(conn.query_params["filters"]) == %{
                   "label" => [
                     "ankole.worker=1",
                     "ankole.installation=prod",
                     "ankole.provider=local",
                     "ankole.tenant=#{Ankole.Repo.tenant_id!()}",
                     "ankole.agent-uid=agent-a"
                   ]
                 }

          Req.Test.json(conn, [
            %{
              "Id" => "container-id",
              "State" => "running",
              "Status" => "Up 2 minutes",
              "Created" => 1_780_000_000,
              "Labels" => %{
                "ankole.tenant" => Ankole.Repo.tenant_id!(),
                "ankole.agent-uid" => @agent,
                "ankole.generation" => @generation
              }
            }
          ])

        "/v1.42/containers/container-id/logs" ->
          assert conn.query_params["tail"] == "50"
          frame = "Error: cannot reach the control plane\n"
          Plug.Conn.send_resp(conn, 200, <<2, 0, 0, 0, byte_size(frame)::32, frame::binary>>)
      end
    end)

    assert {:ok,
            [%{phase: :running, reason: "Up 2 minutes\nError: cannot reach the control plane"}]} =
             Docker.list_instances(provider, @agent)
  end

  test "does not adopt a volume from another provider or a remote local-driver mount", %{
    provider: provider
  } do
    for volume <- [
          %{"Driver" => "local", "Options" => %{}, "Labels" => %{"ankole.provider" => "other"}},
          %{"Driver" => "local", "Options" => %{"type" => "nfs"}}
        ] do
      stub(fn conn ->
        assert {conn.method, conn.request_path} == {"POST", "/v1.42/volumes/create"}
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Ankole.JSON.decode!(body)["Labels"] == %{
                 "ankole.installation" => "prod",
                 "ankole.provider" => "local",
                 "ankole.agent-uid" => @agent,
                 "ankole.tenant" => Ankole.Repo.tenant_id!()
               }

        conn |> Plug.Conn.put_status(201) |> Req.Test.json(volume)
      end)

      assert {:error, _reason} = Docker.prepare_storage(provider, @agent)
    end
  end

  test "storage deletion checks the Agent and provider before it sends DELETE", %{
    provider: provider
  } do
    labels = %{
      "ankole.installation" => "prod",
      "ankole.provider" => "local",
      "ankole.agent-uid" => @agent,
      "ankole.tenant" => Ankole.Repo.tenant_id!()
    }

    for foreign <- [
          Map.put(labels, "ankole.provider", "other"),
          Map.put(labels, "ankole.agent-uid", "other"),
          Map.put(labels, "ankole.tenant", Ecto.UUID.generate())
        ] do
      stub(fn conn ->
        assert conn.method == "GET"
        Req.Test.json(conn, %{"Driver" => "local", "Labels" => foreign})
      end)

      assert {:error, {:docker_volume_owner_mismatch, _}} = Docker.delete_cache(provider, @agent)

      assert {:error, {:docker_volume_owner_mismatch, _}} =
               Docker.delete_storage(provider, @agent, nil)
    end

    parent = self()

    stub(fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, %{
            "Driver" => "local",
            "Labels" => Map.put(labels, "operator.note", "keep")
          })

        "DELETE" ->
          send(parent, {:deleted, conn.request_path})
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    assert {:ok, nil} = Docker.delete_storage(provider, @agent, nil)
    home = "/v1.42/volumes/" <> ProviderKind.storage_name("prod", @agent)
    cache = home <> "-cache"
    assert_received {:deleted, ^home}
    assert_received {:deleted, ^cache}

    stub(fn conn ->
      assert conn.method == "GET"
      Plug.Conn.send_resp(conn, 404, "")
    end)

    assert {:ok, nil} = Docker.delete_storage(provider, @agent, nil)
  end

  test "volume deletion failure remains visible", %{provider: provider} do
    stub(fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, %{
            "Driver" => "local",
            "Labels" => %{
              "ankole.installation" => "prod",
              "ankole.provider" => "local",
              "ankole.agent-uid" => @agent,
              "ankole.tenant" => Ankole.Repo.tenant_id!()
            }
          })

        "DELETE" ->
          conn |> Plug.Conn.put_status(409) |> Req.Test.json(%{"message" => "volume is in use"})
      end
    end)

    assert {:error, {:docker_api, 409, "volume is in use"}} =
             Docker.delete_cache(provider, @agent)
  end

  test "an image pull reads every progress line and reports a failed line", %{
    provider: provider
  } do
    for {lines, result} <- [
          {[~s({"status":"Pulling fs layer"}), ~s({"status":"Download complete"})], :ok},
          {[~s({"status":"Pulling fs layer"}), ~s({"error":"unauthorized"})],
           {:error, {:docker_pull_failed, "unauthorized"}}}
        ] do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v1.42/images/worker:1/json"} ->
            Plug.Conn.send_resp(conn, 404, "")

          {"POST", "/v1.42/images/create"} ->
            assert conn.query_params["fromImage"] == "worker:1"

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Enum.join(lines, "\r\n"))
        end
      end)

      assert Docker.prepare_image(provider, "worker:1") == result
    end
  end

  defp stub(fun), do: Req.Test.stub(__MODULE__, fun)
  defp name, do: ProviderKind.instance_name("prod", @agent, @generation)
  defp instance, do: %{agent_uid: @agent, generation: @generation, instance_ref: nil}
end
