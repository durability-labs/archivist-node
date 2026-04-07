import std/net
import pkg/questionable

type NatStrategy* {.pure.} = enum
  Any
  Upnp
  Pmp
  None
  ExternalIp

type NatConfig* = object
  case strategy: NatStrategy
  of NatStrategy.ExternalIp:
    ip: IpAddress
  of NatStrategy.Pmp, NatStrategy.Any:
    gateway: ?IpAddress
  else:
    discard

func upnp*(_: type NatConfig): NatConfig =
  NatConfig(strategy: NatStrategy.Upnp)

func pmp*(_: type NatConfig, gateway: ?IpAddress): NatConfig =
  NatConfig(strategy: NatStrategy.Pmp, gateway: gateway)

func pmp*(_: type NatConfig): NatConfig =
  NatConfig.pmp(gateway = IpAddress.none)

func pmp*(_: type NatConfig, gateway: IpAddress): NatConfig =
  NatConfig.pmp(gateway = some gateway)

func externalIp*(_: type NatConfig, ip: IpAddress): NatConfig =
  NatConfig(strategy: NatStrategy.ExternalIp, ip: ip)

func anyStrategy*(_: type NatConfig, gateway: ?IpAddress): NatConfig =
  NatConfig(strategy: NatStrategy.Any, gateway: gateway)

func anyStrategy*(_: type NatConfig): NatConfig =
  NatConfig.anyStrategy(gateway = IpAddress.none)

func anyStrategy*(_: type NatConfig, gateway: IpAddress): NatConfig =
  NatConfig.anyStrategy(gateway = some gateway)

func noNat*(_: type NatConfig): NatConfig =
  NatConfig(strategy: NatStrategy.None)

func strategy*(config: NatConfig): NatStrategy =
  config.strategy

func externalIp*(config: NatConfig): ?IpAddress =
  case config.strategy
  of NatStrategy.ExternalIp:
    some config.ip
  else:
    IpAddress.none

func gateway*(config: NatConfig): ?IpAddress =
  case config.strategy
  of NatStrategy.Pmp, NatStrategy.Any: config.gateway
  else: IpAddress.none

func `==`*(a, b: NatConfig): bool =
  if a.strategy != b.strategy:
    return false
  case a.strategy
  of NatStrategy.Any, NatStrategy.Pmp:
    a.gateway == b.gateway
  of NatStrategy.Upnp, NatStrategy.None:
    true
  of NatStrategy.ExternalIp:
    a.ip == b.ip
