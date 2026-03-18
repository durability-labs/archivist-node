import std/net
import pkg/unittest2
import pkg/questionable
import pkg/questionable/results
import archivist/conf/nat
import archivist/nat/config

suite "NAT CLI option":
  test "parses strategy 'any'":
    check parseNatConfig("any") == success NatConfig.anyStrategy()

  test "parses strategy 'any' with a custom NAT-PMP gateway":
    let gateway = parseIpAddress("1.2.3.4")
    check parseNatConfig("any:1.2.3.4") == success NatConfig.anyStrategy(gateway)

  test "parses strategy 'none'":
    check parseNatConfig("none") == success NatConfig.noNat()

  test "parses UPnP strategy":
    check parseNatConfig("upnp") == success NatConfig.upnp()

  test "parses NAT-PMP strategy":
    check parseNatConfig("pmp") == success NatConfig.pmp()

  test "parses NAT-PMP strategy with a custom gateway":
    let gateway = parseIpAddress("1.2.3.4")
    check parseNatConfig("pmp:1.2.3.4") == success NatConfig.pmp(gateway)

  test "parses manually set external IP":
    let ip = parseIpAddress("1.2.3.4")
    check parseNatConfig("extip:1.2.3.4") == success NatConfig.externalIp(ip)

  test "rejects invalid strategy":
    let parsed = parseNatConfig("foo")
    check parsed.errorOption .? msg == some "Not a valid NAT option: foo"

  test "rejects invalid gateway":
    let parsed = parseNatConfig("any:foo")
    check parsed.errorOption .? msg == some "Not a valid IP address: foo"

  test "rejects invalid external ip address":
    let parsed = parseNatConfig("extip:foo")
    check parsed.errorOption .? msg == some "Not a valid IP address: foo"

  test "rejects missing external ip address":
    let parsed = parseNatConfig("extip")
    check parsed.errorOption .? msg == some "Missing external IP address"
