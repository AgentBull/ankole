defmodule Ankole.AIGateway.OpenAIError do
  @moduledoc """
  Public OpenAI-compatible error returned by AIGateway endpoints.

  Provider credentials and raw provider responses never belong in this value.
  """

  @enforce_keys [:status, :message, :type, :code]
  defstruct [:status, :message, :type, :param, :code]

  @type t :: %__MODULE__{
          status: pos_integer(),
          message: String.t(),
          type: String.t(),
          param: String.t() | nil,
          code: String.t()
        }

  @spec invalid(String.t() | nil, String.t(), String.t()) :: t()
  def invalid(param, code, message) do
    %__MODULE__{
      status: 400,
      message: message,
      type: "invalid_request_error",
      param: param,
      code: code
    }
  end

  @spec not_found(String.t() | nil, String.t()) :: t()
  def not_found(param, message \\ "File not found.") do
    %__MODULE__{
      status: 404,
      message: message,
      type: "invalid_request_error",
      param: param,
      code: "not_found"
    }
  end

  @spec image_generation_user(String.t(), String.t()) :: t()
  def image_generation_user(code, message \\ "The image request was rejected.") do
    %__MODULE__{
      status: 400,
      message: message,
      type: "image_generation_user_error",
      param: nil,
      code: code
    }
  end

  @spec server(pos_integer(), String.t(), String.t(), String.t()) :: t()
  def server(status, code, message, type \\ "server_error") do
    %__MODULE__{
      status: status,
      message: message,
      type: type,
      param: nil,
      code: code
    }
  end

  @spec envelope(t()) :: map()
  def envelope(%__MODULE__{} = error) do
    %{
      "error" => %{
        "message" => error.message,
        "type" => error.type,
        "param" => error.param,
        "code" => error.code
      }
    }
  end
end
