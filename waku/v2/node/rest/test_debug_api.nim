import chronicles,
  stew/byteutils,
  unittest2,
  testutils,
  chronos, chronos/apps,
  presto
import "."/[rest_api_response, debug_api]


proc testRouter(): RestRouter =
  RestRouter.init do (pattern, value: string) -> int: return 1

# Copied from nim-presto's testroute.nim test file
proc sendMockRequest(router: RestRouter,
  meth: HttpMethod, url: string,
  body: Option[ContentBody]): Future[RestApiResponse] {.async.} =

  var uri = parseUri(url)
  var req = HttpRequestRef(meth: meth, version: HttpVersion11)
  let spath =
    if uri.path.startsWith("/"):
      SegmentedPath.init($meth & uri.path).get()
    else:
      SegmentedPath.init($meth & "/" & uri.path).get()
  let queryTable =
    block:
      var res = HttpTable.init()
      for key, value in queryParams(uri.query):
        res.add(key, value)
      res
  let route = router.getRoute(spath).get()
  let paramsTable = route.getParamsTable()

  return await route.callback(req, paramsTable, queryTable, body)

# Copied from nim-presto's testroute.nim test file
proc sendMockRequest(router: RestRouter,
  meth: HttpMethod, url: string): Future[RestApiResponse] {.async.} =

  return await sendMockRequest(router, meth, url, none(ContentBody))


suite "Rest API - Debug namespace":
  asyncTest "It should handle the InfoV1 requests":
    # Given
    var router = testRouter()
    installDebugApiHandlers(router)

    # When
    let resp = await router.sendMockRequest(MethodGet, "http://l.to" & ROUTE_DEBUG_INFOV1)

    # Then
    check:
      resp.status == Http200
      resp.kind == RestApiResponseKind.Content
      resp.content.contentType == $MIMETYPE_JSON
      resp.content.data == toBytes("""{"listenAddresses":["123"]}""" )
