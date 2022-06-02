import std/typetraits
import stew/results,
       serialization,
       json_serialization,
       json_serialization/std/[options, net, sets],
       chronicles

logScope: topics = "api_rest_json_serdes"


Json.createFlavor RestJson

template unrecognizedFieldWarning* =
  # TODO: There should be a different notification mechanism for informing the
  #       caller of a deserialization routine for unexpected fields.
  #       The chonicles import in this module should be removed.
  debug "JSON field not recognized by the current version of nwaku. Consider upgrading",
        fieldName, typeName = typetraits.name(typeof value)


proc decodeJsonString*[T](t: typedesc[T],
                          data: JsonString,
                          requireAllFields = true): Result[T, cstring] =
  try:
    ok(RestJson.decode(string(data), T,
                       requireAllFields = requireAllFields,
                       allowUnknownFields = true))
  except SerializationError:
    # TODO: Do better error reporting here
    err("Unable to deserialize data")


proc encodeIntoJsonString*(value: auto): Result[string, cstring] =
  var encoded: string
  try:
    var stream = memoryOutput()
    var writer = JsonWriter[RestJson].init(stream)
    writer.writeValue(value)
    encoded = stream.getOutput(string)
  except SerializationError, IOError:
    # TODO: Do better error reporting here
    return err("unable to serialize data")

  ok(encoded)

proc encodeIntoJsonBytes*(value: auto): Result[seq[byte], cstring] =
  var encoded: seq[byte]
  try:
    var stream = memoryOutput()
    var writer = JsonWriter[RestJson].init(stream)
    writer.writeValue(value)
    encoded = stream.getOutput(seq[byte])
  except SerializationError, IOError:
    # TODO: Do better error reporting here
    return err("unable to serialize data")

  ok(encoded)