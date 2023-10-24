// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.5.0;

interface ILvsInsuranceFund{
    function inject(address _pool, address token, uint256 value) external;
    function use(address _pool, address token, uint256 value) external;
}