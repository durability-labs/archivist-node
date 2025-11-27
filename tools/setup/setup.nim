import pkg/chronicles
import ./choicequestion

proc main() =
  info "Archivist Setup"

  let q = ChoiceQuestion(
    title: "Which one?",
    options: @[
      ChoiceOption(
        title: "one",
        description: "first option",
        warning: ""
      ),
      ChoiceOption(
        title: "two",
        description: "second option",
        warning: "warning!"
      ),
    ],
    defaultIndex: 1
  )

  let chosen = q.activate()
  let c = chosen
  info "chosen: ", title = c.title

when isMainModule:
  main()
  info "All done"
