defmodule Ankole.Brain.CurationGuide do
  @moduledoc "Reads the human-maintained curation policy from an Agent's self store."

  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Scope

  @entry_type "brain_curation_guide"

  @spec load(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def load(owner_uid) when is_binary(owner_uid) do
    with {:ok, scope} <- Scope.for_store(owner_uid, "self"),
         {:ok, entries} <-
           Knowledge.list_entries(scope, type: @entry_type, store_key: "self", limit: 1) do
      case entries do
        [entry] -> open_body(scope, entry.id)
        [] -> {:ok, nil}
      end
    end
  end

  def load(_owner_uid), do: {:error, :invalid_owner_uid}

  @doc "Returns the built-in entry-type guide that every curator must follow."
  @spec type_guide() :: map()
  def type_guide do
    %{
      "type_convergence" =>
        "Reuse the closest existing type and entry before introducing another type. Types describe a stable subject, not one task or one day's activity.",
      "templates" => %{
        "customer" =>
          "Keep stable needs, stakeholders, relationship state, decisions, and supported constraints. Update the same customer entry instead of appending a chronological contact log.",
        "policy" =>
          "A rule the organization or the outside world imposes. Keep the policy scope, trigger, required or forbidden behavior, exceptions, owner, and supporting source; replace superseded rules in the same policy entry. A rule for this Agent's own conduct belongs in the pinned memo.",
        "person" =>
          "Use one entry per person for stable preferences, roles, and relationships. When material supplies speaker_principal_uid for that person, store it as properties.principal_uid.",
        "organization" =>
          "Use one entry per team or organization for durable structure and policy.",
        "project" =>
          "Use one entry per continuing project for goals, decisions, and current state.",
        "topic" =>
          "Use a durable subject name. Do not use a task title or date as the entry name.",
        "channel" =>
          "Record only channel purpose, membership conventions, and communication norms.",
        "agent_system_pinned_memo" =>
          "The resident brief of this Agent's conduct rules, injected into every conversation. Each rule is compact, works without opening another entry, and can change behavior.",
        "brain_curation_guide" => "Keep human curation policy in this self-store entry."
      }
    }
  end

  defp open_body(scope, entry_id) do
    with {:ok, %{blocks: blocks}} <- Knowledge.open(scope, entry_id, block_limit: :all) do
      body =
        blocks
        |> Enum.map(&String.trim(&1.body))
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")

      if body == "", do: {:ok, nil}, else: {:ok, body}
    end
  end
end
