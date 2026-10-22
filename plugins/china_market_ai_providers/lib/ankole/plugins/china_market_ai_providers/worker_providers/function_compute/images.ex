defmodule Ankole.Plugins.ChinaMarketAIProviders.WorkerProviders.FunctionCompute.Images do
  @moduledoc "Second-generation templates that wait for the selected instance's contract."

  alias Ankole.Plugins.ChinaMarketAIProviders.WorkerProviders.FunctionCompute.Client
  alias Ankole.AgentWorkers.ProviderKind

  # The platform runs these shell commands while it builds a template, as its
  # default user (uid 1000) with sudo. sudo replaces the environment; the
  # entrypoint exports the image environment again.
  @start_command "sudo env ANKOLE_WORKER_BOOTSTRAP=function_compute /usr/local/bin/ankole-worker-entry"
  @ready_command "sudo test -f /run/ankole/awaiting-contract"

  def prepare(provider, image) do
    with {:ok, templates} <- list(provider) do
      case matching(templates, name(provider, image)) do
        nil -> create(provider, image)
        template -> ready(template)
      end
    end
  end

  def selected(provider, image) do
    with {:ok, templates} <- list(provider) do
      case matching(templates, name(provider, image)) do
        nil ->
          {:error, :function_compute_template_not_prepared}

        template ->
          case ready(template) do
            :ok -> {:ok, template["templateID"]}
            {:pending, reason} -> {:error, reason}
            error -> error
          end
      end
    end
  end

  def list(provider, token \\ nil) do
    params = %{"teamID" => provider.settings["teamId"], "maxResults" => 100}
    params = if token, do: Map.put(params, "nextToken", token), else: params

    with {:ok, %{"templates" => items} = page} <-
           Client.pop(provider, "ListTemplates", :get, "/templates", nil, params) do
      case page["nextToken"] do
        nil -> {:ok, items}
        "" -> {:ok, items}
        next -> with {:ok, rest} <- list(provider, next), do: {:ok, items ++ rest}
      end
    end
  end

  defp create(provider, image) do
    with {:ok, target} <- target_image(provider, image) do
      body = %{
        "name" => name(provider, image),
        "teamID" => provider.settings["teamId"],
        "runtimeConfig" => %{
          "cpu" => provider.settings["cpus"],
          "memorySize" => provider.settings["memoryMiB"],
          "diskSize" => 15_360,
          "internetAccess" => true,
          "sandboxConfig" => %{
            "generation" => 2,
            "image" => target,
            "startCommand" => @start_command,
            "readyCommand" => @ready_command
          }
        }
      }

      case Client.pop(provider, "CreateTemplate", :post, "/templates", body) do
        {:ok, _} -> {:pending, :function_compute_template_building}
        error -> error
      end
    end
  end

  defp ready(%{"status" => %{"state" => "ready"}}), do: :ok

  defp ready(%{"status" => %{"state" => "error"} = status}),
    do: {:error, {:function_compute_template_failed, get_in(status, ["reason", "message"])}}

  defp ready(_template), do: {:pending, :function_compute_template_building}

  # Image preparation runs outside Agent locks. Concurrent builds can leave
  # equivalent templates; none contains a credential or an Agent's files.
  defp matching(templates, name) do
    matches = Enum.filter(templates, &(&1["name"] == name))
    Enum.find(matches, &(get_in(&1, ["status", "state"]) == "ready")) || List.first(matches)
  end

  defp target_image(provider, image) do
    case Regex.run(~r/(?:@(sha256:[0-9a-f]{64})|:([A-Za-z0-9_][A-Za-z0-9_.-]*))\z/, image) do
      [_, digest] -> {:ok, provider.settings["imageRepository"] <> "@" <> digest}
      [_, "", tag] -> {:ok, provider.settings["imageRepository"] <> ":" <> tag}
      _ -> {:error, :function_compute_image_version_required}
    end
  end

  defp name(provider, image) do
    digest =
      ProviderKind.hash16(
        :erlang.term_to_binary({provider.provider_id, provider.settings_digest, image})
      )

    "ankole-#{provider.runtime.installation}-#{digest}"
  end
end
