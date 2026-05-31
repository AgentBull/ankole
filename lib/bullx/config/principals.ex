defmodule BullX.Config.Principals.MatchRules do
  @moduledoc """
  Skogsra type for Principal AuthN match-rule configuration.

  Match rules are JSON-compatible policy data used when an external login or
  channel identity is not already bound. The type validates the small supported
  rule language before AuthN code uses it to bind or create human Principals.
  """

  use Skogsra.Type

  @bind_result "bind_existing_human"
  @create_result "allow_create_human"
  @bind_ops ~w(equals_human_field)
  @create_ops ~w(email_domain_in equals_any)
  @human_fields ~w(email phone)

  @impl Skogsra.Type
  def cast(value) when is_list(value) do
    value
    |> Enum.map(&normalize_rule/1)
    |> valid_rules()
  end

  def cast(value) when is_binary(value) do
    with {:ok, decoded} <- Jason.decode(value) do
      cast(decoded)
    else
      _ -> :error
    end
  end

  def cast(_value), do: :error

  defp valid_rules(rules) do
    case Enum.all?(rules, &match?({:ok, _rule}, &1)) do
      true -> {:ok, Enum.map(rules, fn {:ok, rule} -> rule end)}
      false -> :error
    end
  end

  defp normalize_rule(rule) when is_map(rule) do
    with {:ok, rule} <- stringify_keys(rule) do
      case {Map.get(rule, "result"), Map.get(rule, "op")} do
        {@bind_result, op} when op in @bind_ops -> normalize_bind_rule(rule)
        {@create_result, op} when op in @create_ops -> normalize_create_rule(rule)
        _other -> :error
      end
    end
  end

  defp normalize_rule(_rule), do: :error

  defp normalize_bind_rule(rule) do
    with {:ok, source_path} <- required_string(rule, "source_path"),
         {:ok, human_field} <- required_string(rule, "human_field"),
         true <- human_field in @human_fields do
      {:ok,
       source_path
       |> base_bind_rule(human_field)
       |> maybe_put_managed_by(rule)}
    else
      _other -> :error
    end
  end

  defp normalize_create_rule(%{"op" => "email_domain_in"} = rule) do
    with {:ok, source_path} <- required_string(rule, "source_path"),
         {:ok, domains} <- required_string_list(rule, "domains") do
      {:ok,
       source_path
       |> base_email_domain_rule(domains)
       |> maybe_put_managed_by(rule)}
    else
      _other -> :error
    end
  end

  defp normalize_create_rule(%{"op" => "equals_any"} = rule) do
    with {:ok, source_path} <- required_string(rule, "source_path"),
         {:ok, values} <- required_string_list(rule, "values") do
      {:ok,
       source_path
       |> base_equals_any_rule(values)
       |> maybe_put_managed_by(rule)}
    else
      _other -> :error
    end
  end

  defp base_bind_rule(source_path, human_field) do
    %{
      "result" => @bind_result,
      "op" => "equals_human_field",
      "source_path" => source_path,
      "human_field" => human_field
    }
  end

  defp base_email_domain_rule(source_path, domains) do
    %{
      "result" => @create_result,
      "op" => "email_domain_in",
      "source_path" => source_path,
      "domains" => Enum.map(domains, &String.downcase/1)
    }
  end

  defp base_equals_any_rule(source_path, values) do
    %{
      "result" => @create_result,
      "op" => "equals_any",
      "source_path" => source_path,
      "values" => values
    }
  end

  defp maybe_put_managed_by(normalized, %{"managed_by" => managed_by})
       when is_binary(managed_by) and managed_by != "" do
    Map.put(normalized, "managed_by", managed_by)
  end

  defp maybe_put_managed_by(normalized, _rule), do: normalized

  defp required_string(rule, key) do
    case Map.fetch(rule, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> :error
    end
  end

  defp required_string_list(rule, key) do
    case Map.fetch(rule, key) do
      {:ok, [_value | _rest] = values} ->
        values
        |> Enum.map(&string_value/1)
        |> valid_string_list()

      _other ->
        :error
    end
  end

  defp valid_string_list(values) do
    case Enum.all?(values, &match?({:ok, _value}, &1)) do
      true -> {:ok, Enum.map(values, fn {:ok, value} -> value end)}
      false -> :error
    end
  end

  defp string_value(value) when is_binary(value) and value != "", do: {:ok, value}
  defp string_value(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp string_value(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp string_value(_value), do: :error

  defp stringify_keys(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_atom(key) ->
        {:cont, {:ok, Map.put(acc, Atom.to_string(key), value)}}

      {key, value}, {:ok, acc} when is_binary(key) ->
        {:cont, {:ok, Map.put(acc, key, value)}}

      {_key, _value}, _acc ->
        {:halt, :error}
    end)
  end
end

defmodule BullX.Config.Principals do
  @moduledoc """
  Runtime configuration for Principal AuthN.

  Match rules are declarative JSON-compatible data. Invalid higher-priority
  sources are rejected as a whole so lower-priority sources can be used.
  """

  use BullX.Config

  @envdoc false
  bullx_env(:principals_authn_match_rules,
    key: [:principals, :authn_match_rules],
    type: BullX.Config.Principals.MatchRules,
    default: []
  )

  @envdoc false
  bullx_env(:principals_authn_auto_create_humans,
    key: [:principals, :authn_auto_create_humans],
    type: :boolean,
    default: true
  )

  @envdoc false
  bullx_env(:principals_authn_require_activation_code,
    key: [:principals, :authn_require_activation_code],
    type: :boolean,
    default: true
  )

  @envdoc false
  bullx_env(:principals_activation_code_ttl_seconds,
    key: [:principals, :activation_code_ttl_seconds],
    type: :integer,
    default: 86_400,
    zoi: Zoi.integer(gte: 1)
  )

  @envdoc false
  bullx_env(:principals_login_auth_code_ttl_seconds,
    key: [:principals, :login_auth_code_ttl_seconds],
    type: :integer,
    default: 300,
    zoi: Zoi.integer(gte: 1)
  )
end
