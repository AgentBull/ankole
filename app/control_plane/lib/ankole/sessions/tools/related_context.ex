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
        "read_only" => true,
        "destructive" => false
      }
    ]
  end

  def normalize(_, args), do: args

  def execute(run, _call, args) do
    with {:ok, context} <-
           Ankole.Conversations.recall_related_context(run, args["ref_id"], args["cursor"]),
         do: {:ok, Ankole.Sessions.Tools.result(Ankole.JSON.plain(context))}
  end
end
