defmodule SqlclWrapper.ListTablesIntegrationTest do
  use ExUnit.Case, async: true
  import SqlclWrapper.IntegrationTestHelper
  require Logger
  @moduledoc """
  Tests listing tables via the SQLcl router using SSE.
  """
  @port 4001 # Define a port for this specific test module
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


  test "POST /tool with run-sql to list tables via router and receive SSE" do

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
    Logger.info("Sending list tables command via HTTPoison.post to #{@url}")

    {:ok, %HTTPoison.AsyncResponse{id: async_id}} = HTTPoison.post(@url, json_rpc_command, [{"Content-Type", "application/json"}], stream_to: self())

    # Collect SSE messages
    received_messages = receive_sse_messages(async_id)
    Logger.info("SSE client received messages: #{inspect(received_messages)}")

    assert is_binary(received_messages)
    assert String.contains?(received_messages,"USERS")
    # The client task should terminate naturally after receiving the close event.
  end
end
