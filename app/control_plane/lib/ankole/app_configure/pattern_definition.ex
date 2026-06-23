defmodule Ankole.AppConfigure.PatternDefinition do
  @moduledoc """
  Declares a family of runtime-computed AppConfigure keys.
  """

  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema

  @enforce_keys [:id, :key_pattern, :schema, :encrypted]
  defstruct [
    :id,
    :key_pattern,
    :schema,
    :default_value,
    :description,
    :generator,
    :encrypted,
    default?: false
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          key_pattern: Regex.t(),
          schema: Schema.t() | Schema.validator(),
          encrypted: boolean(),
          default?: boolean(),
          default_value: term(),
          description: String.t() | nil,
          generator: (-> term()) | nil
        }

  @doc """
  Builds a definition for keys that are only known at runtime.

  Pattern definitions reuse the exact definition validation path so schema,
  default, generator, and encryption semantics stay the same for both forms.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = attrs_map(attrs)

    with {:ok, id} <- fetch_string(attrs, :id),
         {:ok, key_pattern} <- fetch_regex(attrs),
         attrs <- Map.put(attrs, :key, id),
         {:ok, %Definition{} = definition} <- Definition.new(attrs) do
      {:ok,
       %__MODULE__{
         id: id,
         key_pattern: key_pattern,
         schema: definition.schema,
         encrypted: definition.encrypted,
         default?: definition.default?,
         default_value: definition.default_value,
         description: definition.description,
         generator: definition.generator
       }}
    end
  end

  @doc """
  Builds a pattern definition and raises when the declaration is invalid.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, definition} -> definition
      {:error, reason} -> raise ArgumentError, "invalid app configure pattern: #{inspect(reason)}"
    end
  end

  @doc """
  Validates a value with the schema attached to this pattern.
  """
  @spec validate(t(), term()) :: {:ok, term()} | {:error, term()}
  def validate(%__MODULE__{} = definition, value) do
    definition
    |> to_definition()
    |> Definition.validate(value)
  end

  @doc """
  Produces a generated value for this pattern and validates it without persisting it.
  """
  @spec generate(t()) :: {:ok, term()} | {:error, term()}
  def generate(%__MODULE__{} = definition) do
    definition
    |> to_definition()
    |> Definition.generate()
  end

  # Reusing Definition keeps pattern behavior intentionally boring: a pattern is
  # a matching rule plus the same value contract exact keys already use.
  defp to_definition(%__MODULE__{} = definition) do
    %Definition{
      key: definition.id,
      schema: definition.schema,
      encrypted: definition.encrypted,
      default?: definition.default?,
      default_value: definition.default_value,
      description: definition.description,
      generator: definition.generator
    }
  end

  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)
  defp attrs_map(attrs) when is_map(attrs), do: attrs

  defp fetch_string(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_string, key}}
      :error -> {:error, {:missing, key}}
    end
  end

  defp fetch_regex(attrs) do
    case Map.fetch(attrs, :key_pattern) do
      {:ok, %Regex{} = regex} -> {:ok, regex}
      {:ok, _regex} -> {:error, :invalid_key_pattern}
      :error -> {:error, {:missing, :key_pattern}}
    end
  end
end
