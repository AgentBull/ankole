defmodule Ankole.Sessions.Tool do
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
          Ankole.Sessions.ToolResult.t()
          | {:await, Ankole.Sessions.Wait.t()}
          | {:delegate, String.t(), map(),
             (Ankole.Sessions.Run.t(), Ankole.Sessions.ToolResult.t() ->
                Ankole.Sessions.ToolResult.t())}
  @callback declarations() :: [map()]
  @callback declarations(Ankole.Sessions.Run.t()) :: [map()]
  @callback activity(t(), map(), String.t(), Ankole.Sessions.ToolResult.t() | nil) ::
              {String.t() | nil, map()}
  @callback normalize(String.t(), term()) :: term()
  @callback execute(Ankole.Sessions.Run.t(), map(), term()) ::
              {:ok, execution()} | {:error, term()}
  @callback prepare_in_tx(module(), Ankole.Sessions.Run.t(), map(), term()) ::
              {:ok, [{String.t(), String.t()}],
               (-> {:ok, execution(), [(-> term())]} | {:error, term()})}
              | {:error, term()}
  @callback observe(
              Ankole.Sessions.Run.t(),
              Ankole.Sessions.Wait.t(),
              boolean(),
              boolean()
            ) ::
              :pending | {:ready, Ankole.Sessions.ToolResult.t(), [String.t()]}
  @optional_callbacks declarations: 0,
                      declarations: 1,
                      activity: 4,
                      execute: 3,
                      prepare_in_tx: 4,
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
          ". Omit model_profile unless the human asks for one of these profiles by name; " <>
          "the default #{default} profile is the Agent's standard model for this work."
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

  # A function tool without `strict` is strict on the OpenAI Responses API. In
  # strict mode the model must fill every declared property, so an optional
  # parameter such as `model_profile` or `workspace_template_id` can never be
  # omitted and a one-value enum is forced on every call. Session function
  # declarations describe optional parameters, so they send `strict: false`
  # unless they opt in. A custom (freeform) tool has no `strict` field.
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
          schema: declaration |> Map.drop(@internal_keys) |> put_default_strict(),
          executor: owner
        }
      )
    )
  end

  defp put_default_strict(%{"type" => "function"} = schema),
    do: Map.put_new(schema, "strict", false)

  defp put_default_strict(schema), do: schema
end
