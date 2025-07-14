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
    assert parsed_body["jsonrpc"] == "2.0"
    assert parsed_body["id"] == 1
    assert parsed_body["result"] != nil
    assert parsed_body["result"]["isError"] == false
    assert parsed_body["result"]["content"] != nil
    assert Enum.any?(parsed_body["result"]["content"], fn %{"type" => "text", "text" => text} -> String.contains?(text, "theconn") end)
    assert Enum.any?(parsed_body["result"]["content"], fn %{"type" => "text", "text" => text} -> String.contains?(text, "test123") end)
  end

  test "GET /tool establishes SSE connection and receives data" do
    # Start a GET request to establish the SSE connection
    conn = conn(:get, "/tool") |> SqlclWrapper.Router.call(@opts)
    assert conn.state == :chunked
    assert conn.status == 200

    # In a separate process, send a command via a POST request
    Task.start(fn ->
      json_rpc_command = %{
        jsonrpc: "2.0",
        id: 2, # Use a different ID for this request
        method: "tools/call",
        params: %{
          name: "list-connections",
          arguments: %{}
        }
      } |> Jason.encode!()

      conn(:post, "/tool", json_rpc_command)
      |> put_req_header("content-type", "application/json")
      |> SqlclWrapper.Router.call(@opts)
    end)

    # Wait for the SSE event, ignoring other messages
    assert {:ok, body} = wait_for_chunk(15000)
    IO.inspect(body, label: "Output from list-connections SSE")

    # The body will contain the "data: " prefix from the SSE format.
    # We need to parse the JSON part of the SSE data.
    assert body =~ "data: "
    # Extract the JSON string after "data: "
    json_string = String.replace(body, "data: ", "")
    parsed_sse_data = Jason.decode!(json_string)

    assert parsed_sse_data["jsonrpc"] == "2.0"
    assert parsed_sse_data["id"] == 2 # Assert on the ID used in the Task
    assert parsed_sse_data["result"] != nil
    assert parsed_sse_data["result"]["isError"] == false
    assert parsed_sse_data["result"]["content"] != nil
    assert Enum.any?(parsed_sse_data["result"]["content"], fn %{"type" => "text", "text" => text} -> String.contains?(text, "theconn") end)
    assert Enum.any?(parsed_sse_data["result"]["content"], fn %{"type" => "text", "text" => text} -> String.contains?(text, "test123") end)
  end


  test "POST /tool sends 'exit' command and stops SQLcl process" do
    # Send "exit" as a raw command, as per SqlclProcess's handling
    command = "exit"
    conn =
      conn(:post, "/tool", command)
      |> put_req_header("content-type", "text/plain") # "exit" is not JSON
      |> SqlclWrapper.Router.call(@opts)

    assert conn.state == :sent
    assert conn.status == 200
    # The response body for raw commands is now "OK" from SqlclProcess
    assert conn.resp_body == "OK"

    # Give the process a moment to terminate
    :timer.sleep(2000) # Increased sleep to allow for graceful shutdown
    # Assert that the SQLcl process is no longer running
    assert Process.whereis(SqlclWrapper.SqlclProcess) == nil
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

  defp wait_for_chunk(timeout) do
    receive do
      {:chunk, body} -> {:ok, body}
      _ -> wait_for_chunk(timeout)
    after
      timeout -> {:error, :timeout}
    end
  end
end
