import std/net

type NatStrategy* = enum
  NatAny
  NatUpnp
  NatPmp
  NatNone

type NatConfig* = object
  case hasExtIp*: bool
  of true: extIp*: IpAddress
  of false: nat*: NatStrategy
