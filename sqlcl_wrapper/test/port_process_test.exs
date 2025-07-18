defmodule SqlclWrapper.PorcelainTest do
  use ExUnit.Case
  import SqlclWrapper.IntegrationTestHelper # Import the helper
  require Logger

  @moduledoc """
  Tests the raw input and output of the sqlcl.exe process via the Porcelain wrapper.
  """

  setup_all do
    # Start the SqlclProcess manually for the test suite
    Logger.info("Starting SQLcl process for test suite setup...")
    #{:ok, pid} = SqlclWrapper.SqlclProcess.start_link(parent: self())
    pid = case SqlclWrapper.SqlclProcess.start_link(parent: self()) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
    wait_for_sqlcl_startup(pid) # Use the helper's wait_for_sqlcl_startup
    Logger.info("SQLcl process should be ready now.")

    ExUnit.Callbacks.on_exit fn ->
      if pid = Process.whereis(SqlclWrapper.SqlclProcess) do
        Logger.info("Shutting down SQLcl process after test suite.")
        Process.exit(pid, :kill)
      end
    end
    :ok
  end

  test "performs full handshake and calls list-connections tool" do
    pid = Process.whereis(SqlclWrapper.SqlclProcess)
    assert pid != nil

    #SqlclWrapper.SqlclProcess.subscribe(self())

    # 1. Send initialize request with the correct protocol version
    init_req = ~s({"jsonrpc": "2.0", "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "my-stdio-client", "version": "1.0.0"}}, "id": 1})
    {:ok, init_resp} = SqlclWrapper.SqlclProcess.send_command(init_req, 1_000)
    Logger.info("Received initialize response: #{inspect(init_resp)}")
    assert init_resp["id"] == 1
    assert init_resp["result"]

    # 3. Send initialized notification (this is a notification, not a request, so no reply expected)
    initialized_notif = ~s({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
    SqlclWrapper.SqlclProcess.send_command(initialized_notif, 1_000)

    # 4. Send tools/call request
    tool_call_req = ~s({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "list-connections", "arguments": {}}})
    {:ok, tool_call_resp} = SqlclWrapper.SqlclProcess.send_command(tool_call_req, 1_000)

    # 5. Receive tools/call response and assert its content
    Logger.info("Received tool call response: #{inspect(tool_call_resp)}")
    assert tool_call_resp["id"] == 2
    assert tool_call_resp["result"] != nil
    assert is_map(tool_call_resp["result"])
    assert tool_call_resp["result"]["isError"] == false
    assert is_list(tool_call_resp["result"]["content"])
    # Assert that there is 1 connection as per the provided working test output
    assert length(tool_call_resp["result"]["content"]) == 1
    assert tool_call_resp["result"]["content"] == [%{"type" => "text", "text" => "theconn,test123"}]
  end

end
