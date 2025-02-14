{.push raises: [Defect].}

import
  std/[hashes, options, tables, strutils, sequtils, os],
  chronos, chronicles, metrics,
  stew/shims/net as stewNet,
  stew/byteutils,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto,
  libp2p/protocols/ping,
  libp2p/protocols/pubsub/[gossipsub, rpc/messages],
  libp2p/nameresolving/nameresolver,
  libp2p/[builders, multihash],
  libp2p/transports/[transport, tcptransport, wstransport],
  ../protocol/[waku_relay, waku_message],
  ../protocol/waku_store/waku_store,
  ../protocol/waku_swap/waku_swap,
  ../protocol/waku_filter/waku_filter,
  ../protocol/waku_lightpush/waku_lightpush,
  ../protocol/waku_rln_relay/[waku_rln_relay_types], 
  ../utils/[peers, requests, wakuswitch, wakuenr],
  ./storage/migration/migration_types,
  ./peer_manager/peer_manager,
  ./dnsdisc/waku_dnsdisc,
  ./discv5/waku_discv5

export
  builders,
  waku_relay, waku_message,
  waku_store,
  waku_swap,
  waku_filter,
  waku_lightpush,
  waku_rln_relay_types

when defined(rln):
  import
    libp2p/protocols/pubsub/rpc/messages,
    libp2p/protocols/pubsub/pubsub,
    web3,
    ../protocol/waku_rln_relay/[rln, waku_rln_relay_utils]

declarePublicCounter waku_node_messages, "number of messages received", ["type"]
declarePublicGauge waku_node_filters, "number of content filter subscriptions"
declarePublicGauge waku_node_errors, "number of wakunode errors", ["type"]
declarePublicCounter waku_node_conns_initiated, "number of connections initiated by this node", ["source"]

logScope:
  topics = "wakunode"

# Default clientId
const clientId* = "Nimbus Waku v2 node"

# Default topic
const defaultTopic* = "/waku/2/default-waku/proto"

# Default Waku Filter Timeout
const WakuFilterTimeout: Duration = 1.days


# key and crypto modules different
type
  KeyPair* = crypto.KeyPair
  PublicKey* = crypto.PublicKey
  PrivateKey* = crypto.PrivateKey

  # XXX: Weird type, should probably be using pubsub Topic object name?
  Topic* = string
  Message* = seq[byte]

  WakuInfo* = object
    # NOTE One for simplicity, can extend later as needed
    listenAddresses*: seq[string]
    enrUri*: string
    #multiaddrStrings*: seq[string]

  # NOTE based on Eth2Node in NBC eth2_network.nim
  WakuNode* = ref object of RootObj
    peerManager*: PeerManager
    switch*: Switch
    wakuRelay*: WakuRelay
    wakuStore*: WakuStore
    wakuFilter*: WakuFilter
    wakuSwap*: WakuSwap
    wakuRlnRelay*: WakuRLNRelay
    wakuLightPush*: WakuLightPush
    enr*: enr.Record
    libp2pPing*: Ping
    filters*: Filters
    rng*: ref BrHmacDrbgContext
    wakuDiscv5*: WakuDiscoveryV5
    announcedAddresses* : seq[MultiAddress]
    started*: bool # Indicates that node has started listening

proc protocolMatcher(codec: string): Matcher =
  ## Returns a protocol matcher function for the provided codec
  proc match(proto: string): bool {.gcsafe.} =
    ## Matches a proto with any postfix to the provided codec.
    ## E.g. if the codec is `/vac/waku/filter/2.0.0` it matches the protos:
    ## `/vac/waku/filter/2.0.0`, `/vac/waku/filter/2.0.0-beta3`, `/vac/waku/filter/2.0.0-actualnonsense`
    return proto.startsWith(codec)

  return match

proc removeContentFilters(filters: var Filters, contentFilters: seq[ContentFilter]) {.gcsafe.} =
  # Flatten all unsubscribe topics into single seq
  let unsubscribeTopics = contentFilters.mapIt(it.contentTopic)
  
  debug "unsubscribing", unsubscribeTopics=unsubscribeTopics

  var rIdToRemove: seq[string] = @[]
  for rId, f in filters.mpairs:
    # Iterate filter entries to remove matching content topics
  
    # make sure we delete the content filter
    # if no more topics are left
    f.contentFilters.keepIf(proc (cf: auto): bool = cf.contentTopic notin unsubscribeTopics)

    if f.contentFilters.len == 0:
      rIdToRemove.add(rId)

  # make sure we delete the filter entry
  # if no more content filters left
  for rId in rIdToRemove:
    filters.del(rId)
  
  debug "filters modified", filters=filters

proc updateSwitchPeerInfo(node: WakuNode) =
  ## TODO: remove this when supported upstream
  ## 
  ## nim-libp2p does not yet support announcing addrs
  ## different from bound addrs.
  ## 
  ## This is a temporary workaround to replace
  ## peer info addrs in switch to announced
  ## addresses.
  ## 
  ## WARNING: this should only be called once the switch
  ## has already been started.
  
  if node.announcedAddresses.len > 0:
    node.switch.peerInfo.addrs = node.announcedAddresses

template ip4TcpEndPoint(address, port): MultiAddress =
  MultiAddress.init(address, tcpProtocol, port)

template dns4Ma(dns4DomainName: string): MultiAddress =
  MultiAddress.init("/dns4/" & dns4DomainName).tryGet()

template tcpPortMa(port: Port): MultiAddress =
  MultiAddress.init("/tcp/" & $port).tryGet()

template dns4TcpEndPoint(dns4DomainName: string, port: Port): MultiAddress =
  dns4Ma(dns4DomainName) & tcpPortMa(port)

template wsFlag(wssEnabled: bool): MultiAddress =
  if wssEnabled: MultiAddress.init("/wss").tryGet()
  else: MultiAddress.init("/ws").tryGet()

