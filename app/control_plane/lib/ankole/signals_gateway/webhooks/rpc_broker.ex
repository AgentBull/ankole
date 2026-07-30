defmodule Ankole.SignalsGateway.Webhooks.RPCBroker do
  @moduledoc """
  RuntimeFabric RPC entry point for worker-originated webhook endpoint requests.

  The broker captures the current ActorEvent route. It returns a plaintext
  callback URL only from create and never stores that URL or its token.
  """

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.Common
  alias Ankole.SignalsGateway.ActorRuntime.ReplyRoute
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.Webhooks

  @spec handle_create(TurnRef.t(), FabricProto.WebhookEndpointCreateRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_create(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      reply_route = Common.decode_json_bytes(request.reply_route_json)

      with {:ok, token} <- required_text(request.token, :token),
           {:ok, label} <- required_text(request.label, :label),
           {:ok, mode} <- mode(request.mode),
           {:ok, expires_at} <- datetime(request.expires_at, :expires_at),
           {:ok, automation_job_id} <-
             optional_positive_integer(request.automation_job_id, :automation_job_id),
           {:ok, source} <- ReplyRoute.validate(turn_ref, reply_route),
           {:ok, %{status: status, webhook_endpoint: endpoint}} <-
             Webhooks.create_endpoint(
               %{
                 agent_uid: turn_ref.agent_uid,
                 binding_name: source.binding_name,
                 session_id: turn_ref.session_id,
                 signal_channel_id: source.signal_channel_id,
                 provider_thread_id: source.provider_thread_id,
                 source_actor_event_id: source.actor_event_id,
                 source_entry_id: source.source_entry_id,
                 source_provenance: %{
                   "rpc_request_id" => ctx.request_id,
                   "transport_route" => ctx.route,
                   "activation_uid" => turn_ref.activation_uid,
                   "actor_epoch" => turn_ref.actor_epoch,
                   "revision" => turn_ref.revision
                 },
                 label: label,
                 mode: mode,
                 automation_job_id: automation_job_id,
                 expires_at: expires_at
               },
               token
             ) do
        {:ok,
         %{
           "status" => create_status(status),
           "webhook_endpoint" =>
             endpoint
             |> Webhooks.model_projection()
             |> Map.put("url", callback_url(token))
         }}
      end
    end)
  end

  @spec handle_list(TurnRef.t(), FabricProto.WebhookEndpointListRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_list(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      {:ok,
       %{
         "status" => "ok",
         "webhook_endpoints" =>
           turn_ref.agent_uid
           |> Webhooks.list_endpoints(turn_ref.session_id,
             active_only: true,
             limit: list_limit(request.limit)
           )
           |> Enum.map(&Webhooks.model_projection/1)
       }}
    end)
  end

  @spec handle_cancel(TurnRef.t(), FabricProto.WebhookEndpointTargetRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_cancel(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      with {:ok, endpoint_id} <- uuid(request.webhook_endpoint_id, :webhook_endpoint_id),
           {:ok, %{status: status, webhook_endpoint: endpoint}} <-
             Webhooks.cancel_endpoint(turn_ref.agent_uid, turn_ref.session_id, endpoint_id) do
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
    case presence(value) do
      mode when mode in ~w(one_shot standing) -> {:ok, mode}
      _mode -> {:error, :invalid_webhook_mode}
    end
  end

  defp datetime(value, key) do
    case presence(value) do
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
    case presence(value) do
      text when is_binary(text) -> {:ok, text}
      nil -> {:error, {:missing_text, key}}
    end
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp list_limit(value) when is_integer(value) and value > 0, do: min(value, 100)
  defp list_limit(_value), do: 100

  defp create_status(:created), do: "created"
  defp create_status(:already_exists), do: "already_exists"
  defp cancel_status(:cancelled), do: "cancelled"
  defp cancel_status(:already_terminal), do: "already_terminal"

  defp error_payload(request_id, reason) do
    RPCWire.error_payload(request_id, reason,
      fallback_code: "webhook_endpoint_rpc_failed",
      details_json: %{"reason" => inspect(reason)}
    )
  end
end
