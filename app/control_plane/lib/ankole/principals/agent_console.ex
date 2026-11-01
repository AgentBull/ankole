defmodule Ankole.Principals.AgentConsole do
  @moduledoc """
  Runs the Console generic actions of `Ankole.Principals.Agent`.

  Each write uses the `_in_tx` steps of `Ankole.Principals` in the action
  transaction and gives the Agent with the fields of its Principal. A change
  of the Agent status publishes the status of its conversations after the
  commit; a deletion also reconciles the Worker.
  """

  alias Ankole.AgentWorkers.Providers
  alias Ankole.Errors.Invalid.NotFound
  alias Ankole.Principals
  alias Ankole.Principals.Agent
  alias Ankole.Principals.Principal

  @doc false
  def create_in_tx(arguments, %Principal{} = operator) do
    attrs =
      Map.merge(arguments, %{
        created_by: Ankole.ActorRef.from_principal(operator)
      })

    with {:ok, %{principal: principal, agent: agent}} <-
           Principals.create_agent_in_tx(attrs) do
      {:ok, present(agent, principal)}
    end
  end

  @doc false
  def update_in_tx(arguments) do
    {uid, attrs} = Map.pop!(arguments, :uid)

    with {:ok, %{principal: principal, agent: agent}} <-
           Principals.update_agent_in_tx(uid, attrs) do
      {:ok, present(agent, principal)}
    end
  end

  @doc false
  def enable_in_tx(uid) do
    with {:ok, {principal, conversation_ids}} <- Principals.enable_agent_in_tx(uid) do
      {:ok, Principals.get_agent_record!(uid) |> present(principal, conversation_ids)}
    end
  end

  # A disabled Agent is deleted, so the Agent row is read before the change.
  @doc false
  def delete_in_tx(uid) do
    with %Agent{} = agent <- Principals.get_agent_record!(uid),
         {:ok, {principal, conversation_ids}} <- Principals.delete_agent_in_tx(uid) do
      {:ok, present(agent, principal, conversation_ids)}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Publishes the conversation status of an enabled Agent after the commit."
  def publish_enable(%Agent{} = agent),
    do: Principals.publish_agent_changes({agent, agent.__metadata__[:conversation_ids]})

  @doc "Publishes the conversation status and reconciles the Worker after a deletion."
  def publish_delete(%Agent{} = agent),
    do: Principals.publish_agent_deletion({agent, agent.__metadata__[:conversation_ids]})

  @doc """
  Gives the answer of a rejected Agent write for `Ankole.Errors.wrap/2`: a
  missing Agent is not found.
  """
  def rejection(reason) when reason in [:not_found, :not_agent],
    do: NotFound.exception(resource: Agent)

  def rejection(:worker_provider_required),
    do: {"Select a Worker provider or set a default provider", []}

  def rejection(:worker_provider_not_found),
    do: {"The selected Worker provider was not found", []}

  def rejection(:ai_agent_options_not_writable),
    do:
      {"options.ai_agent.models, provider_hosted, and token_quota belong to their own routes", []}

  def rejection(:token_quota_not_writable_at_creation),
    do: {"options.ai_agent.token_quota is set through the token quota route after creation", []}

  def rejection(reason),
    do: Principals.describe_refusal(reason) || Providers.Errors.rejection(reason)

  defp present(agent, principal, conversation_ids \\ []) do
    %{
      agent
      | status: principal.status,
        display_name: principal.display_name,
        avatar_url: principal.avatar_url,
        worker_provider_id: Map.get(Providers.provider_ids([agent.uid]), agent.uid)
    }
    |> Ash.Resource.put_metadata(:conversation_ids, conversation_ids)
  end
end
