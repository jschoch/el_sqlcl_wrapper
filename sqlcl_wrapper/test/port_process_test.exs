defmodule SqlclWrapper.PortProcessTest do
  use ExUnit.Case, async: false
  import SqlclWrapper.IntegrationTestHelper # Import the helper
  require Logger

  @moduledoc """
  Tests the raw input and output of the sqlcl.exe process via the Porcelain wrapper.
  """

  setup do
    # The application supervisor starts the process, we just need to wait for it.
    #wait_for_sqlcl_startup()
    :ok
  end

  test "can ping the GenServer" do
    assert :pong = GenServer.call(SqlclWrapper.SqlclProcess, :ping)
  end

  test "can list tools" do

      req = ~s({  "jsonrpc": "2.0",  "id": 1,  "method": "tools/list",  "params": {     }})
      {:ok, tool_call_resp} = SqlclWrapper.SqlclProcess.send_command(req, 3_000)
      assert tool_call_resp["jsonrpc"] == "2.0"
      tools = tool_call_resp["result"]["tools"]
      Logger.info("tools #{inspect tools,pretty: true}")

      for tool <- tools do
      assert Map.has_key?(tool, "name")
      assert Map.has_key?(tool, "description")
      assert Map.has_key?(tool, "inputSchema")

      assert is_binary(tool["name"])
      assert is_binary(tool["description"])
      assert is_map(tool["inputSchema"])
    end

  end

  test "can call list-connections tool" do
    # The handshake is now handled automatically by the SqlclProcess.
    # We can directly send the tool call.
    tool_call_req = ~s({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "list-connections", "arguments": {"mcp_client":"foo","model":"bar"}}})
    {:ok, tool_call_resp} = SqlclWrapper.SqlclProcess.send_command(tool_call_req, 3_000)

    # Assert the response is valid
    Logger.info("Received tool call response: #{inspect(tool_call_resp)}")
    assert tool_call_resp["id"] == 2
    assert tool_call_resp["result"] != nil
    assert is_map(tool_call_resp["result"])
    assert tool_call_resp["result"]["isError"] == false
  end

  test "can do it twice" do
    tool_call_req = ~s({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "list-connections", "arguments": {"mcp_client":"foo","model":"bar"}}})

    {:ok, tool_call_resp1} = SqlclWrapper.SqlclProcess.send_command(tool_call_req, 3_000)

    {:ok, tool_call_resp2} = SqlclWrapper.SqlclProcess.send_command(tool_call_req, 3_000)
     assert tool_call_resp2["id"] == 2
    assert tool_call_resp2["result"] != nil
    assert is_map(tool_call_resp2["result"])
    assert tool_call_resp2["result"]["isError"] == false

  end

  test "can connect and run a query" do

    connection_name = get_default_connection()

    con_map =  %{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          #"id" => "connect-#{System.unique_integer([:monotonic])}",
          "id" => 2,
          "params" => %{
            "name" => "connect",
            "arguments" => %{
              "connection_name" => connection_name,
              "mcp_client" => "test-client",
              "model" => "claude-sonnet-4"
            }
          }
        }
    con_json = Jason.encode!(con_map)
    IO.puts(con_json)
    Process.sleep(1000)
    {:ok, tool_call_resp} = SqlclWrapper.SqlclProcess.send_command(con_json, 10_000)

    # Assert the response is valid
    Logger.info("Received tool call response: #{inspect(tool_call_resp)}")
    assert tool_call_resp["id"] == 2
    assert tool_call_resp["result"] != nil
    assert is_map(tool_call_resp["result"])
    assert tool_call_resp["result"]["isError"] == false
    query = get_test_query(:simple_select)
    Logger.info("running query #{inspect query}")
    command_message = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => "sql-#{System.unique_integer([:monotonic])}",
      "params" => %{
        "name" => "run-sql",
        "arguments" => %{
          "sql" => query,
          "mcp_client" => "test-client",
          "model" => "claude-sonnet-4"
        }
      }
    }
    con_json = Jason.encode!(command_message)
     {:ok, q_resp} = SqlclWrapper.SqlclProcess.send_command(con_json, 10_000)
    Logger.info("query response: #{inspect q_resp}")
    assert false, "not done yet"

  end

end
