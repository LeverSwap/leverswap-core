// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.5.0;

interface ILvsRouter {
    function updateIG(
        uint256 baseAmount0,
        uint256 baseAmount1,
        uint160 sqrtPriceX96
    ) external returns (
        uint256 ig0X128,
        uint256 ig1X128,
        uint256 igDivBySqrtPrice0X128,
        uint256 igMulSqrtPrice1X128
    );
}
