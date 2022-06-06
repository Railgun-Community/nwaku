import
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/route
import "."/[
  json_serdes,
  rest_api_response
],
  ".."/wakunode2

logScope: topics = "api_rest_debug"


#### Types

type
  DebugWakuInfo* = object
    listenAddresses*: seq[string]
    enrUri*: Option[string]

proc writeValue*(writer: var JsonWriter[RestJson], value: DebugWakuInfo)
  {.raises: [IOError, Defect].} =
  writer.beginRecord()
  writer.writeField("listenAddresses", value.listenAddresses)
  if value.enrUri.isSome:
    writer.writeField("enrUri", value.enrUri)
  writer.endRecord()

proc readValue*(reader: var JsonReader[RestJson], value: var DebugWakuInfo)
  {.raises: [SerializationError, IOError, Defect].} =
  var
    listenAddresses: Option[seq[string]]
    enrUri: Option[string]

  for fieldName in readObjectFields(reader):
    case fieldName
    of "listenAddresses":
      if listenAddresses.isSome():
        reader.raiseUnexpectedField("Multiple `listenAddresses` fields found", "DebugWakuInfo")
      listenAddresses = some(reader.readValue(seq[string]))
    of "enrUri":
      if enrUri.isSome():
        reader.raiseUnexpectedField("Multiple `enrUri` fields found", "DebugWakuInfo")
      enrUri = some(reader.readValue(string))
    else:
      unrecognizedFieldWarning()

  if listenAddresses.isNone():
    reader.raiseUnexpectedValue("Field `listenAddresses` is missing")

  value = DebugWakuInfo(
    listenAddresses: listenAddresses.get,
    enrUri: enrUri
  )


#### Request handlers

const ROUTE_DEBUG_INFOV1* = "/debug/v1/info"

proc installDebugInfoV1Handler(node: WakuNode, router: var RestRouter) =
  router.api(MethodGet, ROUTE_DEBUG_INFOV1) do () -> RestApiResponse:
    let nodeInfo = node.info()
    let info = DebugWakuInfo(
      listenAddresses: nodeInfo.listenAddresses,
      enrUri:
        block:
          if nodeInfo.enrUri.isNil:
            none(string)
          else:
            some(nodeInfo.enrUri)
    )

    let resp = RestApiResponse.jsonResponse(info, status=Http200)
    if resp.isErr():
      debug "An error ocurred while building the json respose", error=resp.error()
      return RestApiResponse.internalServerError()

    return resp.get()


#### Handlers installer

proc installDebugApiHandlers*(router: var RestRouter) =
  # TODO: List here all REST API request handlers (and redirects) for this API
  #  namespace
  installDebugInfoV1Handler(router)
