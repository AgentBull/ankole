defmodule Ankole.Sessions.Tools.Pod do
  @moduledoc "Lightweight Pod page tools for a Session without starting a Worker job."
  @behaviour Ankole.Sessions.Tool
  alias Ankole.Pod.{AgentPages, Pages}

  def declarations do
    [
      declaration(
        "pod_get_page",
        "Read a Pod page at L0 (summary), L1 (outline), or L2 (full content). Doc and knowledge pages return Markdown with their current revision. Brain pages apply conversation disclosure; other pages use your Pod permissions.",
        %{"id" => id(), "level" => %{"type" => "string", "enum" => ["L0", "L1", "L2"]}},
        ["id"],
        true
      ),
      declaration(
        "pod_list_pages",
        "Inspect Pod pages and directory structure. Omit id to inspect root pages in the shared Space (scope: \"space\", default), your Private section (scope: \"private\"), pages directly shared with you from other people's Private sections (scope: \"shared\"), or Space and Private together (scope: \"all\"); pass depth (up to 5) to view nested subdirectories. Use brain to discover organizational knowledge.",
        %{
          "id" => id(),
          "scope" => %{"type" => "string", "enum" => ["space", "private", "shared", "all"]},
          "depth" => %{"type" => "integer", "minimum" => 1, "maximum" => 5}
        },
        [],
        true
      ),
      declaration(
        "pod_save_page",
        "Save the complete Markdown of an existing editable Pod document (type doc) or Brain knowledge page (type knowledge) using the revision from pod_get_page. Shared rules belong on the shared page. If edit access is missing, propose a pod.knowledge.save action card in a native Pod room; in external IM provide the draft and ask an authorized owner to confirm it in Pod.",
        %{
          "id" => id(),
          "base_revision" => %{"type" => "integer", "minimum" => 0},
          "markdown" => %{"type" => "string"}
        },
        ["id", "base_revision", "markdown"],
        false
      ),
      declaration(
        "pod_create_page",
        "Create a Pod collaboration document (type \"doc\", default) in the shared Space, Private section (scope: \"private\"), or under parent_id, or create a Brain knowledge object (type \"knowledge\") under an editable Brain ontology category or knowledge parent_id. Omit type when unsure: parents inside Brain default to knowledge and all other destinations default to doc. Skills and Agent instructions are managed by humans in Meta Ankole.",
        %{
          "parent_id" => id(),
          "title" => %{"type" => "string"},
          "markdown" => %{"type" => "string"},
          "type" => %{"type" => "string", "enum" => ["doc", "knowledge"]},
          "scope" => %{"type" => "string", "enum" => ["space", "private"]}
        },
        ["title", "markdown"],
        false
      )
    ]
  end

  defp id, do: %{"type" => "string", "format" => "uuid"}

  defp declaration(name, description, properties, required, read_only) do
    %{
      "type" => "function",
      "name" => name,
      "description" => description,
      "parameters" => %{
        "type" => "object",
        "properties" => properties,
        "required" => required,
        "additionalProperties" => false
      },
      "read_only" => read_only,
      "destructive" => false,
      "allowed_callers" => if(read_only, do: ["direct", "programmatic"], else: ["direct"]),
      "execution_mode" => if(read_only, do: "parallel", else: "sequential")
    }
  end

  def normalize(name, args) when is_map(args) do
    args
    |> normalize_key_alias("page_id", "id")
    |> normalize_content_alias()
    |> normalize_page_args(name)
  end

  def normalize(_name, args), do: args

  defp normalize_key_alias(args, from, to) do
    case Map.pop(args, from) do
      {nil, rest} -> rest
      {val, rest} -> Map.put_new(rest, to, val)
    end
  end

  defp normalize_content_alias(args) do
    args
    |> normalize_key_alias("content", "markdown")
    |> normalize_key_alias("body", "markdown")
  end

  defp normalize_page_args(args, "pod_get_page"),
    do: normalize_level_arg(args)

  defp normalize_page_args(args, "pod_save_page"),
    do: normalize_revision_arg(args)

  defp normalize_page_args(args, "pod_create_page") do
    args
    |> normalize_key_alias("page_type", "type")
    |> normalize_type_arg()
  end

  defp normalize_page_args(args, _name), do: args

  defp normalize_level_arg(%{"level" => level} = args) when is_integer(level) and level in 0..2,
    do: Map.put(args, "level", "L#{level}")

  defp normalize_level_arg(%{"level" => level} = args) when is_binary(level) do
    case String.upcase(String.trim(level)) do
      normalized when normalized in ["L0", "L1", "L2"] -> Map.put(args, "level", normalized)
      digit when digit in ["0", "1", "2"] -> Map.put(args, "level", "L#{digit}")
      _other -> args
    end
  end

  defp normalize_level_arg(args), do: args

  defp normalize_revision_arg(%{"base_revision" => rev} = args) when is_binary(rev) do
    case Integer.parse(String.trim(rev)) do
      {num, ""} -> Map.put(args, "base_revision", num)
      _other -> args
    end
  end

  defp normalize_revision_arg(args), do: args

  defp normalize_type_arg(%{"type" => type} = args) when is_binary(type) do
    normalized =
      case type |> String.trim() |> String.downcase() do
        t when t in ["doc", "document", "markdown", "page"] -> "doc"
        t when t in ["knowledge", "wiki", "kb", "brain"] -> "knowledge"
        other -> other
      end

    Map.put(args, "type", normalized)
  end

  defp normalize_type_arg(args), do: args

  def execute(run, call, args) do
    with {:ok, actor, context} <- request_context(run),
         {:ok, result} <- dispatch(call["name"], actor, context, args) do
      {:ok, Ankole.Sessions.Tools.result(Ankole.JSON.plain(result))}
    else
      {:error, reason} -> {:error, page_error(reason)}
    end
  end

  def prepare_in_tx(run, call, args) do
    with {:ok, actor, context} <- request_context(run) do
      if call["name"] == "pod_create_page" do
        Ankole.Pod.lock_tree_in_tx()
        destination_attrs = AgentPages.create_destination_attrs(actor, args)
        Ankole.Pod.lock_root_ids_in_tx(Pages.destination_root_ids(actor, destination_attrs))
      end

      {:ok, [],
       fn ->
         with :ok <- Ankole.AuthZ.authorize_turn_in_tx(actor.turn_authority),
              {:ok, page, publish} <- write_in_tx(call["name"], actor, context, args) do
           result = Ankole.Sessions.Tools.result(%{"id" => page.id, "revision" => page.revision})
           {:ok, result, [publish]}
         else
           {:error, reason} -> {:error, page_error(reason)}
         end
       end}
    end
  end

  # Page reasons reach the model as the next step it can take, so a refused
  # call is corrected in one round instead of guessed at from an atom.
  defp page_error(:not_found),
    do:
      "No Page with this id is visible under your Pod permissions and conversation disclosure. Use an id from pod_list_pages or from a page link in this conversation."

  defp page_error(:forbidden),
    do:
      "You do not have edit permission for this Page or destination. Do not retry the write: in a native Pod room propose an action card if appropriate, or in external IM provide the draft in your reply and ask an authorized owner to save it in Pod."

  defp page_error({:revision_conflict, rev}),
    do:
      "Page revision conflict (current revision is #{rev}). Call pod_get_page to read the latest content and revision before saving again."

  defp page_error(:ontology_owned_category),
    do:
      "Cannot create a Page directly at a protected Brain root. Call pod_list_pages to choose an ontology category or knowledge object parent_id inside the Brain."

  defp page_error(:invalid_page_domain),
    do:
      "Page type does not match the parent domain: Brain parents accept only type \"knowledge\", while Pod Space and Private parents accept type \"doc\". Pass a matching parent_id from pod_list_pages or omit type to match the parent automatically."

  defp page_error(:unknown_brain_category),
    do:
      "The parent is not an ontology category or knowledge object in the Brain. Choose a parent from the Brain pages that pod_list_pages lists."

  defp page_error(:invalid_page_type),
    do:
      "Only Pod document (doc) and Brain knowledge pages support Markdown reads/writes. Use Base or Applet tools for structured tables or applets."

  defp page_error(reason), do: reason

  defp request_context(run) do
    ref = %Ankole.Sessions.RunRef{
      agent_uid: run.agent_uid,
      session_id: run.session_id,
      signal_id: run.signal_id
    }

    with {:ok, actor} <-
           Ankole.Pod.RPCBroker.actor_for_request(ref, %{worker_id: run.agent_uid}),
         {:ok, context} <- Ankole.Pod.RPCBroker.page_context(actor),
         do: {:ok, actor, context}
  end

  defp dispatch("pod_get_page", actor, context, args),
    do: AgentPages.read(actor, context, args["id"], args["level"] || "L2")

  defp dispatch("pod_list_pages", actor, context, args),
    do: AgentPages.children(actor, context, args["id"], Map.take(args, ["scope", "depth"]))

  defp write_in_tx("pod_save_page", actor, context, args) do
    AgentPages.save_page_in_tx(
      actor,
      context,
      args["id"],
      args["base_revision"],
      args["markdown"]
    )
  end

  defp write_in_tx("pod_create_page", actor, context, args) do
    AgentPages.create_page_in_tx(actor, context, args)
  end
end
