defmodule SqlclWrapper.SseClientMessageTest do
  use ExUnit.Case, async: true
  require Logger
  require HTTPoison
  import Plug.Test
  import Plug.Conn

  @port 4001
  @url "http://localhost:#{@port}/tool"

  setup_all do
    Logger.info("starting cowboy")
    # Start the Plug.Cowboy server for the router
    {:ok, _cowboy_pid} = Plug.Cowboy.http(SqlclWrapper.Router, [], port: @port)
    Logger.info("Plug.Cowboy server started on port #{@port} for SSE client message tests.")

    Logger.info("Starting SQLcl process for SSE client message test setup...")
    {:ok, sqlcl_pid} = SqlclWrapper.SqlclProcess.start_link(parent: self())
    wait_for_sqlcl_startup(sqlcl_pid)
    Logger.info("SQLcl process ready for SSE client message test setup.")
    Process.sleep(1000) # Give SQLcl a moment to fully initialize

    # Perform MCP handshake
    Logger.info("Attempting to send initialize command to SQLcl process for SSE test...")
    {:ok, _init_resp} = SqlclWrapper.SqlclProcess.send_command(~s({"jsonrpc": "2.0", "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "my-stdio-client", "version": "1.0.0"}}, "id": 1}))
    Logger.info("Attempting to send initialized notification to SQLcl process for SSE test...")
    SqlclWrapper.SqlclProcess.send_command(~s({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}))

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
    {:ok, _connect_resp} = SqlclWrapper.SqlclProcess.send_command(connect_command)
    Logger.info("sleeping for setup")
    Process.sleep(1000) # Give SQLcl a moment to establish connection



    Logger.info("Test SETUP done")

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

  # Helper function to receive SSE messages
  defp receive_sse_messages(async_id, messages \\ [], timeout \\ 20000) do # Increased timeout
    receive do
      %HTTPoison.AsyncChunk{id: ^async_id, chunk: chunk} ->
        # Split chunk by "\n\n" to get individual SSE events
        Logger.info("msg #{inspect chunk}")
        # Remove carriage returns and then split by "\n\n" to get individual SSE events
        #cleaned_chunk = String.replace(chunk, "\r", "")
        #new_events = String.split(cleaned_chunk, "\n\n", trim: true)
        # If the original chunk ends with "\n\n", it means the full message has been received.
        if String.ends_with?(chunk, "\n\n") do
          messages ++ chunk
        else
          receive_sse_messages(async_id, messages ++ chunk, timeout)
        end
      %HTTPoison.AsyncEnd{id: ^async_id} ->
        # Connection closed
        messages
      msg ->
        # Ignore other messages that are not for this async_id
        Logger.info("receive_sse_messages unknown msg #{inspect msg}")
        receive_sse_messages(async_id, messages, timeout)
    after timeout ->
      # Timeout reached, return collected messages
      messages
    end
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
end
