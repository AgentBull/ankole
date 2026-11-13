defmodule Ankole.Sessions.Tools.RelatedContext do
  @moduledoc false
  @behaviour Ankole.Sessions.Tool
  def declarations do
    [
      %{
        "type" => "function",
        "name" => "recall_related_context",
        "activity" => "recall_related_context",
        "description" =>
          "Read prior peer exchanges, direct conversations or page comments from a recent context reference. Only records readable by every person in this conversation are available. Follow next_cursor for further messages.",
        "parameters" => %{
          "type" => "object",
          "required" => ["ref_id"],
          "properties" => %{
            "ref_id" => %{"type" => "string", "format" => "uuid"},
            "cursor" => %{"type" => "string"}
          }
        },
        "allowed_callers" => ["direct", "programmatic"],
        "read_only" => true,
        "destructive" => false
      }
    ]
  end

  def normalize(_, args), do: args

  def execute(run, _call, args) do
    case Ankole.Conversations.recall_related_context(run, args["ref_id"], args["cursor"]) do
      {:ok, context} ->
        {:ok, Ankole.Sessions.Tools.result(Ankole.JSON.plain(context))}

      # The reason covers an id that names no related record as well as one this
      # audience may not read, so the text names where a valid ref_id comes from.
      {:error, :related_context_unavailable} ->
        {:error,
         "No related context with this ref_id is available to everyone in this conversation. Use a reference ID from the recent related context list; read a Page id with pod_get_page or `ankole-pod pages.read` instead."}

      {:error, _reason} = error ->
        error
    end
  end
end
