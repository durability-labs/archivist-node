import pkg/questionable
import ./archivistconfig
import ./hardhatconfig

type NodeConfigs* = object
  clients*: ?ArchivistConfigs
  providers*: ?ArchivistConfigs
  validators*: ?ArchivistConfigs
  hardhat*: ?HardhatConfig
