defmodule Ankole.E2E.ComposeDeployment do
  @moduledoc "The released Compose deployment and its Console HTTP client for upgrade tests."

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]

  @root Path.expand("../../..", __DIR__)
  @compose Path.join(@root, "tools/deploy/docker-compose/compose.yaml")
  @external_resource Path.join(@root, "tools/e2e/pooled-worker-revision")
  @legacy_revision @external_resource |> File.read!() |> String.trim()

  def start_legacy! do
    suffix = Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
    project = "e2e-up-" <> suffix
    directory = Path.join(System.tmp_dir!(), project)
    File.mkdir_p!(directory)

    {legacy, 0} =
      System.cmd("git", ["show", "#{@legacy_revision}:tools/deploy/docker-compose/compose.yaml"],
        cd: @root
      )

    legacy_path = Path.join(directory, "legacy.yaml")
    override_path = Path.join(directory, "test.json")
    seed_path = Path.join(directory, "providers.yaml")
    File.write!(legacy_path, legacy)

    # Only image selection, the test's network, and a host port differ from
    # deployment YAML. The migration and its dependency remain unchanged.
    File.write!(
      override_path,
      Ankole.JSON.encode!(%{
        services: %{
          postgresql: %{pull_policy: "never"},
          migrate: %{pull_policy: "never"},
          "bootstrap-worker-auth-key": %{pull_policy: "never", profiles: ["legacy"]},
          worker: %{pull_policy: "never", profiles: ["legacy"]},
          "control-plane": %{pull_policy: "never", ports: ["127.0.0.1::4000"]}
        }
      })
    )

    environment = [
      {"COMPOSE_PROJECT_NAME", project},
      {"ANKOLE_WORKER_INSTALLATION", project},
      {"ANKOLE_SECRET_BASE", Base.encode64(:crypto.strong_rand_bytes(48))},
      {"RELEASE_COOKIE", Base.encode16(:crypto.strong_rand_bytes(24))},
      {"POSTGRES_PASSWORD", Base.encode16(:crypto.strong_rand_bytes(24))},
      {"ANKOLE_HOST", "127.0.0.1"},
      {"ACME_EMAIL", "compose-e2e@example.test"},
      {"ANKOLE_DOCKER_GID", "0"},
      {"ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY", Base.encode64(:crypto.strong_rand_bytes(32))},
      {"ANKOLE_WORKER_IMAGE",
       "ghcr.io/agentbull/ankole-agent-computer-worker:#{@legacy_revision}"},
      {"ANKOLE_CONTROL_PLANE_IMAGE",
       "ghcr.io/agentbull/ankole-agent-control-plane:#{@legacy_revision}"}
    ]

    deployment = %{
      project: project,
      directory: directory,
      compose: legacy_path,
      override: override_path,
      seed: seed_path,
      env: environment,
      origin: nil,
      cookies: %{},
      csrf: nil,
      token: nil,
      tenant_id: nil
    }

    on_exit(fn -> cleanup(deployment) end)
    compose!(deployment, ["--profile", "legacy", "up", "-d", "worker"])
    wait_http!(deployment)
  end

  def upgrade!(deployment, opts \\ []) do
    compose!(deployment, ["stop", "control-plane"])
    seed = File.read!(Path.join(@root, "tools/deploy/docker-compose/worker-providers.yaml"))

    File.write!(
      deployment.seed,
      String.replace(seed, "network: ankole_workers", "network: #{deployment.project}_workers")
    )

    image = System.fetch_env!("ANKOLE_E2E_CONTROL_PLANE_IMAGE")
    volumes = ["#{deployment.seed}:/etc/ankole/worker-providers.yaml:ro"]

    volumes =
      case Keyword.get(opts, :lark_base_url) do
        nil -> volumes
        base_url -> [lark_runtime_override!(deployment, image, base_url) | volumes]
      end

    File.write!(
      deployment.override,
      Ankole.JSON.encode!(%{
        services: %{
          postgresql: %{pull_policy: "never"},
          migrate: %{pull_policy: "never"},
          "control-plane": %{
            pull_policy: "never",
            ports: ["127.0.0.1::4000"],
            volumes: volumes
          }
        }
      })
    )

    deployment = %{
      deployment
      | compose: @compose,
        env:
          List.keystore(
            deployment.env,
            "ANKOLE_CONTROL_PLANE_IMAGE",
            0,
            {"ANKOLE_CONTROL_PLANE_IMAGE", image}
          )
    }

    try do
      compose!(deployment, ["up", "-d", "control-plane"])
    rescue
      error in ExUnit.AssertionError ->
        logs = compose!(deployment, ["logs", "--no-color", "--tail", "100", "migrate"])
        flunk(Exception.message(error) <> "\nMigration logs:\n" <> logs)
    end

    # The old release needs bearer minting until pooled-worker-revision includes Console cookies.
    deployment = deployment |> Map.put(:token, nil) |> wait_http!()
    %{"tenant" => %{"id" => tenant_id}} = api!(deployment, :get, "/api/v1/site/privileged-tenant")
    %{deployment | tenant_id: tenant_id}
  end

  # The release keeps its production endpoint rule. Only this deployment's
  # runtime configuration adds the existing fake-platform transport seam.
  defp lark_runtime_override!(deployment, image, base_url) do
    container = String.trim(docker!(["create", "--entrypoint", "/bin/true", image]))

    try do
      version_file = Path.join(deployment.directory, "start_erl.data")
      docker!(["cp", "#{container}:/app/releases/start_erl.data", version_file])
      [_erts, version] = version_file |> File.read!() |> String.split()
      target = "/app/releases/#{version}/runtime.exs"
      runtime_file = Path.join(deployment.directory, "runtime.exs")
      docker!(["cp", "#{container}:#{target}", runtime_file])

      File.write!(
        runtime_file,
        File.read!(runtime_file) <>
          "\nconfig :ankole, Ankole.Plugins.LarkAdapter.Config, " <>
          "client_opts: [base_url: #{inspect(base_url)}]\n"
      )

      "#{runtime_file}:#{target}:ro"
    after
      docker!(["rm", container])
    end
  end

  def setup_admin!(deployment) do
    {response, deployment} = request!(deployment, :get, "/setup")
    [_, csrf] = Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, response.body)
    deployment = %{deployment | csrf: csrf}

    container = String.trim(compose!(deployment, ["ps", "-q", "control-plane"]))

    code =
      docker!(["logs", container])
      |> String.split("\n", trim: true)
      |> Enum.find_value(fn line ->
        case Ankole.JSON.decode(line) do
          {:ok, %{"event" => "setup.bootstrap.activation_code_reset", "activation_code" => code}} ->
            code

          _other ->
            nil
        end
      end)

    assert is_binary(code), "The old control plane must print its setup activation code"

    {_response, deployment} =
      request!(deployment, :post, "/.internal-apis/setup/sessions", %{activationCode: code})

    {_response, deployment} =
      request!(deployment, :put, "/.internal-apis/setup/identity-providers/local-main", %{
        adapterID: "local",
        config: %{},
        enabled: true
      })

    {setup, deployment} =
      request!(deployment, :post, "/.internal-apis/setup/local-admin", %{
        email: "compose-e2e@example.test",
        password: "Compose-E2E-Only-1234",
        display_name: "Compose test owner"
      })

    {session, deployment} = request!(deployment, :get, "/.internal-apis/session")

    {response, deployment} = request!(deployment, :get, Map.fetch!(setup.body, "returnTo"))

    [_, csrf] = Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, response.body)
    deployment = %{deployment | csrf: csrf}

    {token, deployment} =
      request!(deployment, :post, "/oauth/token", %{
        grant_type: "urn:ankole:params:oauth:grant-type:browser-session"
      })

    {%{deployment | token: Map.fetch!(token.body, "access_token")},
     Map.fetch!(session.body, "principalUID")}
  end

  def api!(deployment, method, path, body \\ nil) do
    {response, _deployment} = request!(deployment, method, path, body)
    response.body
  end

  def compose!(deployment, args) do
    docker!(
      [
        "compose",
        "-p",
        deployment.project,
        "-f",
        deployment.compose,
        "-f",
        deployment.override | args
      ],
      deployment.env
    )
  end

  def docker!(args, env \\ []) do
    {output, status} = System.cmd("docker", args, env: env, stderr_to_stdout: true)
    assert status == 0, "Docker command failed (#{status}):\n#{output}"
    output
  end

  defp request!(deployment, method, path, body \\ nil) do
    headers = [{"origin", deployment.origin}]

    headers =
      if deployment.tenant_id,
        do: [{"x-ankole-tenant", deployment.tenant_id} | headers],
        else: headers

    headers = if deployment.csrf, do: [{"x-csrf-token", deployment.csrf} | headers], else: headers

    headers =
      if deployment.token,
        do: [{"authorization", "Bearer " <> deployment.token} | headers],
        else: headers

    headers = [
      {"cookie", Enum.map_join(deployment.cookies, "; ", fn {k, v} -> k <> "=" <> v end)}
      | headers
    ]

    options = [
      url: deployment.origin <> path,
      method: method,
      headers: headers,
      retry: false,
      redirect: false
    ]

    options = if body, do: Keyword.put(options, :json, body), else: options
    response = Req.request!(options)

    assert response.status == 200,
           "#{method} #{path}: #{response.status} #{inspect(response.body)}"

    cookies =
      Enum.reduce(Req.Response.get_header(response, "set-cookie"), deployment.cookies, fn cookie,
                                                                                          acc ->
        [name, value] =
          cookie |> String.split(";", parts: 2) |> hd() |> String.split("=", parts: 2)

        Map.put(acc, name, value)
      end)

    {response, %{deployment | cookies: cookies}}
  end

  def wait_http!(deployment) do
    origin = "http://" <> String.trim(compose!(deployment, ["port", "control-plane", "4000"]))
    deployment = %{deployment | origin: origin}

    assert {:ok, true} =
             wait_until(deadline(120_000), fn ->
               case Req.get(deployment.origin <> "/.internal-apis/setup/state",
                      retry: false,
                      receive_timeout: 1_000
                    ) do
                 {:ok, %{status: 200}} ->
                   true

                 {:error, %Req.TransportError{reason: reason}}
                 when reason in [:econnrefused, :closed, :timeout] ->
                   false

                 other ->
                   flunk("Control-plane HTTP failed: #{inspect(other)}")
               end
             end)

    deployment
  end

  defp cleanup(deployment) do
    names =
      docker!([
        "ps",
        "-aq",
        "--filter",
        "label=ankole.installation=#{deployment.project}",
        "--filter",
        "label=ankole.provider=docker"
      ])

    for name <- String.split(names, "\n", trim: true) do
      docker!(["stop", "--time", "30", name])
      docker!(["rm", name])
    end

    # Use the legacy file for teardown: it also declares the old Home volume.
    compose!(deployment, ["--profile", "legacy", "down", "--volumes", "--remove-orphans"])

    # The new deployment can add volumes and networks absent from the old file.
    for kind <- ["volume", "network"] do
      objects =
        docker!([
          kind,
          "ls",
          "-q",
          "--filter",
          "label=com.docker.compose.project=#{deployment.project}"
        ])

      for object <- String.split(objects, "\n", trim: true), do: docker!([kind, "rm", object])
    end

    volumes =
      docker!([
        "volume",
        "ls",
        "-q",
        "--filter",
        "label=ankole.installation=#{deployment.project}",
        "--filter",
        "label=ankole.provider=docker"
      ])

    for volume <- String.split(volumes, "\n", trim: true), do: docker!(["volume", "rm", volume])
    File.rm_rf!(deployment.directory)
  end
end
