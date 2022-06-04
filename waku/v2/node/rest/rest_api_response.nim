import std/typetraits
import chronicles,
    stew/results,
    presto/common
import "."/json_serdes


const MIMETYPE_JSON* = MediaType.init("application/json")

proc jsonResponse*(t: typedesc[RestApiResponse], data: auto, status: HttpCode = Http200): Result[RestApiResponse, cstring] =
  # TODO: Check with Jaceck (@arnetheduck) why I cannot use the `?` operator here
  let res = encodeIntoJsonBytes(data)
  if res.isErr():
    return err(res.error())

  ok(RestApiResponse.response(res.get(), status, $MIMETYPE_JSON))

proc internalServerError*(t: typedesc[RestApiResponse]): RestApiResponse =
  RestApiResponse.error(Http500)