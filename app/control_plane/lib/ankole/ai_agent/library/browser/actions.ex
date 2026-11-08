defmodule Ankole.AIAgent.Library.Browser.Actions do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  alias Ankole.AIAgent.Library.{Contracts, Skills, Management}
  alias Ankole.Pod.APIError

  @impl true
  def run(input, _, %{actor: actor}),
    do: action(input.action.name, input.arguments, actor) |> APIError.result()

  defp action(:list, _, actor) do
    with {:ok, skills} <- Skills.list(actor),
         summaries = Skills.binding_summaries(actor, skills),
         # Permissions depend only on the source kind, so the list checks each kind once.
         permissions =
           skills
           |> Enum.uniq_by(& &1.source_kind)
           |> Map.new(&{&1.source_kind, permissions(&1, actor)}),
         do:
           {:ok,
            %{
              skills:
                Enum.map(
                  skills,
                  &skill(&1, Map.fetch!(summaries, &1.id), permissions[&1.source_kind])
                ),
              can_create: Management.authorize(actor, "tenant_console:custom_skills") == :ok
            }}
  end

  defp action(:detail, %{slug: slug}, actor) do
    with {:ok, detail} <- Skills.detail(actor, slug),
         do: {:ok, %{detail | skill: skill(detail.skill, actor)}}
  end

  defp action(:create, args, actor), do: Skills.create(actor, args) |> project(actor)

  defp action(:save, args, actor) do
    attrs = if args[:new_slug], do: Map.put(args, :slug, args.new_slug), else: args
    Skills.save(actor, args.slug, attrs) |> project(actor)
  end

  defp action(:delete, args, actor) do
    with {:ok, _} <- Skills.delete(actor, args.slug, args.base_revision), do: {:ok, true}
  end

  defp action(:set_all, args, actor),
    do: Skills.set_all(actor, args.slug, args.enabled, args.base_revision) |> project(actor)

  defp action(:set_binding, args, actor),
    do:
      Skills.set_binding(actor, args.slug, args.agent_uid, args.enabled)
      |> project(actor)

  defp action(:put_file, args, actor) do
    with {:ok, bytes} <- decode(args.content_base64),
         do: Skills.put_file(actor, args.slug, args.path, bytes, args) |> project(actor)
  end

  defp action(:change_file, args, actor),
    do: Skills.change_file(actor, args.slug, args.path, args) |> project(actor)

  defp action(:read_file, args, actor) do
    with :ok <- Management.member(actor) do
      Ankole.Repo.transact_repeatable_read_only(fn ->
        with {:ok, skill} <- Skills.get(args.slug),
             {:ok, bytes} <- Skills.read(skill, args.path),
             do: {:ok, %{content_base64: Base.encode64(bytes), revision: skill.revision}}
      end)
    end
  end

  defp action(:import, args, actor) do
    with {:ok, bytes} <- decode(args.content_base64),
         do: Skills.import(actor, args.slug, bytes) |> project(actor)
  end

  defp action(:contracts, args, actor), do: contracts(actor, args.uid)
  defp action(:global_contracts, _, actor), do: contracts(actor, nil)

  defp action(:save_contract, args, actor),
    do: Contracts.save(actor, args.uid, args.slot, args)

  defp action(:save_global_contract, args, actor),
    do: Contracts.save(actor, nil, args.slot, args)

  defp contracts(actor, uid) do
    with {:ok, slots} <- Contracts.list(actor, uid),
         {:ok, effective} <- Contracts.effective(uid) do
      {:ok,
       %{
         contracts:
           Enum.map([:agents, :design], fn slot ->
             local =
               slots[slot] ||
                 %{
                   slot: slot,
                   mode: :inherit,
                   content_xml: "<page />",
                   content_markdown: "",
                   metadata: %{},
                   revision: 0
                 }

             local
             |> Map.take([:slot, :mode, :content_xml, :content_markdown, :metadata, :revision])
             |> Map.put(:effective_markdown, effective[to_string(slot)]["content"])
           end),
         can_edit: Management.agent(actor, uid, "update") == :ok
       }}
    end
  end

  defp decode(value) do
    case Base.decode64(value) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_request}
    end
  end

  defp project({:ok, value}, actor), do: {:ok, skill(value, actor)}
  defp project(error, _), do: error

  defp skill(value, actor),
    do:
      skill(
        value,
        Map.fetch!(Skills.binding_summaries(actor, [value]), value.id),
        permissions(value, actor)
      )

  defp skill(value, summary, permissions),
    do: value |> Map.from_struct() |> Map.merge(summary) |> Map.merge(permissions)

  defp permissions(value, actor),
    do: %{
      can_edit: Management.skill(actor, value, "update") == :ok,
      can_delete:
        value.source_kind == :custom and Management.skill(actor, value, "delete") == :ok,
      can_bind_all: Management.authorize(actor, "tenant_console:skill_bindings") == :ok
    }
end
