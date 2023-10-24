// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import './libraries/Oracle.sol';

import './interfaces/IUniswapV3Oracle.sol';
import './interfaces/IUniswapV3Pool.sol';

contract UniswapV3Oracle is IUniswapV3Oracle {
    using Oracle for Oracle.Observation[65535];

    mapping(address => Oracle.Observation[65535]) public observations;                                 // pool -> observation

    /// @dev Returns the block timestamp truncated to 32 bits, i.e. mod 2**32. This method is overridden in tests.
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp); // truncation is desired
    }

    /// @inheritdoc IUniswapV3Oracle
    function getObservations(uint256 index)
    external
    view
    override
    returns (
        uint32 blockTimestamp,
        int56 tickCumulative,
        uint160 secondsPerLiquidityCumulativeX128,
        bool initialized
    ){
        Oracle.Observation memory observation = observations[msg.sender][index];
        (blockTimestamp) = observation.blockTimestamp;
        (tickCumulative) = observation.tickCumulative;
        (secondsPerLiquidityCumulativeX128) = observation.secondsPerLiquidityCumulativeX128;
        (initialized) = observation.initialized;
    }

    /// @notice This struct is an internal parameter within the snapshotCumulativesInside method
    struct SnapshotCumulativesInternalParam {
        int56 tickCumulativeLower;
        int56 tickCumulativeUpper;
        uint160 secondsPerLiquidityOutsideLowerX128;
        uint160 secondsPerLiquidityOutsideUpperX128;
        uint32 secondsOutsideLower;
        uint32 secondsOutsideUpper;
        int56 lowerTickCumulativeOutside;
        uint160 lowerSecondsPerLiquidityOutsideX128;
        uint32 lowerSecondsOutside;
        bool lowerInitialized;
        int56 upperTickCumulativeOutside;
        uint160 upperSecondsPerLiquidityOutsideX128;
        uint32 upperSecondsOutside;
        bool upperInitialized;
    }

    /// @notice Returns a snapshot of the tick cumulative, seconds per liquidity and seconds inside a tick range
    function snapshotCumulativesInside(int24 tickLower, int24 tickUpper)
    external
    view
    override
    returns (
        int56 tickCumulativeInside,
        uint160 secondsPerLiquidityInsideX128,
        uint32 secondsInside
    )
    {
        (,int24 _currentTick,uint16 _observationIndex,uint16 _observationCardinality,,,) = IUniswapV3Pool(msg.sender).slot0();
        uint128 _liquidity = IUniswapV3Pool(msg.sender).liquidity();

        SnapshotCumulativesInternalParam memory params;
        {
            (,,,,,,,,
                params.lowerTickCumulativeOutside,
                params.lowerSecondsPerLiquidityOutsideX128,
                params.lowerSecondsOutside,
                params.lowerInitialized
            ) = IUniswapV3Pool(msg.sender).ticks(tickLower);
            (,,,,,,,,
                params.upperTickCumulativeOutside,
                params.upperSecondsPerLiquidityOutsideX128,
                params.upperSecondsOutside,
                params.upperInitialized
            ) = IUniswapV3Pool(msg.sender).ticks(tickUpper);

            bool initializedLower;
            (params.tickCumulativeLower, params.secondsPerLiquidityOutsideLowerX128, params.secondsOutsideLower, initializedLower) = (
                params.lowerTickCumulativeOutside,
                params.lowerSecondsPerLiquidityOutsideX128,
                params.lowerSecondsOutside,
                params.lowerInitialized
            );
            require(initializedLower);

            bool initializedUpper;
            (
                params.tickCumulativeUpper,
                params.secondsPerLiquidityOutsideUpperX128,
                params.secondsOutsideUpper,
                initializedUpper
            ) = (
                params.upperTickCumulativeOutside,
                params.upperSecondsPerLiquidityOutsideX128,
                params.upperSecondsOutside,
                params.upperInitialized
            );
            require(initializedUpper);
        }


        if (_currentTick < tickLower) {
            return (
                params.tickCumulativeLower - params.tickCumulativeUpper,
                params.secondsPerLiquidityOutsideLowerX128 - params.secondsPerLiquidityOutsideUpperX128,
                params.secondsOutsideLower - params.secondsOutsideUpper
            );
        } else if (_currentTick < tickUpper) {
            uint32 time = _blockTimestamp();
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) =
                                    observations[msg.sender].observeSingle(
                    time,
                    0,
                    _currentTick,
                    _observationIndex,
                    _liquidity,
                    _observationCardinality
                );
            return (
                tickCumulative - params.tickCumulativeLower - params.tickCumulativeUpper,
                secondsPerLiquidityCumulativeX128 -
                params.secondsPerLiquidityOutsideLowerX128 -
                params.secondsPerLiquidityOutsideUpperX128,
                time - params.secondsOutsideLower - params.secondsOutsideUpper
            );
        } else {
            return (
                params.tickCumulativeUpper - params.tickCumulativeLower,
                params.secondsPerLiquidityOutsideUpperX128 - params.secondsPerLiquidityOutsideLowerX128,
                params.secondsOutsideUpper - params.secondsOutsideLower
            );
        }
    }

    /// @notice Returns the cumulative tick and liquidity as of each timestamp `secondsAgo` from the current block timestamp
    function observe(uint32[] memory secondsAgos)
    external
    view
    override
    returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        (,int24 _currentTick,uint16 _observationIndex,uint16 _observationCardinality,,,) = IUniswapV3Pool(msg.sender).slot0();
        uint128 _liquidity = IUniswapV3Pool(msg.sender).liquidity();

        return
            observations[msg.sender].observe(
            _blockTimestamp(),
            secondsAgos,
            _currentTick,
            _observationIndex,
            _liquidity,
            _observationCardinality
        );
    }

    function initialize() external override returns (uint16 cardinality, uint16 cardinalityNext){
        (cardinality, cardinalityNext) = observations[msg.sender].initialize(_blockTimestamp());
    }

    function write(
        uint16 index,
        uint32 blockTimestamp,
        int24 tick,
        uint128 liquidity,
        uint16 cardinality,
        uint16 cardinalityNext
    ) external override returns (uint16 indexUpdated, uint16 cardinalityUpdated){
        (indexUpdated, cardinalityUpdated) = observations[msg.sender].write(
            index,
            blockTimestamp,
            tick,
            liquidity,
            cardinality,
            cardinalityNext
        );
    }

    function observeSingle(
        uint32 time,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    ) external view override returns (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128){
        (tickCumulative, secondsPerLiquidityCumulativeX128) = observations[msg.sender].observeSingle(
            time,
            0,
            tick,
            index,
            liquidity,
            cardinality
        );
    }

    function grow(
        uint16 current,
        uint16 next
    ) external override returns (uint16){
        return observations[msg.sender].grow(current, next);
    }
}
