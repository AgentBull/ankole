defmodule Ankole.AgentWorkers.Vercel do
  @moduledoc """
  Vercel Sandbox sessions with one persistent Drive per Agent.

  A create never receives the Worker credential. Only a later call with the
  committed session ID can launch the entry command. Repeated creates can
  therefore leave unused sessions, but cannot start another Worker.
  """
  @behaviour Ankole.AgentWorkers.ProviderKind

  alias Ankole.AgentWorkers.ProviderKind
  alias Ankole.AgentWorkers.ProviderKind.Definition
  alias Ankole.AgentWorkers.Providers.Configuration, as: C
  alias Ankole.AgentWorkers.Vercel.Client
  alias Ankole.AgentWorkers

  @terminal ~w(stopped failed aborted)
  @entry_command "/usr/local/bin/ankole-worker-command-entry"
  @entry_args ["bun", "/repo/app/agent_computer/src/main.ts"]

  @impl true
  def definition do
    common =
      C.common("15m")
      |> put_in(["endpoints", "required"], ~w(runtimeFabricUrl relayOrigin aiGatewayUrl))

    %Definition{
      kind: "vercel",
      credentials: %{"token" => %{required: true}},
      pause: false,
      max_instance_lifetime: 86_400,
      schema:
        C.object(
          Map.merge(common, %{
            "teamId" => C.field(%{"type" => "string", "minLength" => 1}, :location),
            "projectId" => C.field(%{"type" => "string", "minLength" => 1}, :location),
            "region" => C.field(%{"type" => "string", "minLength" => 1}, :location),
            "driveSizeGiB" => C.field(%{"type" => "integer", "minimum" => 1}, :location),
            "imageRepository" => C.field(%{"type" => "string", "minLength" => 1}, :instance),
            "cpus" =>
              C.field(%{"enum" => [1 | Enum.to_list(2..32//2)], "default" => 2}, :instance),
            "sessionTimeoutSeconds" =>
              C.field(
                %{"type" => "integer", "minimum" => 1, "maximum" => 86_400, "default" => 86_400},
                :instance
              ),
            "env" => C.field(C.environment(), :instance)
          }),
          ~w(teamId projectId region driveSizeGiB imageRepository endpoints)
        ),
      example: """
      # Team, project, region, and Drive capacity cannot change after creation.
      teamId: team_example
      projectId: prj_example
      region: iad1
      driveSizeGiB: 100
      # Prepared linux/amd64 image in this project's VCR repository.
      imageRepository: ankole-worker
      cpus: 2
      # Must not exceed the account's Sandbox timeout limit.
      sessionTimeoutSeconds: 86400
      env: {}
      endpoints:
        runtimeFabricUrl: wss://ankole.example.com/runtime-fabric/worker
        relayOrigin: https://ankole.example.com
        aiGatewayUrl: https://ankole.example.com/api/v1/ai-gateway
      stopGraceSeconds: 60
      idleReleaseAfter: 15m
      """
    }
  end

  @impl true
  def instance_lifetime(settings), do: Map.get(settings, "sessionTimeoutSeconds", 86_400)

  @impl true
  def check(provider) do
    with {:ok, _} <- sandboxes(provider), do: :ok
  end

  @impl true
  def prepare_image(_provider, image) do
    if Regex.match?(~r/@sha256:[0-9a-f]{64}\z/, image),
      do: :ok,
      else: {:error, :vercel_image_digest_required}
  end

  @impl true
  def prepare_storage(provider, uid) do
    with {:ok, %{"drive" => _}} <-
           Client.request(provider, :post, drive_path(provider, uid),
             json: %{
               projectId: provider.settings["projectId"],
               region: provider.settings["region"],
               maxSizeBytes: provider.settings["driveSizeGiB"] * 1_073_741_824
             }
           ),
         do: :ok
  end

  @impl true
  def create_instance(provider, %{instance_ref: nil} = spec) do
    with :ok <- prepare_image(provider, spec.image) do
      digest = spec.image |> String.split("@") |> List.last()

      body = %{
        projectId: provider.settings["projectId"],
        name: name(provider, spec),
        persistent: false,
        image: provider.settings["imageRepository"] <> "@" <> digest,
        resources: %{vcpus: provider.settings["cpus"], memory: provider.settings["cpus"] * 2048},
        timeout: instance_lifetime(provider.settings) * 1000,
        region: provider.settings["region"],
        env: provider.settings["env"],
        tags: tags(provider, spec),
        networkPolicy: %{mode: "allow-all"},
        mounts: %{
          "/workspace" => %{drive: storage_name(provider, spec.agent_uid), mode: "read-write"}
        }
      }

      case Client.request(provider, :post, "/v4/sandboxes", json: body) do
        {:ok, %{"session" => %{"id" => id}}} ->
          {:ok, id}

        {:error, {:vercel_api, status, code, _} = reason}
        when status in [400, 401, 403, 422] and code != "image_not_ready" ->
          {:rejected, reason}

        other ->
          other
      end
    end
  end

  def create_instance(provider, spec) do
    with {:ok, session} <-
           await_running(
             provider,
             spec.instance_ref,
             System.monotonic_time(:millisecond) + 60_000
           ),
         {:ok, commands} <- commands(provider, session["id"]) do
      if Enum.any?(commands, &entry?/1) do
        {:ok, spec.instance_ref}
      else
        body = %{
          command: @entry_command,
          args: @entry_args,
          cwd: "/repo/app/agent_computer",
          env: Map.merge(provider.settings["env"], spec.env),
          sudo: false,
          wait: false
        }

        with {:ok, %{"command" => _}} <-
               Client.request(provider, :post, session_path(spec.instance_ref) <> "/cmd",
                 json: body
               ),
             do: {:ok, spec.instance_ref}
      end
    end
  end

  @impl true
  def list_instances(provider, uid_or_all) do
    inventory = fn ->
      with {:ok, sandboxes} <- sandboxes(provider) do
        collect(sandboxes, fn sandbox ->
          if uid_or_all == :all or
               sandbox["tags"]["ankole-agent"] == ProviderKind.hash16(uid_or_all),
             do: observe_sandbox(provider, sandbox),
             else: {:ok, []}
        end)
      end
    end

    with {:ok, tagged, rows} <-
           AgentWorkers.inventory_with_workers(provider.provider_id, uid_or_all, inventory) do
      agents = Map.new(rows, &{ProviderKind.hash16(&1.agent_uid), &1.agent_uid})

      agents =
        if uid_or_all == :all,
          do: agents,
          else: Map.put(agents, ProviderKind.hash16(uid_or_all), uid_or_all)

      objects = Enum.map(tagged, fn {hash, object} -> %{object | agent_uid: agents[hash]} end)

      with {:ok, saved} <- collect(rows, &observe_missing_ref(provider, &1, objects)),
           do: {:ok, objects ++ saved}
    end
  end

  @impl true
  def delete_instance(provider, object, :graceful) do
    with {:ok, commands} <- commands(provider, object.instance_ref) do
      if Enum.any?(commands, &(entry?(&1) and is_nil(&1["exitCode"]))) do
        body = %{
          command: "bash",
          args: ["-ec", "kill -TERM \"$(cat /run/ankole-worker.pid)\""],
          sudo: false,
          wait: false
        }

        with {:ok, %{"command" => command}} <-
               Client.request(provider, :post, session_path(object.instance_ref) <> "/cmd",
                 json: body
               ),
             {:ok, %{"command" => finished}} <-
               Client.request(
                 provider,
                 :get,
                 session_path(object.instance_ref) <> "/cmd/" <> Client.path(command["id"]),
                 params: [wait: true]
               ),
             do: command_result(finished)
      else
        delete_instance(provider, object, :now)
      end
    end
  end

  def delete_instance(provider, object, :now) do
    with {:ok, :gone} <- stop_session(provider, object.instance_ref),
         {:ok, sessions} <- sessions(provider, object.sandbox_name) do
      if Enum.all?(sessions, &(&1["status"] in @terminal)) do
        case Client.request(
               provider,
               :delete,
               "/v2/sandboxes/" <> Client.path(object.sandbox_name),
               params: [projectId: provider.settings["projectId"]]
             ) do
          {:ok, _} -> :ok
          {:error, {:vercel_api, 404, _, _}} -> :ok
          error -> error
        end
      else
        :ok
      end
    else
      {:ok, :terminating} -> :ok
      error -> error
    end
  end

  @impl true
  def current_storage_ref(_provider, _uid), do: {:ok, nil, nil}
  @impl true
  def delete_cache(_provider, _uid), do: :ok
  @impl true
  def pause_instance(_provider, _object), do: {:error, :pause_not_supported}
  @impl true
  def resume_instance(_provider, _object), do: {:error, :pause_not_supported}

  @impl true
  def delete_storage(provider, uid, _ref) do
    name = storage_name(provider, uid)

    with {:ok, drives} <-
           Client.list(provider, "/v2/sandboxes/drives", "drives",
             projectId: provider.settings["projectId"],
             sortBy: "name",
             namePrefix: name
           ) do
      case Enum.find(drives, &(&1["name"] == name)) do
        nil ->
          {:ok, nil}

        %{"currentSessionId" => id} when is_binary(id) ->
          {:error, {:vercel_drive_attached, id}}

        _drive ->
          case Client.request(provider, :delete, drive_path(provider, uid),
                 params: [projectId: provider.settings["projectId"]]
               ) do
            {:ok, _} -> {:ok, nil}
            {:error, {:vercel_api, 404, _, _}} -> {:ok, nil}
            error -> error
          end
      end
    end
  end

  defp sandboxes(provider) do
    with {:ok, list} <-
           Client.list(provider, "/v2/sandboxes", "sandboxes",
             project: provider.settings["projectId"],
             tags: "ankole-installation:#{provider.runtime.installation}"
           ) do
      {:ok,
       Enum.filter(list, fn sandbox ->
         tags = sandbox["tags"] || %{}

         tags["ankole-installation"] == provider.runtime.installation and
           tags["ankole-provider"] == provider.provider_id
       end)}
    end
  end

  defp observe_sandbox(provider, sandbox) do
    with {:ok, sessions} <- sessions(provider, sandbox["name"]),
         {:ok, sessions} <- include_current_session(provider, sandbox, sessions) do
      current =
        Enum.filter(
          sessions,
          &(&1["status"] not in @terminal or &1["id"] == sandbox["currentSessionId"])
        )

      hash = sandbox["tags"]["ankole-agent"]
      generation = sandbox["tags"]["ankole-generation"]

      collect(current, fn session ->
        with {:ok, object} <- observation(provider, nil, generation, sandbox["name"], session),
             do: {:ok, [{hash, object}]}
      end)
    end
  end

  defp include_current_session(provider, sandbox, sessions) do
    if Enum.any?(sessions, &(&1["id"] == sandbox["currentSessionId"])) do
      {:ok, sessions}
    else
      with {:ok, %{"session" => session}} <-
             Client.request(provider, :get, session_path(sandbox["currentSessionId"])),
           do: {:ok, [session | sessions]}
    end
  end

  defp observe_missing_ref(_provider, %{instance_ref: nil}, _objects), do: {:ok, []}

  defp observe_missing_ref(provider, row, objects) do
    if Enum.any?(objects, &(&1.instance_ref == row.instance_ref)) do
      {:ok, []}
    else
      case Client.request(provider, :get, session_path(row.instance_ref)) do
        {:ok, %{"session" => %{"status" => status}}} when status in @terminal ->
          ended(provider, row, status)

        {:ok, %{"session" => session}} ->
          with {:ok, object} <-
                 observation(
                   provider,
                   row.agent_uid,
                   row.generation,
                   name(provider, row),
                   session
                 ),
               do: {:ok, [object]}

        {:error, {:vercel_api, 404, _, _}} ->
          ended(provider, row, "session not found")

        error ->
          error
      end
    end
  end

  # A saved session ID was running when create returned it. If its first
  # observation finds it ended, report it once so the generation can end.
  defp ended(provider, %{instance_seen_at: nil} = row, reason) do
    {:ok,
     [
       %{
         agent_uid: row.agent_uid,
         generation: row.generation,
         instance_ref: row.instance_ref,
         sandbox_name: name(provider, row),
         phase: :exited,
         reason: reason,
         started_at: nil
       }
     ]}
  end

  defp ended(_provider, _row, _reason), do: {:ok, []}

  defp observation(provider, uid, generation, name, session) do
    with {:ok, phase, reason} <- phase(provider, session) do
      {:ok,
       %{
         agent_uid: uid,
         generation: generation,
         instance_ref: session["id"],
         sandbox_name: name,
         phase: phase,
         reason: reason,
         started_at:
           DateTime.from_unix!(session["startedAt"] || session["createdAt"], :millisecond)
       }}
    end
  end

  defp phase(provider, %{"status" => "running", "id" => id}) do
    with {:ok, commands} <- commands(provider, id) do
      entries = Enum.filter(commands, &entry?/1)

      cond do
        entries == [] ->
          {:ok, :starting, "Waiting for the committed session to receive its entry command"}

        Enum.any?(entries, &is_nil(&1["exitCode"])) ->
          {:ok, :running, nil}

        true ->
          {:ok, :exited,
           "Worker entry command exited: #{inspect(Enum.map(entries, & &1["exitCode"]))}"}
      end
    end
  end

  defp phase(_provider, %{"status" => "pending"}), do: {:ok, :starting, "Session pending"}

  defp phase(_provider, %{"status" => status}) when status in ~w(stopping snapshotting),
    do: {:ok, :terminating, status}

  defp phase(_provider, %{"status" => status}) when status in @terminal,
    do: {:ok, :exited, status}

  defp await_running(provider, id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :vercel_session_start_timeout}
    else
      case Client.request(provider, :get, session_path(id),
             receive_timeout: min(remaining, 30_000)
           ) do
        {:ok, %{"session" => %{"status" => "running"} = session}} ->
          {:ok, session}

        {:ok, %{"session" => %{"status" => "pending"}}} ->
          Process.sleep(min(remaining, 1_000))
          await_running(provider, id, deadline)

        {:ok, %{"session" => %{"status" => status}}} ->
          {:error, {:vercel_session_not_running, status}}

        error ->
          error
      end
    end
  end

  defp stop_session(provider, id) do
    case Client.request(provider, :get, session_path(id)) do
      {:ok, %{"session" => %{"status" => status}}}
      when status in @terminal ->
        {:ok, :gone}

      {:ok, %{"session" => %{"status" => status}}} when status in ~w(stopping snapshotting) ->
        {:ok, :terminating}

      {:ok, _session} ->
        with {:ok, %{"session" => %{"status" => status}}} <-
               Client.request(provider, :post, session_path(id) <> "/stop"),
             do: {:ok, if(status in @terminal, do: :gone, else: :terminating)}

      {:error, {:vercel_api, 404, _, _}} ->
        {:ok, :gone}

      error ->
        error
    end
  end

  defp sessions(provider, name),
    do:
      Client.list(provider, "/v2/sandboxes/sessions", "sessions",
        project: provider.settings["projectId"],
        name: name
      )

  defp commands(provider, id) do
    with {:ok, %{"commands" => commands}} <-
           Client.request(provider, :get, session_path(id) <> "/cmd"),
         do: {:ok, commands}
  end

  defp entry?(command), do: command["name"] == @entry_command and command["args"] == @entry_args
  defp command_result(%{"exitCode" => 0}), do: :ok

  defp command_result(command),
    do: {:error, {:vercel_command_failed, command["id"], command["exitCode"]}}

  defp session_path(id), do: "/v2/sandboxes/sessions/" <> Client.path(id)

  defp storage_name(provider, uid),
    do: ProviderKind.storage_name(provider.runtime.installation, uid)

  defp drive_path(provider, uid),
    do: "/v2/sandboxes/drives/" <> Client.path(storage_name(provider, uid))

  defp name(provider, spec),
    do: ProviderKind.instance_name(provider.runtime.installation, spec.agent_uid, spec.generation)

  defp tags(provider, spec),
    do: %{
      "ankole-installation" => provider.runtime.installation,
      "ankole-provider" => provider.provider_id,
      "ankole-agent" => ProviderKind.hash16(spec.agent_uid),
      "ankole-generation" => spec.generation,
      "ankole.tenant" => Ankole.Repo.tenant_id!()
    }

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, values} -> {:cont, {:ok, acc ++ values}}
        error -> {:halt, error}
      end
    end)
  end
end