proc new*(T: type WakuNode, nodeKey: crypto.PrivateKey,
    bindIp: ValidIpAddress, bindPort: Port,
    extIp = none(ValidIpAddress), extPort = none(Port),
    peerStorage: PeerStorage = nil,
    maxConnections = builders.MaxConnections,
    wsBindPort: Port = (Port)8000,
    wsEnabled: bool = false,
    wssEnabled: bool = false,
    secureKey: string = "",
    secureCert: string = "",
    wakuFlags = none(WakuEnrBitfield),
    nameResolver: NameResolver = nil,
    sendSignedPeerRecord = false,
    dns4DomainName = none(string),
    discv5UdpPort = none(Port)
    ): T 
    {.raises: [Defect, LPError, IOError, TLSStreamProtocolError].} =
  ## Creates a Waku Node.
  ##
  ## Status: Implemented.
  ##

  ## Initialize addresses
  let
    # Bind addresses
    hostAddress = ip4TcpEndPoint(bindIp, bindPort)
    wsHostAddress = if wsEnabled or wssEnabled: some(ip4TcpEndPoint(bindIp, wsbindPort) & wsFlag(wssEnabled))
                    else: none(MultiAddress)

  # Setup external addresses, if available
  var
    hostExtAddress, wsExtAddress = none(MultiAddress)
  
  if (dns4DomainName.isSome()):
    # Use dns4 for externally announced addresses
    hostExtAddress = some(dns4TcpEndPoint(dns4DomainName.get(), extPort.get()))

    if (wsHostAddress.isSome()):
      wsExtAddress = some(dns4TcpEndPoint(dns4DomainName.get(), wsBindPort) & wsFlag(wssEnabled))
  else:
    # No public domain name, use ext IP if available
    if extIp.isSome() and extPort.isSome():
      hostExtAddress = some(ip4TcpEndPoint(extIp.get(), extPort.get()))

      if (wsHostAddress.isSome()):
        wsExtAddress = some(ip4TcpEndPoint(extIp.get(), wsBindPort) & wsFlag(wssEnabled))

  var announcedAddresses: seq[MultiAddress]
  if hostExtAddress.isSome:
    announcedAddresses.add(hostExtAddress.get())
  else:
    announcedAddresses.add(hostAddress) # We always have at least a bind address for the host
    
  if wsExtAddress.isSome:
    announcedAddresses.add(wsExtAddress.get())
  elif wsHostAddress.isSome:
    announcedAddresses.add(wsHostAddress.get())
  
  ## Initialize peer
  let
    rng = crypto.newRng()
    enrIp = if extIp.isSome(): extIp
            else: some(bindIp)
    enrTcpPort = if extPort.isSome(): extPort
                 else: some(bindPort)
    enrMultiaddrs = if wsExtAddress.isSome: @[wsExtAddress.get()] # Only add ws/wss to `multiaddrs` field
                    elif wsHostAddress.isSome: @[wsHostAddress.get()]
                    else: @[]
    enr = initEnr(nodeKey,
                  enrIp,
                  enrTcpPort,
                  discv5UdpPort,
                  wakuFlags,
                  enrMultiaddrs)
  
  info "Initializing networking", addrs=announcedAddresses

  var switch = newWakuSwitch(some(nodekey),
    hostAddress,
    wsHostAddress,
    transportFlags = {ServerFlags.ReuseAddr},
    rng = rng, 
    maxConnections = maxConnections,
    wssEnabled = wssEnabled,
    secureKeyPath = secureKey,
    secureCertPath = secureCert,
    nameResolver = nameResolver,
    sendSignedPeerRecord = sendSignedPeerRecord)
  
  let wakuNode = WakuNode(
    peerManager: PeerManager.new(switch, peerStorage),
    switch: switch,
    rng: rng,
    enr: enr,
    filters: initTable[string, Filter](),
    announcedAddresses: announcedAddresses
  )

  return wakuNode

proc subscribe(node: WakuNode, topic: Topic, handler: Option[TopicHandler]) =
  if node.wakuRelay.isNil:
    error "Invalid API call to `subscribe`. WakuRelay not mounted."
    # @TODO improved error handling
    return

  info "subscribe", topic=topic

  proc defaultHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
    # A default handler should be registered for all topics
    trace "Hit default handler", topic=topic, data=data

    let msg = WakuMessage.init(data)
    if msg.isOk():
      # Notify mounted protocols of new message
      if (not node.wakuFilter.isNil):
        await node.wakuFilter.handleMessage(topic, msg.value())
      
      if (not node.wakuStore.isNil):
        await node.wakuStore.handleMessage(topic, msg.value())

      waku_node_messages.inc(labelValues = ["relay"])

  let wakuRelay = node.wakuRelay

  if topic notin PubSub(wakuRelay).topics:
    # Add default handler only for new topics
    debug "Registering default handler", topic=topic
    wakuRelay.subscribe(topic, defaultHandler)

  if handler.isSome:
    debug "Registering handler", topic=topic
    wakuRelay.subscribe(topic, handler.get())

proc subscribe*(node: WakuNode, topic: Topic, handler: TopicHandler) =
  ## Subscribes to a PubSub topic. Triggers handler when receiving messages on
  ## this topic. TopicHandler is a method that takes a topic and some data.
  ##
  ## NOTE The data field SHOULD be decoded as a WakuMessage.
  ## Status: Implemented.
  node.subscribe(topic, some(handler))

proc subscribe*(node: WakuNode, request: FilterRequest, handler: ContentFilterHandler) {.async, gcsafe.} =
  ## Registers for messages that match a specific filter. Triggers the handler whenever a message is received.
  ## FilterHandler is a method that takes a MessagePush.
  ##
  ## Status: Implemented.
  
  # Sanity check for well-formed subscribe FilterRequest
  doAssert(request.subscribe, "invalid subscribe request")
  
  info "subscribe content", filter=request

  var id = generateRequestId(node.rng)

  if node.wakuFilter.isNil == false:
    let idOpt = await node.wakuFilter.subscribe(request)

    if idOpt.isSome():
      # Subscribed successfully.
      id = idOpt.get()
    else:
      # Failed to subscribe
      error "remote subscription to filter failed", filter = request
      waku_node_errors.inc(labelValues = ["subscribe_filter_failure"])

  # Register handler for filter, whether remote subscription succeeded or not
  node.filters[id] = Filter(contentFilters: request.contentFilters, handler: handler, pubSubTopic: request.pubSubTopic)
  waku_node_filters.set(node.filters.len.int64)

proc unsubscribe*(node: WakuNode, topic: Topic, handler: TopicHandler) =
  ## Unsubscribes a handler from a PubSub topic.
  ##
  ## Status: Implemented.
  if node.wakuRelay.isNil:
    error "Invalid API call to `unsubscribe`. WakuRelay not mounted."
    # @TODO improved error handling
    return
  
  info "unsubscribe", topic=topic

  let wakuRelay = node.wakuRelay
  wakuRelay.unsubscribe(@[(topic, handler)])

proc unsubscribeAll*(node: WakuNode, topic: Topic) =
  ## Unsubscribes all handlers registered on a specific PubSub topic.
  ##
  ## Status: Implemented.
  
  if node.wakuRelay.isNil:
    error "Invalid API call to `unsubscribeAll`. WakuRelay not mounted."
    # @TODO improved error handling
    return
  
  info "unsubscribeAll", topic=topic

  let wakuRelay = node.wakuRelay
  wakuRelay.unsubscribeAll(topic)
  

proc unsubscribe*(node: WakuNode, request: FilterRequest) {.async, gcsafe.} =
  ## Unsubscribe from a content filter.
  ##
  ## Status: Implemented.
  
  # Sanity check for well-formed unsubscribe FilterRequest
  doAssert(request.subscribe == false, "invalid unsubscribe request")
  
  info "unsubscribe content", filter=request
  
  await node.wakuFilter.unsubscribe(request)
  node.filters.removeContentFilters(request.contentFilters)

  waku_node_filters.set(node.filters.len.int64)


