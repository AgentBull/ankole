defmodule Ankole.Conversations.Tool do
  @moduledoc "The executable contract behind one model-visible declaration."

  @enforce_keys [:name, :schema, :executor]
  defstruct [
    :name,
    :schema,
    :executor,
    read_only: false,
    destructive: false,
    retry_safe: false,
    execution_mode: "parallel"
  ]

  @type t :: %__MODULE__{}
  @type execution ::
          Ankole.Conversations.ToolResult.t()
          | {:await, Ankole.Conversations.Wait.t()}
          | {:delegate, String.t(), map(),
             (Ankole.Conversations.Run.t(), Ankole.Conversations.ToolResult.t() ->
                Ankole.Conversations.ToolResult.t())}
  @callback declarations() :: [map()]
  @callback normalize(String.t(), term()) :: term()
  @callback execute(Ankole.Conversations.Run.t(), map(), term()) ::
              {:ok, execution()} | {:error, term()}
  @callback execute_in_tx(module(), Ankole.Conversations.Run.t(), map(), term()) ::
              {:ok, execution(), [(-> term())]} | {:error, term()}
  @callback observe(
              Ankole.Conversations.Run.t(),
              Ankole.Conversations.Wait.t(),
              boolean(),
              boolean()
            ) ::
              :pending | {:ready, Ankole.Conversations.ToolResult.t(), [String.t()]}
  @optional_callbacks declarations: 0, execute: 3, execute_in_tx: 4, observe: 4

  @internal_keys ~w(execution_mode read_only destructive retry_safe)
  @spec new(map(), module() | :worker) :: t()
  def new(declaration, owner) do
    attrs =
      for key <- @internal_keys,
          Map.has_key?(declaration, key),
          into: %{},
          do: {String.to_existing_atom(key), declaration[key]}

    struct!(
      __MODULE__,
      Map.merge(attrs, %{
        name: declaration["name"],
        schema: Map.drop(declaration, @internal_keys),
        executor: owner
      })
    )
  end
end
