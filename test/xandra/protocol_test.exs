defmodule Xandra.ProtocolTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xandra.Protocol

  describe "frame_protocol_format/1" do
    test "returns the right \"format\"" do
      assert frame_protocol_format(Xandra.Protocol.V3) == :v4_or_less
      assert frame_protocol_format(Xandra.Protocol.V4) == :v4_or_less
      assert frame_protocol_format(Xandra.Protocol.V5) == :v5_or_more
    end
  end

  describe "supports_custom_payload?/1" do
    test "returns true or false based on the protocol" do
      assert supports_custom_payload?(Xandra.Protocol.V3) == false
      assert supports_custom_payload?(Xandra.Protocol.V4) == true
      assert supports_custom_payload?(Xandra.Protocol.V5) == true
    end
  end

  describe "decode_from_proto_type/2 with [string]" do
    test "decodes a string and rebinds variables" do
      encoded = <<3::16, "foo"::binary, "rest"::binary>>

      decode_from_proto_type(contents <- encoded, "[string]")

      assert contents == "foo"
      assert encoded == "rest"
    end

    test "raises if the size doesn't match" do
      encoded = <<3::16, "a"::binary>>

      assert_raise MatchError, fn ->
        decode_from_proto_type(_ <- encoded, "[string]")
        _ = encoded
      end
    end

    test "raises a compile-time error on malformed arguments" do
      message = "the right-hand side of <- must be a variable, got: :not_a_var"

      assert_raise ArgumentError, message, fn ->
        Code.eval_quoted(
          quote do
            decode_from_proto_type(_ <- :not_a_var, "[string]")
          end
        )
      end

      message = "the right-hand side of <- must be a variable, got: hello()"

      assert_raise ArgumentError, message, fn ->
        Code.eval_quoted(
          quote do
            decode_from_proto_type(_ <- hello(), "[string]")
          end
        )
      end
    end
  end

  describe "decode_from_proto_type/2 with [string list]" do
    property "works for zero strings" do
      check all cruft <- bitstring(), max_runs: 5 do
        buffer = <<0::16, cruft::bits>>
        decode_from_proto_type(list <- buffer, "[string list]")
        assert buffer == cruft
        assert list == []
      end
    end

    test "decodes strings" do
      buffer = <<2::16, 3::16, "foo"::binary, 2::16, "ab"::binary, 1::1>>
      decode_from_proto_type(list <- buffer, "[string list]")
      assert buffer == <<1::1>>
      assert list == ["foo", "ab"]
    end
  end

  describe "circular encoding/decoding" do
    property "with [inet] and an IPv4 address" do
      check all ipv4 <- {byte(), byte(), byte(), byte()},
                port <- integer(0..65535) do
        buffer = {ipv4, port} |> encode_to_type("[inet]") |> IO.iodata_to_binary()

        decode_from_proto_type(inet <- buffer, "[inet]")
        assert buffer == ""
        assert inet == {ipv4, port}
      end
    end

    property "with [inet] and an IPv6 address" do
      check all ipv6 <- {byte(), byte(), byte(), byte(), byte(), byte(), byte(), byte()},
                port <- integer(0..65535) do
        buffer = {ipv6, port} |> encode_to_type("[inet]") |> IO.iodata_to_binary()

        decode_from_proto_type(inet <- buffer, "[inet]")
        assert buffer == ""
        assert inet == {ipv6, port}
      end
    end
  end

  describe "set_query_values_flag/2" do
    test "with empty values" do
      assert set_query_values_flag(0x00, []) == 0x00
      assert set_query_values_flag(0x00, %{}) == 0x00
    end

    test "with list values" do
      assert set_query_values_flag(0x00, [1, 2, 3]) == 0x01
    end

    test "with map values" do
      assert set_query_values_flag(0x00, %{foo: :bar}) == 0x41
    end
  end

  describe "encode_serial_consistency/1" do
    test "returns the correct encoded value" do
      assert IO.iodata_to_binary(encode_serial_consistency(nil)) == ""
      assert IO.iodata_to_binary(encode_serial_consistency(:serial)) == <<0x00, 0x08>>
    end

    test "raises for invalid serial consistency" do
      assert_raise ArgumentError, ~r/the :serial_consistency option must be/, fn ->
        encode_serial_consistency(:quorum)
      end
    end
  end
end