proc publish*(node: WakuNode, topic: Topic, message: WakuMessage) {.async, gcsafe.} =
  ## Publish a `WakuMessage` to a PubSub topic. `WakuMessage` should contain a
  ## `contentTopic` field for light node functionality. This field may be also
  ## be omitted.
  ##
  ## Status: Implemented.
    
  if node.wakuRelay.isNil:
    error "Invalid API call to `publish`. WakuRelay not mounted. Try `lightpush` instead."
    # @TODO improved error handling
    return

  let wakuRelay = node.wakuRelay
  trace "publish", topic=topic, contentTopic=message.contentTopic
  var publishingMessage = message

  let data = message.encode().buffer

  discard await wakuRelay.publish(topic, data)

proc lightpush*(node: WakuNode, topic: Topic, message: WakuMessage, handler: PushResponseHandler) {.async, gcsafe.} =
  ## Pushes a `WakuMessage` to a node which relays it further on PubSub topic.
  ## Returns whether relaying was successful or not in `handler`.
  ## `WakuMessage` should contain a `contentTopic` field for light node
  ## functionality. This field may be also be omitted.
  ##
  ## Status: Implemented.

  debug "Publishing with lightpush", topic=topic, contentTopic=message.contentTopic

  let rpc = PushRequest(pubSubTopic: topic, message: message)
  await node.wakuLightPush.request(rpc, handler)

proc query*(node: WakuNode, query: HistoryQuery, handler: QueryHandlerFunc) {.async, gcsafe.} =
  ## Queries known nodes for historical messages. Triggers the handler whenever a response is received.
  ## QueryHandlerFunc is a method that takes a HistoryResponse.
  ##
  ## Status: Implemented.

  # TODO Once waku swap is less experimental, this can simplified
  if node.wakuSwap.isNil:
    debug "Using default query"
    await node.wakuStore.query(query, handler)
  else:
    debug "Using SWAPAccounting query"
    # TODO wakuSwap now part of wakuStore object
    await node.wakuStore.queryWithAccounting(query, handler)

proc resume*(node: WakuNode, peerList: Option[seq[RemotePeerInfo]] = none(seq[RemotePeerInfo])) {.async, gcsafe.} =
  ## resume proc retrieves the history of waku messages published on the default waku pubsub topic since the last time the waku node has been online 
  ## for resume to work properly the waku node must have the store protocol mounted in the full mode (i.e., persisting messages)
  ## messages are stored in the the wakuStore's messages field and in the message db
  ## the offline time window is measured as the difference between the current time and the timestamp of the most recent persisted waku message 
  ## an offset of 20 second is added to the time window to count for nodes asynchrony
  ## peerList indicates the list of peers to query from. The history is fetched from the first available peer in this list. Such candidates should be found through a discovery method (to be developed).
  ## if no peerList is passed, one of the peers in the underlying peer manager unit of the store protocol is picked randomly to fetch the history from. 
  ## The history gets fetched successfully if the dialed peer has been online during the queried time window.
  
  if not node.wakuStore.isNil:
    let retrievedMessages = await node.wakuStore.resume(peerList)
    if retrievedMessages.isOk:
      info "the number of retrieved messages since the last online time: ", number=retrievedMessages.value

# TODO Extend with more relevant info: topics, peers, memory usage, online time, etc
proc info*(node: WakuNode): WakuInfo =
  ## Returns information about the Node, such as what multiaddress it can be reached at.
  ##
  ## Status: Implemented.
  ##

  let peerInfo = node.switch.peerInfo
  
  var listenStr : seq[string]
  for address in node.announcedAddresses:
    var fulladdr = $address & "/p2p/" & $peerInfo.peerId
    listenStr &= fulladdr
  let enrUri = if node.wakuDiscV5 != nil: node.wakuDiscV5.protocol.localNode.record.toUri()
               else: node.enr.toUri()
  let wakuInfo = WakuInfo(listenAddresses: listenStr, enrUri: enrUri)
  return wakuInfo

proc mountFilter*(node: WakuNode, filterTimeout: Duration = WakuFilterTimeout) {.raises: [Defect, KeyError, LPError]} =
  info "mounting filter"
  proc filterHandler(requestId: string, msg: MessagePush)
    {.async, gcsafe, raises: [Defect, KeyError].} =
    
    info "push received"
    for message in msg.messages:
      node.filters.notify(message, requestId) # Trigger filter handlers on a light node

      if not node.wakuStore.isNil and (requestId in node.filters):
        let pubSubTopic = node.filters[requestId].pubSubTopic
        await node.wakuStore.handleMessage(pubSubTopic, message)

      waku_node_messages.inc(labelValues = ["filter"])

  node.wakuFilter = WakuFilter.init(node.peerManager, node.rng, filterHandler, filterTimeout)
  node.switch.mount(node.wakuFilter, protocolMatcher(WakuFilterCodec))

# NOTE: If using the swap protocol, it must be mounted before store. This is
# because store is using a reference to the swap protocol.
proc mountSwap*(node: WakuNode, swapConfig: SwapConfig = SwapConfig.init()) {.raises: [Defect, LPError].} =
  info "mounting swap", mode = $swapConfig.mode
  node.wakuSwap = WakuSwap.init(node.peerManager, node.rng, swapConfig)
  node.switch.mount(node.wakuSwap, protocolMatcher(WakuSwapCodec))
  # NYI - Do we need this?
  #node.subscriptions.subscribe(WakuSwapCodec, node.wakuSwap.subscription())

proc mountStore*(node: WakuNode, store: MessageStore = nil, persistMessages: bool = false, capacity = DefaultStoreCapacity, isSqliteOnly = false) {.raises: [Defect, LPError].} =
  info "mounting store"

  if node.wakuSwap.isNil:
    debug "mounting store without swap"
    node.wakuStore = WakuStore.init(node.peerManager, node.rng, store, persistMessages=persistMessages, capacity=capacity, isSqliteOnly=isSqliteOnly)
  else:
    debug "mounting store with swap"
    node.wakuStore = WakuStore.init(node.peerManager, node.rng, store, node.wakuSwap, persistMessages=persistMessages, capacity=capacity, isSqliteOnly=isSqliteOnly)

  node.switch.mount(node.wakuStore, protocolMatcher(WakuStoreCodec))
    
