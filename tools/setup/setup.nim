import pkg/chronicles
import ./app
import ./choicequestion
import ./steps/networkstep
import ./steps/ethkeystep
import ./steps/modestep
import ./steps/natstep
import ./steps/webuistep

proc main() =
  info "Archivist Setup"

  let
    app = App()
    actions = @[
      getNetworkQuestion().getSelectedAction(),
      getEthKeyQuestion().getSelectedAction(),
      getModeQuestion().getSelectedAction(),
      getNatQuestion().getSelectedAction(),
      getWebUiQuestion().getSelectedAction()
    ]

  info "Performing selected actions..."

  for action in actions:
    action(app)

  info "Wrapping up..."
  app.finalize()

when isMainModule:
  main()
  info "All done"
