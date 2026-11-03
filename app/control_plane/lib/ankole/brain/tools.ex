defmodule Ankole.Brain.Tools do
  @moduledoc "Knowledge reads, attributed facts, synthesis and explicit Brain object edits."
  alias Ankole.Brain.{
    Access,
    Claims,
    Config,
    ContextPack,
    Experts,
    GetPage,
    Objects,
    Recall,
    Synthesis
  }

  alias Ankole.JSON

  defmodule Context do
    @moduledoc "Trusted request attribution and disclosure recipients supplied by the Session."
    defstruct querier_uid: nil,
              authn: %{},
              disclosure: nil,
              default_write_scope: nil,
              conversation_id: nil,
              participant_uids: [],
              parent_fallback: nil,
              holder_default: nil,
              write_fence: nil

    @type t :: %__MODULE__{}

    def for_subject(uid) do
      authority_uid = Ankole.Principals.authority_uid(uid)

      parent =
        case Ankole.Brain.Scope.canonical_page_id(uid) do
          {:ok, id} -> {:page, id}
          error -> error
        end

      %__MODULE__{
        querier_uid: uid,
        disclosure:
          if(authority_uid == uid,
            do: Ankole.Brain.Access.open_disclosure(),
            else: %{mode: :strict, asker_uid: authority_uid, present_uids: [authority_uid]}
          ),
        default_write_scope: {:ok, Ankole.Brain.Scope.principal(authority_uid)},
        participant_uids: [uid],
        parent_fallback: parent,
        holder_default:
          case parent do
            {:page, id} -> id
            _ -> "world"
          end
      }
    end

    def write_scope(explicit, context) do
      source =
        if is_binary(explicit) and explicit != "",
          do: {:ok, explicit},
          else: context.default_write_scope

      with {:ok, id} <- source,
           {:ok, access} <- Ankole.Brain.Access.for_context(context),
           true <- Ankole.Brain.Access.visible?(access, id),
           do: {:ok, id},
           else: (
             false -> {:error, :forbidden}
             error -> error
           )
    end

    def fence(%__MODULE__{write_fence: nil}), do: :ok
    def fence(%__MODULE__{write_fence: fence}), do: fence.()
  end

  @operations ~w(remember recall entity whoknows synthesize delta write_object)
  def operations, do: @operations
  def operation?(operation), do: operation in @operations

  def function_specs(operations),
    do:
      Enum.map(Enum.filter(@operations, &(&1 in operations)), fn name ->
        %{
          "type" => "function",
          "strict" => false,
          "name" => name,
          "description" => description(name),
          "parameters" => parameters(name)
        }
      end)

  def execute(operation, params, %Context{} = context) when is_map(params) do
    cond do
      not Config.enabled?() -> {:error, :brain_disabled}
      operation not in @operations -> {:error, {:unknown_operation, operation}}
      true -> run(operation, params, context)
    end
  end

  def execute(_, _, _), do: {:error, :invalid_params}

  def context_pack(context, params),
    do:
      ContextPack.context_pack(
        context.querier_uid,
        Map.put(params, :conversation_id, context.conversation_id),
        disclosure: context.disclosure
      )

  def volunteer_pointers(context, text),
    do: ContextPack.volunteer_pointers(context.querier_uid, text, disclosure: context.disclosure)

  defp run("write_object", params, context) do
    with {:ok, _} <- required(params, "markdown"),
         true <- is_integer(params["base_revision"]) do
      Ankole.Brain.ObjectWrites.write(params, context)
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp run("remember", params, context) do
    with {:ok, claim} <- required(params, "claim"),
         {:ok, provenance} <- required(params, "provenance"),
         :ok <- Context.fence(context),
         {:ok, source} <- Context.write_scope(params["source_node_id"], context),
         {:ok, subject} <- subject(params["entity"], context) do
      attrs = %{
        claim: claim,
        kind: params["kind"] || "fact",
        provenance: provenance,
        source_node_id: source,
        subject_page_id: subject,
        conversation_id: context.conversation_id,
        holder: params["holder"] || context.holder_default || "world",
        context: params["context"]
      }

      result =
        if attrs.kind in Claims.fact_kinds() do
          Claims.write_fact(
            Map.merge(attrs, %{
              confidence: params["confidence"] || 0.75,
              notability: params["notability"] || "medium",
              valid_from: DateTime.utc_now(:microsecond)
            }),
            context.querier_uid
          )
        else
          with {:ok, take} <-
                 Claims.write_take(
                   Map.merge(
                     Map.delete(attrs, :context),
                     %{weight: params["weight"] || 0.6, until_date: params["until_date"]}
                   ),
                   context.querier_uid
                 ),
               do: {:ok, %{claim: take, status: :inserted}}
        end

      with {:ok, result} <- result,
           do:
             {:ok,
              JSON.plain(%{
                status: result.status,
                claim_id: result.claim.id,
                subject_page_id: subject,
                source_node_id: source
              })}
    end
  end

  defp run("recall", params, context) do
    with {:ok, query} <- required(params, "query"),
         {:ok, result} <-
           Recall.recall(
             context.querier_uid,
             %{
               query: query,
               entity: params["entity"],
               limit: params["limit"],
               budget_tokens: params["budget_tokens"]
             },
             disclosure: context.disclosure,
             conversation_id: context.conversation_id
           ),
         do: {:ok, JSON.plain(result)}
  end

  defp run("entity", params, context) do
    with {:ok, name} <- required(params, "name") do
      case GetPage.get_page(context.querier_uid, name, disclosure: context.disclosure, level: :l1) do
        {:ok, page} -> {:ok, %{"entity" => JSON.plain(page)}}
        {:ambiguous, candidates} -> {:ok, %{"candidates" => JSON.plain(candidates)}}
        error -> error
      end
    end
  end

  defp run("whoknows", params, context) do
    with {:ok, topic} <- required(params, "topic"),
         {:ok, experts} <-
           Experts.who_knows(context.querier_uid, topic,
             limit: params["limit"] || 5,
             disclosure: context.disclosure
           ),
         do: {:ok, %{"experts" => JSON.plain(experts)}}
  end

  defp run("synthesize", params, context) do
    with {:ok, question} <- required(params, "question"),
         :ok <- Context.fence(context),
         do: Synthesis.synthesize(context.querier_uid, question, disclosure: context.disclosure)
  end

  defp run("delta", params, context) do
    with {:ok, since} <- datetime(params["since"]),
         {:ok, until_at} <- datetime(params["until"]),
         do:
           Synthesis.delta(
             context.querier_uid,
             %{entity: params["entity"], since: since, until: until_at},
             disclosure: context.disclosure
           )
  end

  defp subject(nil, _context), do: {:ok, nil}
  defp subject("", _context), do: {:ok, nil}

  defp subject(reference, context) do
    with {:ok, access} <- Access.for_context(context) do
      case Objects.resolve_reference(reference, access: access) do
        {:ok, page} -> {:ok, page.id}
        {:error, :not_found} -> {:ok, nil}
        {:ambiguous, candidates} -> {:error, {:ambiguous_entity, candidates}}
      end
    end
  end

  defp required(params, key) do
    case params[key] do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, {:missing, key}}, else: {:ok, value}

      _ ->
        {:error, {:missing, key}}
    end
  end

  defp datetime(value) when value in [nil, ""], do: {:ok, nil}

  defp datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _} -> {:ok, date}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp description("write_object"),
    do:
      "Create or revise a Brain knowledge object with complete Markdown and frontmatter. For creation give an installed ontology category, title and base_revision 0; for revision give object_id and its current base_revision from entity. Requires both your Agent and the requester to have edit permission. If approval_required is returned, pass the proposal to propose_action_card in a native Pod conversation."

  defp description("remember"),
    do:
      "Remember an atomic fact or prediction with its evidence. Knowledge inherits the visibility of source_node_id, defaulting to the current conversation. Use write_object for Brain object corrections."

  defp description("recall"),
    do:
      "Search visible business facts and knowledge. Results are summaries and relevant excerpts; read a matching Pod page for its full content."

  defp description("entity"),
    do:
      "Read a knowledge entity overview, visible subpages, related claims, timeline and backlinks."

  defp description("whoknows"),
    do: "Find colleagues with relevant visible knowledge and evidence about a topic."

  defp description("synthesize"),
    do: "Synthesize an evidence-backed answer from visible knowledge."

  defp description("delta"),
    do: "Read changed facts and events in a time window, optionally narrowed to an entity."

  defp parameters(name) do
    {required, fields} =
      case name do
        "write_object" ->
          {["markdown", "base_revision"], ~w(object_id category title markdown base_revision)}

        "remember" ->
          {["claim", "provenance"],
           ~w(claim provenance kind holder context entity source_node_id until_date) ++
             ["confidence", "weight", "notability"]}

        "recall" ->
          {["query"], ~w(query entity limit budget_tokens)}

        "entity" ->
          {["name"], ["name"]}

        "whoknows" ->
          {["topic"], ~w(topic limit)}

        "synthesize" ->
          {["question"], ["question"]}

        "delta" ->
          {[], ~w(entity since until)}
      end

    properties =
      Map.new(fields, fn field ->
        {field,
         %{
           "type" =>
             cond do
               field in ~w(confidence weight) -> "number"
               field in ~w(limit budget_tokens base_revision) -> "integer"
               true -> "string"
             end
         }}
      end)

    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end
end
