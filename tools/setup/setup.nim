import pkg/chronicles
import ./app
import ./choicequestion
import ./networkstep

proc main() =
  info "Archivist Setup"

  let app = App()
  getNetworkQuestion().activate(app)


when isMainModule:
  main()
  info "All done"
