defmodule Ankole.AgentWorkers.Lambda.Images do
  @moduledoc "Provider-owned MicroVM images and their frozen launch settings."

  alias Ankole.AgentWorkers.Lambda.Client
  alias Ankole.AgentWorkers.Lambda.ContainerImage
  alias Ankole.AgentWorkers.ProviderKind

  def prepare(provider, role) do
    with {:ok, images} <- owned(provider, role) do
      case Enum.filter(images, &selected?(provider, &1)) do
        [] -> build(provider, role)
        [image] -> refresh(provider, image)
        _ -> {:error, :lambda_multiple_images_for_settings}
      end
    end
  end

  def selected(provider, role) do
    with {:ok, images} <- owned(provider, role) do
      case Enum.filter(images, &selected?(provider, &1)) do
        [image] -> active(provider, image)
        [] -> {:error, :lambda_image_not_prepared}
        _ -> {:error, :lambda_multiple_images_for_settings}
      end
    end
  end

  def owned(provider, role) do
    with {:ok, images} <- Client.list(provider, "/microvm-images", nameFilter: prefix(provider)) do
      Enum.reduce_while(images, {:ok, []}, fn image, {:ok, acc} ->
        case Client.request(provider, :get, image_path(image["imageArn"])) do
          {:ok, full} ->
            tags = full["tags"] || %{}

            own? =
              tags["ankole-installation"] == provider.runtime.installation and
                tags["ankole-provider"] == provider.provider_id and
                tags["ankole-role"] == role

            {:cont, {:ok, if(own?, do: [full | acc], else: acc)}}

          {:error, {:lambda_api, 404, _}} ->
            {:cont, {:ok, acc}}

          error ->
            {:halt, error}
        end
      end)
    end
  end

  defp selected?(provider, image) do
    image["tags"]["ankole-source"] == ProviderKind.hash16(provider.runtime.image) and
      image["tags"]["ankole-settings"] == provider.settings_digest
  end

  defp active(provider, %{"latestActiveImageVersion" => version, "state" => state} = image)
       when is_binary(version) and state in ~w(CREATED UPDATED) do
    with {:ok, config} <-
           Client.request(
             provider,
             :get,
             image_path(image["imageArn"]) <> "/versions/" <> Client.path(version)
           ) do
      if config["state"] == "SUCCESSFUL" and config["status"] == "ACTIVE",
        do: {:ok, config},
        else: {:error, {:lambda_image_unavailable, config["state"], config["stateReason"]}}
    end
  end

  defp active(_provider, image), do: {:error, {:lambda_image_unavailable, image["state"]}}

  defp refresh(_provider, %{"state" => state}) when state in ~w(CREATING UPDATING),
    do: {:pending, :lambda_image_building}

  defp refresh(provider, image) do
    with {:ok, current} <- active(provider, image),
         {:ok, versions} <-
           Client.list(
             provider,
             "/managed-microvm-images/" <> Client.path(current["baseImageArn"]) <> "/versions"
           ) do
      case Enum.find(
             versions,
             &same_base_version?(&1["imageVersion"], current["baseImageVersion"])
           ) do
        %{"status" => "AVAILABLE"} -> :ok
        _ -> patch(provider, image, current, versions)
      end
    end
  end

  # AWS lists a managed version as "1", but reports it as "1.0" on a built image.
  defp same_base_version?(listed, built), do: listed == built or listed <> ".0" == built

  defp patch(provider, image, current, versions) do
    case newest_available(versions) do
      nil ->
        {:error, :lambda_managed_image_unavailable}

      base ->
        body =
          current
          |> Map.take(
            ~w(baseImageArn codeArtifact environmentVariables egressNetworkConnectors cpuConfigurations resources additionalOsCapabilities hooks)
          )
          |> Map.merge(%{
            "baseImageVersion" => base["imageVersion"],
            "buildRoleArn" => provider.settings["buildRoleArn"],
            "clientToken" => token({image["imageArn"], base["imageVersion"]})
          })

        pending(Client.request(provider, :put, image_path(image["imageArn"]), body))
    end
  end

  defp build(provider, role) do
    # A FROM-only build can reuse an OCI image that Lambda cannot activate.
    # A build step exports a new image and keeps the Worker runtime config.
    with {:ok, container} <- ContainerImage.resolve(provider, provider.runtime.image),
         {:ok, base} <- managed_base(provider),
         name =
           prefix(provider) <>
             ProviderKind.hash16(
               token({container, provider.provider_id, provider.settings_digest, role})
             ),
         {:ok, {_filename, zip}} <-
           :zip.create(
             ~c"worker.zip",
             [{~c"Dockerfile", "FROM " <> container <> "\nRUN true\n"}],
             [:memory]
           ),
         {:ok, artifact} <- Client.upload(provider, "ankole-microvms/" <> name <> ".zip", zip) do
      env =
        provider.settings["env"]
        |> Map.merge(%{
          "ANKOLE_WORKER_BOOTSTRAP" => "lambda",
          "ANKOLE_WORKER_TASK" => if(role == "storage", do: "delete_storage", else: "worker"),
          "ANKOLE_RUNTIME_FABRIC_ENDPOINT" => provider.settings["endpoints"]["runtimeFabricUrl"]
        })

      body = %{
        "name" => name,
        "baseImageArn" => base["imageArn"],
        "baseImageVersion" => base["imageVersion"],
        "buildRoleArn" => provider.settings["buildRoleArn"],
        "codeArtifact" => %{"uri" => artifact},
        "cpuConfigurations" => [%{"architecture" => "ARM_64"}],
        "resources" => [%{"minimumMemoryInMiB" => provider.settings["memoryMiB"]}],
        "additionalOsCapabilities" => ["ALL"],
        "egressNetworkConnectors" => [provider.settings["networkConnectorArn"]],
        "environmentVariables" => env,
        "hooks" => %{
          "port" => 8080,
          "microvmImageHooks" => %{"ready" => "ENABLED", "readyTimeoutInSeconds" => 120},
          "microvmHooks" => %{
            "run" => "ENABLED",
            "runTimeoutInSeconds" => 60,
            "terminate" => "ENABLED",
            "terminateTimeoutInSeconds" => 60
          }
        },
        "tags" => %{
          "ankole-installation" => provider.runtime.installation,
          "ankole-provider" => provider.provider_id,
          "ankole-role" => role,
          "ankole-source" => ProviderKind.hash16(provider.runtime.image),
          "ankole-settings" => provider.settings_digest
        },
        "clientToken" => token({name, base["imageVersion"]})
      }

      pending(Client.request(provider, :post, "/microvm-images", body))
    end
  end

  defp managed_base(provider) do
    with {:ok, images} <- Client.list(provider, "/managed-microvm-images") do
      case Enum.find(images, &String.ends_with?(&1["imageArn"], ":microvm-image:al2023-1")) do
        nil ->
          {:error, :lambda_managed_image_unavailable}

        image ->
          with {:ok, versions} <-
                 Client.list(
                   provider,
                   "/managed-microvm-images/" <> Client.path(image["imageArn"]) <> "/versions"
                 ) do
            case newest_available(versions) do
              nil -> {:error, :lambda_managed_image_unavailable}
              version -> {:ok, version}
            end
          end
      end
    end
  end

  defp newest_available(versions),
    do:
      versions
      |> Enum.filter(&(&1["status"] == "AVAILABLE"))
      |> Enum.max_by(& &1["createdAt"], fn -> nil end)

  defp pending({:ok, _}), do: {:pending, :lambda_image_building}
  defp pending({:error, {:lambda_api, 409, _}}), do: {:pending, :lambda_image_building}
  defp pending(error), do: error
  defp image_path(id), do: "/microvm-images/" <> Client.path(id)
  defp prefix(provider), do: "ankole-" <> provider.runtime.installation <> "-"

  defp token(value),
    do:
      value
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
end
