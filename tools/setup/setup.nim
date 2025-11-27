import pkg/chronicles
import ./app
import ./choicequestion
import ./steps/networkstep
import ./steps/ethkeystep

proc main() =
  info "Archivist Setup"

  let
    app = App()
    actions = @[
      getNetworkQuestion().getSelectedAction(),
      getEthKeyQuestion().getSelectedAction()
    ]

  info "Performing selected actions..."

  for action in actions:
    action(app)

when isMainModule:
  main()
  info "All done"
