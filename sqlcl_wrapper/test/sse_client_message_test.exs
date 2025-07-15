defmodule SqlclWrapper.SseClientMessageTest do
  use ExUnit.Case, async: true
  require Logger
  require HTTPoison
  import SqlclWrapper.IntegrationTestHelper

  @port 4001
  @url "http://localhost:#{@port}/tool"


  setup_all do
    do_setup_all(%{port: @port, url: @url})

    on_exit fn ->
      if pid = Process.whereis(SqlclWrapper.SqlclProcess) do
        Logger.info("Shutting down SQLcl process after SSE client message test suite.")
        Process.exit(pid, :kill)
      end
      # Plug.Cowboy doesn't have a direct shutdown function, it usually exits with the supervisor tree.
      # For testing, we rely on the process exiting with the test suite.
    end
    :ok
  end

  test "SSE client receives expected message from SQL query" do
    # Send a command that will produce output
    sql_query = "SELECT /* LLM in use is claude-sonnet-4 */ 'Hello from SSE Client Test!' AS message FROM DUAL;"
    json_rpc_command = %{
      jsonrpc: "2.0",
      id: 101, # Use a different ID for this test
      method: "tools/call",
      params: %{
        name: "run-sql",
        arguments: %{
          "sql" => sql_query,
          "model" => "claude-sonnet-4",
          "mcp_client" => "cline"
        }
      }
    } |> Jason.encode!()

    # Send the command via POST /tool
    # Send the command via HTTPoison.post
    Logger.info("Sending SQL query command via HTTPoison.post to #{@url}")
    # Use HTTPoison.post to send the command, but stream the response to self()
    {:ok, %HTTPoison.AsyncResponse{id: async_id}} = HTTPoison.post(@url, json_rpc_command, [{"Content-Type", "application/json"}], stream_to: self())

    # Collect SSE messages
    received_messages = receive_sse_messages(async_id)
    Logger.info("SSE client received messages: #{inspect(received_messages)}")

    # Assert that the expected data and close event are received
    #assert ["data: \"MESSAGE\"\r\n\"Hello from SSE Client Test!\""] == received_messages
    assert "data: \"MESSAGE\"\r\n\"Hello from SSE Client Test!\"\r\n\n\n\n" == received_messages
    #assert Equal(received_message, "data: \"MESSAGE\"\r\n\"Hello from SSE Client Test!\"\r\n\n\n\n")
    #assert Enum.any?(received_messages, fn msg -> String.contains?(msg, "event: close") end)
  end


end
