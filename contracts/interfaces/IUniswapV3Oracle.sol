// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;
pragma abicoder v2;

import '../libraries/Tick.sol';

interface IUniswapV3Oracle {
    function getObservations(uint256 index)
    external
    view
    returns (
        uint32 blockTimestamp,
        int56 tickCumulative,
        uint160 secondsPerLiquidityCumulativeX128,
        bool initialized
    );
    
    function initialize() external returns (uint16 cardinality, uint16 cardinalityNext);

    function write(uint16 index, uint32 blockTimestamp, int24 tick, uint128 liquidity, uint16 cardinality, uint16 cardinalityNext) external returns (uint16 indexUpdated, uint16 cardinalityUpdated);

    function observeSingle(
        uint32 time,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    ) external view returns (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128);

    function snapshotCumulativesInside(int24 tickLower, int24 tickUpper)
    external
    view
    returns (
        int56 tickCumulativeInside,
        uint160 secondsPerLiquidityInsideX128,
        uint32 secondsInside
    );

    function observe(uint32[] memory secondsAgos)
    external
    view
    returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    function grow(
        uint16 current,
        uint16 next
    ) external returns (uint16);
}
