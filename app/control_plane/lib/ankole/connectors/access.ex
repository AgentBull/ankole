defmodule Ankole.Connectors.Access do
  @moduledoc "Resolves a live execution actor before every gateway request."
  alias Ankole.AuthZ.Actor
  alias Ankole.Pod.{Access, Applets, Pages}
  alias Ankole.Connectors.Tokens

  def authorize(%{"kind" => "worker", "agent_uid" => uid} = claims) do
    authority = Tokens.decode_authority(claims["authority"])

    with :ok <- fence(authority),
         {:ok, %{status: :active} = principal} <- Ankole.Principals.get_principal(uid) do
      {:ok,
       %{
         actor: Actor.new(principal, turn_authority: authority),
         read_only: false,
         deadline:
           System.monotonic_time(:millisecond) + claims["expires_at_ms"] -
             System.system_time(:millisecond)
       }}
    end
  end

  def authorize(%{"kind" => "applet"} = claims) do
    remaining = claims["deadline_ms"] - System.system_time(:millisecond)

    context = %{
      "applet" => %{"pageId" => claims["page_id"]},
      "job" => claims["job"],
      "run" => claims["run"]
    }

    with true <- remaining > 0,
         {:ok, page} <- Pages.fetch(claims["page_id"]),
         :ok <- Applets.available(page),
         {:ok, caller} <- caller(claims),
         {:ok, actor} <-
           Applets.Capabilities.actor(
             context,
             page,
             caller,
             claims["actor_mode"] == "admin",
             "mcp.call"
           ),
         :ok <- fence(actor.turn_authority),
         {:ok, _} <- Access.principal(actor) do
      {:ok,
       %{
         actor: actor,
         return_to: applet_return_to(page.id, claims["job"]),
         read_only: claims["read_only"],
         deadline: System.monotonic_time(:millisecond) + remaining
       }}
    else
      false -> {:error, :handler_timeout}
      error -> error
    end
  end

  def authorize(_), do: {:error, :unauthorized}

  defp applet_return_to(page_id, %{"id" => job_id}),
    do: AnkoleWeb.PodURL.page_path(page_id) <> "?" <> URI.encode_query(automation_job: job_id)

  defp applet_return_to(page_id, _job), do: AnkoleWeb.PodURL.page_path(page_id)

  defp caller(%{"caller_uid" => nil}), do: {:ok, nil}

  defp caller(claims) do
    with {:ok, principal} <- Ankole.Principals.get_principal(claims["caller_uid"]),
         do:
           {:ok,
            Actor.new(principal, turn_authority: Tokens.decode_authority(claims["authority"]))}
  end

  defp fence(authority),
    do: Access.write(authority, fn -> {:ok, :authorized} end) |> fence_result()

  defp fence_result({:ok, :authorized}), do: :ok
  defp fence_result(error), do: error
end
