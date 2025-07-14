defmodule SqlclWrapper.RouterTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn
  require Logger

  @moduledoc """
  Tests for the SqlclWrapper.Router.
  """

  @opts SqlclWrapper.Router.init([])

  setup_all do
    # Start the SqlclProcess manually for the test suite
    Logger.info("Starting SQLcl process for test suite setup...")
    {:ok, pid} = SqlclWrapper.SqlclProcess.start_link(parent: self())
    wait_for_sqlcl_startup(pid)
    Logger.info("SQLcl process ready for test suite setup. Giving it a moment...")
    Process.sleep(1000) # Give SQLcl a moment to fully initialize after startup message
    Logger.info("SQLcl process should be ready now.")

    # Perform MCP handshake
    Logger.info("Attempting to send command to SQLcl process: {\"jsonrpc\": \"2.0\", \"method\": \"initialize\", \"params\": {\"protocolVersion\": \"2024-11-05\", \"capabilities\": {}, \"clientInfo\": {\"name\": \"my-stdio-client\", \"version\": \"1.0.0\"}}, \"id\": 1}")
    {:ok, init_resp} = SqlclWrapper.SqlclProcess.send_command(~s({"jsonrpc": "2.0", "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "my-stdio-client", "version": "1.0.0"}}, "id": 1}))
    Logger.info("Received initialize response: #{inspect(init_resp)}")

    Logger.info("Attempting to send notification to SQLcl process: {\"jsonrpc\": \"2.0\", \"method\": \"notifications/initialized\", \"params\": {}}")
    SqlclWrapper.SqlclProcess.send_command(~s({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}))
    Logger.info("Notification sent to SQLcl process.")

    ExUnit.Callbacks.on_exit fn ->
      if pid = Process.whereis(SqlclWrapper.SqlclProcess) do
        Logger.info("Shutting down SQLcl process after test suite.")
        Process.exit(pid, :kill)
      end
    end
    :ok
  end

  test "POST /tool sends command to SQLcl process" do
    # The router expects JSON, so send a JSON-RPC tool call
    json_rpc_command = %{
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: %{
        name: "list-connections",
        arguments: %{}
      }
    } |> Jason.encode!()

    conn =
      conn(:post, "/tool", json_rpc_command)
      |> put_req_header("content-type", "application/json")
      |> SqlclWrapper.Router.call(@opts)

    assert conn.state == :sent
    assert conn.status == 200
    # The response body should now be JSON from the SQLcl process
    parsed_body = Jason.decode!(conn.resp_body)
    assert parsed_body["result"] != nil
    assert parsed_body["result"]["isError"] == false
    assert parsed_body["result"]["content"] != nil
    assert Enum.any?(parsed_body["result"]["content"], fn %{"type" => "text", "text" => text} -> String.contains?(text, "theconn") end)
    assert Enum.any?(parsed_body["result"]["content"], fn %{"type" => "text", "text" => text} -> String.contains?(text, "test123") end)
  end

  test "POST /tool connects and runs a SQL query" do
    # 1. Connect to "theconn"
    connect_command = %{
      jsonrpc: "2.0",
      id: 2, # Use a different ID
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

    conn_connect =
      conn(:post, "/tool", connect_command)
      |> put_req_header("content-type", "application/json")
      |> SqlclWrapper.Router.call(@opts)

    assert conn_connect.state == :sent
    assert conn_connect.status == 200
    parsed_connect_body = Jason.decode!(conn_connect.resp_body)
    IO.inspect(parsed_connect_body, label: "Parsed Connect Body in Test")
    assert parsed_connect_body["result"] != nil
    assert parsed_connect_body["result"]["isError"] == false

    # Get the first content item's text and assert on it directly
    first_content_text = parsed_connect_body["result"]["content"]
                         |> List.first()
                         |> Map.get("text")

    IO.inspect(first_content_text, label: "First Content Text")
    assert String.contains?(first_content_text, "Successfully connected to:")

    # 2. Run a SQL query to list tables
    sql_query = "SELECT /* LLM in use is claude-sonnet-4 */ table_name FROM user_tables;"
    run_sql_command = %{
      jsonrpc: "2.0",
      id: 3, # Use another different ID
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

    conn_run_sql =
      conn(:post, "/tool", run_sql_command)
      |> put_req_header("content-type", "application/json")
      |> SqlclWrapper.Router.call(@opts)

    assert conn_run_sql.state == :sent
    assert conn_run_sql.status == 200
    parsed_run_sql_body = Jason.decode!(conn_run_sql.resp_body)
    assert parsed_run_sql_body["result"] != nil
    assert parsed_run_sql_body["result"]["isError"] == false
    # Assert that content is not empty, and contains some expected table-like output
    assert parsed_run_sql_body["result"]["content"] != nil
    assert length(parsed_run_sql_body["result"]["content"]) > 0
    # Further assertions could check for specific table names if known, or CSV format
    # For now, just check for some text content
    assert Enum.any?(parsed_run_sql_body["result"]["content"], fn %{"type" => "text", "text" => text} -> String.length(text) > 0 end)
  end

  test "POST /tool runs a select query on the USERS table" do
    # 1. Connect to "theconn"
    connect_command = %{
      jsonrpc: "2.0",
      id: 4, # Use a different ID
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

    conn_connect =
      conn(:post, "/tool", connect_command)
      |> put_req_header("content-type", "application/json")
      |> SqlclWrapper.Router.call(@opts)

    assert conn_connect.state == :sent
    assert conn_connect.status == 200
    parsed_connect_body = Jason.decode!(conn_connect.resp_body)
    assert parsed_connect_body["result"] != nil
    assert parsed_connect_body["result"]["isError"] == false
    assert String.contains?(List.first(parsed_connect_body["result"]["content"])["text"], "Successfully connected to:")

    # 2. Run a SQL query to select from USERS table
    sql_query = "SELECT /* LLM in use is claude-sonnet-4 */ * FROM USERS;"
    run_sql_command = %{
      jsonrpc: "2.0",
      id: 5, # Use another different ID
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

    conn_run_sql =
      conn(:post, "/tool", run_sql_command)
      |> put_req_header("content-type", "application/json")
      |> SqlclWrapper.Router.call(@opts)

    assert conn_run_sql.state == :sent
    assert conn_run_sql.status == 200
    parsed_run_sql_body = Jason.decode!(conn_run_sql.resp_body)
    assert parsed_run_sql_body["result"] != nil
    assert parsed_run_sql_body["result"]["isError"] == false
    assert parsed_run_sql_body["result"]["content"] != nil
    assert length(parsed_run_sql_body["result"]["content"]) > 0
    assert Enum.any?(parsed_run_sql_body["result"]["content"], fn %{"type" => "text", "text" => text} -> String.length(text) > 0 end)
  end

  # This test is problematic as it tries to call internal functions directly
  # and doesn't properly simulate the SSE flow. It's better to rely on
  # "GET /tool establishes SSE connection and receives data" for SSE testing.
  # Removing this test for now.

  test "handles unknown routes with 404" do
    conn =
      conn(:get, "/unknown")
      |> SqlclWrapper.Router.call(@opts)

    assert conn.state == :sent
    assert conn.status == 404
    assert conn.resp_body == "Not Found"
  end

  test "wait_for_sqlcl_startup correctly matches startup string" do
    startup_message = "---------- MCP SERVER STARTUP ----------\nMCP Server started successfully on Sun Jul 13 16:52:24 PDT 2025\nPress Ctrl+C to stop the server\n----------------------------------------"
    send(self(), {:sqlcl_output, {:stdout, startup_message}})
    assert wait_for_sqlcl_startup(self(), "") == :ok
  end

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
