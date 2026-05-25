import std/net
import pkg/questionable/results
import pkg/taskpools
import pkg/chronos
import pkg/libp2p/multiaddress
import pkg/archivist/nat
import ../asynctest

suite "NAT Traversal":
  let externalConfig = NatConfig.externalIp(parseIpAddress("8.8.8.8"))
  let noNatConfig = NatConfig.noNat()

  test "discovery addresses derive UDP multiaddrs from direct IPs":
    let announceAddresses =
      @[
        MultiAddress.init("/ip4/10.0.0.1/tcp/4000").get(),
        MultiAddress.init("/ip4/10.0.0.1/tcp/5000").get(),
        MultiAddress.init("/ip6/2001:db8::1/tcp/4000").get(),
        MultiAddress.init("/dns4/example.com/tcp/4000").get(),
      ]

    let expected =
      @[
        MultiAddress.init("/ip4/10.0.0.1/udp/30303").get(),
        MultiAddress.init("/ip6/2001:db8::1/udp/30303").get(),
      ]

    check discoveryAddresses(announceAddresses, Port(30303)) == expected

  test "no nat passes mapped addresses through unchanged":
    let addresses =
      @[
        MultiAddress.init("/ip4/127.0.0.1/tcp/5000").get(),
        MultiAddress.init("/ip4/0.0.0.0/tcp/5000").get(),
        MultiAddress.init("/ip4/192.168.1.1/tcp/5000").get(),
        MultiAddress.init("/ip6/::1/tcp/5000").get(),
        MultiAddress.init("/ip4/0.0.0.0/udp/1234").get(),
        MultiAddress.init("/ip6/::/udp/1234").get(),
        MultiAddress.init("/ip4/127.0.0.1/tcp/5000").get(),
      ]

    let expected =
      @[
        MultiAddress.init("/ip4/127.0.0.1/tcp/5000").get(),
        MultiAddress.init("/ip4/0.0.0.0/tcp/5000").get(),
        MultiAddress.init("/ip4/192.168.1.1/tcp/5000").get(),
        MultiAddress.init("/ip6/::1/tcp/5000").get(),
        MultiAddress.init("/ip4/0.0.0.0/udp/1234").get(),
        MultiAddress.init("/ip6/::/udp/1234").get(),
      ]

    var noNatTraversal = NatTraversal.new(noNatConfig, 20.minutes, TaskPool.new(2))
    await noNatTraversal.start()
    defer:
      await noNatTraversal.stop()

    var mapped: seq[MultiAddress]

    await noNatTraversal.mapPorts(addresses) do(result: seq[MultiAddress]):
      mapped = result

    check mapped == expected

  test "replaces internal IP address with external IP address":
    let addresses =
      @[
        MultiAddress.init("/ip4/127.0.0.1/tcp/5000").get(),
        MultiAddress.init("/ip4/0.0.0.0/tcp/5000").get(),
        MultiAddress.init("/ip4/192.168.1.1/tcp/5000").get(),
        MultiAddress.init("/ip4/0.0.0.0/udp/1234").get(),
      ]

    let expected =
      @[
        MultiAddress.init("/ip4/8.8.8.8/tcp/5000").get(),
        MultiAddress.init("/ip4/8.8.8.8/udp/1234").get(),
      ]

    var nat = NatTraversal.new(externalConfig, 20.minutes, TaskPool.new(2))
    await nat.start()
    defer:
      await nat.stop()

    var mapped: seq[MultiAddress]

    await nat.mapPorts(addresses) do(result: seq[MultiAddress]):
      mapped = result

    check mapped == expected
