import pkg/questionable/results
import pkg/contractabi
import pkg/ethers/contracts/fields

type StorageAsk* = object
  proofProbability*: UInt256
  pricePerBytePerSecond*: StUint[96]
  collateralPerByte*: UInt128
  slots*: uint64
  slotSize*: uint64
  duration*: StUint[40]
  maxSlotLoss*: uint64

func solidityType*(_: type StorageAsk): string =
  solidityType(StorageAsk.fieldTypes)

func solidityType*(_: type StUint[40]): string =
  "uint40"

func solidityType*(_: type StUint[96]): string =
  "uint96"

func encode*(encoder: var AbiEncoder, ask: StorageAsk) =
  encoder.write(ask.fieldValues)

func decode*(decoder: var AbiDecoder, T: type StorageAsk): ?!T =
  let tupl = ?decoder.read(StorageAsk.fieldTypes)
  success StorageAsk(
    proofProbability: tupl[0],
    pricePerBytePerSecond: tupl[1],
    collateralPerByte: tupl[2],
    slots: tupl[3],
    slotSize: tupl[4],
    duration: tupl[5],
    maxSlotLoss: tupl[6],
  )
