{.push raises: [Defect].}

import 
  std/[options, tables],
  sqlite3_abi,
  stew/[byteutils, results],
  chronicles,
  ./message_store,
  ../sqlite,
  ../../../protocol/waku_message,
  ../../../protocol/waku_store/waku_store,
  ../../../utils/pagination,
  ../../../utils/time

export sqlite

logScope:
  topics = "wakuMessageStore"

const TABLE_TITLE = "Message"
const MaxStoreOverflow = 1.3 # has to be > 1.0

# The code in this file is an adaptation of the Sqlite KV Store found in nim-eth.
# https://github.com/status-im/nim-eth/blob/master/eth/db/kvstore_sqlite3.nim

type
  # WakuMessageStore implements auto deletion as follows:
  # The sqlite DB will store up to `storeMaxLoad = storeCapacity` * `MaxStoreOverflow` messages, giving an overflow window of (storeCapacity*MaxStoreOverflow - storeCapacity).
  # In case of an overflow, messages are sorted by `receiverTimestamp` and the oldest ones are deleted. The number of messages that get deleted is (overflow window / 2) = deleteWindow,
  # bringing the total number of stored messages back to `storeCapacity + (overflow window / 2)`. The rationale for batch deleting is efficiency.
  # We keep half of the overflow window in addition to `storeCapacity` because we delete the oldest messages with respect to `receiverTimestamp` instead of `senderTimestamp`.
  # `ReceiverTimestamp` is guaranteed to be set, while senders could omit setting `senderTimestamp`.
  # However, `receiverTimestamp` can differ from node to node for the same message.
  # So sorting by `receiverTimestamp` might (slightly) prioritize some actually older messages and we compensate that by keeping half of the overflow window.
  WakuMessageStore* = ref object of MessageStore
    database*: SqliteDatabase
    numMessages: int
    storeCapacity: int # represents both the number of messages that are persisted in the sqlite DB (excl. the overflow window explained above), and the number of messages that get loaded via `getAll`.
    storeMaxLoad: int  # = storeCapacity * MaxStoreOverflow
    deleteWindow: int  # = (storeCapacity * MaxStoreOverflow - storeCapacity)/2; half of the overflow window, the amount of messages deleted when overflow occurs
    isSqliteOnly: bool 
 
proc messageCount(db: SqliteDatabase): MessageStoreResult[int64] =
  var numMessages: int64
  proc handler(s: ptr sqlite3_stmt) = 
    numMessages = sqlite3_column_int64(s, 0)
  let countQuery = "SELECT COUNT(*) FROM " & TABLE_TITLE
  let countRes = db.query(countQuery, handler)
  if countRes.isErr:
    return err("failed to count number of messages in DB")
  ok(numMessages)

proc deleteOldest(db: WakuMessageStore): MessageStoreResult[void] =
  var deleteQuery = "DELETE FROM " & TABLE_TITLE & " " &
                          "WHERE id NOT IN " &
                              "(SELECT id FROM " & TABLE_TITLE & " " &
                                "ORDER BY receiverTimestamp DESC " &
                                "LIMIT " & $(db.storeCapacity + db.deleteWindow) & ")"
  let res = db.database.query(deleteQuery, proc(s: ptr sqlite3_stmt) = discard)
  if res.isErr:
    return err(res.error)
  db.numMessages = db.storeCapacity + db.deleteWindow # sqlite3 DELETE does not return the number of deleted rows; Ideally we would subtract the number of actually deleted messages. We could run a separate COUNT.

  info "Oldest messages deleted from DB due to overflow.", storeCapacity=db.storeCapacity, maxStore=db.storeMaxLoad, deleteWindow=db.deleteWindow
  when defined(debug):
    let numMessages = messageCount(db.database).get() # requires another SELECT query, so only run in debug mode
    debug "Number of messages left after delete operation.", messagesLeft=numMessages

  # reduce the size of the DB file after the delete operation. See: https://www.sqlite.org/lang_vacuum.html
  let resVacuum = db.database.query("vacuum", proc(s: ptr sqlite3_stmt) = discard)
  if resVacuum.isErr:
    return err("vacuum after delete was not successful: " & resVacuum.error)

  ok()

