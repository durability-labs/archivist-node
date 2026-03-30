import std/net
import pkg/questionable/results
import pkg/taskpools
import pkg/chronos
import pkg/libp2p/multiaddress
import pkg/archivist/nat
import ../asynctest

suite "NAT Traversal":
  let config = NatConfig.externalIp(parseIpAddress("8.8.8.8"))

  var nat: NatTraversal

  setup:
    nat = !NatTraversal.new(config, TaskPool.new(2))
    await nat.start()

  teardown:
    await nat.stop()

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
        MultiAddress.init("/ip4/8.8.8.8/tcp/5000").get(),
        MultiAddress.init("/ip4/8.8.8.8/tcp/5000").get(),
        MultiAddress.init("/ip4/8.8.8.8/udp/1234").get(),
      ]

    var mapped: seq[MultiAddress]

    await nat.map(addresses) do(result: seq[MultiAddress]):
      mapped = result

    check mapped == expected
