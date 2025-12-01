import ../choicequestion
import ../app

proc setEnableWebUi(app: App) =
  app.writeConfigLine("# Durability-Labs webUI support:")
  app.writeConfigLine("api-cors-origin=\"*\"")
  app.writeConfigLine("# URL: https://app.archivist.storage\n")

proc setNo(app: App) =
  discard

proc getWebUiQuestion*(): ChoiceQuestion = 
  return ChoiceQuestion(
    title: "Enable WebUI",
    options: @[
      ChoiceOption(
        title: "Yes",
        description: @[
          "The Archivist node will support the Durability-Labs web interface."
        ],
        warning: "Cross-origin requests will be enabled. The web interface is hosted on Durability-Labs servers.",
        action: setEnableWebUi
      ),
      ChoiceOption(
        title: "No",
        description: @[
          "The Archivist node will not support the Durability-Labs web interface."
        ],
        warning: "",
        action: setNo
      )
    ],
    defaultIndex: 1
  )
