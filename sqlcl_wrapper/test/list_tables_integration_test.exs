defmodule SqlclWrapper.ListTablesIntegrationTest do
  @moduledoc """
  Tests listing tables via the SQLcl router using SSE.
  """
  @port 4002 # Define a port for this specific test module
  @url "http://localhost:#{@port}/tool"

  use SqlclWrapper.IntegrationTestHelper

  test "POST /tool with run-sql to list tables via router and receive SSE", %{url: url} do
    # Start an SSE client in a separate process to receive the stream
    client_pid = self()
    {:ok, sse_client_task_pid} = Task.start_link(fn ->
      HTTPoison.get(url, [], stream_to: client_pid)
    end)

    # Wait for the client to connect and for the server to subscribe it
    Process.sleep(500) # Give some time for connection to establish

    # Define the JSON-RPC request for listing tables
    sql_query = "SELECT /* LLM in use is claude-sonnet-4 */ table_name FROM user_tables;"
    json_rpc_command = %{
      jsonrpc: "2.0",
      id: "list_tables_#{System.unique_integer()}", # Unique ID for this request
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

    # Send the command via HTTPoison.post to simulate a real client request
    Logger.info("Sending list tables command via HTTPoison.post to #{url}")
    {:ok, %HTTPoison.AsyncResponse{id: async_post_id}} = HTTPoison.post(url, json_rpc_command, [{"Content-Type", "application/json"}], stream_to: self())

    # Wait for the POST response to complete (optional, but good for clarity)
    receive do
      %HTTPoison.AsyncEnd{id: ^async_post_id} ->
        Logger.info("POST command response received.")
      _ ->
        :ok
    after 5000 ->
      raise "Timeout waiting for POST command response"
    end

    # Collect SSE data chunks from the GET stream
    sse_chunks = receive_sse_messages(sse_client_task_pid, 15000) # Increased timeout for potentially longer SQL execution
    body = Enum.join(sse_chunks)
    Logger.info("SSE client received combined body: #{inspect(body)}")

    # Assert that the received body contains the expected SSE data format
    # The actual content will depend on the database, but we expect "TABLE_NAME"
    # and the JSON-RPC result structure.
    assert String.contains?(body, "data: \"TABLE_NAME\"")
    assert String.contains?(body, "event: close") # Expect close event after command finishes

    # The client task should terminate naturally after receiving the close event.
  end
end
