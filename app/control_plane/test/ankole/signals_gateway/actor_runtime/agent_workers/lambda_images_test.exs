defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.LambdaImagesTest do
  use ExUnit.Case, async: false
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.{Config, Lambda, ProviderKind}
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Lambda.{ContainerImage, Images}
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.{Configuration, Provider}

  @fixtures Path.expand("../../../../fixtures/worker_providers/lambda/responses.json", __DIR__)

  setup do
    for key <- [:lambda_api_req_options, :lambda_registry_req_options] do
      previous = Application.get_env(:ankole, key)
      Application.put_env(:ankole, key, plug: {Req.Test, key})

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ankole, key, previous),
          else: Application.delete_env(:ankole, key)
      end)
    end

    {:ok, runtime} = Config.fetch()
    {:ok, settings} = Configuration.parse(Lambda.definition().schema, Lambda.definition().example)

    provider = %Provider{
      provider_id: "lambda-test",
      kind: "lambda",
      settings: settings,
      settings_digest: Configuration.digest(Lambda.definition().schema, settings),
      secrets: %{"accessKeyId" => "AKIAEXAMPLE", "secretAccessKey" => "test-secret"},
      runtime: %{runtime | installation: "prod", image: "registry.example/worker:revision"}
    }

    %{provider: provider}
  end

  test "builds a provider-owned arm64 image from a public registry and uploads the exact Dockerfile",
       %{provider: provider} do
    {manifest, digest} = manifest()
    registry(manifest, digest)

    Req.Test.stub(:lambda_api_req_options, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/2025-09-09/microvm-images"} ->
          Req.Test.json(conn, %{"items" => []})

        {"GET", "/2025-09-09/managed-microvm-images"} ->
          Req.Test.json(conn, fixture("managed_images"))

        {"GET", "/2025-09-09/managed-microvm-images/" <> _} ->
          Req.Test.json(conn, fixture("managed_versions"))

        {"PUT", "/ankole-microvm-builds/ankole-microvms/" <> _name} ->
          assert conn.host == "s3.us-east-1.amazonaws.com"
          assert Plug.Conn.get_req_header(conn, "host") == ["s3.us-east-1.amazonaws.com"]

          assert hd(Plug.Conn.get_req_header(conn, "authorization")) =~
                   "/us-east-1/s3/aws4_request"

          assert hd(Plug.Conn.get_req_header(conn, "authorization")) =~
                   "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date,"

          {:ok, zip, conn} = Plug.Conn.read_body(conn)

          assert Plug.Conn.get_req_header(conn, "x-amz-content-sha256") == [
                   Base.encode16(:crypto.hash(:sha256, zip), case: :lower)
                 ]

          assert {:ok, [{~c"Dockerfile", dockerfile}]} = :zip.extract(zip, [:memory])
          assert dockerfile == "FROM registry.example/worker@#{digest}\n"
          Plug.Conn.send_resp(conn, 200, "")

        {"POST", "/2025-09-09/microvm-images"} ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          body = Ankole.JSON.decode!(raw)
          assert body["resources"] == [%{"minimumMemoryInMiB" => 4096}]
          assert body["cpuConfigurations"] == [%{"architecture" => "ARM_64"}]
          assert body["additionalOsCapabilities"] == ["ALL"]
          assert body["buildRoleArn"] == provider.settings["buildRoleArn"]
          assert body["baseImageArn"] == fixture("version")["baseImageArn"]
          assert body["hooks"] == fixture("version")["hooks"]
          assert body["environmentVariables"] == fixture("version")["environmentVariables"]

          assert body["tags"] == %{
                   "ankole-installation" => "prod",
                   "ankole-provider" => "lambda-test",
                   "ankole-role" => "worker",
                   "ankole-settings" => provider.settings_digest,
                   "ankole-source" => ProviderKind.hash16(provider.runtime.image)
                 }

          assert String.starts_with?(body["name"], "ankole-prod-")
          assert byte_size(body["name"]) <= 64

          assert body["codeArtifact"] == %{
                   "uri" => "s3://ankole-microvm-builds/ankole-microvms/#{body["name"]}.zip"
                 }

          refute raw =~ "WORKER_AUTH_KEY"
          send(self(), {:image_name, body["name"]})
          Req.Test.json(conn, fixture("build_response"))
      end
    end)

    assert {:pending, :lambda_image_building} =
             Lambda.prepare_image(provider, provider.runtime.image)

    assert_received {:image_name, first}

    assert {:pending, :lambda_image_building} =
             Lambda.prepare_image(provider, provider.runtime.image)

    assert_received {:image_name, ^first}
  end

  test "tag plus digest selects the digest and verifies the architecture", %{provider: provider} do
    {manifest, digest} = manifest()
    registry(manifest, digest)

    assert {:ok, "registry.example/worker@" <> ^digest} =
             ContainerImage.resolve(provider, "registry.example/worker:revision@#{digest}")

    Req.Test.stub(:lambda_registry_req_options, fn conn ->
      if String.contains?(conn.request_path, "/manifests/"),
        do: Plug.Conn.send_resp(conn, 200, manifest),
        else: Req.Test.json(conn, %{"os" => "linux", "architecture" => "amd64"})
    end)

    assert {:error, :lambda_arm64_image_required} =
             ContainerImage.resolve(provider, "registry.example/worker:revision")
  end

  test "private ECR pulls use the AWS token only at its matching registry", %{provider: provider} do
    {manifest, digest} = manifest()

    Req.Test.stub(:lambda_api_req_options, fn conn ->
      assert conn.host == "api.ecr.us-east-1.amazonaws.com"
      assert Plug.Conn.get_req_header(conn, "host") == ["api.ecr.us-east-1.amazonaws.com"]

      assert Plug.Conn.get_req_header(conn, "x-amz-target") == [
               "AmazonEC2ContainerRegistry_V20150921.GetAuthorizationToken"
             ]

      assert hd(Plug.Conn.get_req_header(conn, "authorization")) =~ "/us-east-1/ecr/aws4_request"

      assert hd(Plug.Conn.get_req_header(conn, "authorization")) =~
               "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date;x-amz-target,"

      conn
      |> Plug.Conn.put_resp_content_type("application/x-amz-json-1.1")
      |> Plug.Conn.send_resp(200, Ankole.JSON.encode!(fixture("ecr_token")))
    end)

    Req.Test.stub(:lambda_registry_req_options, fn conn ->
      assert conn.host == "123456789012.dkr.ecr.us-east-1.amazonaws.com"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Basic QVdTOmZha2U="]

      if String.contains?(conn.request_path, "/manifests/"),
        do: Plug.Conn.send_resp(conn, 200, manifest),
        else: Req.Test.json(conn, %{"os" => "linux", "architecture" => "arm64"})
    end)

    assert {:ok, "123456789012.dkr.ecr.us-east-1.amazonaws.com/worker@" <> ^digest} =
             ContainerImage.resolve(
               provider,
               "123456789012.dkr.ecr.us-east-1.amazonaws.com/worker:revision"
             )
  end

  test "image-list pagination retains exact provider ownership and build failures", %{
    provider: provider
  } do
    own =
      fixture("image")
      |> put_in(["tags", "ankole-source"], ProviderKind.hash16(provider.runtime.image))
      |> put_in(["tags", "ankole-settings"], provider.settings_digest)

    peer = own |> Map.put("imageArn", "peer-image") |> put_in(["tags", "ankole-provider"], "peer")

    Req.Test.stub(:lambda_api_req_options, fn conn ->
      case conn.request_path do
        "/2025-09-09/microvm-images" ->
          if conn.query_params["nextToken"] == "next-page",
            do: Req.Test.json(conn, %{"items" => [Map.delete(own, "tags")]}),
            else:
              Req.Test.json(conn, %{
                "items" => [Map.delete(peer, "tags")],
                "nextToken" => "next-page"
              })

        "/2025-09-09/microvm-images/peer-image" ->
          Req.Test.json(conn, peer)

        _ ->
          Req.Test.json(conn, own)
      end
    end)

    assert {:ok, [^own]} = Images.owned(provider, "worker")
    assert {:ok, []} = Images.owned(%{provider | provider_id: "other-provider"}, "worker")
    # The SDK declares CREATION_FAILED; the real service returned CREATE_FAILED.
    for state <- ~w(CREATION_FAILED CREATE_FAILED) do
      failed = own |> Map.delete("latestActiveImageVersion") |> Map.put("state", state)

      Req.Test.stub(:lambda_api_req_options, fn conn ->
        if conn.request_path == "/2025-09-09/microvm-images",
          do: Req.Test.json(conn, %{"items" => [Map.delete(failed, "tags")]}),
          else: Req.Test.json(conn, failed)
      end)

      assert {:error, {:lambda_image_unavailable, ^state}} = Images.prepare(provider, "worker")
    end

    failed = Map.put(own, "state", "UPDATE_FAILED")

    Req.Test.stub(:lambda_api_req_options, fn conn ->
      if conn.request_path == "/2025-09-09/microvm-images",
        do: Req.Test.json(conn, %{"items" => [Map.delete(failed, "tags")]}),
        else: Req.Test.json(conn, failed)
    end)

    assert {:error, {:lambda_image_unavailable, "UPDATE_FAILED"}} =
             Images.prepare(provider, "worker")

    assert {:error, {:lambda_image_unavailable, "UPDATE_FAILED"}} =
             Images.selected(provider, "worker")
  end

  defp registry(manifest, digest) do
    Req.Test.stub(:lambda_registry_req_options, fn conn ->
      case {conn.host, Plug.Conn.get_req_header(conn, "authorization"), conn.request_path} do
        {"registry.example", [], _} ->
          conn
          |> Plug.Conn.put_resp_header(
            "www-authenticate",
            ~s(Bearer realm="https://auth.example/token",service="registry.example",scope="repository:worker:pull")
          )
          |> Plug.Conn.send_resp(401, "")

        {"auth.example", [], "/token"} ->
          assert conn.query_params == %{
                   "service" => "registry.example",
                   "scope" => "repository:worker:pull"
                 }

          Req.Test.json(conn, %{"token" => "public-pull"})

        {"registry.example", ["Bearer public-pull"], "/v2/worker/manifests/revision"} ->
          Req.Test.json(conn, %{
            "schemaVersion" => 2,
            "manifests" => [
              %{"digest" => digest, "platform" => %{"os" => "linux", "architecture" => "arm64"}}
            ]
          })

        {"registry.example", ["Bearer public-pull"], "/v2/worker/manifests/" <> ^digest} ->
          Plug.Conn.send_resp(conn, 200, manifest)

        {"registry.example", ["Bearer public-pull"], "/v2/worker/blobs/sha256:config"} ->
          Req.Test.json(conn, %{"os" => "linux", "architecture" => "arm64"})
      end
    end)
  end

  defp manifest do
    raw =
      ~s({"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"digest":"sha256:config"},"layers":[]})

    {raw, "sha256:" <> Base.encode16(:crypto.hash(:sha256, raw), case: :lower)}
  end

  defp fixture(key), do: @fixtures |> File.read!() |> Ankole.JSON.decode!() |> Map.fetch!(key)
end
