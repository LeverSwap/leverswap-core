// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;

import "./WadRayMath.sol";

library LvsPair {
    using WadRayMath for uint256;

    uint256 internal constant SECOND_PER_HOUR = 1 hours;
    
    struct Config{
        bool isEnabled;

        uint256 minimumMarginRatio;// 1 / max leverage
        uint256 maintenanceMarginRatio;

        uint256 alphaInterestRatio;
        uint256 alphaFundingUsage;
        uint256 betaInterestRatio;
        uint256 betaFundingUsage;

        uint256 feeRatio;
        uint256 feeToInsuranceFundRatio;

        uint256 liquidityPenalty;
        uint256 liquidityPriceDiscount;

        address priceFeed0;
        address priceFeed1;
        address sequencerUptimeFeed;
    }

    struct Slot1 {
        uint256 interestIndexGlobal;// IR = IR ∗ (1 + ir)^n
        uint256 lastExecutedTimeStamp;
        uint256 totalDebt;
    }

    function getInterestRatio(Config memory self, uint256 utilization) internal pure returns (uint256 ir){
//        if(utilization <= self.alphaFundingUsage){
//            ir = self.alphaInterestRatio * utilization / self.alphaFundingUsage;
//        } else if (utilization <= self.betaFundingUsage){
//            // can be optimized.
//            ir = self.alphaInterestRatio + (utilization - self.alphaFundingUsage) * (self.alphaInterestRatio - self.betaInterestRatio) / (self.betaFundingUsage - self.alphaFundingUsage);
//        } else {
//            ir = self.betaInterestRatio;
//        }
        return 0.0001e27;
    }

    function calculateCompoundedInterest(uint256 ratePerSecond, uint256 deltaTime) internal pure returns (uint256) {
        uint256 expMinusOne = deltaTime - 1;
        uint256 expMinusTwo = deltaTime > 2 ? deltaTime - 2 : 0;

        ratePerSecond = ratePerSecond / SECOND_PER_HOUR;

        uint256 basePowerTwo = ratePerSecond.rayMul(ratePerSecond);
        uint256 basePowerThree = basePowerTwo.rayMul(ratePerSecond);

        uint256 secondTerm = deltaTime * expMinusOne * basePowerTwo / 2;
        uint256 thirdTerm = deltaTime * expMinusOne * expMinusTwo * basePowerThree / 6;

        return WadRayMath.RAY + ratePerSecond * deltaTime + secondTerm + thirdTerm;
    }
}
