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
    Logger.info("SQLcl process ready for test suite setup.")

    ExUnit.Callbacks.on_exit fn ->
      if pid = Process.whereis(SqlclWrapper.SqlclProcess) do
        Logger.info("Shutting down SQLcl process after test suite.")
        Process.exit(pid, :kill)
      end
    end
    :ok
  end

  test "POST /tool sends command to SQLcl process" do
    command = "list-connections"
    conn =
      conn(:post, "/tool", command)
      |> put_req_header("content-type", "text/plain")
      |> SqlclWrapper.Router.call(@opts)

    assert conn.state == :sent
    assert conn.status == 200
    assert conn.resp_body == "Command sent to SQLcl process."
  end

  test "GET /tool establishes SSE connection and receives data" do
    # Start a GET request to establish the SSE connection
    conn = conn(:get, "/tool") |> SqlclWrapper.Router.call(@opts)
    assert conn.state == :chunked
    assert conn.status == 200

    # In a separate process, send a command via a POST request
    Task.start(fn ->
      conn(:post, "/tool", "list-connections")
      |> put_req_header("content-type", "text/plain")
      |> SqlclWrapper.Router.call(@opts)
    end)

    # Wait for the SSE event, ignoring other messages
    assert {:ok, body} = wait_for_chunk(15000)
    IO.inspect(body, label: "Output from list-connections")
    # The body will contain the "data: " prefix from the SSE format.
    # For example, you could assert:
    # assert body =~ "data: some expected output"
  end


  test "POST /tool sends 'exit' command and stops SQLcl process" do
    command = "exit"
    conn =
      conn(:post, "/tool", command)
      |> put_req_header("content-type", "text/plain")
      |> SqlclWrapper.Router.call(@opts)

    assert conn.state == :sent
    assert conn.status == 200
    assert conn.resp_body == "Command sent to SQLcl process."

    # Give the process a moment to terminate
    :timer.sleep(1000)
    pid = Process.whereis(SqlclWrapper.SqlclProcess)
    Process.exit(pid, :kill)
    :timer.sleep(100)
    # Assert that the SQLcl process is no longer running
    assert Process.whereis(SqlclWrapper.SqlclProcess) == nil
  end

  test "SSE functions can be called" do
    conn = conn(:get, "/tool")
    SqlclWrapper.Router.send_sse_data(conn, "test")
    SqlclWrapper.Router.stream_sqlcl_output(conn)
  end

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
