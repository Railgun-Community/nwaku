import
  chronicles,
  json_serialization,
  json_serialization/std/options
import "."/json_serdes

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

# proc installDebugApiHandlers*(router: var RestRouter) =
#   # let
#   #   cachedVersion =
#   #     RestApiResponse.prepareJsonResponse((version: "Nimbus/" & fullVersionStr))

#   router.api(MethodGet, "/debug/v1/info") do () -> RestApiResponse:
#     return RestApiResponse.jsonResponse(
#       cachedVersion,
#       Http200,
#       contentType = "application/json"
#     )
