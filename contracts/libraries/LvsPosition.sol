// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import "@chainlink/contracts/src/v0.7/interfaces/AggregatorV2V3Interface.sol";

import "./FullMath.sol";
import "./SignedSafeMath.sol";
import "./LowGasSafeMath.sol";
import "./WadRayMath.sol";
import "./SafeCast.sol";
import "./Lvs.sol";

library LvsPosition{
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using FullMath for uint256;
    using SignedSafeMath for int256;
    using WadRayMath for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;
   
    struct Info{
        bool zeroForOne;
        uint256 debt;
        uint256 collateral;
        uint256 input0;
        uint256 input1;
    }

    /// @dev When decreasing position, repaying debt, we split the position into two parts according to the splitRatio.
    function split(Info memory self, uint256 splitRatio) internal pure returns(Info memory part1, Info memory part2){
        part1.zeroForOne = self.zeroForOne;
        part2.zeroForOne = self.zeroForOne;

        part1.debt = self.debt.mulDiv(splitRatio, Lvs.DivPrecision);
        part2.debt = self.debt.sub(part1.debt);

        part1.collateral = self.collateral.mulDiv(splitRatio, Lvs.DivPrecision);
        part2.collateral = self.collateral.sub(part1.collateral);

        part1.input0 = self.input0.mulDiv(splitRatio, Lvs.DivPrecision);
        part2.input0 = self.input0.sub(part1.input0);

        part1.input1 = self.input1.mulDiv(splitRatio, Lvs.DivPrecision);
        part2.input1 = self.input1.sub(part1.input1);
    }

    /// @dev used for increasing position size
    function merge(Info storage self, Info memory append) internal {
        if (self.collateral == 0 && self.debt == 0) {
            self.zeroForOne = append.zeroForOne;
        }
        require(self.zeroForOne == append.zeroForOne, "");
        self.zeroForOne = append.zeroForOne;
        self.debt = self.debt.add(append.debt);
        self.collateral = self.collateral.add(append.collateral);
        self.input0 = self.input0.add(append.input0);
        self.input1 = self.input1.add(append.input1);
    }

//    function positionValueInToken0(Info memory self, uint256 irIndexGlobal, uint256 price) internal pure returns (uint256 collateralValue, uint256 debtValue, uint256 input1Value){
//        uint256 debtValue;
//        uint256 collateralValue;
//        uint256 input1Value;
//        if (self.zeroForOne) {
//            // debt token is token 0, collateral is token1
//            collateralValue = self.collateral.mulDiv(price, Lvs.PricePrecision);
//            debtValue = self.debt.rayMul(irIndexGlobal);
//        } else {
//            // debt token is token1, collateral is token0
//            debtValue = self.debt.rayMul(irIndexGlobal).mulDiv(price, Lvs.PricePrecision);
//            collateralValue = self.collateral;
//        }
//        input1Value = self.input1.mulDiv(price, Lvs.PricePrecision);
//        return (collateralValue, debtValue, input1Value);
//    }
//
//    function positionValueInToken1(Info memory self, uint256 irIndexGlobal, uint256 price) internal pure returns (uint256 collateralValue, uint256 debtValue, uint256 input0Value){
//        uint256 debtValue;
//        uint256 collateralValue;
//        uint256 input0Value;
//        if (self.zeroForOne) {
//            // debt token is token 0, collateral is token1
//            collateralValue = self.collateral;
//            debtValue = self.debt.rayMul(irIndexGlobal).mulDiv(Lvs.PricePrecision, price);
//        } else {
//            // debt token is token1, collateral is token0
//            debtValue = self.debt.rayMul(irIndexGlobal);
//            collateralValue = self.collateral.mulDiv(Lvs.PricePrecision, price);
//        }
//        input0Value = self.input0.mulDiv(Lvs.PricePrecision, price);
//        return (collateralValue, debtValue, input0Value);
//    }

    // the price should be always token0 / token1
    // all values are converted into token0
    function hf(Info memory self, uint256 irIndexGlobal, uint256 price, uint256 mm) internal pure returns(int256 healthFactor){
        int256 debtValue;
        int256 collateralValue;
        if(self.zeroForOne){
            // debt token is token 0, collateral is token1
            collateralValue = self.collateral.mulDiv(price, Lvs.PricePrecision).toInt256();
            debtValue = self.debt.rayMul(irIndexGlobal).toInt256();
        } else {
            // debt token is token1, collateral is token0
            debtValue = self.debt.rayMul(irIndexGlobal).mulDiv(price, Lvs.PricePrecision).toInt256();
            collateralValue = self.collateral.toInt256();
        }
        healthFactor = collateralValue.sub(debtValue).mul(Lvs.DivPrecision.toInt256()).mul(Lvs.RatioPrecision.toInt256()).div(collateralValue.mul(mm.toInt256()));
    }

    function liquidatePrice(Info memory self, bool isToken0, uint256 irIndexGlobal, uint256 mm) internal pure returns (uint256 price){
        if (self.zeroForOne == isToken0) {
            price = self.debt.rayMul(irIndexGlobal).mulDiv(Lvs.RatioPrecision.mul(Lvs.PricePrecision), self.collateral.mul(Lvs.RatioPrecision.sub(mm)));
        } else {
            price = self.collateral.mul(Lvs.RatioPrecision.sub(mm)).mulDiv(Lvs.PricePrecision, Lvs.RatioPrecision.mul(self.debt.rayMul(irIndexGlobal)));
        }
    }
    
    function getIndexPrice(address priceFeed0, address priceFeed1, address sequencerUptimeFeed) internal view returns (uint256){
        AggregatorV2V3Interface dataFeed0 = AggregatorV2V3Interface(priceFeed0);
        AggregatorV2V3Interface dataFeed1 = AggregatorV2V3Interface(priceFeed1);
//        AggregatorV2V3Interface sequencerUptimeFeed = AggregatorV2V3Interface(sequencerUptimeFeed);
//        (
//        /*uint80 roundID*/,
//            int256 answer,
//            uint256 startedAt,
//        /*uint256 updatedAt*/,
//        /*uint80 answeredInRound*/
//        ) = sequencerUptimeFeed.latestRoundData();
//
//        // Answer == 0: Sequencer is up
//        // Answer == 1: Sequencer is down
//        bool isSequencerUp = answer == 0;
//        require(isSequencerUp, "");

        // Make sure the grace period has passed after the
        // sequencer is back up.
//        uint256 timeSinceUp = block.timestamp.sub(startedAt);
//        require(timeSinceUp > Lvs.GRACE_PERIOD_TIME, "");
        // prettier-ignore
        (
        /*uint80 roundID*/,
            int data0,
        /*uint startedAt*/,
        /*uint timeStamp*/,
        /*uint80 answeredInRound*/
        ) = dataFeed0.latestRoundData();

        (,int data1, ,,) = dataFeed1.latestRoundData();
        uint8 decimal0 = dataFeed0.decimals();
        uint8 decimal1 = dataFeed1.decimals();

        return data1.toUint256().mulDiv(Lvs.PricePrecision.mul(10 ** (decimal0)), data0.toUint256().mul(10 ** decimal1));
    }
}
