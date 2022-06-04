import std/typetraits
import chronicles,
  unittest2,
  stew/[results, byteutils],
  json_serialization
import "."/[json_serdes, debug_api]


# TODO: Decouple this test suite from the `debug_api` module by defining
#  private custom types for this test suite module
suite "JSON Serdes":

  suite "decode":
    test "decodeJsonString - use the corresponding readValue template":
      # Given
      let jsonString = JsonString("""{ "listenAddresses":["123"] }""")

      # When
      let res = decodeJsonString(DebugWakuInfo, jsonString, requireAllFields = true)

      # Then
      require(res.isOk)
      let value = res.get()
      check:
        value.listenAddresses == @["123"]
        value.enrUri.isNone

  suite "encode":
    test "encodeIntoJsonString - use the corresponding writeValue template":
      # Given
      let data = DebugWakuInfo(listenAddresses: @["GO"])

      # When
      let res = encodeIntoJsonString(data)

      # Then
      require(res.isOk)
      let value = res.get()
      check:
        value == """{"listenAddresses":["GO"]}"""

    test "encodeIntoJsonBytes - use the corresponding writeValue template":
      # Given
      let data = DebugWakuInfo(listenAddresses: @["ABC"])

      # When
      let res = encodeIntoJsonBytes(data)

      # Then
      require(res.isOk)
      let value = res.get()
      check:
        value == toBytes("""{"listenAddresses":["ABC"]}""" )
