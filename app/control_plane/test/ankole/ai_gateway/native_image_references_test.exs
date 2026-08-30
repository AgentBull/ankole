defmodule Ankole.AIGateway.NativeImageReferencesTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.Artifacts
  alias Ankole.Ecto.UUIDv7

  @max_image_bytes 50 * 1024 * 1024
  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

  test "native image references share one aggregate byte budget" do
    agent = agent_fixture()
    file_id = create_max_size_upload(agent.principal.uid)
    image_id = "ig_#{UUIDv7.autogenerate()}"

    assert {:ok, _artifact} =
             Artifacts.persist_generated_image(
               agent.principal.uid,
               image_id,
               @png_base64,
               "image/png"
             )

    request = %{
      "input" => [
        %{
          "id" => image_id,
          "type" => "image_generation_call",
          "status" => "completed",
          "result" => nil
        },
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_image", "file_id" => file_id}]
        }
      ],
      "tools" => [
        %{
          "type" => "image_generation",
          "input_image_mask" => %{"file_id" => file_id}
        }
      ]
    }

    assert {:error, error} = Artifacts.resolve_native_input(agent.principal.uid, request)
    assert error.status == 400
    assert error.param == "input"
    assert error.code == "request_too_large"
    assert error.message == "Referenced images exceed the 100 MiB request limit."
  end

  defp create_max_size_upload(subject_uid) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ankole-native-budget-#{System.unique_integer([:positive])}.png"
      )

    zero_bits = (@max_image_bytes - 8) * 8
    File.write!(path, <<137, 80, 78, 71, 13, 10, 26, 10, 0::size(zero_bits)>>)

    try do
      assert {:ok, artifact} =
               Artifacts.create_uploaded_file(
                 subject_uid,
                 %Plug.Upload{path: path, filename: "input.png", content_type: "image/png"},
                 %{"purpose" => "vision"}
               )

      Artifacts.public_id(artifact)
    after
      File.rm(path)
    end
  end
end
