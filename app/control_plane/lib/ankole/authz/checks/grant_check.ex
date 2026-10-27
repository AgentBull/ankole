defmodule Ankole.AuthZ.Checks.GrantCheck do
  @moduledoc false
  @behaviour Ankole.AuthZ.Check

  def check(actor, %{scope: :site_console} = request) do
    with {:ok, id} <- Ankole.Tenants.privileged_id(),
         {:ok, checks} <-
           Ankole.Repo.with_tenant(Ankole.Repo.tenant_id() || id, fn -> checks(request) end),
         do: Ankole.Repo.with_tenant(id, fn -> authorize(actor, checks) end)
  end

  def check(actor, request) do
    with {:ok, checks} <- checks(request), do: authorize(actor, checks)
  end

  defp checks(%{rule: rule, subject: subject}) do
    with {:ok, args} <- arguments(subject),
         {:ok, resource} <- expand_values(rule.resource, args),
         do: permissions(rule, args, resource)
  end

  defp authorize(actor, checks) do
    Enum.reduce_while(checks, :ok, fn {resource, action}, :ok ->
      case Ankole.AuthZ.Decision.authorize(actor, resource, action) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp permissions(%{permissions: nil, action: action}, _args, resource),
    do: {:ok, [{resource, action}]}

  defp permissions(%{permissions: permissions} = rule, args, resource)
       when is_function(permissions, 4),
       do: {:ok, permissions.(args, args, resource, rule.action)}

  def expand(pattern, subject) do
    with {:ok, args} <- arguments(subject), do: expand_values(pattern, args)
  end

  defp expand_values(pattern, args) do
    Regex.scan(~r/\{(\w+)\}/, pattern)
    |> Enum.reduce_while({:ok, pattern}, fn [placeholder, name], {:ok, expanded} ->
      case args[name] do
        value when is_binary(value) ->
          {:cont, {:ok, String.replace(expanded, placeholder, value)}}

        _ ->
          {:halt, {:error, :forbidden}}
      end
    end)
  end

  defp arguments(subject) do
    args = Map.get(subject, :arguments, %{})
    attributes = Map.get(subject, :attributes, %{})
    data = Map.get(subject, :data) || %{}

    Ankole.AuthZ.Dsl.params(subject.resource)
    |> Enum.reduce_while(
      {:ok, Map.new(args, fn {key, value} -> {to_string(key), value} end)},
      fn param, {:ok, values} ->
        value =
          Map.get(args, param.name) || Map.get(attributes, param.name) ||
            Map.get(data, param.name) || target(subject, param.name)

        if is_nil(value) do
          {:cont, {:ok, values}}
        else
          case resolve(param.type, value) do
            {:ok, value} -> {:cont, {:ok, Map.put(values, to_string(param.name), value)}}
            error -> {:halt, error}
          end
        end
      end
    )
  end

  defp target(%Ash.Query{filter: filter}, key) when not is_nil(filter) do
    case Ash.Filter.fetch_simple_equality_predicate(filter, key) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp target(_, _), do: nil

  def resolve(type, value) when is_binary(value) do
    with {:ok, value} <- normalize(type, value),
         true <- value != "" and not String.contains?(value, "*"),
         true <- not String.contains?(value, ":") or synced_group?(type, value) do
      {:ok, value}
    else
      _ -> {:error, :forbidden}
    end
  end

  def resolve(_, _), do: {:error, :forbidden}

  defp synced_group?(:group, value) do
    case Ankole.AuthZ.get_principal_group(value) do
      {:ok, %{domain: domain}} when domain in [:directory, :im_group, :signal_source] -> true
      _ -> false
    end
  end

  defp synced_group?(_, _), do: false

  defp normalize(:principal_key, value), do: {:ok, Ankole.PrincipalKey.canonicalize(value)}
  defp normalize(:uuid, value), do: value |> String.trim() |> Ecto.UUID.cast()
  defp normalize(:group, value), do: {:ok, Ankole.AuthZ.resolve_group_name(value)}
  defp normalize(:provider_id, value), do: {:ok, value |> String.trim() |> String.downcase()}

  defp normalize(:model_profile, value),
    do: {:ok, Ankole.AIAgent.ModelProfiles.canonicalize_profile(value)}

  defp normalize(:string, value), do: {:ok, String.trim(value)}
end
