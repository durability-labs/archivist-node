import ./choicequestion
import ./app

proc setNetwork(app: App, network: string) =
  app.fetchNetworkConfig(network)
  app.writeConfigLine("config line!")

proc setMainnet(app: App) =
  app.setNetwork("mainnet")

proc setTestnet(app: App) =
  app.setNetwork("testnet")

proc setDevnet(app: App) =
  app.setNetwork("devnet")

proc getNetworkQuestion*(): ChoiceQuestion = 
  let networkWarning = "Setup will connect to a Durability-Labs server to fetch required network information."
  return ChoiceQuestion(
    title: "Choose a network?",
    options: @[
      ChoiceOption(
        title: "mainnet",
        description: @[
          "Archivist mainnet where durable data storage is traded using tokens with real monetary value."
        ],
        warning: networkWarning,
        action: setMainnet
      ),
      ChoiceOption(
        title: "testnet",
        description: @[
          "Network for testing new Archivist versions before they launch on mainnet.",
          "Tokens used hold no real value. Ideal for testing new node installations."
        ],
        warning: networkWarning,
        action: setTestnet
      ),
      ChoiceOption(
        title: "devnet",
        description: @[
          "Unstable network used for development of Archivist.",
          "Tokens used hold no real value."
        ],
        warning: networkWarning,
        action: setDevnet
      ),
      ChoiceOption(
        title: "none",
        description: @[
          "Setup will not configure a network for you. You can add bootstrap-records,",
          "an RPC endpoint, and a marketplace smartcontract address to the configuration file manually."
        ],
        warning: "",
        action: proc(app: App) = discard
      )
    ],
    defaultIndex: 1
  )
