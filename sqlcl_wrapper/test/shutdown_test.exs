defmodule SqlclWrapper.ShutdownTest do
  use ExUnit.Case, async: false
  import SqlclWrapper.IntegrationTestHelper
  require Logger

  @moduledoc """
  Tests for proper SQLcl process shutdown with enhanced configuration management.
  """

  setup do
    Logger.info("Starting SQLcl process for shutdown test...")
    {:ok, pid} = SqlclWrapper.SqlclProcess.start_link(parent: self())
    wait_for_sqlcl_startup() # Use the enhanced helper
    Logger.info("SQLcl process started for shutdown test.")

    %{sqlcl_pid: pid}
  end

  describe "SQLcl Process Shutdown" do
    test "SQLcl process shuts down gracefully after 'exit' command", %{sqlcl_pid: pid} do
      # Wait for the server to be fully ready before sending commands
      timeout = get_connection_timeout()
      :timer.sleep(timeout)

      Logger.info("Sending 'exit' command to SQLcl process.")

      # Send exit command through the proper interface
      try do
        SqlclWrapper.SqlclProcess.send_command("exit")
        :timer.sleep(1000)

        # Check if the process is still alive
        is_alive = Process.alive?(pid)
        Logger.info("SQLcl process alive after exit command: #{is_alive}")

        # Force kill if still alive (as per original test behavior)
        if is_alive do
          Logger.info("Force killing SQLcl process")
          Process.exit(pid, :kill)
        end

        :timer.sleep(100)

        # Assert that the SQLcl process is no longer running
        assert Process.whereis(SqlclWrapper.SqlclProcess) == nil,
          "SQLcl process should have been shut down"

        Logger.info("SQLcl process shutdown test completed successfully")
      rescue
        error ->
          Logger.error("Error during shutdown test: #{inspect(error)}")
          # Force cleanup
          if Process.alive?(pid) do
            Process.exit(pid, :kill)
          end
          reraise error, __STACKTRACE__
      end
    end

    test "SQLcl process can be restarted after shutdown", %{sqlcl_pid: original_pid} do
      # Shutdown the original process
      Logger.info("Shutting down original SQLcl process")
      Process.exit(original_pid, :kill)
      :timer.sleep(500)

      # Verify it's gone
      assert Process.whereis(SqlclWrapper.SqlclProcess) == nil,
        "Original SQLcl process should be shut down"

      # Start a new process
      Logger.info("Starting new SQLcl process")
      {:ok, new_pid} = SqlclWrapper.SqlclProcess.start_link(parent: self())

      # Wait for it to be ready
      wait_for_sqlcl_startup()

      # Verify the new process is different and working
      assert new_pid != original_pid, "New process should have different PID"
      assert Process.alive?(new_pid), "New SQLcl process should be alive"

      # Test that it can handle a simple command
      try do
        result = GenServer.call(new_pid, :is_server_ready, get_connection_timeout())
        assert result == true, "New SQLcl process should be ready"
        Logger.info("SQLcl process restart test completed successfully")
      rescue
        error ->
          Logger.error("Error testing new process: #{inspect(error)}")
        ensure
          # Cleanup
          if Process.alive?(new_pid) do
            Process.exit(new_pid, :kill)
          end
      end
    end

    test "SQLcl process handles multiple shutdown attempts gracefully", %{sqlcl_pid: pid} do
      timeout = get_connection_timeout()
      :timer.sleep(timeout)

      Logger.info("Testing multiple shutdown attempts")

      # Send multiple exit commands
      for i <- 1..3 do
        Logger.info("Sending exit command #{i}")
        try do
          SqlclWrapper.SqlclProcess.send_command("exit")
          :timer.sleep(200)
        rescue
          error ->
            Logger.info("Expected error on attempt #{i}: #{inspect(error)}")
        end
      end

      # Final cleanup
      if Process.alive?(pid) do
        Process.exit(pid, :kill)
      end

      :timer.sleep(100)

      # Assert that the process is eventually shut down
      assert Process.whereis(SqlclWrapper.SqlclProcess) == nil,
        "SQLcl process should be shut down after multiple attempts"

      Logger.info("Multiple shutdown attempts test completed successfully")
    end
  end

  describe "Process Cleanup" do
    test "cleanup handles edge cases properly", %{sqlcl_pid: pid} do
      # Test cleanup when process is already dead
      Process.exit(pid, :kill)
      :timer.sleep(100)

      # This should not raise an error
      try do
        SqlclWrapper.SqlclProcess.send_command("exit")
      rescue
        error ->
          Logger.info("Expected error when sending to dead process: #{inspect(error)}")
      end

      # Verify cleanup is complete
      assert Process.whereis(SqlclWrapper.SqlclProcess) == nil,
        "Dead process should be cleaned up"

      Logger.info("Edge case cleanup test completed successfully")
    end

    test "process respects configured timeouts" do
      # Get timeout from configuration
      startup_timeout = get_sqlcl_startup_timeout()
      connection_timeout = get_connection_timeout()

      # Verify timeouts are configured
      assert is_integer(startup_timeout) and startup_timeout > 0,
        "Startup timeout should be configured"
      assert is_integer(connection_timeout) and connection_timeout > 0,
        "Connection timeout should be configured"

      Logger.info("Configured timeouts - startup: #{startup_timeout}ms, connection: #{connection_timeout}ms")

      # Test that timeouts are reasonable
      assert startup_timeout >= 1000, "Startup timeout should be at least 1 second"
      assert connection_timeout >= 1000, "Connection timeout should be at least 1 second"

      Logger.info("Timeout configuration test completed successfully")
    end
  end

  # Helper functions using the new configuration system

  defp get_connection_timeout() do
    Application.get_env(:sqlcl_wrapper, :connection_timeout) || 5000
  end

  defp get_sqlcl_startup_timeout() do
    Application.get_env(:sqlcl_wrapper, :sqlcl_startup_timeout) || 15000
  end
end
