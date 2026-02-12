import pkg/unittest2
import pkg/stew/bitseqs

import pkg/archivist/utils

suite "parseDuration":
  test "should parse durations":
    var res: Duration # caller must still know if 'b' refers to bytes|bits
    check parseDuration("10Hr", res) == 3
    check res == hours(10)
    check parseDuration("64min", res) == 3
    check res == minutes(64)
    check parseDuration("7m/block", res) == 2 # '/' stops parse
    check res == minutes(7) # 1 shl 30, forced binary metric
    check parseDuration("3d", res) == 2 # '/' stops parse
    check res == days(3) # 1 shl 30, forced binary metric

suite "combineSafe":
  test "should combine same-length BitSeqs":
    var a = BitSeq.init(4)
    a[0] = true
    a[2] = true
    var b = BitSeq.init(4)
    b[1] = true
    b[3] = true

    a.combineSafe(b)
    check a.len == 4
    check a[0] == true
    check a[1] == true
    check a[2] == true
    check a[3] == true

  test "should combine when tgt is longer":
    var tgt = BitSeq.init(8)
    tgt[0] = true
    tgt[5] = true
    var src = BitSeq.init(3)
    src[1] = true
    src[2] = true

    tgt.combineSafe(src)
    check tgt.len == 8
    check tgt[0] == true
    check tgt[1] == true
    check tgt[2] == true
    check tgt[3] == false
    check tgt[4] == false
    check tgt[5] == true
    check tgt[6] == false
    check tgt[7] == false

  test "should combine when tgt is shorter":
    var tgt = BitSeq.init(3)
    tgt[0] = true
    var src = BitSeq.init(8)
    src[1] = true
    src[5] = true
    src[7] = true

    tgt.combineSafe(src)
    check tgt.len == 8
    check tgt[0] == true
    check tgt[1] == true
    check tgt[2] == false
    check tgt[3] == false
    check tgt[4] == false
    check tgt[5] == true
    check tgt[6] == false
    check tgt[7] == true

  test "should handle empty src":
    var tgt = BitSeq.init(4)
    tgt[0] = true
    let src = BitSeq.init(0)

    tgt.combineSafe(src)
    check tgt.len == 4
    check tgt[0] == true

  test "should handle empty tgt":
    var tgt = BitSeq.init(0)
    var src = BitSeq.init(3)
    src[1] = true

    tgt.combineSafe(src)
    check tgt.len == 3
    check tgt[0] == false
    check tgt[1] == true
    check tgt[2] == false

  test "should not set marker bit as data":
    # Verify that src's SSZ marker bit does not leak as a data bit in tgt
    var tgt = BitSeq.init(8)
    var src = BitSeq.init(3)
    src[0] = true

    tgt.combineSafe(src)
    check tgt.len == 8
    check tgt[0] == true
    check tgt[1] == false
    check tgt[2] == false
    check tgt[3] == false # src's marker was at bit 3, must not appear as data
