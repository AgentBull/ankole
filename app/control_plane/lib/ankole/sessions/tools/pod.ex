defmodule Ankole.Sessions.Tools.Pod do
  @moduledoc "Lightweight Pod page tools for a Session without starting a Worker job."
  @behaviour Ankole.Sessions.Tool
  alias Ankole.Pod.{AgentPages, Pages}

  def declarations do
    [
      declaration(
        "pod_get_page",
        "Read a Pod page at L0 (summary), L1 (outline), or L2 (full content). Knowledge pages return OKF Markdown. Only content visible to this conversation is returned.",
        %{"id" => id(), "level" => %{"type" => "string", "enum" => ["L0", "L1", "L2"]}},
        ["id"],
        true
      ),
      declaration(
        "pod_list_pages",
        "List the visible children of a Pod page, with their knowledge summaries. Omit id to find the shared Space roots. Use brain to discover organizational knowledge.",
        %{"id" => id()},
        [],
        true
      ),
      declaration(
        "pod_save_page",
        "Save the complete OKF Markdown and frontmatter of a knowledge page using the revision from pod_get_page. Shared rules belong on the shared page. If edit access is missing, propose a pod.knowledge.save action card in a native Pod room; in external IM provide the draft and ask an authorized owner to confirm it in Pod.",
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
        "Create a Brain knowledge object under a visible editable ontology category or knowledge object. Use ankole-pod pages.create with type doc and markdown for collaboration documents. Skills and Agent instructions are managed by humans in Meta Ankole.",
        %{
          "parent_id" => id(),
          "title" => %{"type" => "string"},
          "markdown" => %{"type" => "string"}
        },
        ["parent_id", "title", "markdown"],
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
      "execution_mode" => if(read_only, do: "parallel", else: "sequential")
    }
  end

  def normalize(_name, args), do: args

  def execute(run, call, args) do
    with {:ok, actor, context} <- request_context(run),
         {:ok, result} <- dispatch(call["name"], actor, context, args),
         do: {:ok, Ankole.Sessions.Tools.result(Ankole.JSON.plain(result))}
  end

  def prepare_in_tx(run, call, args) do
    with {:ok, actor, context} <- request_context(run) do
      if call["name"] == "pod_create_page" do
        Ankole.Pod.lock_tree_in_tx()
        Ankole.Pod.lock_root_ids_in_tx(Ankole.Pod.root_ids([args["parent_id"]]))
      end

      {:ok, [],
       fn ->
         with :ok <- Ankole.AuthZ.authorize_turn_in_tx(actor.turn_authority),
              {:ok, page, publish} <- write_in_tx(call["name"], actor, context, args) do
           result = Ankole.Sessions.Tools.result(%{"id" => page.id, "revision" => page.revision})
           {:ok, result, [publish]}
         end
       end}
    end
  end

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
    do: AgentPages.children(actor, context, args["id"])

  defp write_in_tx("pod_save_page", actor, context, args) do
    with {:ok, %{page: page}} <-
           AgentPages.save_in_tx(
             actor,
             context,
             args["id"],
             args["base_revision"],
             args["markdown"]
           ),
         do: {:ok, page, fn -> Pages.committed_page(page) end}
  end

  defp write_in_tx("pod_create_page", actor, context, args) do
    with {:ok, page} <-
           AgentPages.create_in_tx(
             actor,
             context,
             args["parent_id"],
             args["title"],
             args["markdown"]
           ),
         do: {:ok, page, fn -> Pages.committed_tree(page) end}
  end
end
