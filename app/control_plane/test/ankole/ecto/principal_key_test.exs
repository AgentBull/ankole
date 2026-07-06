defmodule Ankole.Ecto.PrincipalKeyTest do
  use ExUnit.Case, async: true

  alias Ankole.Ecto.PrincipalKey, as: EctoPrincipalKey
  alias Ankole.PrincipalKey

  import Ecto.Changeset

  test "domain normalizer owns required Principal UID rules" do
    assert {:ok, "alice"} = PrincipalKey.normalize(" Alice ")
    assert {:error, :invalid_uid} = PrincipalKey.normalize(" ")
    assert {:error, :invalid_uid} = PrincipalKey.normalize(:alice)
  end

  test "Ecto type normalizes optional Principal UID values" do
    assert {:ok, "agent-a"} = EctoPrincipalKey.cast(" Agent-A ")
    assert {:ok, nil} = EctoPrincipalKey.cast(" ")
    assert :error = EctoPrincipalKey.cast(:agent)
  end

  test "schemaless changesets receive canonical Principal UID values from the type" do
    changeset =
      {%{}, %{agent_uid: EctoPrincipalKey}}
      |> cast(%{"agent_uid" => " Agent-A "}, [:agent_uid])
      |> validate_required([:agent_uid])

    assert {:ok, %{agent_uid: "agent-a"}} = apply_action(changeset, :validate)
  end
end
