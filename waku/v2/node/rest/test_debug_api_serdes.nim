import std/typetraits
import chronicles,
  unittest,
  stew/[results, byteutils],
  json_serialization
import "."/[json_serdes, debug_api]


suite "Debug API - serialization":

  suite "DebugWakuInfo - decode":
    test "optional field is not provided":
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

  suite "DebugWakuInfo - encode":
    test "optional field is none":
      # Given
      let data = DebugWakuInfo(listenAddresses: @["GO"], enrUri: none(string))

      # When
      let res = encodeIntoJsonBytes(data)

      # Then
      require(res.isOk)
      let value = res.get()
      check:
        value == toBytes("""{"listenAddresses":["GO"]}""")
