defmodule SqlclWrapper.SseIntegrationTest do
  use ExUnit.Case, async: true
  import SqlclWrapper.IntegrationTestHelper
  require Logger
  require HTTPoison
  # Define a port for the test server to run on
  @port 4001
  @url "http://localhost:#{@port}/tool"

  setup_all do

    do_setup_all(%{port: @port, url: @url})


    on_exit fn ->
      if pid = Process.whereis(SqlclWrapper.SqlclProcess) do
        Logger.info("Shutting down SQLcl process after SSE integration test suite.")
        Process.exit(pid, :kill)
      end
      # Plug.Cowboy doesn't have a direct shutdown function, it usually exits with the supervisor tree.
      # For testing, we rely on the process exiting with the test suite.
    end
    :ok
  end

  test "GET /tool establishes SSE connection and receives data" do
    # Start an SSE client in a separate process
    client_pid = self()
    {:ok, sse_client_task_pid} = Task.start_link(fn ->
      HTTPoison.get(@url, [], stream_to: client_pid)
    end)

    # Wait for the client to connect and for the server to subscribe it
    Process.sleep(500) # Give some time for connection to establish

    # Send a command that will produce output
    sql_query = "SELECT /* LLM in use is claude-sonnet-4 */ 'Hello from SQLcl SSE!' AS message FROM DUAL;"
    json_rpc_command = %{
      jsonrpc: "2.0",
      id: 100,
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
    Logger.info("Sending SQL query command via HTTPoison.post to #{@url}")
    {:ok, %HTTPoison.AsyncResponse{id: async_post_id}} = HTTPoison.post(@url, json_rpc_command, [{"Content-Type", "application/json"}], stream_to: self())

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
    sse_chunks = receive_sse_messages(sse_client_task_pid, [], 5000) # Pass client_pid, empty list for messages, and timeout
    body = Enum.join(sse_chunks)
    Logger.info("SSE client received combined body: #{inspect(body)}")

    # Assert that the received body contains the expected SSE data format
    assert String.contains?(body, "data: \"MESSAGE\"\r\n\"Hello from SQLcl SSE!\"\r\n\n")
    assert String.contains?(body, "event: close") # Expect close event after command finishes

    # The client task should terminate naturally after receiving the close event.
    # No explicit Task.shutdown is needed here.
  end

  test "running two queries in the same session via SSE" do
    client_pid = self()
    {:ok, sse_client_task_pid} = Task.start_link(fn ->
      HTTPoison.get(@url, [], stream_to: client_pid)
    end)

    Process.sleep(500) # Give some time for connection to establish

    # First query
    first_sql_query = "SELECT /* LLM in use is claude-sonnet-4 */ 'First Query Result' AS message FROM DUAL;"
    first_json_rpc_command = build_json_rpc_tool_call(101, "run-sql", first_sql_query)

    Logger.info("Sending first SQL query command via HTTPoison.post to #{@url}")
    {:ok, %HTTPoison.AsyncResponse{id: first_async_post_id}} = HTTPoison.post(@url, first_json_rpc_command, [{"Content-Type", "application/json"}], stream_to: self())

    receive do
      %HTTPoison.AsyncEnd{id: ^first_async_post_id} ->
        Logger.info("First POST command response received.")
      _ ->
        :ok
    after 5000 ->
      raise "Timeout waiting for first POST command response"
    end

    # Second query
    second_sql_query = "SELECT /* LLM in use is claude-sonnet-4 */ 'Second Query Result' AS message FROM DUAL;"
    second_json_rpc_command = build_json_rpc_tool_call(102, "run-sql", second_sql_query)

    Logger.info("Sending second SQL query command via HTTPoison.post to #{@url}")
    {:ok, %HTTPoison.AsyncResponse{id: second_async_post_id}} = HTTPoison.post(@url, second_json_rpc_command, [{"Content-Type", "application/json"}], stream_to: self())

    receive do
      %HTTPoison.AsyncEnd{id: ^second_async_post_id} ->
        Logger.info("Second POST command response received.")
      _ ->
        :ok
    after 5000 ->
      raise "Timeout waiting for second POST command response"
    end

    # Collect SSE data chunks from the GET stream
    sse_chunks = receive_sse_messages(sse_client_task_pid, [], 10000) # Increased timeout for two queries
    body = Enum.join(sse_chunks)
    Logger.info("SSE client received combined body for two queries: #{inspect(body)}")

    # Assert that both query results are present and the session closes
    assert String.contains?(body, "data: \"MESSAGE\"\r\n\"First Query Result\"\r\n\n")
    assert String.contains?(body, "data: \"MESSAGE\"\r\n\"Second Query Result\"\r\n\n")
    assert String.contains?(body, "event: close")
  end



end
