defmodule Ankole.SignalsGateway.BindingFilters do
  @moduledoc """
  CEL admission filters for signal bindings.

  A filter is first-party operator configuration, not untrusted script input.
  The gateway's responsibility is narrower: build the normalized fact first,
  evaluate CEL before any durable write, and fail closed when the persisted
  filter is invalid. The native kernel owns CEL parsing and execution.
  """

  import Kernel, except: [match?: 2]

  alias Ankole.SignalsGateway.IngressFact

  @type result :: :match | :no_match | {:error, term()}

  @doc """
  Validates the stored filter object shape and CEL syntax.
  """
  @spec validate_config(map() | nil) :: :ok | {:error, String.t()}
  def validate_config(nil), do: :ok
  def validate_config(filters) when filters == %{}, do: :ok

  def validate_config(%{"cel" => source} = filters) when map_size(filters) == 1 do
    validate_source(source)
  end

  def validate_config(%{cel: source} = filters) when map_size(filters) == 1 do
    validate_source(source)
  end

  def validate_config(%{}), do: {:error, "must be empty or contain only cel"}
  def validate_config(_filters), do: {:error, "must be a map"}

  @doc """
  Evaluates binding filters against a constructed ingress fact.
  """
  @spec match?(map() | nil, IngressFact.t()) :: result()
  def match?(filters, fact)

  def match?(nil, %IngressFact{}), do: :match
  def match?(filters, %IngressFact{}) when filters == %{}, do: :match

  def match?(%{"cel" => source} = filters, %IngressFact{} = fact) when map_size(filters) == 1 do
    match_cel(source, fact)
  end

  def match?(%{cel: source} = filters, %IngressFact{} = fact) when map_size(filters) == 1 do
    match_cel(source, fact)
  end

  def match?(%{}, %IngressFact{}), do: {:error, {:invalid_binding_filter, "unsupported shape"}}
  def match?(_filters, %IngressFact{}), do: {:error, {:invalid_binding_filter, "must be a map"}}

  defp validate_source(source) when is_binary(source) do
    if String.trim(source) == "" do
      {:error, "cel must not be blank"}
    else
      validate_kernel_filter(source)
    end
  end

  defp validate_source(_source), do: {:error, "cel must be a string"}

  defp match_cel(source, fact) when is_binary(source) do
    case evaluate_kernel_filter(source, fact) do
      {:ok, true} -> :match
      {:ok, false} -> :no_match
      {:error, reason} -> {:error, {:invalid_binding_filter, reason}}
    end
  end

  defp match_cel(_source, _fact), do: {:error, {:invalid_binding_filter, "cel must be a string"}}

  defp validate_kernel_filter(source) do
    try do
      case Ankole.Kernel.signals_gateway_validate_filter(source) do
        true -> :ok
        {:error, reason} -> {:error, to_string(reason)}
        _other -> {:error, "is invalid"}
      end
    rescue
      exception -> {:error, Exception.message(exception)}
    catch
      _kind, reason -> {:error, inspect(reason)}
    end
  end

  defp evaluate_kernel_filter(source, fact) do
    try do
      case Ankole.Kernel.signals_gateway_filter_match(source, filter_context(fact)) do
        true -> {:ok, true}
        false -> {:ok, false}
        {:error, reason} -> {:error, to_string(reason)}
        _other -> {:error, "is invalid"}
      end
    rescue
      exception -> {:error, Exception.message(exception)}
    catch
      _kind, reason -> {:error, inspect(reason)}
    end
  end

  defp filter_context(%IngressFact{} = fact) do
    %{
      "binding" => %{
        "name" => fact.binding_name,
        "adapter" => fact.adapter
      },
      "signal" => %{
        "kind" => json_value(fact.kind),
        "agent_uid" => fact.agent_uid,
        "ingress_event_id" => fact.ingress_event_id,
        "gateway_time" => json_value(fact.gateway_time),
        "channel" => channel_context(fact),
        "entry" => entry_context(fact),
        "lifecycle" => lifecycle_context(fact),
        "reaction" => reaction_context(fact),
        "action" => action_context(fact),
        "internal" => internal_context(fact),
        "command" => command_context(fact)
      }
    }
  end

  defp channel_context(fact) do
    %{
      "id" => fact.signal_channel_id,
      "kind" => json_value(fact.channel_kind),
      "reply_mode" => json_value(fact.reply_mode),
      "name" => fact.channel_name,
      "title" => fact.channel_title,
      "visibility" => fact.channel_visibility,
      "metadata" => json_value(fact.channel_metadata)
    }
  end

  defp entry_context(fact) do
    %{
      "id" => fact.provider_entry_id,
      "provider_entry_id" => fact.provider_entry_id,
      "thread_id" => fact.provider_thread_id,
      "provider_thread_id" => fact.provider_thread_id,
      "sender_key" => fact.sender_key,
      "actor_input_type" => fact.actor_input_type,
      "text" => fact.text,
      "formatted_content" => json_value(fact.formatted_content),
      "attachments" => json_value(fact.attachments),
      "links" => json_value(fact.links),
      "author" => json_value(fact.author),
      "mentions" => json_value(fact.mentions),
      "metadata" => json_value(fact.metadata),
      "provider_time" => json_value(fact.provider_time),
      "explicit" => fact.explicit?,
      "mirror_only" => fact.mirror_only?
    }
  end

  defp lifecycle_context(fact) do
    %{
      "kind" => json_value(fact.lifecycle_kind),
      "provider_kind" => json_value(fact.provider_lifecycle_kind)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp reaction_context(fact) do
    %{
      "key" => fact.reaction_key,
      "raw_key" => fact.raw_reaction_key,
      "actor_key" => fact.actor_key,
      "action" => fact.action
    }
  end

  defp action_context(fact) do
    %{
      "id" => fact.action_id,
      "actor_key" => fact.actor_key,
      "payload" => json_value(fact.action)
    }
  end

  defp internal_context(fact) do
    %{
      "session_id" => fact.session_id,
      "timer_id" => fact.timer_id,
      "subject" => fact.internal_subject,
      "payload" => json_value(fact.internal)
    }
  end

  defp command_context(fact) do
    %{
      "prefixes" => json_value(fact.command_prefixes),
      "payload" => json_value(fact.command_payload)
    }
  end

  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp json_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  defp json_value(%{} = value) do
    Map.new(value, fn {key, map_value} -> {json_key(key), json_value(map_value)} end)
  end

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value) when is_atom(value), do: Atom.to_string(value)

  defp json_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp json_value(_value), do: nil

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key), do: to_string(key)
end
