defmodule SqlclWrapper.SseIntegrationTest do
  use ExUnit.Case, async: true
  require Logger
  require HTTPoison
  # Define a port for the test server to run on
  @port 4001
  @url "http://localhost:#{@port}/tool"

  setup_all do
    Logger.info("starting cowboy")
    # Start the Plug.Cowboy server for the router
    {:ok, _cowboy_pid} = Plug.Cowboy.http(SqlclWrapper.Router, [], port: @port)
    # Start the SqlclProcess manually for the test suite
    Logger.info("Starting SQLcl process for SSE integration test setup...")
    {:ok, pid} = SqlclWrapper.SqlclProcess.start_link(parent: self())
    wait_for_sqlcl_startup(pid)
    Logger.info("SQLcl process ready for SSE integration test setup. Giving it a moment...")
    Process.sleep(1000) # Give SQLcl a moment to fully initialize after startup message
    Logger.info("SQLcl process should be ready now for SSE integration tests.")

    # Perform MCP handshake
    Logger.info("Attempting to send initialize command to SQLcl process for SSE test...")
    {:ok, init_resp} = SqlclWrapper.SqlclProcess.send_command(~s({"jsonrpc": "2.0", "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "my-stdio-client", "version": "1.0.0"}}, "id": 1}))
    Logger.info("Received initialize response for SSE test: #{inspect(init_resp)}")

    Logger.info("Attempting to send initialized notification to SQLcl process for SSE test...")
    SqlclWrapper.SqlclProcess.send_command(~s({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}))
    Logger.info("Initialized notification sent for SSE test.")

    # Connect to the database using the "theconn" connection
    Logger.info("Attempting to connect to database using 'theconn' for SSE test...")
    connect_command = %{
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: %{
        name: "connect",
        arguments: %{
          "connection_name" => "theconn",
          "model" => "claude-sonnet-4",
          "mcp_client" => "cline"
        }
      }
    } |> Jason.encode!()
    {:ok, connect_resp} = SqlclWrapper.SqlclProcess.send_command(connect_command)
    Logger.info("Received connect response for SSE test: #{inspect(connect_resp)}")
    Process.sleep(1000) # Give SQLcl a moment to establish connection

    # Start the Plug.Cowboy server for the router
    {:ok, _pid} = Plug.Cowboy.http(SqlclWrapper.Router, [], port: @port)
    Logger.info("Plug.Cowboy server started on port #{@port} for SSE integration tests.")

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
    sse_chunks = receive_sse_messages(sse_client_task_pid, 5000) # Pass client_pid to receive_sse_messages
    body = Enum.join(sse_chunks)
    Logger.info("SSE client received combined body: #{inspect(body)}")

    # Assert that the received body contains the expected SSE data format
    assert String.contains?(body, "data: \"MESSAGE\"\r\n\"Hello from SQLcl SSE!\"\r\n\n")
    assert String.contains?(body, "event: close") # Expect close event after command finishes

    # The client task should terminate naturally after receiving the close event.
    # No explicit Task.shutdown is needed here.
  end

  # Helper function from router_test.exs
  defp wait_for_sqlcl_startup(pid, buffer \\ "") do
    receive do
      {:sqlcl_process_started, ^pid} ->
        :ok
      {:sqlcl_output, {:stdout, iodata}} ->
        new_buffer = buffer <> IO.iodata_to_binary(iodata)
        if String.contains?(new_buffer, "MCP Server started successfully") do
          :ok
        else
          wait_for_sqlcl_startup(pid, new_buffer)
        end
      {:sqlcl_output, {:stderr, iodata}} ->
        new_buffer = buffer <> IO.iodata_to_binary(iodata)
        if String.contains?(new_buffer, "MCP Server started successfully") do
          :ok
        else
          wait_for_sqlcl_startup(pid, new_buffer)
        end
      {:sqlcl_output, {:exit, _}} -> raise "SQLcl process exited prematurely during setup"
    after 10000 -> # Timeout for receiving the message
      raise "Timeout waiting for SQLcl process to start. Buffer: #{buffer}"
    end
  end

  # Helper function to receive SSE messages (adapted from sse_client_message_test.exs)
  defp receive_sse_messages(client_pid, timeout, messages \\ []) do
    receive do
      %HTTPoison.AsyncChunk{id: _async_id, chunk: chunk} when is_binary(chunk) ->
        Logger.info("SSE client received chunk: #{inspect(chunk)}")
        receive_sse_messages(client_pid, timeout, messages ++ [chunk])
      %HTTPoison.AsyncEnd{id: _async_id} ->
        Logger.info("SSE client stream ended.")
        messages
      msg ->
        # Ignore other messages not related to HTTPoison.AsyncChunk or AsyncEnd
        Logger.debug("receive_sse_messages: Unhandled message: #{inspect(msg)}")
        receive_sse_messages(client_pid, timeout, messages)
    after timeout ->
      Logger.warning("receive_sse_messages: Timeout after #{timeout}ms. Returning collected messages.")
      messages
    end
  end
end
