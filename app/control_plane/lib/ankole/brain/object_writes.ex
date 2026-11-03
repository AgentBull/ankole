defmodule Ankole.Brain.ObjectWrites do
  @moduledoc "Explicit, attributed Brain edits within the current conversation's disclosure boundary."
  alias Ankole.Brain.{Namespace, Tools.Context}
  alias Ankole.Pod.{AgentPages, Pages}
  alias Ankole.Pod.Pages.Tree

  def category("agents"), do: {:error, :ontology_owned_category}

  def category(name) when is_binary(name) do
    prefixes = Ankole.Brain.Schemas.SchemaType |> Ankole.Ash.read!()

    if Enum.any?(prefixes, &(String.trim_trailing(&1.slug_prefix, "/") == name)) do
      with {:ok, root} <- Namespace.root(), do: Tree.child(root.id, name)
    else
      {:error, :unknown_brain_category}
    end
  end

  def category(_), do: {:error, :unknown_brain_category}

  def write(params, context) do
    with :ok <- Context.fence(context),
         {:ok, principal} <- Ankole.Principals.get_principal(context.querier_uid),
         actor = Ankole.AuthZ.Actor.new(principal, authn: context.authn),
         {:ok, target, action} <- target(params),
         {:ok, _} <- AgentPages.visible(context, target) do
      case AgentPages.editable(actor, context, target) do
        :ok ->
          commit(action, actor, context, target, params)

        {:error, :forbidden} ->
          {:ok,
           %{
             "status" => "approval_required",
             "proposal" => proposal(action, target, params),
             "next_step" =>
               "Call propose_action_card in a native Pod conversation with this proposal. An authorized human must approve it."
           }}

        error ->
          error
      end
    end
  end

  defp target(%{"object_id" => id}) when is_binary(id) do
    with {:ok, %{type: :knowledge, system_key: nil} = page} <- Pages.fetch(id),
         do: {:ok, page, :save},
         else: (
           {:ok, _} -> {:error, :system_node}
           error -> error
         )
  end

  defp target(%{"category" => name, "title" => title, "base_revision" => 0})
       when is_binary(title) do
    with true <- String.trim(title) != "",
         {:ok, page} <- category(name),
         do: {:ok, page, :create},
         else: (
           false -> {:error, :invalid_request}
           error -> error
         )
  end

  defp target(_), do: {:error, :invalid_request}

  defp commit(:save, actor, context, target, params) do
    AgentPages.save(actor, context, target.id, params["base_revision"], params["markdown"])
    |> result()
  end

  defp commit(:create, actor, context, target, params) do
    AgentPages.create(actor, context, target.id, params["title"], params["markdown"])
    |> result()
  end

  defp result({:ok, %{page: page}}),
    do: {:ok, %{"status" => "saved", "object_id" => page.id, "revision" => page.revision}}

  defp result({:ok, %Ankole.Pod.Page{} = page}),
    do: {:ok, %{"status" => "saved", "object_id" => page.id, "revision" => page.revision}}

  defp result(error), do: error

  defp proposal(action, target, params) do
    %{
      "action_kind" =>
        if(action == :create, do: "brain.object.create", else: "pod.knowledge.save"),
      "node_id" => target.id,
      "category" => params["category"],
      "title" => params["title"],
      "base_revision" => params["base_revision"],
      "markdown" => params["markdown"],
      "summary" =>
        if(action == :create,
          do: "Create Brain object #{params["title"]}",
          else: "Update Brain object #{target.title}"
        )
    }
  end
end
