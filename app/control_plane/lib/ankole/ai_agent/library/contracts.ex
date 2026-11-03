defmodule Ankole.AIAgent.Library.Contracts do
  @moduledoc "Owns global and individual Agent contracts and their deterministic composition."
  require Ash.Query
  alias Ankole.AIAgent.Library.{Management, SourceReader}
  alias Ankole.AIAgent.Library.Schemas.AgentContract
  alias Ankole.Repo

  def initialize_in_tx do
    with :ok <- Repo.require_transaction(),
         {:ok, _} <- seed(nil, :agents, default_agents()),
         {:ok, _} <- seed(nil, :design, SourceReader.load_default_design_template()),
         do: :ok
  end

  def seed_agent_in_tx(uid, type) do
    with :ok <- initialize_in_tx() do
      if type == :personal_assistant do
        markdown =
          join(
            SourceReader.load_personal_assistant_template("SOUL.md"),
            SourceReader.load_personal_assistant_template("MISSION.md"),
            "\n\n"
          )

        with {:ok, _} <- seed(uid, :agents, markdown), do: :ok
      else
        :ok
      end
    end
  end

  def get(uid, slot) do
    query = Ash.Query.filter(AgentContract, slot == ^slot)

    query =
      if is_nil(uid),
        do: Ash.Query.filter(query, is_nil(agent_uid)),
        else: Ash.Query.filter(query, agent_uid == ^uid)

    Ankole.Ash.read_one(query)
  end

  def list(actor, uid) do
    with :ok <- Management.agent(actor, uid, "read"),
         {:ok, agents} <- get(uid, :agents),
         {:ok, design} <- get(uid, :design),
         do: {:ok, %{agents: agents, design: design}}
  end

  def save(actor, uid, slot, attrs) do
    with :ok <- Management.agent(actor, uid, "update"),
         true <- slot in [:agents, :design],
         true <-
           attrs.mode in [:inherit, :append, :override] and
             (not is_nil(uid) or attrs.mode == :override),
         {:ok, content} <- content(attrs.content_xml, attrs.metadata) do
      Repo.transact_top_level(
        fn ->
          Ankole.AdvisoryLock.lock!(Repo, "contract:#{Repo.tenant_id!()}:#{uid}:#{slot}")

          with {:ok, current} <- get(uid, slot) do
            case current do
              nil when attrs.base_revision == 0 ->
                Ankole.Ash.create(
                  AgentContract,
                  :create,
                  Map.merge(content, %{
                    agent_uid: uid,
                    slot: slot,
                    mode: attrs.mode,
                    updated_by: actor.principal.uid
                  })
                )

              nil ->
                {:error, :stale}

              row ->
                Ankole.Ash.update(
                  row,
                  :save,
                  Map.merge(content, %{
                    mode: attrs.mode,
                    base_revision: attrs.base_revision,
                    updated_by: actor.principal.uid
                  })
                )
            end
          end
        end,
        after_commit: &Management.committed/1
      )
    else
      false -> {:error, :invalid_contract}
      error -> error
    end
  end

  def effective(uid) do
    with {:ok, agents} <- compose(uid, :agents),
         {:ok, design} <- compose(uid, :design),
         do: {:ok, %{"agents" => agents, "design" => design}}
  end

  def default_agents,
    do:
      join(
        SourceReader.load_default_soul_template(),
        SourceReader.load_default_mission_template(),
        "\n\n"
      )

  @doc "Agent objects merge recursively; arrays/scalars replace and null removes a key."
  def merge_metadata(global, local) do
    Enum.reduce(local, global, fn
      {key, nil}, merged ->
        Map.delete(merged, key)

      {key, value}, merged ->
        Map.update(merged, key, value, fn old ->
          if is_map(old) and is_map(value), do: merge_metadata(old, value), else: value
        end)
    end)
  end

  defp compose(uid, slot) do
    with {:ok, global} <- get(nil, slot), {:ok, local} <- get(uid, slot) do
      case local do
        %{mode: :override} ->
          {:ok, document(slot, local.content_markdown)}

        %{mode: :append} when not is_nil(global) ->
          with {:ok, left} <- Ankole.Kernel.knowledge_export(global.content_xml, %{}),
               {:ok, right} <- Ankole.Kernel.knowledge_export(local.content_xml, %{}),
               separator = if(slot == :design, do: "\n\n---\n\n", else: "\n\n"),
               {:ok, parsed} <- Ankole.Kernel.knowledge_parse(join(left, right, separator)),
               {:ok, text} <-
                 Ankole.Kernel.knowledge_export(
                   parsed.xml,
                   merge_metadata(global.metadata, local.metadata)
                 ),
               do: {:ok, document(slot, text)}

        _ when not is_nil(global) ->
          {:ok, document(slot, global.content_markdown)}

        _ ->
          {:error, :agent_contract_missing}
      end
    end
  end

  defp document(slot, text),
    do: %{"kind" => to_string(slot), "content" => text, "content_hash" => SourceReader.hash(text)}

  defp content(xml, metadata) do
    with {:ok, _} <- Ankole.Kernel.knowledge_validate(xml),
         {:ok, text} <- Ankole.Kernel.knowledge_export(xml, metadata),
         do: {:ok, %{content_xml: xml, metadata: metadata, content_markdown: text}}
  end

  defp seed(uid, slot, markdown) do
    with {:ok, parsed} <- Ankole.Kernel.knowledge_parse(markdown),
         {:ok, content} <- content(parsed.xml, parsed.metadata),
         {:ok, current} <- get(uid, slot) do
      hash = SourceReader.hash(content.content_markdown)

      cond do
        is_nil(current) ->
          Ankole.Ash.create(
            AgentContract,
            :create,
            Map.merge(content, %{
              agent_uid: uid,
              slot: slot,
              mode: :override,
              upstream_state: %{"upstream_base_hash" => hash}
            })
          )

        is_nil(uid) and current.upstream_state["upstream_base_hash"] != hash and
            SourceReader.hash(current.content_markdown) ==
              current.upstream_state["upstream_base_hash"] ->
          Ankole.Ash.update(
            current,
            :save,
            Map.merge(content, %{
              base_revision: current.revision,
              upstream_state: %{"upstream_base_hash" => hash}
            })
          )

        true ->
          {:ok, current}
      end
    end
  end

  defp join(left, right, separator),
    do: [left, right] |> Enum.reject(&(String.trim(&1) == "")) |> Enum.join(separator)
end
