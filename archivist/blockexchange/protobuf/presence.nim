{.push raises: [].}

import pkg/questionable
import ./blockexc

import ../../blocktype

export questionable
export BlockPresenceType

type
  PresenceMessage* = blockexc.BlockPresence
  Presence* = object
    address*: BlockAddress
    have*: bool

func init*(_: type Presence, message: PresenceMessage): ?Presence =
  some Presence(
    address: message.address, have: message.`type` == BlockPresenceType.Have
  )

func init*(_: type PresenceMessage, presence: Presence): PresenceMessage =
  PresenceMessage(
    address: presence.address,
    `type`: if presence.have: BlockPresenceType.Have else: BlockPresenceType.DontHave,
  )