when defined(rln):
  proc addRLNRelayValidator*(node: WakuNode, pubsubTopic: string, contentTopic: ContentTopic, spamHandler: Option[SpamHandler] = none(SpamHandler)) =
    ## this procedure is a thin wrapper for the pubsub addValidator method
    ## it sets a validator for the waku messages published on the supplied pubsubTopic and contentTopic 
    ## if contentTopic is empty, then validation takes place for All the messages published on the given pubsubTopic
    ## the message validation logic is according to https://rfc.vac.dev/spec/17/
    proc validator(topic: string, message: messages.Message): Future[pubsub.ValidationResult] {.async.} =
      trace "rln-relay topic validator is called"
      let msg = WakuMessage.init(message.data) 
      if msg.isOk():
        let 
          wakumessage = msg.value()
          payload = string.fromBytes(wakumessage.payload)

        # check the contentTopic
        if (wakumessage.contentTopic != "") and (contentTopic != "") and (wakumessage.contentTopic != contentTopic):
          trace "content topic did not match:", contentTopic=wakumessage.contentTopic, payload=payload
          return pubsub.ValidationResult.Accept

        # validate the message
        let 
          validationRes = node.wakuRlnRelay.validateMessage(wakumessage)
          proof = toHex(wakumessage.proof.proof)
          epoch = fromEpoch(wakumessage.proof.epoch)
          root = toHex(wakumessage.proof.merkleRoot)
          shareX = toHex(wakumessage.proof.shareX)
          shareY = toHex(wakumessage.proof.shareY)
          nullifier = toHex(wakumessage.proof.nullifier)
        case validationRes:
          of Valid:
            debug "message validity is verified, relaying:",  contentTopic=wakumessage.contentTopic, epoch=epoch, timestamp=wakumessage.timestamp, payload=payload
            trace "message validity is verified, relaying:", proof=proof, root=root, shareX=shareX, shareY=shareY, nullifier=nullifier
            return pubsub.ValidationResult.Accept
          of Invalid:
            debug "message validity could not be verified, discarding:", contentTopic=wakumessage.contentTopic, epoch=epoch, timestamp=wakumessage.timestamp, payload=payload
            trace "message validity could not be verified, discarding:", proof=proof, root=root, shareX=shareX, shareY=shareY, nullifier=nullifier
            return pubsub.ValidationResult.Reject
          of Spam:
            debug "A spam message is found! yay! discarding:", contentTopic=wakumessage.contentTopic, epoch=epoch, timestamp=wakumessage.timestamp, payload=payload
            trace "A spam message is found! yay! discarding:", proof=proof, root=root, shareX=shareX, shareY=shareY, nullifier=nullifier
            if spamHandler.isSome:
               let handler = spamHandler.get
               handler(wakumessage)
            return pubsub.ValidationResult.Reject          
    # set a validator for the supplied pubsubTopic 
    let pb  = PubSub(node.wakuRelay)
    pb.addValidator(pubsubTopic, validator)

  proc mountRlnRelay*(node: WakuNode,
                      ethClientAddrOpt: Option[string] = none(string),
                      ethAccAddrOpt: Option[web3.Address] = none(web3.Address),
                      memContractAddOpt:  Option[web3.Address] = none(web3.Address),
                      groupOpt: Option[seq[IDCommitment]] = none(seq[IDCommitment]),
                      memKeyPairOpt: Option[MembershipKeyPair] = none(MembershipKeyPair),
                      memIndexOpt: Option[MembershipIndex] = none(MembershipIndex),
                      onchainMode: bool = true,
                      pubsubTopic: string,
                      contentTopic: ContentTopic,
                      spamHandler: Option[SpamHandler] = none(SpamHandler)) {.async.} =
    # TODO return a bool value to indicate the success of the call
    # check whether inputs are provided

    # relay protocol is the prerequisite of rln-relay
    if node.wakuRelay.isNil:
      error "Failed to mount WakuRLNRelay. Relay protocol is not mounted."
      return
    # check whether the pubsub topic is supported at the relay level
    if pubsubTopic notin node.wakuRelay.defaultTopics:
      error "Failed to mount WakuRLNRelay. The relay protocol does not support the configured pubsub topic.", pubsubTopic=pubsubTopic
      return
    if onchainMode:
      if memContractAddOpt.isNone():
        error "failed to mount rln relay: membership contract address is not provided"
        return
      if ethClientAddrOpt.isNone():
        error "failed to mount rln relay: Ethereum client address is not provided"
        return
      if ethAccAddrOpt.isNone():
        error "failed to mount rln relay: Ethereum account address is not provided"
        return
    else:
      if groupOpt.isNone():
        error "failed to mount rln relay:  group information is not provided"
        return

    if memKeyPairOpt.isNone():
      error "failed to mount rln relay: membership key of the node is not provided"
      return
    if memIndexOpt.isNone():
      error "failed to mount rln relay:  membership index is not provided"
      return
    
    var 
      ethClientAddr: string 
      ethAccAddr: web3.Address
      memContractAdd: web3.Address
    if onchainMode:
      ethClientAddr = ethClientAddrOpt.get()
      ethAccAddr = ethAccAddrOpt.get()
      memContractAdd = memContractAddOpt.get()

    let 
      group = groupOpt.get()
      memKeyPair = memKeyPairOpt.get()
      memIndex = memIndexOpt.get()

    # check the peer's index and the inclusion of user's identity commitment in the group
    doAssert((memKeyPair.idCommitment)  == group[int(memIndex)])

    # create an RLN instance
    var rlnInstance = createRLNInstance()
    doAssert(rlnInstance.isOk)
    var rln = rlnInstance.value

    # generate the membership keys if none is provided
    # in a happy path, this condition never gets through for a static group of users
    # the node should pass its keys i.e., memKeyPairOpt to the function
    if not memKeyPairOpt.isSome:
      let membershipKeyPair = rln.membershipKeyGen()
      # check whether keys are generated
      doAssert(membershipKeyPair.isSome())
      debug "the membership key for the rln relay is generated", idKey=membershipKeyPair.get().idKey.toHex, idCommitment=membershipKeyPair.get().idCommitment.toHex


    # add members to the Merkle tree
    for index in 0..group.len-1:
      let member = group[index]
      let member_is_added = rln.insertMember(member)
      doAssert(member_is_added)
    

    # create the WakuRLNRelay
    var rlnPeer = WakuRLNRelay(membershipKeyPair: memKeyPair,
      membershipIndex: memIndex,
      membershipContractAddress: memContractAdd,
      ethClientAddress: ethClientAddr,
      ethAccountAddress: ethAccAddr,
      rlnInstance: rln,
      pubsubTopic: pubsubTopic,
      contentTopic: contentTopic)

    if onchainMode:
      # register the rln-relay peer to the membership contract
      let isSuccessful = await rlnPeer.register()
      # check whether registration is done
      doAssert(isSuccessful)
      debug "peer is successfully registered into the membership contract"

    # adds a topic validator for the supplied pubsub topic at the relay protocol
    # messages published on this pubsub topic will be relayed upon a successful validation, otherwise they will be dropped
    # the topic validator checks for the correct non-spamming proof of the message
    addRLNRelayValidator(node, pubsubTopic, contentTopic, spamHandler)
    debug "rln relay topic validator is mounted successfully", pubsubTopic=pubsubTopic, contentTopic=contentTopic

    node.wakuRlnRelay = rlnPeer


proc startRelay*(node: WakuNode) {.async.} =
  if node.wakuRelay.isNil:
    trace "Failed to start relay. Not mounted."
    return

  ## Setup and start relay protocol
  info "starting relay"
  
  # Topic subscriptions
  for topic in node.wakuRelay.defaultTopics:
    node.subscribe(topic, none(TopicHandler))

  # Resume previous relay connections
  if node.peerManager.hasPeers(protocolMatcher(WakuRelayCodec)):
    info "Found previous WakuRelay peers. Reconnecting."
    
    # Reconnect to previous relay peers. This will respect a backoff period, if necessary
    let backoffPeriod = node.wakuRelay.parameters.pruneBackoff + chronos.seconds(BackoffSlackTime)

    await node.peerManager.reconnectPeers(WakuRelayCodec,
                                          protocolMatcher(WakuRelayCodec),
                                          backoffPeriod)
  
  # Start the WakuRelay protocol
  await node.wakuRelay.start()

  info "relay started successfully"

