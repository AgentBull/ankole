defmodule Ankole.PrincipalsFixtures do
  @moduledoc """
  Test helpers for the `Ankole.Principals` context.
  """

  alias Ankole.Principals
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.Provider
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker

  def first_site_admin_fixture(uid) do
    Ankole.Repo.transact(fn repo ->
      with {:ok, _} <- Ankole.AuthZ.Root.ensure_all_humans_group(repo),
           {:ok, group} <- Ankole.AuthZ.Root.ensure_site_admin_group(repo),
           {:ok, _} <- Ankole.AuthZ.Grants.upsert_console_admin_grants(repo, group),
           do: Ankole.AuthZ.root_init_admin(uid, repo)
    end)
  end

  def disable_principal_fixture(uid) do
    with {:ok, principal} <- Principals.get_principal(uid) do
      case principal.type do
        :human ->
          Ankole.Principals.HumanAccess.disable(
            uid,
            "test_disable",
            nil,
            Ankole.Kernel.gen_uuid_v7()
          )

        :agent ->
          Principals.delete_agent(uid)

        _ ->
          Ankole.Repo.transact(fn repo ->
            principal
            |> Ankole.Principals.Principal.status_changeset(%{status: :disabled})
            |> repo.update()
          end)
      end
    end
  end

  def unique_uid(prefix \\ "principal") do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  def unique_mobile do
    # NANP-valid exchange (200-999) plus a four-digit line keeps every
    # generated number E.164-valid across eight million unique values.
    n = System.unique_integer([:positive]) |> rem(8_000_000)
    exchange = 200 + div(n, 10_000)
    line = n |> rem(10_000) |> Integer.to_string() |> String.pad_leading(4, "0")

    "+1415#{exchange}#{line}"
  end

  def human_fixture(attrs \\ %{}) do
    {:ok, result} =
      attrs
      |> Enum.into(%{
        display_name: "Human",
        email: "#{unique_uid("human")}@example.com",
        mobile: unique_mobile(),
        job_title: "Operator"
      })
      |> Principals.create_human()

    result
  end

  def agent_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{
        handle: unique_uid("agent"),
        display_name: "Agent",
        role: "Research Analyst"
      })
      |> Map.put_new_lazy(:owner_principal_uid, fn ->
        %{principal: owner} = human_fixture()
        owner.uid
      end)
      |> Map.put_new_lazy(:worker_provider_id, fn -> worker_provider_fixture().provider_id end)

    {:ok, result} = Principals.create_agent(attrs)
    result
  end

  def worker_provider_fixture(attrs \\ %{}) do
    {:ok, provider} =
      attrs
      |> Enum.into(%{
        provider_id: unique_uid("fixture-worker"),
        display_name: "Test Worker provider",
        kind: "docker",
        config: "network: bridge\n",
        credentials: %{}
      })
      |> Providers.create()

    provider
  end

  @doc """
  Deletes every committed row an `agent_fixture/1` creates: the agent
  Principal, its lazily created owner human, its Worker row, and both
  canonical Brain objects. Tests that run the fixture inside
  `Sandbox.unboxed_run/2` must use this cleanup; deleting only the agent
  Principal leaks the owner and the Worker row, and later suite runs collide
  with them.
  """
  def delete_agent_fixture_rows(agent_uid, provider_id \\ nil) do
    import Ecto.Query, only: [where: 3]

    worker = Ankole.Repo.get(AgentWorker, agent_uid)
    provider_id = if worker, do: worker.provider_id, else: provider_id

    owner_uid =
      case Ankole.Repo.get(Ankole.Principals.Agent, agent_uid) do
        %Ankole.Principals.Agent{owner_principal_uid: owner_uid} -> owner_uid
        nil -> nil
      end

    slugs =
      if owner_uid,
        do: ["agents/#{agent_uid}", "people/#{owner_uid}"],
        else: ["agents/#{agent_uid}"]

    Ankole.Brain.Schemas.Object
    |> where([object], object.slug in ^slugs)
    |> Ankole.Repo.delete_all()

    Ankole.Principals.Principal
    |> where([principal], principal.uid == ^agent_uid)
    |> Ankole.Repo.delete_all()

    # The Worker row has no foreign key: a deleted Agent's row stays until its
    # backend objects are gone.
    AgentWorker
    |> where([worker], worker.agent_uid == ^agent_uid)
    |> Ankole.Repo.delete_all()

    # Remove only a fixture provider that no remaining Worker uses.
    if provider_id && String.starts_with?(provider_id, "fixture-worker-") do
      unless Ankole.Repo.exists?(where(AgentWorker, [w], w.provider_id == ^provider_id)) do
        Provider
        |> where([provider], provider.provider_id == ^provider_id)
        |> Ankole.Repo.delete_all()
      end
    end

    if owner_uid do
      Ankole.Principals.Principal
      |> where([principal], principal.uid == ^owner_uid)
      |> Ankole.Repo.delete_all()
    end

    :ok
  end

  def platform_subject_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{
        provider: "lark-main",
        external_id: unique_uid("user"),
        display_name: "Platform User",
        email: "#{unique_uid("platform")}@example.com",
        metadata: %{"tenant_key" => "tenant_x"}
      })

    {:ok, result} = Principals.upsert_platform_subject_human(attrs)
    result
  end

  def external_identity_fixture(attrs \\ %{}) do
    %{principal: principal} = Map.get_lazy(attrs, :human, fn -> human_fixture() end)

    attrs =
      attrs
      |> Map.delete(:human)
      |> Enum.into(%{
        principal_uid: principal.uid,
        provider: "lark-main",
        external_id: unique_uid("actor"),
        metadata: %{}
      })

    {:ok, identity} = Principals.create_external_identity(attrs)
    identity
  end
end
