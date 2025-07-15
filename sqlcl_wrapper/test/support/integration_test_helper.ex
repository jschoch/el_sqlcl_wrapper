defmodule SqlclWrapper.IntegrationTestHelper do
  require Logger
  require HTTPoison

  @doc """
  Provides common setup and helper functions for SQLcl integration tests.
  """
  def do_setup_all(%{port: port, url: url}) do
    Logger.info("starting cowboy")
    # Start the Plug.Cowboy server for the router
    {:ok, _cowboy_pid} = Plug.Cowboy.http(SqlclWrapper.Router, [], port: port)
    Logger.info("Plug.Cowboy server started on port #{port} for SSE client message tests.")

    Logger.info("Starting SQLcl process for SSE client message test setup...")
    {:ok, sqlcl_pid} = SqlclWrapper.SqlclProcess.start_link(parent: self())
    wait_for_sqlcl_startup(sqlcl_pid)
    Logger.info("SQLcl process ready for SSE client message test setup.")
    Process.sleep(100) # Give SQLcl a moment to fully initialize

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
    Process.sleep(100) # Give SQLcl a moment to establish connection



    Logger.info("Test SETUP done")


  end
  def receive_sse_messages(async_id, messages \\ [], timeout \\ 20000) do # Increased timeout
    receive do
      %HTTPoison.AsyncChunk{id: ^async_id, chunk: chunk} ->
        Logger.info("msg #{inspect chunk}")
        new_messages = messages ++ [chunk] # Accumulate chunks as a list of strings
        if String.ends_with?(chunk, "\n\n") do
          new_messages # Return all accumulated chunks if a full message is received
        else
          receive_sse_messages(async_id, new_messages, timeout)
        end
      %HTTPoison.AsyncEnd{id: ^async_id} ->
        # Connection closed, return all accumulated messages
        messages
      msg ->
        # Ignore other messages that are not for this async_id
        Logger.info("receive_sse_messages unknown msg #{inspect msg}")
        receive_sse_messages(async_id, messages, timeout)
    after timeout ->
      # Timeout reached, raise an error as per "Erlang way"
      raise "Timeout waiting for SSE messages after #{timeout}ms. Received messages: #{inspect(messages)}"
    end
  end

   def wait_for_sqlcl_startup(pid, buffer \\ "") do
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

  def build_json_rpc_tool_call(id, tool_name, the_sql) do
    %{
      jsonrpc: "2.0",
      id: id,
      method: "tools/call",
      params: %{
        name: tool_name,
        arguments: %{
          "sql" => the_sql,
          "model" => "claude_sonnnet-4",
          #"model" => "how do i populate this?",
          "mcp_client" => "cline"
        }
      }
    } |> Jason.encode!()
  end
end