proc mountRelay*(node: WakuNode,
                 topics: seq[string] = newSeq[string](),
                 relayMessages = true,
                 triggerSelf = true,
                 peerExchangeHandler = none(RoutingRecordsHandler))
  # @TODO: Better error handling: CatchableError is raised by `waitFor`
  {.gcsafe, raises: [Defect, InitializationError, LPError, CatchableError].} =

  proc msgIdProvider(m: messages.Message): Result[MessageID, ValidationResult] =
    let mh = MultiHash.digest("sha2-256", m.data)
    if mh.isOk():
      return ok(mh[].data.buffer)
    else:
      return ok(($m.data.hash).toBytes())

  let wakuRelay = WakuRelay.init(
    switch = node.switch,
    msgIdProvider = msgIdProvider,
    triggerSelf = triggerSelf,
    sign = false,
    verifySignature = false,
    maxMessageSize = MaxWakuMessageSize
  )
  
  info "mounting relay", relayMessages=relayMessages

  ## The default relay topics is the union of
  ## all configured topics plus the hard-coded defaultTopic(s)
  wakuRelay.defaultTopics = concat(@[defaultTopic], topics)

  ## Add peer exchange handler
  if peerExchangeHandler.isSome():
    wakuRelay.parameters.enablePX = true # Feature flag for peer exchange in nim-libp2p
    wakuRelay.routingRecordsHandler.add(peerExchangeHandler.get())

  node.switch.mount(wakuRelay, protocolMatcher(WakuRelayCodec))

  if relayMessages:
    ## Some nodes may choose not to have the capability to relay messages (e.g. "light" nodes).
    ## All nodes, however, currently require WakuRelay, regardless of desired capabilities.
    ## This is to allow protocol stream negotation with relay-capable nodes to succeed.
    ## Here we mount relay on the switch only, but do not proceed to subscribe to any pubsub
    ## topics. We also never start the relay protocol. node.wakuRelay remains nil.
    ## @TODO: in future, this WakuRelay dependency will be removed completely  
    node.wakuRelay = wakuRelay
        
  info "relay mounted successfully"

  if node.started:
    # Node has started already. Let's start relay too.
    waitFor node.startRelay()

proc mountLightPush*(node: WakuNode) {.raises: [Defect, LPError].} =
  info "mounting light push"

  if node.wakuRelay.isNil:
    debug "mounting lightpush without relay"
    node.wakuLightPush = WakuLightPush.init(node.peerManager, node.rng, nil)
  else:
    debug "mounting lightpush with relay"
    node.wakuLightPush = WakuLightPush.init(node.peerManager, node.rng, nil, node.wakuRelay)
  
  node.switch.mount(node.wakuLightPush, protocolMatcher(WakuLightPushCodec))

proc mountLibp2pPing*(node: WakuNode) {.raises: [Defect, LPError].} =
  info "mounting libp2p ping protocol"

  try:
    node.libp2pPing = Ping.new(rng = node.rng)
  except Exception as e:
    # This is necessary as `Ping.new*` does not have explicit `raises` requirement
    # @TODO: remove exception handling once explicit `raises` in ping module
    raise newException(LPError, "Failed to initialize ping protocol")

  node.switch.mount(node.libp2pPing)

proc keepaliveLoop(node: WakuNode, keepalive: chronos.Duration) {.async.} =
  while node.started:
    # Keep all connected peers alive while running
    trace "Running keepalive"

    # First get a list of connected peer infos
    let peers = node.peerManager.peers()
                                .filterIt(node.peerManager.connectedness(it.peerId) == Connected)
                                .mapIt(it.toRemotePeerInfo())

    # Attempt to retrieve and ping the active outgoing connection for each peer
    for peer in peers:
      let connOpt = await node.peerManager.dialPeer(peer, PingCodec)

      if connOpt.isNone:
        # @TODO more sophisticated error handling here
        debug "failed to connect to remote peer", peer=peer
        waku_node_errors.inc(labelValues = ["keep_alive_failure"])
        return

      discard await node.libp2pPing.ping(connOpt.get())  # Ping connection
    
    await sleepAsync(keepalive)

proc startKeepalive*(node: WakuNode) =
  let defaultKeepalive = 2.minutes # 20% of the default chronosstream timeout duration

  info "starting keepalive", keepalive=defaultKeepalive

  asyncSpawn node.keepaliveLoop(defaultKeepalive)

## Helpers
proc connectToNode(n: WakuNode, remotePeer: RemotePeerInfo, source = "api") {.async.} =
  ## `source` indicates source of node addrs (static config, api call, discovery, etc)
  info "Connecting to node", remotePeer = remotePeer, source = source
  
  # NOTE This is dialing on WakuRelay protocol specifically
  info "Attempting dial", wireAddr = remotePeer.addrs[0], peerId = remotePeer.peerId
  let connOpt = await n.peerManager.dialPeer(remotePeer, WakuRelayCodec)
  
  if connOpt.isSome():
    info "Successfully connected to peer", wireAddr = remotePeer.addrs[0], peerId = remotePeer.peerId
    waku_node_conns_initiated.inc(labelValues = [source])
  else:
    error "Failed to connect to peer", wireAddr = remotePeer.addrs[0], peerId = remotePeer.peerId
    waku_node_errors.inc(labelValues = ["conn_init_failure"])

proc setStorePeer*(n: WakuNode, address: string) {.raises: [Defect, ValueError, LPError].} =
  info "Set store peer", address = address

  let remotePeer = parseRemotePeerInfo(address)

  n.wakuStore.setPeer(remotePeer)

proc setFilterPeer*(n: WakuNode, address: string) {.raises: [Defect, ValueError, LPError].} =
  info "Set filter peer", address = address

  let remotePeer = parseRemotePeerInfo(address)

  n.wakuFilter.setPeer(remotePeer)

proc setLightPushPeer*(n: WakuNode, address: string) {.raises: [Defect, ValueError, LPError].} =
  info "Set lightpush peer", address = address

  let remotePeer = parseRemotePeerInfo(address)

  n.wakuLightPush.setPeer(remotePeer)

proc connectToNodes*(n: WakuNode, nodes: seq[string], source = "api") {.async.} =
  ## `source` indicates source of node addrs (static config, api call, discovery, etc)
  info "connectToNodes", len = nodes.len
  
  for nodeId in nodes:
    await connectToNode(n, parseRemotePeerInfo(nodeId), source)

  # The issue seems to be around peers not being fully connected when
  # trying to subscribe. So what we do is sleep to guarantee nodes are
  # fully connected.
  #
  # This issue was known to Dmitiry on nim-libp2p and may be resolvable
  # later.
  await sleepAsync(5.seconds)

