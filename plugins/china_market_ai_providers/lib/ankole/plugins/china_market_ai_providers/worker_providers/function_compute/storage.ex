defmodule Ankole.Plugins.ChinaMarketAIProviders.WorkerProviders.FunctionCompute.Storage do
  @moduledoc "AgenticSpace ownership and selected-instance OSS deletion."

  alias Ankole.Plugins.ChinaMarketAIProviders.WorkerProviders.FunctionCompute, as: FC
  alias Ankole.Plugins.ChinaMarketAIProviders.WorkerProviders.FunctionCompute.Client
  alias Ankole.Plugins.ChinaMarketAIProviders.WorkerProviders.FunctionCompute.Images
  alias Ankole.AgentWorkers.ProviderKind

  def prepare(%{settings: %{"storage" => %{"oss" => _}}}, _uid), do: :ok

  def prepare(provider, uid) do
    with {:ok, spaces} <- spaces(provider),
         {:ok, space} <- ensure_space(provider, uid, spaces),
         {:ok, points} <- access_points(provider, uid),
         {:ok, point} <- ensure_access_point(provider, uid, space, points),
         {:ok, volumes} <- volumes(provider),
         do: ensure_volume(provider, uid, point, volumes)
  end

  def mounts(provider, uid) do
    metadata = %{"fc.sandbox.auth.role" => provider.settings["ramRole"]}

    metadata =
      if provider.settings["vpc"],
        do:
          Map.put(
            metadata,
            "fc.sandbox.network.vpc",
            Ankole.JSON.encode!(provider.settings["vpc"])
          ),
        else: metadata

    case provider.settings["storage"] do
      %{"agenticFs" => _} ->
        %{
          metadata: metadata,
          body: %{
            "volumeMounts" => [%{"name" => mount_name(provider, uid), "path" => "/workspace"}]
          }
        }

      %{"oss" => oss} ->
        config = %{
          "mountPoints" => [
            %{
              "bucketName" => oss["bucket"],
              "mountDir" => "/workspace",
              "bucketPath" => String.trim_trailing(oss["root"], "/") <> "/" <> uid,
              "endpoint" => "https://oss-#{provider.settings["region"]}.aliyuncs.com",
              "readOnly" => false
            }
          ]
        }

        %{
          metadata: Map.put(metadata, "fc.sandbox.storage.oss", Ankole.JSON.encode!(config)),
          body: %{}
        }
    end
  end

  def delete(%{settings: %{"storage" => %{"agenticFs" => fs}}} = provider, uid, ref) do
    with {:ok, volumes} <- volumes(provider),
         {:ok, points} <- access_points(provider, uid),
         {:ok, spaces} <- spaces(provider) do
      volume =
        Enum.find(volumes, &String.starts_with?(&1["volumeName"], name(provider, uid) <> "-ap-"))

      space =
        Enum.find(
          spaces,
          &(String.trim_trailing(&1["FileSystemPath"], "/") == "/" <> name(provider, uid))
        )

      cond do
        volume ->
          pending(
            Client.pop(
              provider,
              "DeleteVolume",
              :delete,
              "/volumes/" <> Client.path(volume["volumeID"]),
              nil,
              %{"teamID" => provider.settings["teamId"]}
            ),
            ref
          )

        points != [] ->
          pending(
            Client.nas(provider, "DeleteAccessPoint", %{
              "FileSystemId" => fs["fileSystemId"],
              "AccessPointId" => hd(points)["AccessPointId"]
            }),
            ref
          )

        space ->
          pending(
            Client.nas(provider, "DeleteAgenticSpace", %{
              "FileSystemId" => fs["fileSystemId"],
              "AgenticSpaceId" => space["AgenticSpaceId"]
            }),
            ref
          )

        true ->
          {:ok, nil}
      end
    end
  end

  def delete(provider, uid, nil) do
    with :ok <- Images.prepare(provider, provider.runtime.image),
         {:ok, template} <- Images.selected(provider, provider.runtime.image) do
      task = Ankole.Ecto.UUIDv7.autogenerate()

      metadata =
        FC.labels(provider)
        |> Map.merge(%{
          "ankole-agent" => ProviderKind.agent_hash(uid),
          "ankole-task" => "storage",
          "ankole-task-id" => task
        })

      request = FC.create_request(provider, uid, template, metadata, 3600)
      # A create has no contract. Save the deletion request before selecting
      # the only sandbox that may receive permission to remove files.
      {:pending, %{"task_id" => task, "request" => request}}
    else
      {:pending, _} -> {:pending, nil}
      error -> error
    end
  end

  def delete(provider, _uid, %{"request" => request} = ref)
      when not is_map_key(ref, "sandbox_id") do
    with {:ok, %{"sandboxID" => id}} <- Client.api(provider, :post, "/sandboxes", json: request),
         do: {:pending, Map.put(ref, "sandbox_id", id)}
  end

  def delete(provider, uid, %{"sandbox_id" => id} = ref) do
    case FC.get(provider, id) do
      {:ok, sandbox} ->
        continue_delete(provider, uid, ref, sandbox)

      {:error, {:function_compute_api, 404, _, _}} ->
        # A missing helper without its completion marker may have failed.
        # Retry the task in a new selected sandbox before removing the row.
        if ref["completed"], do: {:ok, nil}, else: {:pending, nil}

      error ->
        error
    end
  end

  defp continue_delete(provider, uid, ref, sandbox) do
    with :ok <- delete_unused_helpers(provider, ref) do
      if ref["completed"] do
        with :ok <- FC.delete_instance(provider, %{instance_ref: ref["sandbox_id"]}, :now),
             do: {:pending, ref}
      else
        case Client.file(provider, sandbox, :get, "/run/ankole/task-done") do
          {:ok, _} ->
            {:pending, Map.put(ref, "completed", true)}

          {:error, {:function_compute_api, 404, _, _}} ->
            contract = %{
              "WORKER_ID" => uid,
              "ANKOLE_WORKER_TASK" => "delete_storage",
              "ANKOLE_WORKER_STORAGE" => "mounted"
            }

            with {:ok, _} <-
                   Client.file(
                     provider,
                     sandbox,
                     :post,
                     "/run/ankole/contract.json",
                     Ankole.JSON.encode!(contract)
                   ),
                 do: {:pending, ref}

          error ->
            error
        end
      end
    end
  end

  defp delete_unused_helpers(provider, ref) do
    filter =
      Map.merge(FC.labels(provider), %{
        "ankole-task" => "storage",
        "ankole-task-id" => ref["task_id"]
      })

    with {:ok, helpers} <- Client.sandboxes(provider, filter) do
      helpers
      |> Enum.filter(fn item -> Enum.all?(filter, fn {k, v} -> item["metadata"][k] == v end) end)
      |> Enum.reject(&(&1["sandboxID"] == ref["sandbox_id"]))
      |> Enum.reduce_while(:ok, fn item, :ok ->
        case FC.delete_instance(provider, %{instance_ref: item["sandboxID"]}, :now) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp ensure_space(provider, uid, spaces) do
    fs = provider.settings["storage"]["agenticFs"]
    path = "/" <> name(provider, uid)

    case Enum.find(spaces, &(String.trim_trailing(&1["FileSystemPath"], "/") == path)) do
      nil ->
        with {:ok, _} <-
               Client.nas(provider, "CreateAgenticSpace", %{
                 "FileSystemId" => fs["fileSystemId"],
                 "FileSystemPath" => path,
                 "Azone" => fs["zone"],
                 "Quota.SizeLimit" => fs["sizeLimitGiB"] * 1_073_741_824,
                 "Quota.FileCountLimit" => fs["fileCountLimit"]
               }),
             do: {:error, :function_compute_space_pending}

      %{"Status" => "Running"} = space ->
        {:ok, space}

      _ ->
        {:error, :function_compute_space_pending}
    end
  end

  defp ensure_access_point(provider, uid, space, points) do
    case Enum.find(points, &(&1["AccessPointName"] == mount_name(provider, uid))) do
      nil ->
        vpc = provider.settings["vpc"]

        params =
          tag_params(provider, uid)
          |> Map.merge(%{
            "FileSystemId" => provider.settings["storage"]["agenticFs"]["fileSystemId"],
            "AgenticSpaceId" => space["AgenticSpaceId"],
            "AccessPointName" => mount_name(provider, uid),
            "EnabledRam" => true,
            "VpcId" => vpc["vpcId"],
            "VswId" => hd(vpc["vSwitchIds"])
          })

        with {:ok, _} <- Client.nas(provider, "CreateAccessPoint", params),
             do: {:error, :function_compute_access_point_pending}

      %{"Status" => "Active"} = point ->
        {:ok, point}

      _ ->
        {:error, :function_compute_access_point_pending}
    end
  end

  defp ensure_volume(provider, uid, point, volumes) do
    if Enum.any?(volumes, &(&1["volumeName"] == mount_name(provider, uid))) do
      :ok
    else
      with {:ok, _} <-
             Client.pop(provider, "CreateVolume", :post, "/volumes", %{
               "teamID" => provider.settings["teamId"],
               "volumeName" => mount_name(provider, uid),
               "agenticFSVolumeConfig" => %{
                 "serverAddr" => point["DomainName"] <> ":/",
                 "userID" => 1000,
                 "groupID" => 1000
               }
             }),
           do: :ok
    end
  end

  defp spaces(provider),
    do: nas_list(provider, "DescribeAgenticSpaces", ~w(AgenticSpaces AgenticSpace), %{})

  defp access_points(provider, uid) do
    with {:ok, items} <-
           nas_list(provider, "DescribeAccessPoints", ["AccessPoints"], tag_params(provider, uid)) do
      labels = Map.put(FC.labels(provider), "ankole-agent", ProviderKind.agent_hash(uid))

      {:ok,
       Enum.filter(items, fn item ->
         tags = Map.new(item["Tags"], &{&1["Key"], &1["Value"]})
         Enum.all?(labels, fn {k, v} -> tags[k] == v end)
       end)}
    end
  end

  defp nas_list(provider, action, keys, params) do
    params =
      Map.merge(params, %{
        "FileSystemId" => provider.settings["storage"]["agenticFs"]["fileSystemId"],
        "MaxResults" => 100
      })

    with {:ok, page} <- Client.nas(provider, action, params) do
      items = get_in(page, keys)

      case page["NextToken"] do
        token when token in [nil, ""] ->
          {:ok, items}

        token ->
          with {:ok, rest} <-
                 nas_list(provider, action, keys, Map.put(params, "NextToken", token)),
               do: {:ok, items ++ rest}
      end
    end
  end

  defp volumes(provider, token \\ nil) do
    params = %{"teamID" => provider.settings["teamId"], "maxResults" => 100}
    params = if token, do: Map.put(params, "nextToken", token), else: params

    with {:ok, %{"volumes" => items} = page} <-
           Client.pop(provider, "ListVolumes", :get, "/volumes", nil, params) do
      case page["nextToken"] do
        next when next in [nil, ""] -> {:ok, items}
        next -> with {:ok, rest} <- volumes(provider, next), do: {:ok, items ++ rest}
      end
    end
  end

  defp tag_params(provider, uid) do
    Map.put(FC.labels(provider), "ankole-agent", ProviderKind.agent_hash(uid))
    |> Enum.sort()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {{k, v}, i} -> [{"Tag.#{i}.Key", k}, {"Tag.#{i}.Value", v}] end)
    |> Map.new()
  end

  # An instance network change needs a new access point and Volume record.
  # All such records refer to the same stable AgenticSpace and are removed
  # with that Agent. They do not own the Agent's files.
  defp mount_name(provider, uid) do
    vpc = provider.settings["vpc"]
    network = :erlang.term_to_binary({vpc["vpcId"], hd(vpc["vSwitchIds"])})
    name(provider, uid) <> "-ap-" <> ProviderKind.hash16(network)
  end

  defp name(provider, uid), do: ProviderKind.storage_name(provider.runtime.installation, uid)
  defp pending({:ok, _}, ref), do: {:pending, ref}
  defp pending(error, _ref), do: error
end