proc init*(T: type WakuMessageStore, db: SqliteDatabase, storeCapacity: int = 50000, isSqliteOnly = false): MessageStoreResult[T] =
  ## Table is the SQL query for creating the messages Table.
  ## It contains:
  ##  - 4-Byte ContentTopic stored as an Integer
  ##  - Payload stored as a blob

  let prepare = db.prepareStmt("""
    CREATE TABLE IF NOT EXISTS """ & TABLE_TITLE & """ (
        id BLOB,
        receiverTimestamp """ & TIMESTAMP_TABLE_TYPE & """ NOT NULL,
        contentTopic BLOB NOT NULL,
        pubsubTopic BLOB NOT NULL,
        payload BLOB,
        version INTEGER NOT NULL,
        senderTimestamp """ & TIMESTAMP_TABLE_TYPE & """  NOT NULL,
        CONSTRAINT messageIndex PRIMARY KEY (senderTimestamp, id, pubsubTopic)
    ) WITHOUT ROWID;
    """, NoParams, void)

  if prepare.isErr:
    return err("failed to prepare")

  let prepareRes = prepare.value.exec(())
  if prepareRes.isErr:
    return err("failed to exec")

  let numMessages = messageCount(db).get()
  debug "number of messages in sqlite database", messageNum=numMessages

  # add index on receiverTimestamp
  let addIndexStmt = "CREATE INDEX IF NOT EXISTS i_rt ON " & TABLE_TITLE & "(receiverTimestamp);"
  let resIndex = db.query(addIndexStmt, proc(s: ptr sqlite3_stmt) = discard)
  if resIndex.isErr:
    return err("Could not establish index on receiverTimestamp: " & resIndex.error)

  let storeMaxLoad = int(float(storeCapacity) * MaxStoreOverflow)
  let deleteWindow = int(float(storeMaxLoad - storeCapacity) / 2)
  let wms = WakuMessageStore(database: db,
                      numMessages: int(numMessages),
                      storeCapacity: storeCapacity,
                      storeMaxLoad: storeMaxLoad,
                      deleteWindow: deleteWindow,
                      isSqliteOnly: isSqliteOnly)

  # if the in-memory store is used and if the loaded db is already over max load, delete the oldest messages before returning the WakuMessageStore object
  if not isSqliteOnly and wms.numMessages >= wms.storeMaxLoad:
    let res = wms.deleteOldest()
    if res.isErr: return err("deleting oldest messages failed")

  ok(wms)


method put*(db: WakuMessageStore, cursor: Index, message: WakuMessage, pubsubTopic: string): MessageStoreResult[void] =
  ## Adds a message to the storage.
  ##
  ## **Example:**
  ##
  ## .. code-block::
  ##   let res = db.put(message)
  ##   if res.isErr:
  ##     echo "error"
  ## 
  let prepare = db.database.prepareStmt(
    "INSERT INTO " & TABLE_TITLE & " (id, receiverTimestamp, contentTopic, payload, pubsubTopic, version, senderTimestamp) VALUES (?, ?, ?, ?, ?, ?, ?);",
    (seq[byte], Timestamp, seq[byte], seq[byte], seq[byte], int64, Timestamp),
    void
  )

  if prepare.isErr:
    return err("failed to prepare")

  let res = prepare.value.exec((@(cursor.digest.data), cursor.receiverTime, message.contentTopic.toBytes(), message.payload, pubsubTopic.toBytes(), int64(message.version), message.timestamp))
  if res.isErr:
    return err("failed")

  db.numMessages += 1
  # if the in-memory store is used and if the loaded db is already over max load, delete the oldest messages
  if not db.isSqliteOnly and db.numMessages >= db.storeMaxLoad:
    let res = db.deleteOldest()
    if res.isErr: return err("deleting oldest failed")

  ok()