proc connectToNodes*(n: WakuNode, nodes: seq[RemotePeerInfo], source = "api") {.async.} =
  ## `source` indicates source of node addrs (static config, api call, discovery, etc)
  info "connectToNodes", len = nodes.len
  
  for remotePeerInfo in nodes:
    await connectToNode(n, remotePeerInfo, source)

  # The issue seems to be around peers not being fully connected when
  # trying to subscribe. So what we do is sleep to guarantee nodes are
  # fully connected.
  #
  # This issue was known to Dmitiry on nim-libp2p and may be resolvable
  # later.
  await sleepAsync(5.seconds)

proc runDiscv5Loop(node: WakuNode) {.async.} =
  ## Continuously add newly discovered nodes
  ## using Node Discovery v5
  if (node.wakuDiscv5.isNil):
    warn "Trying to run discovery v5 while it's disabled"
    return

  info "Starting discovery loop"

  while node.wakuDiscv5.listening:
    trace "Running discovery loop"
    ## Query for a random target and collect all discovered nodes
    ## @TODO: we could filter nodes here
    let discoveredPeers = await node.wakuDiscv5.findRandomPeers()
    if discoveredPeers.isOk:
      ## Let's attempt to connect to peers we
      ## have not encountered before
      
      trace "Discovered peers", count=discoveredPeers.get().len()

      let newPeers = discoveredPeers.get().filterIt(
        not node.switch.peerStore[AddressBook].contains(it.peerId))

      if newPeers.len > 0:
        debug "Connecting to newly discovered peers", count=newPeers.len()
        await connectToNodes(node, newPeers, "discv5")

    # Discovery `queryRandom` can have a synchronous fast path for example
    # when no peers are in the routing table. Don't run it in continuous loop.
    #
    # Also, give some time to dial the discovered nodes and update stats etc
    await sleepAsync(5.seconds)

proc startDiscv5*(node: WakuNode): Future[bool] {.async.} =
  ## Start Discovery v5 service
  
  info "Starting discovery v5 service"
  
  if not node.wakuDiscv5.isNil:
    ## First start listening on configured port
    try:
      trace "Start listening on discv5 port"
      node.wakuDiscv5.open()
    except CatchableError:
      error "Failed to start discovery service. UDP port may be already in use"
      return false
  
    ## Start Discovery v5
    trace "Start discv5 service"
    node.wakuDiscv5.start()
    trace "Start discovering new peers using discv5"
    
    asyncSpawn node.runDiscv5Loop()

    debug "Successfully started discovery v5 service"
    info "Discv5: discoverable ENR ", enr = node.wakuDiscV5.protocol.localNode.record.toUri()
    return true

  return false

proc stopDiscv5*(node: WakuNode): Future[bool] {.async.} =
  ## Stop Discovery v5 service
  
  if not node.wakuDiscv5.isNil:
    info "Stopping discovery v5 service"
    
    ## Stop Discovery v5 process and close listening port
    if node.wakuDiscv5.listening:
      trace "Stop listening on discv5 port"
      await node.wakuDiscv5.closeWait()

    debug "Successfully stopped discovery v5 service"

proc start*(node: WakuNode) {.async.} =
  ## Starts a created Waku Node and
  ## all its mounted protocols.
  ##
  ## Status: Implemented.
  
  await node.switch.start()
  
  # TODO Get this from WakuNode obj
  let peerInfo = node.switch.peerInfo
  info "PeerInfo", peerId = peerInfo.peerId, addrs = peerInfo.addrs
  var listenStr = ""
  for address in node.announcedAddresses:
    var fulladdr = "[" & $address & "/p2p/" & $peerInfo.peerId & "]" 
    listenStr &= fulladdr
                
  ## XXX: this should be /ip4..., / stripped?
  info "Listening on", full = listenStr
  info "DNS: discoverable ENR ", enr = node.enr.toUri()

  ## Update switch peer info with announced addrs
  node.updateSwitchPeerInfo()

  if not node.wakuRelay.isNil:
    await node.startRelay()
  
  info "Node started successfully"
  node.started = true

proc stop*(node: WakuNode) {.async.} =
  if not node.wakuRelay.isNil:
    await node.wakuRelay.stop()
  
  if not node.wakuDiscv5.isNil:
    discard await node.stopDiscv5()

  await node.switch.stop()

  node.started = false

