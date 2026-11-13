defmodule Ankole.Pod.APIErrorTest do
  use ExUnit.Case, async: true

  alias Ankole.Pod.APIError

  test "database connector failures keep their code and message with a matching status" do
    for {code, status} <- [
          {"database_host_blocked", 422},
          {"database_unavailable", 503},
          {"statement_timeout", 504}
        ] do
      assert %{code: ^code, message: "adapter message", status: ^status} =
               APIError.public_error(%{code: code, message: "adapter message", retryable: true})
    end
  end
end
