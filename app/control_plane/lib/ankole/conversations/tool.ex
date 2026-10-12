defmodule Ankole.Conversations.Tool do
  @moduledoc "The executable contract behind one model-visible declaration."

  @enforce_keys [:name, :schema, :executor]
  defstruct [
    :name,
    :schema,
    :executor,
    :activity,
    receipt: "durable",
    receipt_read_actions: [],
    visible_delivery: false,
    read_only: false,
    destructive: false,
    retry_safe: false,
    run_kinds: ~w(main ambient scheduled),
    ends_run: false,
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
  @callback declarations(Ankole.Conversations.Run.t()) :: [map()]
  @callback activity(t(), map(), String.t(), Ankole.Conversations.ToolResult.t() | nil) ::
              {String.t() | nil, map()}
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
  @optional_callbacks declarations: 0,
                      declarations: 1,
                      activity: 4,
                      execute: 3,
                      execute_in_tx: 4,
                      observe: 4

  @internal_keys ~w(execution_mode read_only destructive retry_safe receipt receipt_read_actions visible_delivery activity run_kinds ends_run)
  def available?(declaration, kind),
    do: Atom.to_string(kind) in Map.get(declaration, "run_kinds", ~w(main ambient scheduled))

  def receipt?(tool, args),
    do: tool.receipt == "durable" and args["action"] not in tool.receipt_read_actions

  def with_profiles(tool, profiles, default) do
    description =
      if profiles == [] do
        "No custom model profile is available; omit model_profile to use the default #{default} profile."
      else
        "Available custom model profiles: " <>
          Enum.map_join(
            Enum.sort_by(profiles, & &1["name"]),
            ", ",
            &"#{&1["name"]} (#{&1["description"]})"
          ) <>
          ". Omit model_profile to use the default #{default} profile."
      end

    tool = Map.update!(tool, "description", &(&1 <> " " <> description))

    if profiles == [],
      do: tool,
      else:
        put_in(tool, ["parameters", "properties", "model_profile"], %{
          "type" => "string",
          "enum" => profiles |> Enum.map(& &1["name"]) |> Enum.sort()
        })
  end

  @spec new(map(), module() | :worker) :: t()
  def new(declaration, owner) do
    attrs =
      for key <- @internal_keys,
          Map.has_key?(declaration, key),
          into: %{},
          do: {String.to_existing_atom(key), declaration[key]}

    struct!(
      __MODULE__,
      Map.merge(
        Map.put_new(attrs, :receipt, if(attrs[:read_only], do: "none", else: "durable")),
        %{
          name: declaration["name"],
          schema: Map.drop(declaration, @internal_keys),
          executor: owner
        }
      )
    )
  end
end
