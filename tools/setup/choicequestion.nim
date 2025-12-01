import std/rdstdin
import std/sequtils
import std/strutils

import ./app
import ./print

type
  OptionAction* = proc(app: App): void
  ChoiceOption* = object
    title*: string
    description*: seq[string]
    warning*: string
    action*: OptionAction

  ChoiceQuestion* = object
    title*: string
    options*: seq[ChoiceOption]
    defaultIndex*: int

proc hasWarning(option: ChoiceOption): bool =
  option.warning.len > 0

proc getOptionSep(option: ChoiceOption): string = 
  if option.hasWarning:
    return ".* "
  return ".  "

proc print(i: int, option: ChoiceOption) =
  p2($i & getOptionSep(option) & option.title)
  for line in option.description:
    p3(line)
  if option.hasWarning:
    p3("*: " & option.warning)

proc print(question: ChoiceQuestion) =
  p1("[ " & question.title & " ]")
  var i = 1
  for option in question.options:
    print(i, option)
    inc i
    newline()

proc hasDefault(question: ChoiceQuestion): bool =
  question.defaultIndex > -1

proc getDefault(question: ChoiceQuestion): ChoiceOption = 
  question.options[question.defaultIndex]

proc getDefaultStr(question: ChoiceQuestion): string =
  if question.hasDefault:
    return "(default: " & $(question.defaultIndex + 1) &
      ". " & question.getDefault().title & ")"
  return ""

proc getSelectedOption(question: ChoiceQuestion): ChoiceOption =
  let
    possibleValues = 1 .. question.options.len
    optionsStrs = possibleValues.mapIt($it)
    optionsStr = optionsStrs.join(",")
    defaultStr = getDefaultStr(question)

  while true:
    let input = readLineFromStdin("Options[" & optionsStr & "]" & defaultStr & ": ")
    p2(input)
    if input == "q":
      p1("quit")
      quit(0)
    if input.len == 0 and question.hasDefault:
      return question.getDefault()

    try:
      let selected = parseInt(input)
      if selected in possibleValues:
        return question.options[selected - 1]
    except ValueError:
      discard
    p1("Invalid input received")
    newline()

proc getSelectedAction*(question: ChoiceQuestion): OptionAction =
  newline()
  newline()
  print(question)

  let selectedOption = getSelectedOption(question)
  p2("selected: " & selectedOption.title)
  newline()

  return selectedOption.action
