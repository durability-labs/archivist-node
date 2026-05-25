## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license, ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import ../../blocktype

type
  EngineError* = object of CatchableError
    address*: BlockAddress

  RetriesExhaustedEngineError* = object of EngineError
  StorageFailedEngineError* = object of EngineError
  QueueFailedEngineError* = object of EngineError
  RequestAbandonedEngineError* = object of EngineError
