defmodule Ankole.Sessions.Tools.Peers do
  @moduledoc false
  @behaviour Ankole.Sessions.Tool

  def declarations(run) do
    case Ankole.Principals.get_agent_record!(run.agent_uid) do
      %{type: :personal_assistant} -> declarations()
      _ -> []
    end
  end

  def declarations do
    [
      %{
        "type" => "function",
        "name" => "send_to_agent",
        "activity" => "send_to_agent",
        "strict" => false,
        "description" =>
          "Delegate domain work asynchronously to an AI colleague. The colleague retrieves its own role knowledge and asks the human any task-specific questions directly. Returns a delivery receipt, not the answer. Preserve the user's original goal, constraints and canonical page links. Inside an agent_peer exchange, reply normally; do not call this tool to answer the sender.",
        "parameters" => %{
          "type" => "object",
          "required" => ["target_agent_uid", "message"],
          "properties" => %{
            "target_agent_uid" => %{"type" => "string", "minLength" => 1},
            "message" => %{"type" => "string", "minLength" => 1},
            "page_ids" => %{
              "type" => "array",
              "items" => %{"type" => "string", "format" => "uuid"}
            },
            "priority" => %{"type" => "boolean"}
          }
        },
        "execution_mode" => "sequential",
        "read_only" => false,
        "destructive" => false
      }
    ]
  end

  def normalize(_, args), do: args

  def prepare_in_tx(run, _call, args) do
    case Ankole.Conversations.prepare_peer_send(run, args) do
      {:error, %{} = error} ->
        {:ok, [], fn -> {:ok, Ankole.Sessions.Tools.result(error, is_error: true), []} end}

      {:error, reason} ->
        {:ok, [],
         fn ->
           {:ok,
            Ankole.Sessions.Tools.result(
              %{
                error: reason,
                guidance:
                  "Only a personal assistant may initiate colleague work. Inside a peer exchange, reply normally to return the result. A chain stops at six hops; a new human instruction starts a new chain."
              },
              is_error: true
            ), []}
         end}

      result ->
        result
    end
  end
end
