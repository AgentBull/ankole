defmodule Ankole.PrincipalsFixtures do
  @moduledoc """
  Test helpers for the `Ankole.Principals` context.
  """

  alias Ankole.Principals

  def unique_uid(prefix \\ "principal") do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  def unique_mobile do
    line_number =
      System.unique_integer([:positive])
      |> rem(9_000)
      |> Kernel.+(1_000)
      |> Integer.to_string()
      |> String.pad_leading(4, "0")

    "+1415555#{line_number}"
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
    {:ok, result} =
      attrs
      |> Enum.into(%{
        uid: unique_uid("agent"),
        display_name: "Agent",
        role: "Research Analyst"
      })
      |> Principals.create_agent()

    result
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

  def channel_actor_identity_fixture(attrs \\ %{}) do
    %{principal: principal} = Map.get_lazy(attrs, :human, fn -> human_fixture() end)

    attrs =
      attrs
      |> Map.delete(:human)
      |> Enum.into(%{
        principal_uid: principal.uid,
        kind: :channel_actor,
        adapter: "lark",
        channel_id: unique_uid("channel"),
        external_id: unique_uid("actor"),
        metadata: %{}
      })

    {:ok, identity} = Principals.create_external_identity(attrs)
    identity
  end
end
