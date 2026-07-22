defmodule Ankole.Brain.SourceLearning do
  @moduledoc """
  Admits one explicitly retained source into the ordinary Agent runtime.

  Source bytes are durable before this module runs. Admission only materializes
  a run-local copy and appends a `brain.source.learn` ActorEvent, so a missing
  worker is a retryable learning failure rather than lost evidence.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.CurationGuide
  alias Ankole.AgentHomePaths
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Schemas.AuditLog
  alias Ankole.Brain.Schemas.RetainedSource
  alias Ankole.Brain.Sources
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.WorkerFiles

  @binding_name "brain-console"
  @event_type "brain.source.learn"

  @spec enqueue(Scope.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def enqueue(scope, document_id, opts \\ [])

  def enqueue(%Scope{writable_store_key: nil}, _document_id, _opts),
    do: {:error, :read_only_scope}

  def enqueue(%Scope{} = scope, document_id, opts)
      when is_binary(document_id) and is_list(opts) do
    with {:ok, %{source: %RetainedSource{} = source, content: content}} <-
           Sources.retained_with_content(scope, document_id),
         true <- source.store_key == scope.writable_store_key,
         true <- source.capture_method == "file",
         agent_uid when is_binary(agent_uid) <- source.learning_agent_uid,
         :ok <- ensure_agent_owner(agent_uid),
         {:ok, curation_guide} <- CurationGuide.load(agent_uid),
         run_id = Ankole.Ecto.UUIDv7.autogenerate(),
         session_id = "brain-source:#{source.id}:#{run_id}",
         filename = source_filename(source),
         relative_path = workspace_relative_path(agent_uid, session_id, filename),
         :ok <- materialize(content, relative_path, opts),
         {:ok, actor_event} <-
           append_event(
             source,
             scope,
             agent_uid,
             run_id,
             session_id,
             filename,
             curation_guide,
             opts
           ) do
      {:ok,
       %{
         status: :queued,
         actor_event_id: actor_event.id,
         session_id: session_id,
         document_id: source.document_id
       }}
    else
      false -> {:error, :source_not_learnable}
      {:error, _reason} = error -> error
    end
  end

  def enqueue(_scope, _document_id, _opts), do: {:error, :invalid_arguments}

  @doc "Derives the Knowledge write context from the durable actor event."
  @spec write_context(TurnRef.t()) ::
          {:ok, :agent | {:source_learning, String.t()}} | {:error, term()}
  def write_context(%TurnRef{} = turn_ref) do
    case Repo.get(ActorEvent, turn_ref.actor_event_id) do
      %ActorEvent{
        agent_uid: agent_uid,
        session_id: session_id,
        type: @event_type,
        payload: payload
      }
      when agent_uid == turn_ref.agent_uid and session_id == turn_ref.session_id ->
        case get_in(payload, ["data", "retained_source", "document_id"]) do
          document_id when is_binary(document_id) -> {:ok, {:source_learning, document_id}}
          _missing -> {:error, :source_learning_descriptor_missing}
        end

      _ordinary_or_missing_event ->
        {:ok, :agent}
    end
  end

  @doc "Projects the latest learning run without redefining ActorEvent completion semantics."
  @spec latest_outcome(RetainedSource.t()) :: %{
          status: String.t(),
          actor_event_id: String.t() | nil
        }
  def latest_outcome(%RetainedSource{} = source) do
    event =
      ActorEvent
      |> where([event], event.agent_uid == ^source.learning_agent_uid)
      |> where([event], event.type == @event_type)
      |> where([event], event.source_entry_id == ^source.document_id)
      |> order_by([event], desc: event.inserted_at, desc: event.id)
      |> limit(1)
      |> Repo.one()

    project_outcome(event, source.document_id)
  end

  defp ensure_agent_owner(owner_uid) do
    case Principals.get_agent(owner_uid) do
      {:ok, _agent} -> :ok
      {:error, _reason} -> {:error, :source_owner_not_agent}
    end
  end

  defp materialize(content, relative_path, opts) do
    materialize_fun =
      Keyword.get(opts, :materialize_fun, fn path, content ->
        case WorkerFiles.put("agent_sessions", path, content) do
          {:ok, _result} -> :ok
          {:error, _reason} = error -> error
        end
      end)

    materialize_fun.(relative_path, content)
  end

  defp append_event(
         source,
         scope,
         agent_uid,
         run_id,
         session_id,
         filename,
         curation_guide,
         opts
       ) do
    now = DateTime.utc_now(:microsecond)
    source_event_id = "brain-source-learn:#{run_id}"

    virtual_path =
      Path.join(
        AgentHomePaths.session_workspace(agent_uid, session_id),
        "source/#{filename}"
      )

    attrs = %{
      agent_uid: agent_uid,
      binding_name: @binding_name,
      session_id: session_id,
      source_event_id: source_event_id,
      source_entry_id: source.document_id,
      type: @event_type,
      available_at: now,
      payload: %{
        "specversion" => "1.0",
        "id" => source_event_id,
        "source" => "console://brain/sources",
        "subject" => "brain_retained_sources:#{source.id}",
        "time" => DateTime.to_iso8601(now),
        "type" => @event_type,
        "data" => %{
          "session" => %{
            "agent_uid" => agent_uid,
            "session_id" => session_id,
            "binding_name" => @binding_name
          },
          "brain_scope" => brain_scope(scope),
          "entry" => %{
            "text" => learning_instruction(source, curation_guide),
            "document_id" => source.document_id,
            "attachments" => [
              %{
                "name" => filename,
                "resource_type" => "document",
                "mime_type" => source.media_type,
                "size" => source.byte_size,
                "agent_computer_path" => virtual_path
              }
            ]
          },
          "retained_source" => %{
            "document_id" => source.document_id,
            "title" => source.title,
            "capture_method" => source.capture_method,
            "origin_locator" => source.origin_locator,
            "media_type" => source.media_type,
            "byte_size" => source.byte_size,
            "sha256" => source.sha256,
            "path" => virtual_path
          }
        }
      }
    }

    append_fun = Keyword.get(opts, :append_fun, &SignalsGateway.append_actor_event/1)
    append_fun.(attrs)
  end

  defp learning_instruction(source, curation_guide) do
    base = """
    The user asked you to learn the retained source “#{source.title}”.
    The long-term memory system (code name Brain) preserves information an Agent creates or encounters so that it can recover the most relevant items for future work. It contains chat messages, curated current entries, and external materials that a person asked the Agent to learn.
    Read the entire source with source_read. Call it again until it reports complete=true.
    Integrate only durable, supported knowledge into one or more relevant long-term memory entries; update an existing entry when it already owns the subject, otherwise create a focused entry.
    In this run memory_update accepts only create_entry with name, type, and initial_body, or append_block/edit_block against an existing page.
    For each supported claim, use the source marker that memory_update provides for this run.
    Do not save tool failures, temporary runtime limitations, task progress, or claims the source does not support.
    """

    case curation_guide do
      guide when is_binary(guide) ->
        String.trim(base) <> "\n\nHuman-maintained long-term memory curation guide:\n\n" <> guide

      nil ->
        String.trim(base)
    end
  end

  defp project_outcome(nil, _document_id), do: %{status: "stored", actor_event_id: nil}

  defp project_outcome(%ActorEvent{input_state: "dead_letter", id: id}, _document_id),
    do: %{status: "failed", actor_event_id: id}

  defp project_outcome(%ActorEvent{completed_at: nil, id: id}, _document_id),
    do: %{status: "learning", actor_event_id: id}

  defp project_outcome(%ActorEvent{turn_outcome: nil, id: id}, _document_id),
    do: %{status: "failed", actor_event_id: id}

  defp project_outcome(%ActorEvent{turn_outcome: "iteration_exhausted", id: id}, _document_id),
    do: %{status: "incomplete", actor_event_id: id}

  defp project_outcome(%ActorEvent{turn_outcome: "loop_finished", id: id}, document_id) do
    status = if learning_writes?(id, document_id), do: "integrated", else: "no_change"
    %{status: status, actor_event_id: id}
  end

  defp learning_writes?(actor_event_id, document_id) do
    AuditLog
    |> where(
      [audit],
      fragment("?->>'actor_event_id' = ?", audit.metadata, ^actor_event_id) and
        fragment("?->>'source_document_id' = ?", audit.metadata, ^document_id)
    )
    |> Repo.exists?()
  end

  defp brain_scope(%Scope{writable_store_key: "shared"}), do: %{"visibility" => "shared"}

  defp brain_scope(%Scope{writable_store_key: "self"}), do: %{"visibility" => "self"}

  defp brain_scope(%Scope{writable_store_key: "dm:" <> peer_uid}) do
    %{"visibility" => "dm", "peer_uid" => peer_uid}
  end

  defp brain_scope(%Scope{writable_store_key: "channel:" <> channel_id}) do
    %{"visibility" => "channel", "channel_id" => channel_id, "channel_kind" => "im_group"}
  end

  defp workspace_relative_path(owner_uid, session_id, filename) do
    AgentHomePaths.session_lane_path(owner_uid, session_id, "source/#{filename}")
  end

  defp source_filename(source) do
    (source.original_name || source.title)
    |> Path.basename()
    |> String.replace(~r/[^\p{L}\p{N}._-]+/u, "-")
    |> String.trim("-")
    |> String.slice(0, 180)
    |> ensure_extension(source.media_type)
  end

  defp ensure_extension("", media_type), do: ensure_extension("source", media_type)

  defp ensure_extension(filename, media_type) do
    if Path.extname(filename) == "" do
      filename <> media_extension(media_type)
    else
      filename
    end
  end

  defp media_extension(media_type) do
    normalized = String.downcase(media_type || "")

    cond do
      String.contains?(normalized, "pdf") -> ".pdf"
      String.contains?(normalized, "html") -> ".html"
      String.contains?(normalized, "json") -> ".json"
      String.contains?(normalized, "markdown") -> ".md"
      String.starts_with?(normalized, "text/") -> ".txt"
      true -> ".bin"
    end
  end
end
