defmodule Ankole.Signals.Webhooks.RPCBroker do
  @moduledoc """
  RuntimeFabric RPC entry point for worker-originated webhook endpoint requests.

  The broker keeps the current Signal source and resolves its long-lived
  recipient. It returns a plaintext
  callback URL only from create and never stores that URL or its token.
  """

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.Conversations.Route
  alias Ankole.AgentWorkers.RPCWire
  alias Ankole.Sessions.RunRef
  alias Ankole.Signals.Webhooks

  @spec handle_create(RunRef.t(), FabricProto.WebhookEndpointCreateRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_create(%{agent_uid: _} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      with {:ok, label} <- required_text(request.label, :label),
           {:ok, mode} <- mode(request.mode),
           {:ok, expires_at} <- datetime(request.expires_at, :expires_at),
           {:ok, automation_job_id} <-
             optional_positive_integer(request.automation_job_id, :automation_job_id),
           {:ok, %{source: source, owner_session_id: owner_session_id, reply_route: route}} <-
             Route.long_lived_source(turn_ref),
           {:ok, %{webhook_endpoint: endpoint, token: token}} <-
             Webhooks.create_endpoint(%{
               agent_uid: turn_ref.agent_uid,
               binding_name: route["binding_name"],
               session_id: owner_session_id,
               conversation_id: route["conversation_id"],
               provider_thread_id: route["provider_thread_id"],
               source_signal_id: source.signal_id,
               provider_message_id: source.provider_message_id,
               source_provenance: %{
                 "rpc_request_id" => ctx.request_id,
                 "transport_route" => ctx.route
               },
               label: label,
               mode: mode,
               automation_job_id: automation_job_id,
               expires_at: expires_at
             }) do
        {:ok,
         %{
           "status" => "created",
           "webhook_endpoint" =>
             endpoint
             |> Webhooks.model_projection()
             |> Map.put("url", callback_url(token))
         }}
      end
    end)
  end

  @spec handle_list(RunRef.t(), FabricProto.WebhookEndpointListRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_list(%{agent_uid: _} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      with {:ok, owner} <- Route.long_lived_owner(turn_ref.agent_uid, turn_ref.session_id) do
        {:ok,
         %{
           "status" => "ok",
           "webhook_endpoints" =>
             turn_ref.agent_uid
             |> Webhooks.list_endpoints(owner.session_id,
               active_only: true,
               limit: list_limit(request.limit)
             )
             |> Enum.map(&Webhooks.model_projection/1)
         }}
      end
    end)
  end

  @spec handle_cancel(RunRef.t(), FabricProto.WebhookEndpointTargetRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_cancel(%{agent_uid: _} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      with {:ok, owner} <- Route.long_lived_owner(turn_ref.agent_uid, turn_ref.session_id),
           {:ok, endpoint_id} <- uuid(request.webhook_endpoint_id, :webhook_endpoint_id),
           {:ok, %{status: status, webhook_endpoint: endpoint}} <-
             Webhooks.cancel_endpoint(turn_ref.agent_uid, owner.session_id, endpoint_id) do
        {:ok,
         %{
           "status" => cancel_status(status),
           "webhook_endpoint" => Webhooks.model_projection(endpoint)
         }}
      end
    end)
  end

  defp respond(ctx, fun) do
    case fun.() do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, error_payload(ctx.request_id, reason)}
    end
  end

  defp callback_url(token) do
    String.trim_trailing(AnkoleWeb.Endpoint.url(), "/") <>
      "/webhooks/v1/event-callbacks/" <> token
  end

  defp mode(value) do
    case Ankole.Attrs.optional_text(value) do
      mode when mode in ~w(one_shot standing) -> {:ok, mode}
      _mode -> {:error, :invalid_webhook_mode}
    end
  end

  defp datetime(value, key) do
    case Ankole.Attrs.optional_text(value) do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          _invalid -> {:error, {:invalid_datetime, key}}
        end

      nil ->
        {:error, {:missing_text, key}}
    end
  end

  defp uuid(value, key) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_uuid, key}}
    end
  end

  defp optional_positive_integer(value, _key) when value in [nil, ""], do: {:ok, nil}

  defp optional_positive_integer(value, key) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer in 1000..9_007_199_254_740_991 -> {:ok, integer}
      _invalid -> {:error, {:invalid_positive_integer, key}}
    end
  end

  defp optional_positive_integer(_value, key),
    do: {:error, {:invalid_positive_integer, key}}

  defp required_text(value, key) do
    case Ankole.Attrs.optional_text(value) do
      text when is_binary(text) -> {:ok, text}
      nil -> {:error, {:missing_text, key}}
    end
  end

  defp list_limit(value) when is_integer(value) and value > 0, do: min(value, 100)
  defp list_limit(_value), do: 100

  defp cancel_status(:cancelled), do: "cancelled"
  defp cancel_status(:already_terminal), do: "already_terminal"

  defp error_payload(request_id, reason) do
    RPCWire.error_payload(request_id, reason,
      fallback_code: "webhook_endpoint_rpc_failed",
      details_json: %{"reason" => inspect(reason)}
    )
  end
end
