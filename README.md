# SURGE Protocol — EVM Contracts

Smart contracts for the SURGE token launchpad (bonding curve, launch, trade) on EVM chains (Base, BSC, etc.).

## Structure

- **contracts/fun/** — Bonding curve core: `Bonding.sol`, `BondingETHRouter.sol`, `FRouter.sol`, `FFactory.sol`, `FPair.sol`, `FERC20.sol`
- **contracts/virtualPersona/** — MainToken, MainFactory (post–bonding curve)
- **contracts/tax/** — BondingTax
- **contracts/pool/** — Interfaces (Uniswap V2, IV2LockerFactory)

## Networks

Deployed on Base, BSC, and other EVM networks. See deployment configs for addresses.
