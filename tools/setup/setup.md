# Setup - The plan:
1. Read setup user input file

1. Network:
  Mainnet*[ ]   Testnet*[X]   Devnet*[ ]    None [ ]

1. Keys:
  Generate new[X]   Skip[ ]

1. Mode:
  Client[ ]   Storage*[ ]   Validator[ ]

1. NAT:
  any, none, upnp, pmp, extIP*

1. WebUI:
  No[X]   Yes[ ]

1. Boring config:
  datadir
  circuitdir
  ports
  quota
  logfile
  loglevel

1. Write setup user input file
1. Write or update config.toml
1. ping config endpoint if needed
1. if prover + main/test/devnet: run cirdl
1. if testnet/devnet + new key: show faucet links + pubkey
1. if webUI: open webUI
