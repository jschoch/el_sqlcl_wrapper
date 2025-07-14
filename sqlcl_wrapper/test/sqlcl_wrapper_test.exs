defmodule SqlclWrapperTest do
  use ExUnit.Case
  doctest SqlclWrapper

  test "greets the world" do
    assert SqlclWrapper.hello() == :world
  end
end
