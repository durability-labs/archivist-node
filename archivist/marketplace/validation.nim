import pkg/questionable/results
import ../validation
import ../validationconfig
import ../clock
import ./abstractmarketplace
import ./options

func new*(
    _: type Validation,
    marketplace: AbstractMarketplace,
    clock: Clock,
    options: MarketplaceOptions,
): ?!Validation =
  let config =
    ?ValidationConfig.init(
      maxSlots = options.validationMaxSlots |? 0,
      groups = options.validationGroups,
      groupIndex = options.validationGroupIndex |? 0,
    )
  success Validation.new(clock, marketplace, config)
