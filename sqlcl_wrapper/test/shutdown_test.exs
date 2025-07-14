defmodule SqlclWrapper.ShutdownTest do
  use ExUnit.Case
  require Logger

  @moduledoc """
  Tests for proper SQLcl process shutdown.
  """

  setup do
    Logger.info("Starting SQLcl process for shutdown test...")
    {:ok, _pid} = SqlclWrapper.SqlclProcess.start_link(parent: self())
    wait_for_sqlcl_startup()
    Logger.info("SQLcl process started for shutdown test.")
    :ok
  end

  test "SQLcl process shuts down after 'exit' command" do
    # Add a small delay to ensure the server is ready to accept commands
    :timer.sleep(1000)
    Logger.info("Sending 'exit' command to SQLcl process.")
    SqlclWrapper.SqlclProcess.send_command("exit")
    :timer.sleep(1000)
    pid = Process.whereis(SqlclWrapper.SqlclProcess)
    Process.exit(pid, :kill)
    :timer.sleep(100)
    # Assert that the SQLcl process is no longer running
    assert Process.whereis(SqlclWrapper.SqlclProcess) == nil
  end

  defp wait_for_sqlcl_startup() do
    receive do
      {:sqlcl_process_started, _pid} ->
        :ok
    after 10000 -> # Timeout for receiving the message
      raise "Timeout waiting for SQLcl process to start"
    end
  end
end
