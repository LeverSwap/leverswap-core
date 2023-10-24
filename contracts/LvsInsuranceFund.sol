// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "./interfaces/IUniswapV3Pool.sol";
import "./libraries/TransferHelperForRouter.sol";
import "./libraries/LowGasSafeMath.sol";
import "./interfaces/ILvsInsuranceFund.sol";

contract LvsInsuranceFund is ILvsInsuranceFund {
    address public owner;
    address public admin;
    address public lvsRouter;
    using LowGasSafeMath for uint256;

    mapping(address => bool) public pools;
    mapping(address => mapping(address => uint256)) public balance;
    mapping(address => mapping(address => uint256)) public used;

    event FundInjected(address from, address pool, address token, uint256 value);
    event FundUsed(address pool, address token, uint256 value);
    event OwnerChanged(address oldOwner, address newOwner);
    event AdminChanged(address oldAdmin, address newAdmin);
    event LvsRouterModified(address oldRouter, address newRouter);

    constructor() {
        owner = msg.sender;
    }

    modifier OnlyOwner (){
        require(msg.sender == owner, "");
        _;
    }

    modifier OnlyAdmin() {
        require(msg.sender == admin || msg.sender == owner, "");
        _;
    }

    function changeOwner(address _owner) public OnlyOwner {
        emit OwnerChanged(owner, _owner);
        owner = _owner;
    }

    function changeAdmin(address _admin) public OnlyAdmin {
        emit AdminChanged(admin, _admin);
        admin = _admin;
    }

    function modifyLvsRouter(address _router) public OnlyOwner {
        require(_router != address(0), "");
        emit LvsRouterModified(lvsRouter, _router);
        lvsRouter = _router;
    }
    
    function addPool(address _pool) public OnlyOwner {
        pools[_pool] = true;
    }

    function removePool(address _pool) public OnlyOwner {
        pools[_pool] = false;
    }

    function inject(address _pool, address token, uint256 value) override public {
        require(pools[_pool], "I0");
        require(token == IUniswapV3Pool(_pool).token0() || token == IUniswapV3Pool(_pool).token1(), "I1");
        TransferHelperForRouter.safeTransferFrom(token, msg.sender, address(this), value);
        balance[_pool][token] = balance[_pool][token].add(value);
        emit FundInjected(msg.sender, _pool, token, value);
    }

    function use(address _pool, address token, uint256 value) override public {
        require(msg.sender == lvsRouter, "");
        require(pools[_pool], "");
        require(token == IUniswapV3Pool(_pool).token0() || token == IUniswapV3Pool(_pool).token1(), "");

        require(balance[_pool][token] >= value, "");
        TransferHelperForRouter.safeTransfer(token, msg.sender, value);
        balance[_pool][token] = balance[_pool][token].sub(value);
        used[_pool][token] = used[_pool][token].add(value);
        emit FundUsed(_pool, token, value);
    }
}

