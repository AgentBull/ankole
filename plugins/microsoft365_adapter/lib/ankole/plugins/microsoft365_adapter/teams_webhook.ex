defmodule Ankole.Plugins.Microsoft365Adapter.TeamsWebhook do
  @moduledoc """
  Bot Framework messaging-endpoint handler behind
  `/webhooks/v1/teams/{appID}/messages`.

  One URL serves one Microsoft App: the instance segment is the app id, the
  connector JWT audience must equal it, and every enabled binding configured
  with that app id receives the activity. Processing completes before the 200
  is returned (durable-accept-then-ack); connector redelivery is absorbed by
  the gateway's `(agent_uid, binding_name, source_event_id)` idempotency.
  """

  alias Ankole.{Logging, SignalsGateway}
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.Microsoft365Adapter.{BotFrameworkAuth, Config, Inbound}
  alias Ankole.Plugins.Microsoft365Adapter.TeamsChannels
  alias Ankole.SignalsGateway.AdapterContext

  @spec handle_webhook(map()) :: {:ok, map()} | {:error, term()}
  def handle_webhook(%{kind: "messages", instance_id: app_id} = request) do
    activity = request.body_params

    # The JWT is verified before bindings are even looked up, so an
    # unauthenticated probe learns nothing about configured instances.
    case authorize(request, app_id, activity) do
      {:ok, _claims} ->
        case consumers_for_app(app_id) do
          {:ok, consumers} -> run_dispatch(activity, consumers, app_id)
          {:error, :unknown_app} -> {:ok, %{status: 404, body: %{"error" => "unknown app"}}}
        end

      {:error, auth_reason} ->
        Logging.warning(
          "microsoft365_adapter.teams_webhook.unauthorized",
          "Teams webhook request rejected",
          %{app_id: app_id, reason: inspect(auth_reason)}
        )

        {:ok, %{status: 401, body: %{"error" => "unauthorized"}}}
    end
  end

  def handle_webhook(_request), do: {:ok, %{status: 404, body: %{"error" => "unknown webhook"}}}

  defp run_dispatch(activity, consumers, app_id) do
    case dispatch_activity(activity, consumers) do
      {:ok, _results} ->
        {:ok, %{status: 200, body: %{}}}

      {:error, reason} ->
        Logging.warning(
          "microsoft365_adapter.teams_webhook.dispatch_failed",
          "Teams activity dispatch failed",
          %{app_id: app_id, activity_type: activity_type(activity), reason: inspect(reason)}
        )

        {:ok, %{status: 500, body: %{"error" => "activity processing failed"}}}
    end
  end

  defp authorize(request, app_id, activity) do
    BotFrameworkAuth.verify(request.headers, app_id, activity)
  end

  defp consumers_for_app(app_id) do
    consumers =
      "teams"
      |> SignalsGateway.list_enabled_bindings()
      |> Enum.flat_map(fn binding ->
        case Config.load_chat_config_ref(binding.config_ref) do
          {:ok, %{"appID" => ^app_id} = config} ->
            context =
              AdapterContext.new(
                agent_uid: binding.agent_uid,
                binding_name: binding.name,
                adapter: binding.adapter,
                user_name: Map.get(config, "userName", "Teams")
              )

            [Inbound.chat_consumer(context, config)]

          {:ok, _other_app_config} ->
            []

          :error ->
            []

          {:error, reason} ->
            Logging.warning(
              "microsoft365_adapter.teams_webhook.binding_config_invalid",
              "Teams binding config could not be loaded",
              %{binding_name: binding.name, reason: inspect(reason)}
            )

            []
        end
      end)

    case consumers do
      [] -> {:error, :unknown_app}
      consumers -> {:ok, consumers}
    end
  end

  defp dispatch_activity(activity, consumers) do
    case activity_type(activity) do
      "message" ->
        if Inbound.card_action?(activity) do
          Inbound.handle_card_action("message", activity, consumers)
        else
          Inbound.handle_message_receive("message", activity, consumers)
        end

      "messageDelete" ->
        Inbound.handle_message_removed("messageDelete", activity, consumers)

      "messageUpdate" ->
        handle_message_update(activity, consumers)

      "messageReaction" ->
        dispatch_reactions(activity, consumers)

      "conversationUpdate" ->
        dispatch_conversation_update(activity, consumers)

      "installationUpdate" ->
        dispatch_conversation_update(activity, consumers)

      "invoke" ->
        # Action.Execute and other invoke flows are out of contract; card
        # actions ride on Action.Submit message activities.
        {:ok, [%{status: :ignored_invoke_activity}]}

      _other ->
        {:ok, [%{status: :ignored_unknown_activity_type}]}
    end
  end

  # Teams reuses messageUpdate for edits, soft-delete restores, and
  # soft-deletes themselves, discriminated by channelData.eventType. Edits and
  # undeletes are ignored (ingress has no entry-edit capability); soft deletes
  # map to entry removal.
  defp handle_message_update(activity, consumers) do
    case get_in(activity, ["channelData", "eventType"]) do
      "softDeleteMessage" ->
        Inbound.handle_message_removed("messageUpdate", activity, consumers)

      "undeleteMessage" ->
        {:ok, [%{status: :ignored_undelete_message}]}

      _edit ->
        {:ok, [%{status: :ignored_message_changed}]}
    end
  end

  defp dispatch_reactions(activity, consumers) do
    added =
      if MapHelpers.fetch_list(activity, "reactionsAdded") != [],
        do: Inbound.handle_reaction_created("messageReaction", activity, consumers),
        else: {:ok, []}

    removed =
      if MapHelpers.fetch_list(activity, "reactionsRemoved") != [],
        do: Inbound.handle_reaction_deleted("messageReaction", activity, consumers),
        else: {:ok, []}

    with {:ok, added_results} <- added,
         {:ok, removed_results} <- removed do
      {:ok, added_results ++ removed_results}
    end
  end

  defp dispatch_conversation_update(activity, consumers) do
    consumers
    |> Enum.filter(&match?(%{kind: :chat}, &1))
    |> Enum.map(&TeamsChannels.handle_conversation_update(&1, activity))
    |> MapHelpers.collect_results()
  end

  defp activity_type(activity), do: MapHelpers.optional_text(activity, "type")
end
