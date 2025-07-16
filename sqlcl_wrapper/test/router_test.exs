defmodule SqlclWrapper.RouterTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn
  import SqlclWrapper.IntegrationTestHelper # Import the helper
  require Logger

  @moduledoc """
  Tests for the SqlclWrapper.Router.
  """

  @opts SqlclWrapper.Router.init([])
  @port 4002 # Define a port for this specific test module to avoid conflicts
  @url "http://localhost:#{@port}/tool"

  setup_all do
    do_setup_all(%{port: @port, url: @url}) # Use the helper's setup_all

    on_exit fn ->
      if pid = Process.whereis(SqlclWrapper.SqlclProcess) do
        Logger.info("Shutting down SQLcl process after router test suite.")
        Process.exit(pid, :kill)
      end
    end
    :ok
  end

  test "POST /tool sends command to SQLcl process" do
    # The router expects JSON, so send a JSON-RPC tool call
    json_rpc_command = build_json_rpc_tool_call(1,"list-connections","")

    conn =
      conn(:post, "/tool", json_rpc_command)
      |> put_req_header("content-type", "application/json")
      |> SqlclWrapper.Router.call(@opts)

    assert conn.state == :chunked, "conn.state was #{inspect conn.state}"
    assert conn.status == 200
    # The response body should now be JSON from the SQLcl process
    Logger.info("body was #{inspect conn.resp_body}")
    Logger.info("body was #{inspect conn.resp_body}")
    # Extract and decode the JSON from the chunked response
    raw_body = String.trim_leading(conn.resp_body, "data: ")
    raw_body = String.trim_trailing(raw_body, "\n\n")
    parsed_body = Jason.decode!(raw_body)

    assert parsed_body != nil
    assert parsed_body["result"]["isError"] == false
    assert parsed_body["result"]["content"] != nil
    assert Enum.any?(parsed_body["result"]["content"], fn %{"type" => "text", "text" => text} -> String.contains?(text, "theconn") end)
    assert Enum.any?(parsed_body["result"]["content"], fn %{"type" => "text", "text" => text} -> String.contains?(text, "test123") end)
  end

  test "POST /tool connects and runs a SQL query" do
    # 1. Connect to "theconn"
    connect_command = build_json_rpc_connect_call(2, "theconn")

    conn_connect =
      conn(:post, "/tool", connect_command)
      |> put_req_header("content-type", "application/json")
      |> SqlclWrapper.Router.call(@opts)

    # We don't need to assert on the connection request's response body in this test.
    # The primary focus is on the subsequent SQL query.
    assert conn_connect.state == :chunked
    assert conn_connect.status == 200

    # 2. Run a SQL query to list tables
    sql_query = "SELECT /* LLM in use is claude-sonnet-4 */ table_name FROM user_tables;"
    run_sql_command = build_json_rpc_tool_call(3, "run-sql", sql_query)

    conn_run_sql =
      conn(:post, "/tool", run_sql_command)
      |> put_req_header("content-type", "application/json")
      |> SqlclWrapper.Router.call(@opts)

    assert conn_run_sql.state == :chunked
    assert conn_run_sql.status == 200
    # Extract and decode the JSON from the chunked response
    run_sql_raw_body = String.trim_leading(conn_run_sql.resp_body, "data: ")
    run_sql_raw_body = String.trim_trailing(run_sql_raw_body, "\n\n")
    Logger.info(" body: #{run_sql_raw_body}")
    # Assert that the raw body contains expected CSV content
    assert String.contains?(run_sql_raw_body, "TABLE_NAME")
    assert String.contains?(run_sql_raw_body, "USERS")
    assert String.contains?(run_sql_raw_body, "POSTS")
    assert String.contains?(run_sql_raw_body, "FOLLOWERS")
  end

  test "POST /tool runs a select query on the USERS table" do
    # 1. Connect to "theconn"
    connect_command = build_json_rpc_connect_call(4, "theconn")

    conn_connect =
      conn(:post, "/tool", connect_command)
      |> put_req_header("content-type", "application/json")
      |> SqlclWrapper.Router.call(@opts)

    assert conn_connect.state == :chunked
    assert conn_connect.status == 200
    parsed_connect_body = Jason.decode!(conn_connect.resp_body)
    assert parsed_connect_body["result"] != nil
    assert parsed_connect_body["result"]["isError"] == false
    assert String.contains?(List.first(parsed_connect_body["result"]["content"])["text"], "Successfully connected to:")

    # 2. Run a SQL query to select from USERS table
    sql_query = "SELECT /* LLM in use is claude-sonnet-4 */ * FROM USERS;"
    run_sql_command = build_json_rpc_tool_call(5, "run-sql", sql_query)

    conn_run_sql =
      conn(:post, "/tool", run_sql_command)
      |> put_req_header("content-type", "application/json")
      |> SqlclWrapper.Router.call(@opts)

    assert conn_run_sql.state == :chunked
    assert conn_run_sql.status == 200
    # Extract and decode the JSON from the chunked response
    run_sql_raw_body = String.trim_leading(conn_run_sql.resp_body, "data: ")
    run_sql_raw_body = String.trim_trailing(run_sql_raw_body, "\n\n")
    parsed_run_sql_body = Jason.decode!(run_sql_raw_body)

    assert parsed_run_sql_body["result"] != nil
    assert parsed_run_sql_body["result"]["isError"] == false
    assert parsed_run_sql_body["result"]["content"] != nil
    assert length(parsed_run_sql_body["result"]["content"]) > 0
    # Get the text content which is the CSV string
    csv_content = Enum.find_value(parsed_run_sql_body["result"]["content"], fn %{"type" => "text", "text" => text} -> text end)
    assert csv_content != nil
    # Assert that the CSV content contains expected column headers for USERS table
    assert String.contains?(csv_content, "ID") # Assuming ID is a column in USERS
    assert String.contains?(csv_content, "USERNAME") # Assuming USERNAME is a column in USERS
    assert String.contains?(csv_content, "EMAIL") # Assuming EMAIL is a column in USERS
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
end
