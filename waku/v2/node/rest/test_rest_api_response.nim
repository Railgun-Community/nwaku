import std/typetraits
import chronicles,
  unittest2,
  stew/[results, byteutils],
  json_serialization,
  presto/common

import "."/[rest_api_response, debug_api]


# TODO: Decouple this test suite from the `debug_api` module by defining
#  private custom types for this test suite module
suite "Presto RestApiResponse extension":

  test "valid json response":
    # Given
    let data = DebugWakuInfo(listenAddresses: @["TEST"])

    # When
    let res = RestApiResponse.jsonResponse(data, status = Http200)

    # Then
    require(res.isOk)
    let value = res.get()
    check:
      value.status == Http200
      value.kind == RestApiResponseKind.Content
      value.content.contentType == $MIMETYPE_JSON
      value.content.data == toBytes("""{"listenAddresses":["TEST"]}""" )
