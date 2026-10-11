defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Lambda.ContainerImage do
  @moduledoc "Resolves a public or ECR container image to its linux/arm64 manifest."

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Lambda.Client

  @accept Enum.join(
            [
              "application/vnd.oci.image.index.v1+json",
              "application/vnd.docker.distribution.manifest.list.v2+json",
              "application/vnd.oci.image.manifest.v1+json",
              "application/vnd.docker.distribution.manifest.v2+json"
            ],
            ", "
          )

  def resolve(provider, image) do
    with {:ok, registry, repository, reference} <- parse(image),
         {:ok, auth} <- authentication(provider, registry),
         {:ok, raw, auth} <- get(registry, repository, "manifests/" <> reference, auth),
         :ok <- verify_reference(reference, raw),
         {:ok, digest} <- arm64_manifest(registry, repository, raw, auth) do
      {:ok, registry <> "/" <> repository <> "@" <> digest}
    end
  end

  defp verify_reference("sha256:" <> expected, raw) do
    if Base.encode16(:crypto.hash(:sha256, raw), case: :lower) == expected,
      do: :ok,
      else: {:error, :lambda_container_digest_mismatch}
  end

  defp verify_reference(_tag, _raw), do: :ok

  defp parse(image) do
    case Regex.run(
           ~r/\A([^\s\/]+)\/([^\s@:]+)(?::([A-Za-z0-9_][A-Za-z0-9_.-]*))?(?:@(sha256:[a-f0-9]{64}))?\z/,
           image
         ) do
      [_, registry, repository | reference] ->
        {:ok, registry, repository, Enum.find(Enum.reverse(reference), "latest", &(&1 != ""))}

      _ ->
        {:error, :lambda_qualified_container_image_required}
    end
  end

  defp authentication(provider, registry) do
    case Regex.run(~r/\A[0-9]{12}\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com\z/, registry) do
      [_, region] ->
        with {:ok, %{"authorizationData" => entries}} <- Client.ecr_token(provider, region) do
          case Enum.find(entries, &(&1["proxyEndpoint"] == "https://" <> registry)) do
            %{"authorizationToken" => token} -> {:ok, "Basic " <> token}
            _ -> {:error, :lambda_ecr_registry_not_authorized}
          end
        end

      _ ->
        {:ok, nil}
    end
  end

  defp arm64_manifest(registry, repository, raw, auth) do
    case Ankole.JSON.decode(raw) do
      {:ok, %{"manifests" => entries}} ->
        case Enum.filter(
               entries,
               &(get_in(&1, ["platform", "os"]) == "linux" and
                   get_in(&1, ["platform", "architecture"]) == "arm64")
             ) do
          [%{"digest" => digest}] ->
            with {:ok, manifest, auth} <- get(registry, repository, "manifests/" <> digest, auth),
                 {:ok, actual} <- arm64_manifest(registry, repository, manifest, auth) do
              if actual == digest,
                do: {:ok, digest},
                else: {:error, :lambda_container_digest_mismatch}
            end

          _ ->
            {:error, :lambda_arm64_manifest_not_unique}
        end

      {:ok, %{"config" => %{"digest" => config}}} ->
        with {:ok, raw_config, _auth} <- get(registry, repository, "blobs/" <> config, auth),
             {:ok, %{"os" => "linux", "architecture" => "arm64"}} <-
               Ankole.JSON.decode(raw_config) do
          {:ok, "sha256:" <> Base.encode16(:crypto.hash(:sha256, raw), case: :lower)}
        else
          {:error, _reason} = error -> error
          _ -> {:error, :lambda_arm64_image_required}
        end

      _ ->
        {:error, :lambda_invalid_container_manifest}
    end
  end

  defp get(registry, repository, resource, auth) do
    url = "https://#{registry}/v2/#{repository}/#{resource}"

    headers =
      if auth, do: [{"authorization", auth}, {"accept", @accept}], else: [{"accept", @accept}]

    case request(url, headers: headers, decode_body: false) do
      {:ok, %{status: 200, body: raw}} ->
        {:ok, raw, auth}

      {:ok, %{status: 401} = response} when is_nil(auth) ->
        with {:ok, token} <- bearer_token(response),
             do: get(registry, repository, resource, "Bearer " <> token)

      {:ok, %{status: status}} ->
        {:error, {:lambda_container_registry, status}}

      {:error, reason} ->
        {:error, {:lambda_container_registry, reason}}
    end
  end

  defp bearer_token(response) do
    case Req.Response.get_header(response, "www-authenticate") do
      ["Bearer " <> challenge] ->
        fields =
          Regex.scan(~r/(realm|service|scope)="([^"]*)"/, challenge)
          |> Map.new(fn [_, k, v] -> {k, v} end)

        with "https://" <> _ = realm <- fields["realm"],
             {:ok, %{status: 200, body: body}} <-
               request(realm, params: Map.drop(fields, ["realm"])),
             token when is_binary(token) <- body["token"] || body["access_token"] do
          {:ok, token}
        else
          _ -> {:error, :lambda_container_registry_authentication_failed}
        end

      _ ->
        {:error, :lambda_container_registry_authentication_failed}
    end
  end

  defp request(url, opts) do
    [retry: false, receive_timeout: 30_000, redirect_log_level: false]
    |> Keyword.merge(Application.get_env(:ankole, :lambda_registry_req_options, []))
    |> Req.new()
    |> Req.get([url: url] ++ opts)
  end
end
