import pkg/chronicles
import ./app
import ./print
import ./choicequestion
import ./linequestion
import ./steps/networkstep
import ./steps/ethkeystep
import ./steps/modestep
import ./steps/natstep
import ./steps/webuistep
import ./steps/lineitemstep

proc intro() =
  newline()
  p1("Welcome to Archivist Setup utility")
  p2("This tool will help you configure your Archivist node.")
  p2("Where possible, sane default values are provided.")
  p2("The selected configuration can be adjusted afterwards")
  p2("by manually editing the generated configuration file.")
  newline()

proc main() =
  info "Archivist Setup"

  let
    app = App()
    lineItems = getLineItemQuestions()

  intro()

  var actions = @[
      getNetworkQuestion().getSelectedAction(),
      # getEthKeyQuestion().getSelectedAction(),
      # getModeQuestion().getSelectedAction(),
      # getNatQuestion().getSelectedAction(),
      # getWebUiQuestion().getSelectedAction(),
    ]
  
  for item in lineItems:
    actions.add(item.getLineAction())

  info "Performing selected actions..."

  for action in actions:
    action(app)

  info "Wrapping up..."
  app.finalize()

when isMainModule:
  main()
  info "All done"
