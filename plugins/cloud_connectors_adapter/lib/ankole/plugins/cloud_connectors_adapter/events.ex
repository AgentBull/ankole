defmodule Ankole.Plugins.CloudConnectorsAdapter.Events do
  @moduledoc "Stable event envelopes identify the platform resource independently of delivery and executor IDs."

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["resource", "changes"],
      "properties" => %{
        "resource" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["id", "attributes"],
          "properties" => %{
            "id" => %{
              "type" => "string",
              "minLength" => 1,
              "description" =>
                "The third-party resource identifier, independent of the event delivery."
            },
            "attributes" => %{
              "type" => "object",
              "additionalProperties" => true,
              "description" =>
                "Platform resource attributes. Event consumers must tolerate optional platform fields."
            }
          }
        },
        "changes" => %{
          "type" => "object",
          "additionalProperties" => true,
          "description" =>
            "Changed fields supplied by the platform; empty when no field diff is available."
        }
      }
    }
  end

  def project(type, resource, changes) when is_map(resource) do
    case resource_id(type, resource) do
      nil ->
        {:error, :invalid_trigger_payload}

      id ->
        {:ok,
         %{
           "resource" => %{"id" => to_string(id), "attributes" => resource},
           "changes" => changes(changes)
         }}
    end
  end

  def project(_, _, _), do: {:error, :invalid_trigger_payload}

  defp resource_id("gitlab.push", resource), do: resource["project_id"]
  defp resource_id("typeform.form_response.submitted", resource), do: resource["token"]
  defp resource_id("calendly." <> _, resource), do: resource["uri"]
  defp resource_id("figma." <> _, resource), do: resource["file_key"]

  defp resource_id("sentry.error.alert_triggered", resource),
    do: get_in(resource, ["event", "event_id"]) || get_in(resource, ["event", "id"])

  defp resource_id(_, resource), do: resource["id"]
  defp changes(value) when is_map(value), do: value
  defp changes(value) when is_list(value), do: %{"fields" => value}
end
