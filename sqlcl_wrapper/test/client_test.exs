defmodule SqlclWrapper.MCPClientTest do
  use ExUnit.Case, async: false
  import SqlclWrapper.IntegrationTestHelper
  require Logger

  @moduledoc """
  Tests MCP protocol compliance, SQL execution, and connection management.
  """

  setup_all do

    :ok
  end

  test "do a thing" do
    #{first, result} = SqlclWrapper.MCPClient.call_tool("initialize", %{mcp_client: "blaz", model: "bluz"})
    #{first, result} = SqlclWrapper.MCPClient.call_tool("list", %{mcp_client: "blaz", model: "bluz"})
    SqlclWrapper.MCPClient.get_server_capabilities()
    {first, res} = SqlclWrapper.MCPClient.call_tool("list-connections", %{mcp_client: "blaz", model: "bluz"})
    #assert :ok == first, "result was #{inspect( result)}"
    result_map = res.result
    assert result_map["isError"] == false, "something went wrong with the map #{inspect result_map, pretty: true}"
    assert Map.has_key?(result_map,"content")
    assert is_list(result_map["content"])

  end

  test "can create a connection" do

    # First get the list of available connections
    SqlclWrapper.MCPClient.get_server_capabilities()
    {status, res} = SqlclWrapper.MCPClient.call_tool("list-connections", %{"mcp_client" => "test_client", "model" => "test_model"})
    assert status == :ok, "Failed to list connections: #{inspect(res)}"

    #result = res.result
    result = res.result
    Logger.info("List connections result: #{inspect(result, pretty: true)}")

    # Extract connection names from the result - the result is double-wrapped
    connections = case result do
      %{"content" => [%{"text" => json_text}]} when is_binary(json_text) ->
        # The inner content is JSON-encoded, need to decode it
        case Jason.decode(json_text) do
          {:ok, %{"content" => [%{"text" => connections_text}]}} ->
            # Parse the comma-separated connection list
            Logger.info("connections: #{connections_text}")
            connections_text
            |> String.split(",")
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))
          doh ->
            Logger.error("could not parse the result #{inspect result}")
            []
        end
      wtf ->
        Logger.error("WTF: #{inspect wtf}")
        []
    end

    Logger.info("Parsed connections: #{inspect(connections)}")

    # Get the expected default connection from test environment
    expected_connection = get_default_connection()
    Logger.info("Expected default connection: #{expected_connection}")

    # Verify the expected connection is in the list
    assert Enum.member?(connections, expected_connection),
      "Expected connection '#{expected_connection}' not found in connections: #{inspect(connections)}"

    if length(connections) > 0 do
      # Connect to the expected default connection
      Logger.info("Attempting to connect to: #{expected_connection}")

      {connect_status, connect_res} = SqlclWrapper.MCPClient.call_tool("connect", %{
        "connection_name" => expected_connection,
        "mcp_client" => "test_client",
        "model" => "test_model"
      })

      connect_result = connect_res.result
      Logger.info("Connect result: #{inspect(connect_result, pretty: true)}")

      assert connect_status == :ok, "Failed to connect to #{expected_connection}: #{inspect(connect_result)}"

      # Verify the connection was successful by checking the response content
      case connect_result do
        %{"content" => content} when is_list(content) ->
          # Connection should return some content indicating success
          assert length(content) > 0, "Connection response should contain content"
        _ ->
          # Connection might return other formats, just ensure it's not an error
          refute Map.has_key?(connect_result, "error"), "Connection should not return an error"
      end
    else
      # Skip the test if no connections are available
      Logger.info("No connections available to test, skipping connection test")
      assert true, "No connections available for testing"
    end

  end

  test "can run a simple query" do
    # First get server capabilities and list connections
    SqlclWrapper.MCPClient.get_server_capabilities()
    {status, res} = SqlclWrapper.MCPClient.call_tool("list-connections", %{"mcp_client" => "test_client", "model" => "test_model"})
    assert status == :ok, "Failed to list connections: #{inspect(res)}"

    # Extract connections and connect to default
    result = res.result
    connections = case result do
      %{"content" => [%{"text" => json_text}]} when is_binary(json_text) ->
        case Jason.decode(json_text) do
          {:ok, %{"content" => [%{"text" => connections_text}]}} ->
            connections_text
            |> String.split(",")
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))
          _ -> []
        end
      _ -> []
    end

    expected_connection = get_default_connection()
    assert Enum.member?(connections, expected_connection), "Expected connection not found"

    # Connect to the database
    {connect_status, connect_res} = SqlclWrapper.MCPClient.call_tool("connect", %{
      "connection_name" => expected_connection,
      "mcp_client" => "test_client",
      "model" => "test_model"
    })
    assert connect_status == :ok, "Failed to connect: #{inspect(connect_res)}"

    # Run a simple select query using test helper
    query = get_test_query(:simple_select)
    Logger.info("Running query: #{query}")

    {query_status, query_res} = SqlclWrapper.MCPClient.call_tool("run-sql", %{
      "mcp_client" => "test_client",
      "model" => "claude",
      "sql" => query
    })

    assert query_status == :ok, "Failed to run query: #{inspect(query_res)}"

    query_result = query_res.result
    Logger.info("Query result: #{inspect(query_result, pretty: true)}")

    # Verify the query returned content
    case query_result do
      %{"content" => content} when is_list(content) ->
        assert length(content) > 0, "Query should return content"
      _ ->
        refute Map.has_key?(query_result, "error"), "Query should not return an error"
    end
  end
end
