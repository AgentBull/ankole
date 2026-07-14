defmodule Ankole.Brain.Snapshot do
  @moduledoc """
  Captures the Brain projection injected at conversation start.

  The snapshot is stored on the AIGateway conversation itself. Later writes to
  Brain become durable immediately but cannot change the model prefix until a
  successor conversation is created.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIGateway
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.Brain.Config
  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Schemas.Entry
  alias Ankole.Brain.Scope
  alias Ankole.Repo

  @pinned_name "Agent Memo"
  @pinned_type "agent_system_pinned_memo"

  @spec get_or_create(Conversation.t()) :: {:ok, map()} | {:error, term()}
  def get_or_create(%Conversation{id: conversation_id} = conversation) do
    case existing_snapshot(conversation) do
      {:ok, snapshot} ->
        {:ok, snapshot}

      :missing ->
        # AppConfigure's cache miss is loaded by its owning GenServer. Resolve it
        # before taking the conversation row lock; otherwise the transaction may
        # hold one pool connection while synchronously waiting for that GenServer
        # to check out another (a deterministic deadlock with a one-connection
        # SQL sandbox and needless pool pressure in production).
        with {:ok, config} <- Config.knowledge() do
          Repo.transact(fn repo ->
            with %Conversation{} = conversation <-
                   AIGateway.lock_conversation(repo, conversation_id),
                 {:ok, snapshot, conversation} <- snapshot_in_tx(repo, conversation, config) do
              {:ok, %{snapshot: snapshot, conversation: conversation}}
            else
              nil -> {:error, :brain_conversation_not_found}
              {:error, _reason} = error -> error
            end
          end)
          |> case do
            {:ok, %{snapshot: snapshot}} -> {:ok, snapshot}
            {:error, _reason} = error -> error
          end
        end
    end
  end

  defp existing_snapshot(%Conversation{} = conversation) do
    case get_in(conversation.metadata || %{}, ["brain", "snapshot"]) do
      snapshot when is_map(snapshot) -> {:ok, snapshot}
      _missing -> :missing
    end
  end

  defp snapshot_in_tx(repo, %Conversation{} = conversation, config) do
    brain = get_in(conversation.metadata || %{}, ["brain"])

    case brain do
      %{"snapshot" => snapshot} when is_map(snapshot) ->
        {:ok, snapshot, conversation}

      %{} ->
        with {:ok, scope} <- Scope.from_conversation(conversation),
             :ok <- lock_pinned_memo(repo, scope.owner_uid),
             {:ok, pinned} <- pinned_memo(scope.owner_uid, config),
             {:ok, channel} <- channel_entry(scope),
             snapshot = %{"pinned_memo" => pinned, "channel_entry" => channel},
             metadata = put_in(conversation.metadata, ["brain", "snapshot"], snapshot),
             {:ok, conversation} <-
               AIGateway.update_conversation_metadata_in_tx(repo, conversation, metadata) do
          {:ok, snapshot, conversation}
        end

      _other ->
        {:error, :missing_brain_scope}
    end
  end

  defp lock_pinned_memo(repo, owner_uid) do
    case repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
           "brain:pinned-memo:#{owner_uid}"
         ]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:brain_snapshot_lock_failed, reason}}
    end
  end

  defp pinned_memo(owner_uid, %{"pinned_memo_max_tokens" => budget}) do
    with {:ok, scope} <- Scope.for_store(owner_uid, "public"),
         {:ok, entry} <- ensure_pinned_entry(scope),
         {:ok, projection} <- Knowledge.open(scope, entry.id, block_limit: :all) do
      {:ok, snapshot_entry(projection, budget)}
    end
  end

  defp ensure_pinned_entry(scope) do
    case Repo.one(
           from entry in Entry,
             where:
               entry.owner_uid == ^scope.owner_uid and entry.store_key == "public" and
                 entry.type == ^@pinned_type,
             limit: 1
         ) do
      %Entry{} = entry ->
        {:ok, entry}

      nil ->
        with {:ok, %{results: [%{entry_id: entry_id}]}} <-
               Knowledge.apply_mechanical_operation(
                 scope,
                 %{
                   operation: "create_entry",
                   name: @pinned_name,
                   type: @pinned_type,
                   summary: "",
                   aliases: [],
                   properties: %{}
                 },
                 %{"surface" => "conversation_snapshot", "automatic" => true}
               ),
             %Entry{} = entry <- Repo.get(Entry, entry_id) do
          {:ok, entry}
        else
          nil -> {:error, :brain_pinned_memo_not_found}
          {:error, _reason} = error -> error
        end
    end
  end

  defp channel_entry(%Scope{current_channel: %{id: channel_id, kind: "im_group"}} = scope) do
    with %Entry{} = entry <-
           Repo.one(
             from entry in Entry,
               where:
                 entry.owner_uid == ^scope.owner_uid and entry.store_key == "public" and
                   fragment("?->>'channel_id' = ?", entry.properties, ^channel_id),
               limit: 1
           ),
         {:ok, projection} <- Knowledge.open(scope, entry.id, block_limit: :all) do
      {:ok, snapshot_entry(projection, :unlimited)}
    else
      nil -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp channel_entry(%Scope{}), do: {:ok, nil}

  defp snapshot_entry(%{entry: entry, blocks: blocks}, budget) do
    {resident_text, truncated} =
      entry
      |> resident_text(blocks)
      |> truncate(budget)

    %{
      "resident_text" => resident_text,
      "truncated" => truncated
    }
  end

  # Resident context is a model-facing read projection, not the generic
  # Knowledge Markdown used for browsing and precise edits. Blocks are already
  # ordered by Knowledge.open/3; a summary is only a fallback for an entry with
  # no body so it cannot duplicate the actionable text.
  defp resident_text(entry, blocks) do
    bodies =
      blocks
      |> Enum.map(&String.trim(&1.body))
      |> Enum.reject(&(&1 == ""))

    case bodies do
      [] -> String.trim(entry.summary || "")
      _bodies -> Enum.join(bodies, "\n\n")
    end
  end

  defp truncate(text, :unlimited) do
    {text, false}
  end

  defp truncate(text, budget) when is_integer(budget) and budget > 0 do
    tokens = estimate_tokens(text)

    if tokens <= budget do
      {text, false}
    else
      {fit_prefix(text, budget), true}
    end
  end

  defp fit_prefix(text, budget) do
    graphemes = String.graphemes(text)

    0..length(graphemes)
    |> Enum.reduce_while({0, length(graphemes), ""}, fn _step, {low, high, best} ->
      if low > high do
        {:halt, best}
      else
        middle = div(low + high, 2)
        candidate = graphemes |> Enum.take(middle) |> Enum.join()

        if estimate_tokens(candidate) <= budget do
          {:cont, {middle + 1, high, candidate}}
        else
          {:cont, {low, middle - 1, best}}
        end
      end
    end)
    |> case do
      {_low, _high, best} -> best
      best when is_binary(best) -> best
    end
  end

  defp estimate_tokens(text), do: Ankole.Kernel.estimate_o200k_base_tokens(text)
end
