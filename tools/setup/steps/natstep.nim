import ../choicequestion
import ../app

proc setNat(app: App, value: string) =
  app.writeConfigLine("# NAT settings:")
  app.writeConfigLine(value & "\n")

proc setNatAny(app: App) =
  app.setNat("nat=any")

proc setNatNone(app: App) =
  app.setNat("nat=none")

proc setNatUpnp(app: App) =
  app.setNat("nat=upnp")

proc setNatPmp(app: App) =
  app.setNat("nat=pmp")

proc setNatExtIp(app: App) =
  let publicIp = app.fetchPublicIp()
  app.setNat("nat=extip:" & publicIp)

proc setNatManual(app: App) =
  app.setNat("# nat=extip:<PUBLIC_IP_ADDRESS_HERE>")
  app.writeConfigLine("# available nat options: any, none, upnp, pmp, extip\n")

proc getNatQuestion*(): ChoiceQuestion =
  return ChoiceQuestion(
    title: "Choose NAT behavior",
    options:
      @[
        ChoiceOption(
          title: "Any",
          description:
            @["The Archivist node may attempt any method to perform NAT traversal."],
          warning: "",
          action: setNatAny,
        ),
        ChoiceOption(
          title: "None",
          description:
            @["The Archivist node will not attempt to perform NAT traversal."],
          warning: "",
          action: setNatNone,
        ),
        ChoiceOption(
          title: "uPNP",
          description: @["The Archivist node will attempt to use only uPNP."],
          warning: "",
          action: setNatUpnp,
        ),
        ChoiceOption(
          title: "PMP",
          description: @["The Archivist node will attempt to use only PMP."],
          warning: "",
          action: setNatPmp,
        ),
        ChoiceOption(
          title: "extIP",
          description: @["The Archivist node will use your external IP address."],
          warning:
            "Setup will connect to a Durability-Labs server to determine your external IP address",
          action: setNatExtIp,
        ),
        ChoiceOption(
          title: "extIP (manual)",
          description:
            @[
              "Setup will not add a NAT setting for you. You can edit the config file to set it manually."
            ],
          warning: "",
          action: setNatManual,
        ),
      ],
    defaultIndex: 0,
  )
