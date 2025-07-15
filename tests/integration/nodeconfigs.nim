import pkg/questionable
import ./archivistconfig
import ./hardhatconfig

type NodeConfigs* = object
  clients*: ?CodexConfigs
  providers*: ?CodexConfigs
  validators*: ?CodexConfigs
  hardhat*: ?HardhatConfig
