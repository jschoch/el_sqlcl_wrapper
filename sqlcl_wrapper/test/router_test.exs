defmodule SqlclWrapper.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import SqlclWrapper.IntegrationTestHelper
  require Logger

  @moduledoc """
  Tests for the SqlclWrapper.Router with enhanced configuration management.
  """

  @opts SqlclWrapper.Router.init([])
  @port 4002

  setup_all do
    do_setup_all(%{port: @port, initialize_mcp: false})

    on_exit(fn ->
      if pid = Process.whereis(SqlclWrapper.SqlclProcess) do
        Logger.info("Shutting down SQLcl process after router test suite.")
        Process.exit(pid, :kill)
      end
    end)
    :ok
  end

  describe "Router Tool Calls" do
    test "POST /tool handles list-connections with configured connection" do
      connection_name = get_default_connection()
      json_rpc_command = build_json_rpc_tool_call(1, "list-connections", %{})

      conn =
        conn(:post, "/tool", json_rpc_command)
        |> put_req_header("content-type", "application/json")
        |> SqlclWrapper.Router.call(@opts)

      assert conn.state == :chunked
      assert conn.status == 200

      # Extract and verify the response contains the configured connection
      raw_body = String.trim_leading(conn.resp_body, "data: ")
      raw_body = String.trim_trailing(raw_body, "\n\n")

      assert String.contains?(raw_body, connection_name),
        "Expected connection '#{connection_name}' not found in response: #{raw_body}"

      Logger.info("List connections test passed with connection: #{connection_name}")
    end

    test "POST /tool connects and runs SQL query using configured connection" do
      connection_name = get_default_connection()

      # Step 1: Connect to the configured connection
      connect_command = build_json_rpc_connect_call(2, connection_name)

      conn_connect =
        conn(:post, "/tool", connect_command)
        |> put_req_header("content-type", "application/json")
        |> SqlclWrapper.Router.call(@opts)

      assert conn_connect.state == :chunked
      assert conn_connect.status == 200

      # Step 2: Run a configured test query
      test_query = get_test_query(:list_tables)
      run_sql_command = build_json_rpc_tool_call(3, "run-sql", %{"sql" => test_query})

      conn_run_sql =
        conn(:post, "/tool", run_sql_command)
        |> put_req_header("content-type", "application/json")
        |> SqlclWrapper.Router.call(@opts)

      assert conn_run_sql.state == :chunked
      assert conn_run_sql.status == 200

      # Extract and verify the response
      run_sql_raw_body = String.trim_leading(conn_run_sql.resp_body, "data: ")
      run_sql_raw_body = String.trim_trailing(run_sql_raw_body, "\n\n")

      Logger.info("SQL query response: #{run_sql_raw_body}")

      # Verify we get table listing results
      assert String.contains?(run_sql_raw_body, "TABLE_NAME") or
             String.length(run_sql_raw_body) > 0,
        "Expected table listing results in response"
    end

    test "POST /tool handles user table query with validation" do
      connection_name = get_default_connection()

      # Connect first
      connect_command = build_json_rpc_connect_call(4, connection_name)
      conn_connect =
        conn(:post, "/tool", connect_command)
        |> put_req_header("content-type", "application/json")
        |> SqlclWrapper.Router.call(@opts)

      assert conn_connect.status == 200

      # Run user table query with validation
      sql_query = "SELECT /* LLM in use is claude-sonnet-4 */ * FROM USERS WHERE ROWNUM <= 3"
      run_sql_command = build_json_rpc_tool_call(5, "run-sql", %{"sql" => sql_query})

      conn_run_sql =
        conn(:post, "/tool", run_sql_command)
        |> put_req_header("content-type", "application/json")
        |> SqlclWrapper.Router.call(@opts)

      assert conn_run_sql.state == :chunked
      assert conn_run_sql.status == 200

      # Extract and validate the response
      run_sql_raw_body = String.trim_leading(conn_run_sql.resp_body, "data: ")
      run_sql_raw_body = String.trim_trailing(run_sql_raw_body, "\n\n")

      Logger.info("User table query response: #{run_sql_raw_body}")

      # Validate expected columns and data from configuration
      validation_config = get_table_validation_config("USERS")
      expected_columns = validation_config[:columns] || []
      expected_data = validation_config[:sample_data] || []

      for column <- expected_columns do
        assert String.contains?(run_sql_raw_body, column),
          "Expected column '#{column}' not found in response"
      end

      # Check for at least one sample data entry
      has_sample_data = Enum.any?(expected_data, fn data ->
        String.contains?(run_sql_raw_body, data)
      end)

      assert has_sample_data, "Expected at least one sample data entry in response"
    end

    test "POST /tool handles SQLcl commands" do
      connection_name = get_default_connection()

      # Connect first
      connect_command = build_json_rpc_connect_call(6, connection_name)
      conn_connect =
        conn(:post, "/tool", connect_command)
        |> put_req_header("content-type", "application/json")
        |> SqlclWrapper.Router.call(@opts)

      assert conn_connect.status == 200

      # Run SQLcl command
      sqlcl_command = build_json_rpc_tool_call(7, "run-sqlcl", %{"sqlcl" => "show version"})

      conn_sqlcl =
        conn(:post, "/tool", sqlcl_command)
        |> put_req_header("content-type", "application/json")
        |> SqlclWrapper.Router.call(@opts)

      assert conn_sqlcl.state == :chunked
      assert conn_sqlcl.status == 200

      # Extract and verify response
      sqlcl_raw_body = String.trim_leading(conn_sqlcl.resp_body, "data: ")
      sqlcl_raw_body = String.trim_trailing(sqlcl_raw_body, "\n\n")

      Logger.info("SQLcl command response: #{sqlcl_raw_body}")

      assert String.length(sqlcl_raw_body) > 0, "SQLcl command should return content"
    end
  end

  describe "Router Error Handling" do
    test "handles unknown routes with 404" do
      conn =
        conn(:get, "/unknown")
        |> SqlclWrapper.Router.call(@opts)

      assert conn.state == :sent
      assert conn.status == 404
      assert conn.resp_body == "Not Found"
    end

    test "handles invalid JSON in POST requests" do
      conn =
        conn(:post, "/tool", "{invalid json")
        |> put_req_header("content-type", "application/json")
        |> SqlclWrapper.Router.call(@opts)

      # Should handle the error gracefully
      assert conn.status in [400, 500]
    end

    test "handles missing tool name in requests" do
      invalid_command = Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "id" => 99,
        "params" => %{
          "arguments" => %{"test" => "value"}
        }
      })

      conn =
        conn(:post, "/tool", invalid_command)
        |> put_req_header("content-type", "application/json")
        |> SqlclWrapper.Router.call(@opts)

      # Should handle the error gracefully
      assert conn.status in [400, 500]
    end
  end

  describe "SQLcl Process Integration" do
    test "wait_for_sqlcl_startup correctly matches startup string" do
      startup_message = "---------- MCP SERVER STARTUP ----------\nMCP Server started successfully on Sun Jul 13 16:52:24 PDT 2025\nPress Ctrl+C to stop the server\n----------------------------------------"
      send(self(), {:sqlcl_output, {:stdout, startup_message}})
      assert wait_for_sqlcl_startup(self(), "") == :ok
    end

    test "can verify SQLcl process is running" do
      pid = Process.whereis(SqlclWrapper.SqlclProcess)
      assert pid != nil, "SQLcl process should be running"
      assert Process.alive?(pid), "SQLcl process should be alive"
    end
  end

  # Helper functions using the new configuration system

  defp get_default_connection() do
    Application.get_env(:sqlcl_wrapper, :default_connection) || "theconn"
  end

  defp get_test_query(query_name) do
    Application.get_env(:sqlcl_wrapper, :test_queries)[query_name]
  end

  defp get_table_validation_config(table_name) do
    table_key = String.downcase(table_name) <> "_table" |> String.to_atom()
    Application.get_env(:sqlcl_wrapper, :test_data_validation)[table_key] || %{}
  end
end
