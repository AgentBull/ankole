defmodule Ankole.PrincipalsFixtures do
  @moduledoc """
  Test helpers for the `Ankole.Principals` context.
  """

  alias Ankole.Principals

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
        uid: unique_uid("human"),
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
        uid: unique_uid("agent"),
        display_name: "Agent",
        role: "Research Analyst"
      })
      |> Map.put_new_lazy(:owner_principal_uid, fn ->
        %{principal: owner} = human_fixture()
        owner.uid
      end)

    {:ok, result} = Principals.create_agent(attrs)
    result
  end

  @doc """
  Deletes every committed row an `agent_fixture/1` creates: the agent
  Principal, its lazily created owner human, and both canonical Brain
  objects. Tests that run the fixture inside `Sandbox.unboxed_run/2` must
  use this cleanup; deleting only the agent Principal leaks the owner and
  later suite runs collide with it.
  """
  def delete_agent_fixture_rows(agent_uid) do
    import Ecto.Query, only: [where: 3]

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
