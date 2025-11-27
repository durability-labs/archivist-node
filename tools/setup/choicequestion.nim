import std/rdstdin
import std/sequtils
import std/strutils

type
  ChoiceOption* = object
    title*: string
    description*: string
    warning*: string

  ChoiceQuestion* = object
    title*: string
    options*: seq[ChoiceOption]
    defaultIndex*: int

proc newline() =
  echo " "

proc p1(s: string) =
  echo "  " & s

proc p2(s: string) =
  echo "     " & s

proc p3(s: string) =
  echo "            " & s

proc hasWarning(option: ChoiceOption): bool =
  option.warning.len > 0

proc getOptionSep(option: ChoiceOption): string = 
  if option.hasWarning:
    return ".* "
  return ".  "

proc print(i: int, option: ChoiceOption) =
  p2($i & getOptionSep(option) & option.title)
  p3(option.description)
  if option.hasWarning:
    p3("*: " & option.warning)

proc print(question: ChoiceQuestion) =
  p1(question.title)
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

proc activate*(question: ChoiceQuestion): ChoiceOption =
  newline()
  print(question)

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
      let defaultOption = question.getDefault()
      p2("default: " & defaultOption.title)
      return defaultOption

    try:
      let selected = parseInt(input)
      if selected in possibleValues:
        return question.options[selected - 1]
    except ValueError:
      discard
    p1("Invalid input received")
    newline()

