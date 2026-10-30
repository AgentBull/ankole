defmodule Ankole.AuthZ.Authorizer do
  @moduledoc "Ash execution boundary for the Principal/AuthZ permission engine."
  @behaviour Ash.Authorizer

  @doc false
  def __ankole_authz__?, do: true

  @impl true
  def initial_state(actor, resource, action, _domain),
    do: %{actor: actor, resource: resource, action: action.name}

  @impl true
  def strict_check_context(_), do: [:query, :changeset, :action_input]
  @impl true
  def check_context(_), do: []
  @impl true
  def check(_, _), do: {:error, Ash.Error.Forbidden.exception([])}
  @impl true
  def strict_check(state, context) do
    scope = Spark.Dsl.Extension.get_opt(state.resource, [:authz], :scope, nil)

    with %{} = rule <- Ankole.AuthZ.Dsl.rule(state.resource, state.action),
         :ok <- guardrail(state.actor, scope, rule.check) do
      subject = context[:query] || context[:changeset] || context[:action_input]

      case rule.check do
        check when check in [:public, :guardrail] ->
          {:authorized, state}

        :pod_filter ->
          case pod_filter(state.actor, subject) do
            {:ok, %{filter: filter}} ->
              {:filter, state, filter}

            _ ->
              forbidden()
          end

        :grant ->
          case Ankole.AuthZ.Checks.GrantCheck.check(state.actor, %{
                 rule: rule,
                 subject: subject,
                 scope: scope
               }) do
            :ok -> {:authorized, state}
            _ -> forbidden()
          end
      end
    else
      _ -> forbidden()
    end
  end

  @impl true
  def add_calculations(
        %{context: %{private: %{pod_authorization: {actor, _policy}}}} = query,
        %{actor: actor} = state,
        _context
      ),
      do: {:ok, query, state}

  def add_calculations(query, state, _context) do
    case Ankole.AuthZ.Dsl.rule(state.resource, state.action) do
      %{check: :pod_filter} ->
        with :ok <- Ankole.AuthZ.Checks.ActorGuardrail.check(state.actor, :pod),
             {:ok, policy} <- Ankole.AuthZ.Checks.PodAnchorFilter.check(state.actor, query) do
          {:ok, Ankole.AuthZ.Checks.PodAnchorFilter.apply_policy(query, state.actor, policy),
           state}
        else
          _ -> forbidden()
        end

      _ ->
        {:ok, query, state}
    end
  end

  defp guardrail(_actor, :public, :public), do: :ok
  defp guardrail(_actor, _scope, :public), do: {:error, :forbidden}
  defp guardrail(actor, scope, _check), do: Ankole.AuthZ.Checks.ActorGuardrail.check(actor, scope)

  defp pod_filter(actor, %{context: %{private: %{pod_authorization: {actor, policy}}}}),
    do: {:ok, policy}

  defp pod_filter(actor, query), do: Ankole.AuthZ.Checks.PodAnchorFilter.check(actor, query)

  defp forbidden, do: {:error, Ash.Error.Forbidden.exception([])}
end