method getAll*(db: WakuMessageStore, onData: message_store.DataProc): MessageStoreResult[bool] =
  ## Retrieves `storeCapacity` many  messages from the storage.
  ##
  ## **Example:**
  ##
  ## .. code-block::
  ##   proc data(timestamp: uint64, msg: WakuMessage) =
  ##     echo cast[string](msg.payload)
  ##
  ##   let res = db.get(data)
  ##   if res.isErr:
  ##     echo "error"
  var gotMessages = false
  proc msg(s: ptr sqlite3_stmt) =
    gotMessages = true
    let
      receiverTimestamp = column_timestamp(s, 0)

      topic = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 1))
      topicLength = sqlite3_column_bytes(s,1)
      contentTopic = ContentTopic(string.fromBytes(@(toOpenArray(topic, 0, topicLength-1))))

      p = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 2))
      length = sqlite3_column_bytes(s, 2)
      payload = @(toOpenArray(p, 0, length-1))

      pubsubTopicPointer = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 3))
      pubsubTopicLength = sqlite3_column_bytes(s,3)
      pubsubTopic = string.fromBytes(@(toOpenArray(pubsubTopicPointer, 0, pubsubTopicLength-1)))

      version = sqlite3_column_int64(s, 4)

      senderTimestamp = column_timestamp(s, 5)


      # TODO retrieve the version number
    onData(Timestamp(receiverTimestamp),
           WakuMessage(contentTopic: contentTopic, payload: payload , version: uint32(version), timestamp: Timestamp(senderTimestamp)), 
                       pubsubTopic)

  var selectQuery = "SELECT receiverTimestamp, contentTopic, payload, pubsubTopic, version, senderTimestamp " &
                    "FROM " & TABLE_TITLE & " " & 
                    "ORDER BY receiverTimestamp ASC"

  # Apply limit. This works because SQLITE will perform the time-based ORDER BY before applying the limit.
  selectQuery &= " LIMIT " & $db.storeCapacity &
                 " OFFSET cast((SELECT count(*)  FROM " & TABLE_TITLE & ") AS INT) - " & $db.storeCapacity # offset = total_row_count - limit
  
  let res = db.database.query(selectQuery, msg)
  if res.isErr:
    return err(res.error)

  ok gotMessages


