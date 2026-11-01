defmodule Ankole.Signals.CloudBindings do
  @moduledoc false

  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.Signals.{Binding, Bindings, Target, Webhooks}

  def put(agent_uid, binding_name, attrs) do
    with {:ok, cloud_binding} <- prepare(agent_uid, binding_name, attrs) do
      Repo.transact_top_level(fn -> put_in_tx(cloud_binding) end)
    end
  end

  def update(%Binding{} = source, target_agent_uid, binding_name, attrs) do
    with {:ok, %{principal: target}} <- Principals.get_agent(target_agent_uid),
         {:ok, current_config} <- stored_config(source),
         {:ok, patch} <- Bindings.extract_binding_config(attrs),
         attrs = Map.put(attrs, "config", Map.merge(current_config, patch)),
         {:ok, cloud_binding} <- prepare(target.uid, binding_name, attrs) do
      Repo.transact_top_level(fn ->
        move_in_tx(source, current_config, cloud_binding)
      end)
    end
  end

  def stored_config(
        %Binding{adapter: "cloudevents", config_ref: "webhook-endpoint://" <> id} = binding
      ) do
    {:ok,
     %{
       "webhook_endpoint_id" => id,
       "target_kind" =>
         cond do
           binding.target["conversation_id"] -> "conversation"
           binding.target["session_id"] -> "session"
         end,
       "target_id" => binding.target["conversation_id"] || binding.target["session_id"] || "",
       "filter_cel" => binding.filters["cel"] || ""
     }}
  end

  defp move_in_tx(source, current_config, cloud_binding) do
    with :ok <- validate_target(cloud_binding),
         {:ok, {source, destination}} <-
           Bindings.lock_binding_update_in_tx(
             source.agent_uid,
             cloud_binding.agent_uid,
             cloud_binding.name,
             source.adapter,
             current_config
           ),
         {:ok, binding} <- Bindings.enable_in_tx(cloud_binding, destination, source) do
      {:ok, %{binding: binding, config_key: nil}}
    end
  end

  defp prepare(agent_uid, binding_name, attrs) do
    attrs = Ankole.Attrs.normalize_external_attrs(attrs)

    with {:ok, name} <- Bindings.normalize_name(binding_name),
         {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
         {:ok, config} <- Bindings.extract_binding_config(attrs),
         {:ok, endpoint_id} <- Ecto.UUID.cast(config["webhook_endpoint_id"]),
         %Ankole.Signals.WebhookEndpoint{event_format: "cloudevents"} <-
           Webhooks.get_endpoint(endpoint_id),
         {:ok, target} <- cloud_target(attrs, config) do
      {:ok,
       %{
         agent_uid: principal.uid,
         name: name,
         adapter: "cloudevents",
         config_ref: "webhook-endpoint://#{endpoint_id}",
         target: target,
         filters: Map.get(attrs, "filters", cloud_filters(config)),
         enabled: true
       }}
    else
      :error -> {:error, :invalid_cloud_event_binding}
      nil -> {:error, :webhook_endpoint_not_found}
      %Ankole.Signals.WebhookEndpoint{} -> {:error, :invalid_cloud_event_binding}
      {:error, _} = error -> error
    end
  end

  defp put_in_tx(cloud_binding) do
    with :ok <- validate_target(cloud_binding),
         {:ok, binding} <- Bindings.enable_in_tx(cloud_binding),
         do: {:ok, %{binding: binding, config_key: nil}}
  end

  defp validate_target(cloud_binding) do
    if cloud_target_owned?(cloud_binding.agent_uid, cloud_binding.target),
      do: :ok,
      else: {:error, :conversation_not_found}
  end

  defp cloud_target(attrs, config) do
    result =
      case Map.get(attrs, "target") do
        %{} = target ->
          {:ok, target}

        nil ->
          case config["target_kind"] do
            "conversation" -> {:ok, %{"conversation_id" => config["target_id"]}}
            "session" -> {:ok, %{"session_id" => config["target_id"]}}
            _ -> {:error, :invalid_signal_target}
          end

        _ ->
          {:error, :invalid_signal_target}
      end

    case result do
      {:ok, target} ->
        case Target.parse(target) do
          {:conversation, id} ->
            {:ok, %{"conversation_id" => id}}

          {:session, key} ->
            if Ankole.Sessions.Key.routable?(key),
              do: result,
              else: {:error, :invalid_signal_target}

          :error ->
            {:error, :invalid_signal_target}
        end

      error ->
        error
    end
  end

  defp cloud_target_owned?(uid, %{"conversation_id" => id}) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, %Ankole.Conversations.Participant{role: :agent}} <-
           Ankole.Conversations.get_participant(id, uid) do
      true
    else
      _other -> false
    end
  end

  defp cloud_target_owned?(_uid, _target), do: true

  defp cloud_filters(%{"filter_cel" => cel}) when is_binary(cel) and cel != "",
    do: %{"cel" => cel}

  defp cloud_filters(_config), do: %{}
end
