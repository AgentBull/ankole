defmodule Ankole.Plugins.CloudConnectorsAdapter.Webhooks do
  @moduledoc false
  alias Ankole.Plugins.CloudConnectorsAdapter.{Events, Signatures, Subscriptions}

  def reconcile(id, config, credentials, endpoint, desired),
    do: Subscriptions.reconcile(id, config, credentials, endpoint, desired)

  def receive(id, config, secret, body, headers) do
    signing_secret = secret["webhook_secret"] || secret["signing_secret"]

    with true <- is_binary(signing_secret) and signing_secret != "",
         {:ok, payload} <- Signatures.verify(id, signing_secret, body, headers, config),
         :ok <- resource_scope(id, config, payload),
         {:ok, type, resource, changes} <- event(id, payload, headers),
         {:ok, data} <- Events.project(type, resource, changes) do
      {:ok,
       %{
         "specversion" => "1.0",
         "id" => delivery_id(id, payload, headers, body),
         "source" => "connector://#{id}",
         "type" => type,
         "data" => data
       }}
    else
      false -> {:error, :invalid_webhook_signature}
      error -> error
    end
  end

  def cloud_event("salesforce.record.created", data) do
    resource = data["lead"] || data["contact"]
    Events.project("salesforce.record.created", resource, %{})
  end

  def cloud_event("salesforce.record.updated", data),
    do:
      Events.project(
        "salesforce.record.updated",
        %{
          "id" => data["id"],
          "object" => data["sobject"],
          "updated_at" => data["last_modified_date"],
          "fields" => data["monitored_values"] || %{}
        },
        data["changed_fields"] || %{}
      )

  def cloud_event("googlecalendar." <> _ = type, data),
    do:
      Events.project(
        type,
        data |> Map.put("id", data["event_id"]) |> Map.delete("event_id"),
        data["updated_fields"] || %{}
      )

  defp resource_scope("sentry", config, payload) do
    scope = Map.fetch!(config, :resource_scope)
    expected = scope["project"] || scope["scope_key"]
    issue_project = get_in(payload, ["data", "issue", "project"]) || %{}
    event = get_in(payload, ["data", "event"]) || %{}

    projects = [
      issue_project["id"],
      issue_project["slug"],
      event["project"],
      project_slug(event["url"])
    ]

    if Enum.any?(projects, &(not is_nil(&1) and to_string(&1) == expected)),
      do: :ok,
      else: :ignore
  end

  defp resource_scope(_, _, _), do: :ok

  defp project_slug(nil), do: nil

  defp project_slug(url) do
    case Regex.run(~r{/projects/[^/]+/([^/]+)/events/}, URI.parse(url).path || "") do
      [_, slug] -> URI.decode(slug)
      _ -> nil
    end
  end

  defp event(
         "gitlab",
         %{"object_kind" => "pipeline", "object_attributes" => %{"status" => status} = resource},
         _
       )
       when status in ~w(success failed canceled skipped),
       do: {:ok, "gitlab.pipeline.completed", resource, %{}}

  defp event("gitlab", %{"object_kind" => "pipeline"}, _), do: :ignore

  defp event("gitlab", %{"object_kind" => kind} = data, _) when kind in ~w(merge_request issue),
    do: {:ok, "gitlab." <> kind <> ".updated", data["object_attributes"], data["changes"] || %{}}

  defp event("gitlab", %{"object_kind" => "push"} = data, _), do: {:ok, "gitlab.push", data, %{}}

  defp event("typeform", %{"event_type" => "form_response", "form_response" => data}, _),
    do: {:ok, "typeform.form_response.submitted", data, %{}}

  defp event("calendly", %{"event" => type, "payload" => data}, _)
       when type in ~w(invitee.created invitee.canceled),
       do: {:ok, "calendly." <> type, data, %{}}

  defp event("stripe", %{"type" => type, "data" => data}, _)
       when type in ~w(checkout.session.completed invoice.paid payment_intent.succeeded),
       do: {:ok, "stripe." <> type, data["object"], data["previous_attributes"] || %{}}

  defp event("trello", %{"action" => %{"type" => "createCard", "data" => data}}, _),
    do: {:ok, "trello.card.created", data["card"], %{}}

  defp event("trello", %{"action" => %{"type" => "updateCard", "data" => data}}, _) do
    type =
      if data["listBefore"] && data["listAfter"],
        do: "trello.card.moved",
        else: "trello.card.updated"

    {:ok, type, data["card"], Map.take(data, ~w(old listBefore listAfter))}
  end

  defp event("figma", %{"event_type" => "PING"}, _), do: {:challenge, ""}

  defp event("figma", %{"event_type" => type} = data, _)
       when type in ~w(FILE_UPDATE FILE_COMMENT LIBRARY_PUBLISH),
       do:
         {:ok,
          %{
            "FILE_UPDATE" => "figma.file.updated",
            "FILE_COMMENT" => "figma.file_comment.created",
            "LIBRARY_PUBLISH" => "figma.library.published"
          }[type], Map.drop(data, ~w(event_type webhook_id)), %{}}

  defp event("sentry", %{"action" => "created", "data" => %{"issue" => issue}}, _),
    do: {:ok, "sentry.issue.created", issue, %{}}

  defp event("sentry", %{"action" => "triggered", "data" => data}, _),
    do: {:ok, "sentry.error.alert_triggered", data, %{}}

  defp event("zendesk", %{"event_type" => type, "ticket" => ticket}, _)
       when type in ~w(zendesk.ticket.created zendesk.ticket.updated),
       do: {:ok, type, ticket, %{}}

  defp event(_, _, _), do: :ignore

  defp delivery_id("gitlab", _, headers, body),
    do: Signatures.header(headers, "x-gitlab-event-uuid") || digest(body)

  defp delivery_id("stripe", data, _, _), do: data["id"]
  defp delivery_id("typeform", data, _, _), do: data["event_id"]
  defp delivery_id("trello", data, _, _), do: get_in(data, ["action", "id"])

  defp delivery_id("zendesk", _, headers, body) do
    Signatures.header(headers, "x-zendesk-webhook-invocation-id") ||
      case Signatures.header(headers, "x-zendesk-webhook-signature") do
        sig when is_binary(sig) and sig != "" ->
          ts = Signatures.header(headers, "x-zendesk-webhook-signature-timestamp") || ""
          digest(ts <> "." <> sig)

        _ ->
          digest(body)
      end
  end

  defp delivery_id(_, _, _, body), do: digest(body)
  defp digest(body), do: Base.encode16(:crypto.hash(:sha256, body), case: :lower)
end
