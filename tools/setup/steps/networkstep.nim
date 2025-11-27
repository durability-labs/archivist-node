import std/sequtils
import std/strutils

import ../choicequestion
import ../app

proc setNetwork(app: App, network: string) =
  let config = app.fetchNetworkConfig(network)
  let records = config.spr.records.mapIt(
    "\"" & it & "\""
  ).join(",")

  app.writeConfigLine("# Bootstrap signed-peer-records for " & network & ":")
  app.writeConfigLine("bootstrap-node=[" & records & "]\n")

  app.writeConfigLine("# Enable marketplace connectivity:")
  app.writeConfigLine("persistence=1")
  app.writeConfigLine("eth-provider=\"" & config.rpcs[0] & "\"\n") # todo: Select a random one?

proc setMainnet(app: App) =
  app.setNetwork("mainnet")

proc setTestnet(app: App) =
  app.setNetwork("testnet")

proc setDevnet(app: App) =
  app.setNetwork("devnet")

proc writeExample(app: App) =
  app.writeConfigLine("# example bootstrap signed-peer-records:")
  app.writeConfigLine("# bootstrap-node=[\"spr:Ci...\",\"spr:Ci...\"]\n")

  app.writeConfigLine("# Enable marketplace connectivity:")
  app.writeConfigLine("persistence=1")
  app.writeConfigLine("# example eth-provider:")
  app.writeConfigLine("# eth-provider=\"https://eth-rpc-provider.here\"\n")

proc getNetworkQuestion*(): ChoiceQuestion = 
  let networkWarning = "Setup will connect to a Durability-Labs server to fetch required network information."
  return ChoiceQuestion(
    title: "Choose a network?",
    options: @[
      ChoiceOption(
        title: "Mainnet",
        description: @[
          "Archivist mainnet where durable data storage is traded using tokens with real monetary value."
        ],
        warning: networkWarning,
        action: setMainnet
      ),
      ChoiceOption(
        title: "Testnet",
        description: @[
          "Network for testing new Archivist versions before they launch on mainnet.",
          "Tokens used hold no real value. Ideal for testing new node installations."
        ],
        warning: networkWarning,
        action: setTestnet
      ),
      ChoiceOption(
        title: "Devnet",
        description: @[
          "Unstable network used for development of Archivist.",
          "Tokens used hold no real value."
        ],
        warning: networkWarning,
        action: setDevnet
      ),
      ChoiceOption(
        title: "None",
        description: @[
          "Setup will not configure a network for you. You can add bootstrap-records,",
          "an RPC endpoint, and a marketplace smartcontract address to the configuration file manually."
        ],
        warning: "",
        action: writeExample
      )
    ],
    defaultIndex: 1
  )
