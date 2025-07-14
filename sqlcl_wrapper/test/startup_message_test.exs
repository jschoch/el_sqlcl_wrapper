defmodule SqlclWrapper.StartupMessageTest do
  use ExUnit.Case, async: false
  alias SqlclWrapper.SqlclProcess

  test "sends startup message to parent" do
    # Start the SqlclProcess with the test process as the parent
    {:ok, _pid} = SqlclProcess.start_link(parent: self())

    # Assert that the parent (the test process) receives the startup message
    assert_receive {:sqlcl_process_started, _sqlcl_pid}, 5000

    # Clean up the process
    Process.exit(Process.whereis(SqlclProcess), :kill)
  end
end
