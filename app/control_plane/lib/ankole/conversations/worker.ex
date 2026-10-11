defmodule Ankole.Conversations.Worker do
  @moduledoc "Transport and decoding for a Run's disposable Worker workspace."
  alias Ankole.Conversations.{Fence, Run, Tools, ToolResult}
  alias Ankole.RuntimeFabric.V1, as: Proto

  alias Ankole.SignalsGateway.ActorRuntime.{
    AgentWorkers,
    TurnEnvelope,
    WorkerRoute,
    WorkerWebFetchConfig
  }

  alias Ankole.Repo

  @spec ref(Run.t()) :: Proto.RunRef.t()
  def ref(run),
    do: %Proto.RunRef{
      actor: %Proto.ActorKey{session_id: run.session_id},
      actor_event_id: run.actor_event_id
    }

  @spec open(Run.t()) ::
          {:ok, Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker.t()}
          | {:wait, atom()}
          | {:error, term()}
  def open(run) do
    with {:ok, row} <-
           Repo.transact(fn repo ->
             with :ok <- Fence.check_in_tx(repo, run, :share) do
               # Adoption first asks the current process about its existing
               # workspace. The Worker enforces physical capacity for a new one.
               {:ok, AgentWorkers.workspace_status(run.agent_uid)}
             end
           end),
         {:ok, row} <- row,
         {:ok, fetch} <- WorkerWebFetchConfig.runtime_config(run.agent_uid),
         {:ok, _} <-
           WorkerRoute.send_mandatory(
             AgentWorkers.target(row),
             envelope(:workspace_open, %Proto.WorkspaceOpen{
               run: ref(run),
               workspace_id: run.workspace_id,
               runtime_env: run.spec.runtime_env,
               agent_context: TurnEnvelope.agent_context(run.context),
               binding_name: run.event.binding_name || "",
               fetch_runtime_config: fetch,
               idle_timeout_ms:
                 max(
                   get_in(run.spec.request_context, ["ai_agent", "inactivity_timeout_ms"]) || 0,
                   0
                 )
             })
           ) do
      {:ok, row}
    end
  end

  @spec check(Run.t(), map()) :: {:ok, :same | :changed} | {:error, Exception.t()}
  def check(run, row) do
    case AgentWorkers.connected_worker(run.agent_uid) do
      {:ok, current} ->
        {:ok,
         if(
           current.transport_route == row.transport_route and
             current.incarnation_id == row.incarnation_id,
           do: :same,
           else: :changed
         )}

      {:error, :agent_worker_unavailable} ->
        {:ok, :changed}
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  @spec connection(map()) :: {:ok, pid()} | {:error, term()}
  def connection(row), do: WorkerRoute.connection_pid(AgentWorkers.target(row))

  @spec send_call(Run.t(), map(), Ankole.Conversations.Driver.PendingCall.t()) ::
          {:ok, term()} | {:error, term()}
  def send_call(run, row, pending) do
    WorkerRoute.send_mandatory(
      AgentWorkers.target(row),
      envelope(:tool_call, %Proto.ToolCall{
        run: ref(run),
        response_id: Run.response_id(run.model_response),
        call_id: Run.call_id(pending.call),
        namespace: pending.call["namespace"] || "",
        name: pending.worker_name || pending.call["name"],
        arguments_json: Ankole.JSON.encode!(pending.args),
        mode: pending.mode
      })
    )
  end

  @spec decode(atom(), map()) ::
          :ready
          | :ignore
          | {:waiting, atom()}
          | {:unavailable, term()}
          | {:unknown, String.t()}
          | {:presentation, String.t(), map()}
          | {:result, String.t(), ToolResult.t(), [map()]}
  def decode(:workspace_ready, %{reason: reason}) when reason in [:CAPACITY, :DRAINING],
    do: {:waiting, reason}

  def decode(:workspace_ready, %{reason: :READY, error: ""}), do: :ready
  def decode(:workspace_ready, payload), do: {:unavailable, payload.error}
  def decode(:tool_status, %{state: "unknown", call_id: id}), do: {:unknown, id}
  def decode(:tool_status, _payload), do: :ignore

  def decode(:tool_progress, payload) do
    case Ankole.JSON.decode(payload.presentation_json) do
      {:ok, %{"kind" => kind, "payload" => value}} -> {:presentation, kind, value}
      _ -> :ignore
    end
  end

  def decode(:tool_result, payload) do
    with {:ok, content} when is_list(content) <- Ankole.JSON.decode(payload.content_json),
         {:ok, details} <- decode_details(payload.details_json) do
      text = content |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join("\n", & &1["text"])

      result = %ToolResult{
        output: text,
        details: details,
        is_error: payload.is_error,
        failure_kind: payload.failure_kind
      }

      images = Enum.map(payload.images, &model_image/1)

      # A function output carries only text, so the images follow in a user
      # message. Its caption repeats the output so the model can tell which
      # call returned which image.
      follow =
        if images == [],
          do: [],
          else: [
            %{"role" => "user", "content" => [%{"type" => "input_text", "text" => text} | images]}
          ]

      {:result, payload.call_id, result, follow}
    else
      _ -> {:result, payload.call_id, Tools.error("Worker returned an invalid tool result."), []}
    end
  end

  def decode(_type, _payload), do: :ignore

  # Tool images get the same conversion as received chat images, so every
  # provider receives a WebP within its byte and dimension limits.
  defp model_image(bytes) do
    with {:ok, model_url} <- Ankole.Kernel.model_image_url(bytes) do
      %{"type" => "input_image", "image_url" => model_url}
    else
      _invalid -> %{"type" => "input_text", "text" => "[The image could not be decoded.]"}
    end
  end

  @spec close(Run.t()) :: :ok | {:ok, term()} | {:error, term()}
  def close(run) do
    case AgentWorkers.connected_worker(run.agent_uid) do
      {:ok, row} ->
        WorkerRoute.send_mandatory(
          AgentWorkers.target(row),
          envelope(:workspace_close, %Proto.WorkspaceClose{run: ref(run)})
        )

      _ ->
        :ok
    end
  end

  @spec cancel(Run.t(), map(), [String.t()]) :: :ok
  def cancel(run, row, call_ids) do
    Enum.each(call_ids, fn id ->
      WorkerRoute.send_mandatory(
        AgentWorkers.target(row),
        envelope(:tool_cancel, %Proto.ToolCancel{
          run: ref(run),
          response_id: Run.response_id(run.model_response),
          call_id: id
        })
      )
    end)
  end

  @spec matches?(term(), Run.t()) :: boolean()
  def matches?(%Proto.RunRef{actor: actor, actor_event_id: id}, run),
    do:
      actor.session_id == run.session_id and
        id == run.actor_event_id

  def matches?(_, _), do: false
  defp decode_details(""), do: {:ok, %{}}
  defp decode_details(bytes), do: Ankole.JSON.decode(bytes)

  defp envelope(type, payload) do
    id = "#{type}:#{Ecto.UUID.generate()}"

    %Proto.Envelope{
      message_id: id,
      body: {type, payload}
    }
  end
end