method getPage*(db: WakuMessageStore,
              pred: QueryFilterMatcher,
              pagingInfo: PagingInfo):
             (seq[WakuMessage], PagingInfo, HistoryResponseError) =
  ## Get a single page of history matching the predicate and
  ## adhering to the pagingInfo parameters
  
  trace "getting page from SQLite DB", pagingInfo=pagingInfo

  let
    maxPageSize = if pagingInfo.pageSize == 0 or pagingInfo.pageSize > MaxPageSize: MaxPageSize # Used default MaxPageSize for invalid pagingInfos
                  else: pagingInfo.pageSize

  var cursor = pagingInfo.cursor 

  var messages: seq[WakuMessage]
  var
    lastIndex: Index
    numRecordsVisitedPage: uint64 = 0  # number of DB records visited during retrieving the last page from the DB
    numRecordsVisitedTotal: uint64 = 0 # number of DB records visited in total

  proc msg(s: ptr sqlite3_stmt) = # this is the actual onData proc that is passed to the query proc (the message store adds one indirection)
    let
      receiverTimestamp = column_timestamp(s, 0)

      topic = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 1))
      topicLength = sqlite3_column_bytes(s,1)
      contentTopic = ContentTopic(string.fromBytes(@(toOpenArray(topic, 0, topicLength-1))))

      p = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 2))
      length = sqlite3_column_bytes(s, 2)
      payload = @(toOpenArray(p, 0, length-1))

      pubsubTopicPointer = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 3))
      pubsubTopicLength = sqlite3_column_bytes(s,3)
      pubsubTopic = string.fromBytes(@(toOpenArray(pubsubTopicPointer, 0, pubsubTopicLength-1)))

      version = sqlite3_column_int64(s, 4)

      senderTimestamp = column_timestamp(s, 5)
      retMsg = WakuMessage(contentTopic: contentTopic, payload: payload, version: uint32(version), timestamp: Timestamp(senderTimestamp))
      # TODO: we should consolidate WakuMessage, Index, and IndexedWakuMessage; reason: avoid unnecessary copying and recalculation
      # TODO: retrieve digest from DB
      index = retMsg.computeIndex(receiverTimestamp, pubsubTopic)
      indexedWakuMsg = IndexedWakuMessage(msg: retMsg, index: index, pubsubTopic: pubsubTopic)

    lastIndex = index
    numRecordsVisitedPage += 1
    try:
      if pred(indexedWakuMsg): #TODO throws unknown exception
        messages.add(retMsg)
    except:
      # TODO properly handle this exception
      quit 1

  # TODO: deduplicate / condense the following 4 DB query strings
  # If no index has been set in pagingInfo, start with the first message (or the last in case of backwards direction)
  if cursor == Index(): ## TODO: pagingInfo.cursor should be an Option. We shouldn't rely on empty initialisation to determine if set or not!
    let noCursorQuery = if pagingInfo.direction == PagingDirection.FORWARD:
        "SELECT receiverTimestamp, contentTopic, payload, pubsubTopic, version, senderTimestamp " &
        "FROM " & TABLE_TITLE & " " &
        "ORDER BY senderTimestamp, receiverTimestamp, id, pubsubTopic " &
        "LIMIT " & $maxPageSize & ";"
    else:
        "SELECT receiverTimestamp, contentTopic, payload, pubsubTopic, version, senderTimestamp " &
        "FROM " & TABLE_TITLE & " " &
        "ORDER BY senderTimestamp DESC, receiverTimestamp DESC, id DESC, pubsubTopic DESC " &
        "LIMIT " & $maxPageSize & ";"

    let res = db.database.query(noCursorQuery, msg)
    if res.isErr:
      # TODO properly handle this exception
      quit 1
    numRecordsVisitedTotal = numRecordsVisitedPage
    numRecordsVisitedPage = 0
    cursor = lastIndex

  let preparedPageQuery = if pagingInfo.direction == PagingDirection.FORWARD:
      db.database.prepareStmt(
        "SELECT receiverTimestamp, contentTopic, payload, pubsubTopic, version, senderTimestamp " &
        "FROM " & TABLE_TITLE & " " &
        "WHERE (senderTimestamp, id, pubsubTopic) > (?, ?, ?)" &
        "ORDER BY senderTimestamp, id, receiverTimestamp, pubsubTopic " &
        "LIMIT " & $maxPageSize & ";",
        (Timestamp, seq[byte], seq[byte]),
        (Timestamp, seq[byte], seq[byte], seq[byte], int64, Timestamp),
      )
    else:
      db.database.prepareStmt(
        "SELECT receiverTimestamp, contentTopic, payload, pubsubTopic, version, senderTimestamp " &
        "FROM " & TABLE_TITLE & " " &
        "WHERE (senderTimestamp, id, pubsubTopic) < (?, ?, ?)" &
        "ORDER BY senderTimestamp DESC, receiverTimestamp DESC, id DESC, pubsubTopic DESC " &
        "LIMIT " & $maxPageSize & ";",
        (Timestamp, seq[byte], seq[byte]),
        (Timestamp, seq[byte], seq[byte], seq[byte], int64, Timestamp),
      )

  if preparedPageQuery.isErr:
    # return err("failed to prepare page query")
    quit 1 # TODO

  # TODO: DoS attack migration against: sending a lot of queries with sparse (or non-matching) filters making the store node run through the whole DB. Even worse with pageSize = 1.
  while uint64(messages.len) < maxPageSize:
    let res = preparedPageQuery.value.exec((cursor.senderTime, @(cursor.digest.data), cursor.pubsubTopic.toBytes()), msg)
    if res.isErr:
      # return err("failed")
      quit 1 # TODO
    numRecordsVisitedTotal += numRecordsVisitedPage
    if numRecordsVisitedPage == 0: break # we are at the end of the DB (find more efficient/integrated solution to track that event)
    numRecordsVisitedPage = 0
    cursor = lastIndex

  let outPagingInfo = PagingInfo(pageSize: messages.len.uint,
                             cursor: lastIndex,
                             direction: pagingInfo.direction)

  let historyResponseError = if numRecordsVisitedTotal == 0: HistoryResponseError.INVALID_CURSOR # Index is not in DB (also if queried Index points to last entry)
    else: HistoryResponseError.NONE

  return (messages, outPagingInfo, historyResponseError) # TODO: use canonical way of handling errors




method getPage*(db: WakuMessageStore,
              pagingInfo: PagingInfo):
             (seq[WakuMessage], PagingInfo, HistoryResponseError) =
  ## Get a single page of history without filtering.
  ## Adhere to the pagingInfo parameters
  
  proc predicate(i: IndexedWakuMessage): bool = true # no filtering

  return getPage(db, predicate, pagingInfo)




proc close*(db: WakuMessageStore) = 
  ## Closes the database.
  db.database.close()
