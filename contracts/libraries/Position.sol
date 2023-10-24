// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import './FullMath.sol';
import './FixedPoint128.sol';
import './LiquidityMath.sol';
import './FixedPoint96.sol';
import './TickMath.sol';

/// @title Position
/// @notice Positions represent an owner address' liquidity between a lower and upper tick boundary
/// @dev Positions store additional state for tracking fees owed to the position
library Position {
    // info stored for each user's position
    struct Info {
        // the amount of liquidity owned by this position
        uint128 liquidity;
        // fee growth per unit of liquidity as of the last update to liquidity or fees owed
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // interest growth per unit of liquidity as of the last update to liquidity or interest owed
        uint256 igAbove1LastX128;
        uint256 igBelow0LastX128;
        uint256 igInside0LastX128;
        uint256 igInside1LastX128;
        uint256 igDivBySqrtPriceInside0LastX128;
        uint256 igMulSqrtPriceInside1LastX128;
        // the fees owed to the position owner in token0/token1
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    //input params for position update
    struct UpdateParams {
        int128 liquidityDelta;
        uint256 feeGrowthInside0X128;
        uint256 feeGrowthInside1X128;
        uint256 igInside0X128;
        uint256 igBelow0X128;
        uint256 igDivBySqrtPriceInside0X128;
        uint256 igInside1X128;
        uint256 igAbove1X128;
        uint256 igMulSqrtPriceInside1X128;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice Returns the Info struct of a position, given an owner and position boundaries
    /// @param self The mapping containing all user positions
    /// @param owner The address of the position owner
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @return position The position info struct of the given owners' position
    function get(
        mapping(bytes32 => Info) storage self,
        address owner,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (Position.Info storage position) {
        position = self[keccak256(abi.encodePacked(owner, tickLower, tickUpper))];
    }

    /// @notice Credits accumulated fees to a user's position
    /// @param self The individual position to update
    /// @param params input params struct for update
    function update(
        Info storage self,
        UpdateParams memory params
    ) internal {
        Info memory _self = self;

        uint128 liquidityNext;
        if (params.liquidityDelta == 0) {
            require(_self.liquidity > 0, 'NP'); // disallow pokes for 0 liquidity positions
            liquidityNext = _self.liquidity;
        } else {
            liquidityNext = LiquidityMath.addDelta(_self.liquidity, params.liquidityDelta);
        }

        // calculate accumulated fees
        uint128 tokensOwed0 =
            uint128(
                FullMath.mulDiv(
                    params.feeGrowthInside0X128 - _self.feeGrowthInside0LastX128,
                    _self.liquidity,
                    FixedPoint128.Q128
                )
            );
        uint128 tokensOwed1 =
            uint128(
                FullMath.mulDiv(
                    params.feeGrowthInside1X128 - _self.feeGrowthInside1LastX128,
                    _self.liquidity,
                    FixedPoint128.Q128
                )
            );
        uint128 tokensInterestOwed0 = _self.liquidity == 0 ? 0 :
            uint128(
                FullMath.mulDiv(
                    _self.liquidity,
                    params.igDivBySqrtPriceInside0X128 - _self.igDivBySqrtPriceInside0LastX128 //32
                    - FullMath.mulDiv(
                        params.igInside0X128 - _self.igInside0LastX128,
                        FixedPoint96.Q96,
                        TickMath.getSqrtRatioAtTick(params.tickUpper)
                    )
                    + FullMath.mulDiv(
                        params.igBelow0X128 - _self.igBelow0LastX128,
                        FixedPoint96.Q96,
                        TickMath.getSqrtRatioAtTick(params.tickLower)
                    )
                    - FullMath.mulDiv(
                        params.igBelow0X128 - _self.igBelow0LastX128,
                        FixedPoint96.Q96,
                        TickMath.getSqrtRatioAtTick(params.tickUpper)
                    ),
                    FixedPoint128.Q128
                )
            );
        uint128 tokensInterestOwed1 = self.liquidity == 0 ? 0 :
            uint128(
                FullMath.mulDiv(
                    _self.liquidity,
                    params.igMulSqrtPriceInside1X128 - _self.igMulSqrtPriceInside1LastX128
                    - FullMath.mulDiv(
                        TickMath.getSqrtRatioAtTick(params.tickLower),
                        params.igInside1X128 - _self.igInside1LastX128,
                        FixedPoint96.Q96
                    )
                    + FullMath.mulDiv(
                        TickMath.getSqrtRatioAtTick(params.tickUpper) - TickMath.getSqrtRatioAtTick(params.tickLower),
                        params.igAbove1X128 - _self.igAbove1LastX128,
                        FixedPoint96.Q96
                    ),
                    FixedPoint128.Q128
                )

            );

        // update the position
        if (params.liquidityDelta != 0) self.liquidity = liquidityNext;
        self.feeGrowthInside0LastX128 = params.feeGrowthInside0X128;
        self.feeGrowthInside1LastX128 = params.feeGrowthInside1X128;
        self.igAbove1LastX128 = params.igAbove1X128;
        self.igBelow0LastX128 = params.igBelow0X128;
        self.igInside0LastX128 = params.igInside0X128;
        self.igInside1LastX128 = params.igInside1X128;
        self.igDivBySqrtPriceInside0LastX128 = params.igDivBySqrtPriceInside0X128;
        self.igMulSqrtPriceInside1LastX128 = params.igMulSqrtPriceInside1X128;
        if (tokensOwed0 > 0 || tokensOwed1 > 0 || tokensInterestOwed0 > 0 || tokensInterestOwed1 > 0) {
            // overflow is acceptable, have to withdraw before you hit type(uint128).max fees
            self.tokensOwed0 += tokensOwed0 + tokensInterestOwed0;
            self.tokensOwed1 += tokensOwed1 + tokensInterestOwed1;
        }
    }
}
