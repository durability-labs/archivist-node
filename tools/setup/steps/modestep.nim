import ../choicequestion
import ../app

proc setClientMode(app: App) =
  app.writeConfigLine("# Archivist node is configured as client:")
  app.writeConfigLine("# No additional flags necessary.\n")

proc setStorageManualMode(app: App) =
  app.writeConfigLine("# Archivist node is configured for storage:")
  app.writeConfigLine("prover=1")
  app.writeConfigLine("circuit-dir=circuitdir\n")
  
proc setStorageMode(app: App) =
  setStorageManualMode(app)
  app.storageModeSelected = true

proc setValidatorMode(app: App) =
  app.writeConfigLine("# Archivist node is configured as validator:")
  app.writeConfigLine("validator=1\n")

proc getModeQuestion*(): ChoiceQuestion = 
  return ChoiceQuestion(
    title: "Choose a mode",
    options: @[
      ChoiceOption(
        title: "Client",
        description: @[
          "The Archivist node can be used to upload and download data, and it can be used to",
          "purchase data storage in the network."
        ],
        warning: "",
        action: setClientMode
      ),
      ChoiceOption(
        title: "Storage",
        description: @[
          "All capabilities of the Client mode, and the node can be configured to automatically",
          "engage storage contracts, using local storage capacity to earn tokens. This requires:",
          "reliable up-time, reliable network connectivity, and tokens to be used for collateral."
        ],
        warning: "Setup will connect to a Durability-Labs server to download zkProver circuit files.",
        action: setStorageMode
      ),
      ChoiceOption(
        title: "Storage (manual)",
        description: @[
          "Same as Storage mode, except setup will not fetch circuit files for you."
        ],
        warning: "",
        action: setStorageManualMode
      ),
      ChoiceOption(
        title: "Validator",
        description: @[
          "All capabilities of the Client mode, and the node can be configured to automatically",
          "perform validation for on-going storage contracts to earn tokens."
        ],
        warning: "",
        action: setValidatorMode
      )
    ],
    defaultIndex: -1
  )