{.pop.} # @TODO confutils.nim(775, 17) Error: can raise an unlisted exception: ref IOError
when isMainModule:
  ## Node setup happens in 6 phases:
  ## 1. Set up storage
  ## 2. Initialize node
  ## 3. Mount and initialize configured protocols
  ## 4. Start node and mounted protocols
  ## 5. Start monitoring tools and external interfaces
  ## 6. Setup graceful shutdown hooks

  import
    confutils, toml_serialization,
    system/ansi_c,
    libp2p/nameresolving/dnsresolver,
    ../../common/utils/nat,
    ./config,
    ./waku_setup,
    ./storage/message/waku_message_store,
    ./storage/peer/waku_peer_storage
  
  logScope:
    topics = "wakunode.setup"
  
  ###################
  # Setup functions #
  ###################

  # 1/7 Setup storage
  proc setupStorage(conf: WakuNodeConf):
    SetupResult[tuple[pStorage: WakuPeerStorage, mStorage: WakuMessageStore]] =

    ## Setup a SQLite Database for a wakunode based on a supplied
    ## configuration file and perform all necessary migration.
    ## 
    ## If config allows, return peer storage and message store
    ## for use elsewhere.
    
    var
      sqliteDatabase: SqliteDatabase
      storeTuple: tuple[pStorage: WakuPeerStorage, mStorage: WakuMessageStore]

    # Setup DB
    if conf.dbPath != "":
      let dbRes = SqliteDatabase.init(conf.dbPath)
      if dbRes.isErr:
        warn "failed to init database", err = dbRes.error
        waku_node_errors.inc(labelValues = ["init_db_failure"])
        return err("failed to init database")
      else:
        sqliteDatabase = dbRes.value

    if not sqliteDatabase.isNil and (conf.persistPeers or conf.persistMessages):
      # Database initialized. Let's set it up
      sqliteDatabase.runMigrations(conf) # First migrate what we have

      if conf.persistPeers:
        # Peer persistence enable. Set up Peer table in storage
        let res = WakuPeerStorage.new(sqliteDatabase)

        if res.isErr:
          warn "failed to init new WakuPeerStorage", err = res.error
          waku_node_errors.inc(labelValues = ["init_store_failure"])
        else:
          storeTuple.pStorage = res.value
      
      if conf.persistMessages:
        # Historical message persistence enable. Set up Message table in storage
        let res = WakuMessageStore.init(sqliteDatabase, conf.storeCapacity, conf.sqliteStore, conf.sqliteRetentionTime)

        if res.isErr:
          warn "failed to init WakuMessageStore", err = res.error
          waku_node_errors.inc(labelValues = ["init_store_failure"])
        else:
          storeTuple.mStorage = res.value
    
    ok(storeTuple)

  # 2/7 Retrieve dynamic bootstrap nodes
  proc retrieveDynamicBootstrapNodes(conf: WakuNodeConf): SetupResult[seq[RemotePeerInfo]] =
    
    if conf.dnsDiscovery and conf.dnsDiscoveryUrl != "":
      # DNS discovery
      debug "Discovering nodes using Waku DNS discovery", url=conf.dnsDiscoveryUrl

      var nameServers: seq[TransportAddress]
      for ip in conf.dnsDiscoveryNameServers:
        nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

      let dnsResolver = DnsResolver.new(nameServers)

      proc resolver(domain: string): Future[string] {.async, gcsafe.} =
        trace "resolving", domain=domain
        let resolved = await dnsResolver.resolveTxt(domain)
        return resolved[0] # Use only first answer
      
      var wakuDnsDiscovery = WakuDnsDiscovery.init(conf.dnsDiscoveryUrl,
                                                   resolver)
      if wakuDnsDiscovery.isOk:
        return wakuDnsDiscovery.get().findPeers()
          .mapErr(proc (e: cstring): string = $e)
      else:
        warn "Failed to init Waku DNS discovery"

    debug "No method for retrieving dynamic bootstrap nodes specified."
    ok(newSeq[RemotePeerInfo]()) # Return an empty seq by default

  # 3/7 Initialize node
  proc initNode(conf: WakuNodeConf,
                pStorage: WakuPeerStorage = nil,
                dynamicBootstrapNodes: openArray[RemotePeerInfo] = @[]): SetupResult[WakuNode] =
    
    ## Setup a basic Waku v2 node based on a supplied configuration
    ## file. Optionally include persistent peer storage.
    ## No protocols are mounted yet.

    var dnsResolver: DnsResolver
    if conf.dnsAddrs:
      # Support for DNS multiaddrs
      var nameServers: seq[TransportAddress]
      for ip in conf.dnsAddrsNameServers:
        nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53
      
      dnsResolver = DnsResolver.new(nameServers)
    
    let 
      ## `udpPort` is only supplied to satisfy underlying APIs but is not
      ## actually a supported transport for libp2p traffic.
      udpPort = conf.tcpPort
      (extIp, extTcpPort, extUdpPort) = setupNat(conf.nat,
                                                clientId,
                                                Port(uint16(conf.tcpPort) + conf.portsShift),
                                                Port(uint16(udpPort) + conf.portsShift))

      dns4DomainName = if conf.dns4DomainName != "": some(conf.dns4DomainName)
                       else: none(string)
      
      discv5UdpPort = if conf.discv5Discovery: some(Port(uint16(conf.discv5UdpPort) + conf.portsShift))
                      else: none(Port)

      ## @TODO: the NAT setup assumes a manual port mapping configuration if extIp config is set. This probably
      ## implies adding manual config item for extPort as well. The following heuristic assumes that, in absence of manual
      ## config, the external port is the same as the bind port.
      extPort = if (extIp.isSome() or dns4DomainName.isSome()) and extTcpPort.isNone():
                  some(Port(uint16(conf.tcpPort) + conf.portsShift))
                else:
                  extTcpPort
      
      wakuFlags = initWakuFlags(conf.lightpush,
                                conf.filter,
                                conf.store,
                                conf.relay)

      node = WakuNode.new(conf.nodekey,
                          conf.listenAddress, Port(uint16(conf.tcpPort) + conf.portsShift), 
                          extIp, extPort,
                          pStorage,
                          conf.maxConnections.int,
                          Port(uint16(conf.websocketPort) + conf.portsShift),
                          conf.websocketSupport,
                          conf.websocketSecureSupport,
                          conf.websocketSecureKeyPath,
                          conf.websocketSecureCertPath,
                          some(wakuFlags),
                          dnsResolver,
                          conf.relayPeerExchange, # We send our own signed peer record when peer exchange enabled
                          dns4DomainName,
                          discv5UdpPort
                          )
    
    if conf.discv5Discovery:
      let
        discoveryConfig = DiscoveryConfig.init(
          conf.discv5TableIpLimit, conf.discv5BucketIpLimit, conf.discv5BitsPerHop)

      # select dynamic bootstrap nodes that have an ENR containing a udp port.
      # Discv5 only supports UDP https://github.com/ethereum/devp2p/blob/master/discv5/discv5-theory.md)
      var discv5BootstrapEnrs: seq[enr.Record]
      for n in dynamicBootstrapNodes:
        if n.enr.isSome():
          let
            enr = n.enr.get()
            tenrRes = enr.toTypedRecord()
          if tenrRes.isOk() and (tenrRes.get().udp.isSome() or tenrRes.get().udp6.isSome()):
            discv5BootstrapEnrs.add(enr)
    
      # parse enrURIs from the configuration and add the resulting ENRs to the discv5BootstrapEnrs seq
      for enrUri in conf.discv5BootstrapNodes:
        addBootstrapNode(enrUri, discv5BootstrapEnrs)

      node.wakuDiscv5 = WakuDiscoveryV5.new(
        extIP, extPort, discv5UdpPort,
        conf.listenAddress,
        discv5UdpPort.get(),
        discv5BootstrapEnrs,
        conf.discv5EnrAutoUpdate,
        keys.PrivateKey(conf.nodekey.skkey),
        wakuFlags,
        [], # Empty enr fields, for now
        node.rng,
        discoveryConfig
      )
    
    ok(node)

  # 4/7 Mount and initialize configured protocols
  proc setupProtocols(node: WakuNode,
                      conf: WakuNodeConf,
                      mStorage: WakuMessageStore = nil): SetupResult[bool] =
    
    ## Setup configured protocols on an existing Waku v2 node.
    ## Optionally include persistent message storage.
    ## No protocols are started yet.
    
    # Mount relay on all nodes
    var peerExchangeHandler = none(RoutingRecordsHandler)
    if conf.relayPeerExchange:
      proc handlePeerExchange(peer: PeerId, topic: string,
                              peers: seq[RoutingRecordsPair]) {.gcsafe, raises: [Defect].} =
        ## Handle peers received via gossipsub peer exchange
        # TODO: Only consider peers on pubsub topics we subscribe to
        let exchangedPeers = peers.filterIt(it.record.isSome()) # only peers with populated records
                                  .mapIt(toRemotePeerInfo(it.record.get()))
        
        debug "connecting to exchanged peers", src=peer, topic=topic, numPeers=exchangedPeers.len

        # asyncSpawn, as we don't want to block here
        asyncSpawn node.connectToNodes(exchangedPeers, "peer exchange")
    
      peerExchangeHandler = some(handlePeerExchange)

    mountRelay(node,
               conf.topics.split(" "),
               relayMessages = conf.relay, # Indicates if node is capable to relay messages
               peerExchangeHandler = peerExchangeHandler) 
    
    # Keepalive mounted on all nodes
    mountLibp2pPing(node)
    
    when defined(rln): 
      if conf.rlnRelay:
        info "WakuRLNRelay is enabled"

        # set up rln relay inputs
        let (groupOpt, memKeyPairOpt, memIndexOpt) = rlnRelaySetUp(conf.rlnRelayMemIndex)
        if memIndexOpt.isNone:
          error "failed to mount WakuRLNRelay"
        else:
          # mount rlnrelay in offline mode (for now)
          waitFor node.mountRlnRelay(groupOpt = groupOpt, memKeyPairOpt = memKeyPairOpt, memIndexOpt= memIndexOpt, onchainMode = false, pubsubTopic = conf.rlnRelayPubsubTopic, contentTopic = conf.rlnRelayContentTopic)

          info "membership id key", idkey=memKeyPairOpt.get().idKey.toHex
          info "membership id commitment key", idCommitmentkey=memKeyPairOpt.get().idCommitment.toHex

          # check the correct construction of the tree by comparing the calculated root against the expected root
          # no error should happen as it is already captured in the unit tests
          # TODO have added this check to account for unseen corner cases, will remove it later 
          let 
            root = node.wakuRlnRelay.rlnInstance.getMerkleRoot.value.toHex() 
            expectedRoot = STATIC_GROUP_MERKLE_ROOT
          if root != expectedRoot:
            error "root mismatch: something went wrong not in Merkle tree construction"
          debug "the calculated root", root
          info "WakuRLNRelay is mounted successfully", pubsubtopic=conf.rlnRelayPubsubTopic, contentTopic=conf.rlnRelayContentTopic

    if conf.swap:
      mountSwap(node)
      # TODO Set swap peer, for now should be same as store peer

    # Store setup
    if (conf.storenode != "") or (conf.store):
      mountStore(node, mStorage, conf.persistMessages, conf.storeCapacity, conf.sqliteStore)

      if conf.storenode != "":
        setStorePeer(node, conf.storenode)

    # NOTE Must be mounted after relay
    if (conf.lightpushnode != "") or (conf.lightpush):
      mountLightPush(node)

      if conf.lightpushnode != "":
        setLightPushPeer(node, conf.lightpushnode)
    
    # Filter setup. NOTE Must be mounted after relay
    if (conf.filternode != "") or (conf.filter):
      mountFilter(node, filterTimeout = chronos.seconds(conf.filterTimeout))

      if conf.filternode != "":
        setFilterPeer(node, conf.filternode)
    
    ok(true) # Success

  # 5/7 Start node and mounted protocols
  proc startNode(node: WakuNode, conf: WakuNodeConf,
    dynamicBootstrapNodes: seq[RemotePeerInfo] = @[]): SetupResult[bool] =
    ## Start a configured node and all mounted protocols.
    ## Resume history, connect to static nodes and start
    ## keep-alive, if configured.
    
    # Start Waku v2 node
    waitFor node.start()

    # Start discv5 and connect to discovered nodes
    if conf.discv5Discovery:
      if not waitFor node.startDiscv5():
        error "could not start Discovery v5"
  
    # Resume historical messages, this has to be called after the node has been started
    if conf.store and conf.persistMessages:
      waitFor node.resume()
    
    # Connect to configured static nodes
    if conf.staticnodes.len > 0:
      waitFor connectToNodes(node, conf.staticnodes, "static")
    
    info "Connecting to dynamic bootstrap peers"
    waitFor connectToNodes(node, dynamicBootstrapNodes, "dynamic bootstrap")
    
    # Start keepalive, if enabled
    if conf.keepAlive:
      node.startKeepalive()
    
    ok(true) # Success

  # 6/7 Start monitoring tools and external interfaces
  proc startExternal(node: WakuNode, conf: WakuNodeConf): SetupResult[bool] =
    ## Start configured external interfaces and monitoring tools
    ## on a Waku v2 node, including the RPC API and metrics
    ## monitoring ports.
    
    if conf.rpc:
      startRpc(node, conf.rpcAddress, Port(conf.rpcPort + conf.portsShift), conf)

    if conf.metricsLogging:
      startMetricsLog()

    if conf.metricsServer:
      startMetricsServer(conf.metricsServerAddress,
        Port(conf.metricsServerPort + conf.portsShift))
    
    ok(true) # Success

  {.push warning[ProveInit]: off.}
  let conf = try:
    WakuNodeConf.load(
      secondarySources = proc (conf: WakuNodeConf, sources: auto) =
        if conf.configFile.isSome:
          sources.addConfigFile(Toml, conf.configFile.get)
    )
  except CatchableError as err:
    error "Failure while loading the configuration: \n", err_msg=err.msg
    quit 1 # if we don't leave here, the initialization of conf does not work in the success case
  {.pop.}

  # if called with --version, print the version and quit
  if conf.version:
    const git_version {.strdefine.} = "n/a"
    echo "version / git commit hash: ", git_version
    quit(QuitSuccess)
  
  var
    node: WakuNode  # This is the node we're going to setup using the conf

  ##############
  # Node setup #
  ##############
  
  debug "1/7 Setting up storage"
  
  var
    pStorage: WakuPeerStorage
    mStorage: WakuMessageStore
  
  let setupStorageRes = setupStorage(conf)

  if setupStorageRes.isErr:
    error "1/7 Setting up storage failed. Continuing without storage."
  else:
    (pStorage, mStorage) = setupStorageRes.get()

  debug "2/7 Retrieve dynamic bootstrap nodes"
  
  var dynamicBootstrapNodes: seq[RemotePeerInfo]
  let dynamicBootstrapNodesRes = retrieveDynamicBootstrapNodes(conf)
  if dynamicBootstrapNodesRes.isErr:
    warn "2/7 Retrieving dynamic bootstrap nodes failed. Continuing without dynamic bootstrap nodes."
  else:
    dynamicBootstrapNodes = dynamicBootstrapNodesRes.get()

  debug "3/7 Initializing node"

  let initNodeRes = initNode(conf, pStorage, dynamicBootstrapNodes)

  if initNodeRes.isErr:
    error "3/7 Initializing node failed. Quitting."
    quit(QuitFailure)
  else:
    node = initNodeRes.get()

  debug "4/7 Mounting protocols"

  let setupProtocolsRes = setupProtocols(node, conf, mStorage)

  if setupProtocolsRes.isErr:
    error "4/7 Mounting protocols failed. Continuing in current state."

  debug "5/7 Starting node and mounted protocols"
  
  let startNodeRes = startNode(node, conf, dynamicBootstrapNodes)

  if startNodeRes.isErr:
    error "5/7 Starting node and mounted protocols failed. Continuing in current state."

  debug "6/7 Starting monitoring and external interfaces"

  let startExternalRes = startExternal(node, conf)

  if startExternalRes.isErr:
    error "6/7 Starting monitoring and external interfaces failed. Continuing in current state."

  debug "7/7 Setting up shutdown hooks"

  # 7/7 Setup graceful shutdown hooks
  ## Setup shutdown hooks for this process.
  ## Stop node gracefully on shutdown.
  
  # Handle Ctrl-C SIGINT
  proc handleCtrlC() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      setupForeignThreadGc()
    info "Shutting down after receiving SIGINT"
    waitFor node.stop()
    quit(QuitSuccess)
  
  setControlCHook(handleCtrlC)

  # Handle SIGTERM
  when defined(posix):
    proc handleSigterm(signal: cint) {.noconv.} =
      info "Shutting down after receiving SIGTERM"
      waitFor node.stop()
      quit(QuitSuccess)
    
    c_signal(SIGTERM, handleSigterm)
  
  debug "Node setup complete"

  runForever()
