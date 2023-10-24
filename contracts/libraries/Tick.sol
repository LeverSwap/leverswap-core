// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import './LowGasSafeMath.sol';
import './SafeCast.sol';

import './TickMath.sol';
import './LiquidityMath.sol';

/// @title Tick
/// @notice Contains functions for managing tick processes and relevant calculations
library Tick {
    using LowGasSafeMath for int256;
    using SafeCast for int256;

    // info stored for each initialized individual tick
    struct Info {
        // the total position liquidity that references this tick
        uint128 liquidityGross;
        // amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left),
        int128 liquidityNet;
        // fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
        // interest growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint256 igOutside0X128;
        uint256 igOutside1X128;
        uint256 igDivBySqrtPriceOutside0X128;
        uint256 igMulSqrtPriceOutside1X128;
        
        // the cumulative tick value on the other side of the tick
        int56 tickCumulativeOutside;
        // the seconds per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint160 secondsPerLiquidityOutsideX128;
        // the seconds spent on the other side of the tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint32 secondsOutside;
        // true iff the tick is initialized, i.e. the value is exactly equivalent to the expression liquidityGross != 0
        // these 8 bits are set to prevent fresh sstores when crossing newly initialized ticks
        bool initialized;
    }

    // return info of the method `getFeeGrowthInside`
    struct FeeGrowthInsideReturns {
        uint256 feeGrowthInside0X128;                                   // The all-time global fee growth, per unit of liquidity, in token0, inside the position's tick boundaries
        uint256 feeGrowthInside1X128;                                   // The all-time global fee growth, per unit of liquidity, in token1, inside the position's tick boundaries

        uint256 igInside0X128;                                          // The all-time global interest growth, per unit of liquidity, inside the position's tick interest boundaries
        uint256 igInside1X128;                                          // The all-time global interest growth, per unit of liquidity, inside the position's tick interest boundaries
        uint256 igBelow0X128;                                           // The all-time global interest growth, per unit of liquidity, below the position's tick interest boundaries
        uint256 igAbove1X128;                                           // The all-time global interest growth, per unit of liquidity, above the position's tick interest boundaries
        uint256 igDivBySqrtPriceInside0X128;                            // The all-time global interest growth, per unit of liquidity, inside the position's tick interest boundaries, divided by sqrtPriceX96
        uint256 igMulSqrtPriceInside1X128;                              // The all-time global interest growth, per unit of liquidity, inside the position's tick interest boundaries, multiplied by sqrtPriceX96
    }           

    // input param of the method `getFeeGrowthInside`
    struct FeeGrowthInsideParams {
        int24 tickLower;                                                // The lower tick boundary of the position
        int24 tickUpper;                                                // The upper tick boundary of the position 
        int24 tickCurrent;                                              // The current tick
        uint256 feeGrowthGlobal0X128;                                   // The all-time global fee growth, per unit of liquidity, in token0
        uint256 feeGrowthGlobal1X128;                                   // The all-time global fee growth, per unit of liquidity, in token1

        uint256 ig0X128;                                                // The all-time global interest growth, per unit of liquidity
        uint256 ig1X128;                                                // The all-time global interest growth, per unit of liquidity
        uint256 igDivBySqrtPrice0X128;                                  // The all-time global interest growth, per unit of liquidity, divided by sqrtPriceX96
        uint256 igMulSqrtPrice1X128;                                    // The all-time global interest growth, per unit of liquidity, multiplied by sqrtPriceX96
    }
    
    // input param of the method `update`
    struct TickUpdateParams {
        int24 tick;                                                     // self The mapping containing all tick information for initialized ticks                                                     
        int24 tickCurrent;                                              // tick The tick that will be updated
        int128 liquidityDelta;                                          // liquidityDelta A new amount of liquidity to be added (subtracted) when tick is crossed from left to right (right to left)
        uint256 feeGrowthGlobal0X128;                                   // The all-time global fee growth, per unit of liquidity, in token0
        uint256 feeGrowthGlobal1X128;                                   // The all-time global fee growth, per unit of liquidity, in token1
        uint256 ig0X128;                                                // The all-time global interest growth, per unit of liquidity
        uint256 ig1X128;                                                // The all-time global interest growth, per unit of liquidity
        uint256 igDivBySqrtPrice0X128;                                  // The all-time global interest growth, per unit of liquidity, divided by sqrtPriceX96
        uint256 igMulSqrtPrice1X128;                                    // The all-time global interest growth, per unit of liquidity, multiplied by sqrtPriceX96
        uint160 secondsPerLiquidityCumulativeX128;                      // The all-time seconds per max(1, liquidity) of the pool
        int56 tickCumulative;                                           // The tick * time elapsed since the pool was first initialized
        uint32 time;                                                    // The current block timestamp cast to a uint32
        bool upper;                                                     // true for updating a position's upper tick, or false for updating a position's lower tick
        uint128 maxLiquidity;                                           // The maximum liquidity allocation for a single tick
    }

    /// @notice Derives max liquidity per tick from given tick spacing
    /// @dev Executed within the pool constructor
    /// @param tickSpacing The amount of required tick separation, realized in multiples of `tickSpacing`
    ///     e.g., a tickSpacing of 3 requires ticks to be initialized every 3rd tick i.e., ..., -6, -3, 0, 3, 6, ...
    /// @return The max liquidity per tick
    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128) {
        int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        uint24 numTicks = uint24((maxTick - minTick) / tickSpacing) + 1;
        return type(uint128).max / numTicks;
    }

    /// @notice Retrieves fee growth data
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param params The input param struct
    /// @return info The all-time fee growth in token0, per unit of liquidity, inside the position's tick boundaries;
    /// The all-time interest growth in token0, per unit of liquidity, all the position's tick interest boundaries
    function getFeeGrowthInside(
        mapping(int24 => Tick.Info) storage self,
        FeeGrowthInsideParams memory params
    ) internal view returns (FeeGrowthInsideReturns memory info) {
        Info storage lower = self[params.tickLower];
        Info storage upper = self[params.tickUpper];

        // calculate fee growth below
        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;
        // calculate interest growth below
        uint256 igBelow1X128;
        uint256 igDivBySqrtPriceBelow0X128;
        uint256 igMulSqrtPriceBelow1X128;
        if (params.tickCurrent >= params.tickLower) {
            feeGrowthBelow0X128 = lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = lower.feeGrowthOutside1X128;

            info.igBelow0X128 = lower.igOutside0X128;
            igBelow1X128 = lower.igOutside1X128;
            igDivBySqrtPriceBelow0X128 = lower.igDivBySqrtPriceOutside0X128;
            igMulSqrtPriceBelow1X128 = lower.igMulSqrtPriceOutside1X128;
        } else {
            feeGrowthBelow0X128 = params.feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = params.feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;

            info.igBelow0X128 = params.ig0X128 - lower.igOutside0X128;
            igBelow1X128 = params.ig1X128 - lower.igOutside1X128;
            igDivBySqrtPriceBelow0X128 = params.igDivBySqrtPrice0X128 - lower.igDivBySqrtPriceOutside0X128;
            igMulSqrtPriceBelow1X128 = params.igMulSqrtPrice1X128 - lower.igMulSqrtPriceOutside1X128;
        }

        // calculate fee growth above
        uint256 feeGrowthAbove0X128;
        uint256 feeGrowthAbove1X128;
        // calculate interest growth above
        uint256 igAbove0X128;
        uint256 igDivBySqrtPriceAbove0X128;
        uint256 igMulSqrtPriceAbove1X128;
        if (params.tickCurrent < params.tickUpper) {
            feeGrowthAbove0X128 = upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = upper.feeGrowthOutside1X128;

            igAbove0X128 = upper.igOutside0X128;
            info.igAbove1X128 = upper.igOutside1X128;
            igDivBySqrtPriceAbove0X128 = upper.igDivBySqrtPriceOutside0X128;
            igMulSqrtPriceAbove1X128 = upper.igMulSqrtPriceOutside1X128;
        } else {
            feeGrowthAbove0X128 = params.feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = params.feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128;

            igAbove0X128 = params.ig0X128 - upper.igOutside0X128;
            info.igAbove1X128 = params.ig1X128 - upper.igOutside1X128;
            igDivBySqrtPriceAbove0X128 = params.igDivBySqrtPrice0X128 - upper.igDivBySqrtPriceOutside0X128;
            igMulSqrtPriceAbove1X128 = params.igMulSqrtPrice1X128 - upper.igMulSqrtPriceOutside1X128;
        }

        info.feeGrowthInside0X128 = params.feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
        info.feeGrowthInside1X128 =params.feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;

        info.igInside0X128 = params.ig0X128 - info.igBelow0X128 - igAbove0X128;
        info.igInside1X128 = params.ig1X128 - igBelow1X128 - info.igAbove1X128;
        info.igDivBySqrtPriceInside0X128 = params.igDivBySqrtPrice0X128 - igDivBySqrtPriceBelow0X128 - igDivBySqrtPriceAbove0X128;
        info.igMulSqrtPriceInside1X128 = params.igMulSqrtPrice1X128 - igMulSqrtPriceBelow1X128 - igMulSqrtPriceAbove1X128;
    }

    /// @notice Updates a tick and returns true if the tick was flipped from initialized to uninitialized, or vice versa
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param params The input param struct
    /// @return flipped Whether the tick was flipped from initialized to uninitialized, or vice versa
    function update(
        mapping(int24 => Tick.Info) storage self,
        TickUpdateParams memory params
    ) internal returns (bool flipped) {
        Tick.Info storage info = self[params.tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        uint128 liquidityGrossAfter = LiquidityMath.addDelta(liquidityGrossBefore, params.liquidityDelta);

        require(liquidityGrossAfter <= params.maxLiquidity, 'LO');

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            // by convention, we assume that all growth before a tick was initialized happened _below_ the tick
            if (params.tick <= params.tickCurrent) {
                info.feeGrowthOutside0X128 = params.feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = params.feeGrowthGlobal1X128;
                info.secondsPerLiquidityOutsideX128 = params.secondsPerLiquidityCumulativeX128;
                info.tickCumulativeOutside = params.tickCumulative;
                info.secondsOutside = params.time;

                info.igOutside0X128 = params.ig0X128;
                info.igOutside1X128 = params.ig1X128;
                info.igDivBySqrtPriceOutside0X128 = params.igDivBySqrtPrice0X128;
                info.igMulSqrtPriceOutside1X128 = params.igMulSqrtPrice1X128;
            }
            info.initialized = true;
        }

        info.liquidityGross = liquidityGrossAfter;

        // when the lower (upper) tick is crossed left to right (right to left), liquidity must be added (removed)
        info.liquidityNet = params.upper
            ? int256(info.liquidityNet).sub(params.liquidityDelta).toInt128()
            : int256(info.liquidityNet).add(params.liquidityDelta).toInt128();
    }

    /// @notice Clears tick data
    /// @param self The mapping containing all initialized tick information for initialized ticks
    /// @param tick The tick that will be cleared
    function clear(mapping(int24 => Tick.Info) storage self, int24 tick) internal {
        delete self[tick];
    }

    /// @notice Transitions to next tick as needed by price movement
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tick The destination tick of the transition
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1
    /// @param ig0X128 The all-time global interest growth, per unit of liquidity, in token0
    /// @param ig1X128 The all-time global interest growth, per unit of liquidity, in token1
    /// @param igDivBySqrtPrice0X128 The all-time global interest growth, per unit of liquidity, divided by sqrtPriceX96
    /// @param igMulSqrtPrice1X128 The all-time global interest growth, per unit of liquidity, multiplied by sqrtPriceX96
    /// @param secondsPerLiquidityCumulativeX128 The current seconds per liquidity
    /// @param tickCumulative The tick * time elapsed since the pool was first initialized
    /// @param time The current block.timestamp
    /// @return liquidityNet The amount of liquidity added (subtracted) when tick is crossed from left to right (right to left)
    function cross(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        uint256 ig0X128,
        uint256 ig1X128,
        uint256 igDivBySqrtPrice0X128,
        uint256 igMulSqrtPrice1X128,
        uint160 secondsPerLiquidityCumulativeX128,
        int56 tickCumulative,
        uint32 time
    ) internal returns (int128 liquidityNet) {
        Tick.Info storage info = self[tick];
        info.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - info.feeGrowthOutside0X128;
        info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - info.feeGrowthOutside1X128;
        info.secondsPerLiquidityOutsideX128 = secondsPerLiquidityCumulativeX128 - info.secondsPerLiquidityOutsideX128;
        info.tickCumulativeOutside = tickCumulative - info.tickCumulativeOutside;
        info.secondsOutside = time - info.secondsOutside;
        liquidityNet = info.liquidityNet;

        info.igOutside0X128 = ig0X128 - info.igOutside0X128;
        info.igOutside1X128 = ig1X128 - info.igOutside1X128;
        info.igDivBySqrtPriceOutside0X128 = igDivBySqrtPrice0X128 - info.igDivBySqrtPriceOutside0X128;
        info.igMulSqrtPriceOutside1X128 = igMulSqrtPrice1X128 - info.igMulSqrtPriceOutside1X128;
    }
}
