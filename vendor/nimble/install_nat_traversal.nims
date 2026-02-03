template before(_, _) = discard

include "nat_traversal/nat_traversal.nimble"

import std/os

withDir("vendor" / "nimble" / "nat_traversal"):
  buildBundledLibsTask()
