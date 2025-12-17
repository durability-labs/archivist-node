import std/rdstdin
import std/sequtils
import std/strutils

import ./app
import ./print

type
  OptionAction* = proc(app: App): void
  LineQuestion* = object
    description*: string
    key*: string
    defaultValue*: string

proc doNothing(app: App) =
  discard

proc getLineAction*(question: LineQuestion): OptionAction =
  newline()
  p2(question.description)
  p1(question.key & " = " & question.defaultValue)

  var value = question.defaultValue

  proc writeLineItem(app: App) =
    app.writeConfigLine("# " & question.description)
    app.writeConfigLine(question.key & "=" & value & "\n")

  while true:
    let input = readLineFromStdin("(enter value or blank to accept default): ")
    p2(input)
    if input.len > 0:
      value = input
    return writeLineItem
  return doNothing
