## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/[oids, options]
import chronos
import chronicles
import bearssl
import nimcrypto/[utils, sha2, hmac]

import libp2p/stream/[connection]
import libp2p/protobuf/minprotobuf
import libp2p/utility
import libp2p/errors
import libp2p/crypto/[crypto, chacha20poly1305]

when defined(libp2p_dump):
  import libp2p/debugutils

logScope:
  topics = "nim-waku noise"

const
  # Empty is a special value which indicates k has not yet been initialized.
  EmptyKey = default(ChaChaPolyKey)

type
  ChaChaPolyCiphertext* = object
    data: seq[byte]
    tag: ChaChaPolyTag

  ChaChaPolyCipherState* = object
    k*: ChaChaPolyKey
    nonce*: ChaChaPolyNonce
    ad*: seq[byte]

  NoiseError* = object of LPError
  NoiseDecryptTagError* = object of NoiseError

# ChaChaPoly encryption
proc encrypt*(
    state: ChaChaPolyCipherState,
    plaintext: openArray[byte]): ChaChaPolyCiphertext
    {.noinit, raises: [Defect].} =
  #TODO: add padding
  result.data.add plaintext
  ChaChaPoly.encrypt(state.k, state.nonce, result.tag, result.data, state.ad)

proc decrypt*(
    state: ChaChaPolyCipherState, 
    ciphertext: ChaChaPolyCiphertext): seq[byte]
    {.raises: [Defect, NoiseDecryptTagError].} =
  var
    tagIn = ciphertext.tag
    tagOut: ChaChaPolyTag
  result = ciphertext.data
  ChaChaPoly.decrypt(state.k, state.nonce, tagOut, result, state.ad)
  #TODO: add unpadding
  trace "decrypt", tagIn = tagIn.shortLog, tagOut = tagOut.shortLog, nonce = state.nonce
  if tagIn != tagOut:
    debug "decrypt failed", result = shortLog(result)
    raise newException(NoiseDecryptTagError, "decrypt tag authentication failed.")


proc randomChaChaPolyCipherState*(rng: var BrHmacDrbgContext): ChaChaPolyCipherState =
  brHmacDrbgGenerate(rng, result.k)
  brHmacDrbgGenerate(rng, result.nonce)
  result.ad = newSeq[byte](32)
  brHmacDrbgGenerate(rng, result.ad)