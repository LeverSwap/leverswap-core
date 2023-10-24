// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "./libraries/TransferHelperForRouter.sol";
import "./libraries/CallbackValidation.sol";
import "./libraries/LowGasSafeMath.sol";
import "./libraries/LvsPosition.sol";
import "./libraries/PoolAddress.sol";
import "./libraries/WadRayMath.sol";
import "./libraries/FullMath.sol";
import "./libraries/SafeCast.sol";
import "./libraries/LvsPair.sol";
import "./libraries/Path.sol";
import "./libraries/TickMath.sol";
import "./libraries/Lvs.sol";

import "./interfaces/callback/IUniswapV3SwapCallback.sol";
import "./interfaces/IUniswapV3Pool.sol";
import './interfaces/ILvsRouter.sol';
import './interfaces/IWETH9.sol';
import "./interfaces/ILvsInsuranceFund.sol";

contract LvsRouter is IUniswapV3SwapCallback, ILvsRouter {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using WadRayMath for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using FullMath for uint256;
    using Path for bytes;
    using LvsPosition for LvsPosition.Info;
    using LvsPair for LvsPair.Config;

    /// @dev Used as the placeholder value for amountInCached, because the computed amount in for an exact output swap
    /// can never actually be this value
    uint256 private constant DEFAULT_AMOUNT_IN_CACHED = type(uint256).max;
    /// @dev Transient storage variable used for returning the computed amount in for an exact output swap.
    uint256 private amountInCached = DEFAULT_AMOUNT_IN_CACHED;
    /// @dev The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    /// @dev The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    address public controller;
    address public insuranceFund;
    address public factory;
    address public WETH9;
    // key keccack(pool + taker address + zeroForOne);
    mapping(bytes32 => LvsPosition.Info) public positions;
    // key is pool address
    mapping(address => LvsPair.Config) public pairConfig;
    // pool address => zeroForOne
    mapping(address => mapping(bool => LvsPair.Slot1)) public pairSlot1;
    
    event IncreasePosition(address indexed taker, address indexed pool, bool indexed zeroForOne);
    event DecreasePosition(address indexed taker, address indexed pool, bool indexed zeroForOne);

    struct SwapCallbackData {
        bytes path;
        address payer;
        address lendingPool;
        uint256 imAmount;
    }

    struct SwapParams {
        bytes path;
        uint256 imAmount;
        uint256 amountInputOrOutput;
        uint256 limitAmount;
        address payer;
        address lendingPool;
        bool exactInput;
        bool zeroForOne;
    }

    struct IncreasePositionParams {
        bytes path;                                                 // includes token out, token in, fee;
        address lendingPool;                                        // can be calculated by single path, but not multi path
        bool zeroForOne;                                            // can be calculated by path
        uint256 imAmount;
        uint256 vol;
        uint256 limitAmount;
        uint256 deadline;
    }

    struct IncreasePositionInternalParams {
        LvsPair.Config config;
        bool exactInput;
        address pathHead;
        address pathEnd;
        address token0;
        address token1;
        bytes32 key;
        uint256 amountIn;
        uint256 amountOut;
        uint256 borrowAmount;
        uint256 debtShare;
        int256 hf;
    }

    struct DecreasePositionParams {
        bytes path;                                                // includes token out, token in, fee;
        address lendingPool;
        bool zeroForOne;
        bool refundToken0;
        uint256 collateralDelta;
        uint256 limitAmount;
        uint256 deadline;
    }

    struct DecreasePositionInternalParams {
        LvsPair.Config config;
        bool exactInput;
        address pathHead;
        address pathEnd;
        address token0;
        address token1;
        bytes32 key;
        uint256 closeRate;
        LvsPosition.Info position;
        LvsPosition.Info closePosition;
        LvsPosition.Info restPosition;
        uint256 repayAmount;
        uint256 amountIn;
        uint256 amountOut;
        address debtToken;
        address collateralToken;
        int256 hf;
    }

    struct ExactInputInternalParams {
        uint256 amountIn;
        address recipient;
        uint160 sqrtPriceLimitX96;
        SwapCallbackData data;
    }

    struct RepayDebtParams {
        address pool;
        bool zeroForOne;
        uint256 repayAmount;
    }

    /// @dev check in case of blockchain delay
    modifier checkDeadline(uint256 deadline) {
        require(block.timestamp <= deadline, 'CD0');
        _;
    }

    constructor(address _factory, address _insuranceFund, address _WETH9){
        factory = _factory;
        insuranceFund = _insuranceFund;
        WETH9 = _WETH9;
        controller = msg.sender;
    }

    /// @dev Returns the pool for the given token pair and fee. The pool contract may or may not exist.
    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) private view returns (IUniswapV3Pool) {
        return IUniswapV3Pool(PoolAddress.computeAddress(factory, PoolAddress.getPoolKey(tokenA, tokenB, fee)));
    }

    function getPositionKey(address taker, address pool, bool zeroForOne) public pure returns (bytes32){
        return keccak256(abi.encodePacked(taker, pool, zeroForOne));
    }

    function increasePosition(IncreasePositionParams memory params) external payable checkDeadline(params.deadline) {
        IncreasePositionInternalParams memory iParams;
        iParams.config = pairConfig[params.lendingPool];
        require(iParams.config.isEnabled, 'IP0');
        require(params.imAmount > 0 && params.vol > params.imAmount, "IP1");
        require(params.imAmount.mulDiv(Lvs.RatioPrecision, params.vol) >= iParams.config.minimumMarginRatio, "IP2");
        IUniswapV3Pool(params.lendingPool).updateInterest();
        iParams.pathHead = BytesLib.toAddress(params.path, 0);
        iParams.pathEnd = BytesLib.toAddress(params.path, params.path.length - 20);
        iParams.token0 = IUniswapV3Pool(params.lendingPool).token0();
        iParams.token1 = IUniswapV3Pool(params.lendingPool).token1();
        iParams.exactInput = params.zeroForOne ? iParams.pathHead == iParams.token0 : iParams.pathHead == iParams.token1;
        params.zeroForOne == iParams.exactInput ?
            require(iParams.pathHead == iParams.token0 && iParams.pathEnd == iParams.token1, "IP3") :
            require(iParams.pathHead == iParams.token1 && iParams.pathEnd == iParams.token0, "IP4");

        (iParams.amountIn, iParams.amountOut) = _swap(
            SwapParams(
                params.path,
                params.imAmount,
                params.vol,
                params.limitAmount,
                msg.sender,
                params.lendingPool,
                iParams.exactInput,
                params.zeroForOne
            )
        );

        iParams.borrowAmount = iParams.exactInput ? params.vol.sub(params.imAmount) : iParams.amountIn;
        LvsPair.Slot1 storage slot1 = pairSlot1[params.lendingPool][params.zeroForOne];
        iParams.debtShare = iParams.borrowAmount.rayDiv(slot1.interestIndexGlobal);
        slot1.totalDebt = slot1.totalDebt.add(iParams.debtShare);
        iParams.key = getPositionKey(msg.sender, params.lendingPool, params.zeroForOne);
        positions[iParams.key].merge(
            LvsPosition.Info({
                zeroForOne: params.zeroForOne,
                debt: iParams.debtShare,
                collateral: iParams.exactInput ? iParams.amountOut : params.vol,
                input0: params.zeroForOne == iParams.exactInput ? params.imAmount : 0,
                input1: params.zeroForOne == iParams.exactInput ? 0 : params.imAmount
            })
        );
        
        emit IncreasePosition(msg.sender, params.lendingPool, params.zeroForOne);
        (iParams.hf,) = _hf(slot1.interestIndexGlobal, positions[iParams.key], iParams.config);
        require(iParams.hf > Lvs.DivPrecision.toInt256(), "IP5");
    }

    function decreasePosition(DecreasePositionParams memory params) external payable checkDeadline(params.deadline) {
        DecreasePositionInternalParams memory iParams;
        iParams.config = pairConfig[params.lendingPool];
        require(iParams.config.isEnabled, 'DP0');
        IUniswapV3Pool(params.lendingPool).updateInterest();
        iParams.exactInput = params.zeroForOne ? !params.refundToken0 : params.refundToken0;
        iParams.pathHead = BytesLib.toAddress(params.path, 0);
        iParams.pathEnd = BytesLib.toAddress(params.path, params.path.length - 20);
        iParams.token0 = IUniswapV3Pool(params.lendingPool).token0();
        iParams.token1 = IUniswapV3Pool(params.lendingPool).token1();
        params.zeroForOne == iParams.exactInput ?
            require(iParams.pathHead == iParams.token0 && iParams.pathEnd == iParams.token1, "DP1") :
            require(iParams.pathHead == iParams.token1 && iParams.pathEnd == iParams.token0, "DP2");
        iParams.key = getPositionKey(msg.sender, params.lendingPool, !params.zeroForOne);
        iParams.position = positions[iParams.key];
        require(iParams.position.collateral > 0 && params.collateralDelta > 0, "DP3");
        if (params.collateralDelta > iParams.position.collateral) {
            params.collateralDelta = iParams.position.collateral;
        }
        iParams.closeRate = params.collateralDelta.mulDiv(Lvs.DivPrecision, iParams.position.collateral);
        require(iParams.closeRate > 0, "DP4");
        (iParams.closePosition, iParams.restPosition) = iParams.position.split(iParams.closeRate);
        iParams.repayAmount = iParams.closePosition.debt.rayMul(pairSlot1[params.lendingPool][!params.zeroForOne].interestIndexGlobal);
        
        (iParams.amountIn, iParams.amountOut) = _swap(
            SwapParams(
                params.path,
                0,
                iParams.exactInput ? iParams.closePosition.collateral : iParams.repayAmount,
                params.limitAmount,
                address(this),
                address(0),
                iParams.exactInput,
                params.zeroForOne
            )
        );
        require(iParams.exactInput ? iParams.amountOut >= iParams.repayAmount : iParams.amountIn <= iParams.closePosition.collateral, "DP5");
        (iParams.debtToken, iParams.collateralToken) = !params.zeroForOne ? (iParams.token0, iParams.token1) : (iParams.token1, iParams.token0);
        TransferHelperForRouter.safeTransfer(iParams.debtToken, params.lendingPool, iParams.repayAmount);
        IUniswapV3Pool(params.lendingPool).repay(iParams.debtToken, iParams.repayAmount);
        TransferHelperForRouter.safeTransfer(
            iParams.exactInput ? iParams.debtToken : iParams.collateralToken,
            msg.sender,
            iParams.exactInput ? iParams.amountOut.sub(iParams.repayAmount) : iParams.closePosition.collateral.sub(iParams.amountIn)
        );
        pairSlot1[params.lendingPool][!params.zeroForOne].totalDebt = pairSlot1[params.lendingPool][!params.zeroForOne].totalDebt.sub(iParams.closePosition.debt);
        positions[iParams.key] = iParams.restPosition;

        emit DecreasePosition(msg.sender, params.lendingPool, !params.zeroForOne);
        if (iParams.restPosition.collateral > 0) {
            (iParams.hf,) = _hf(pairSlot1[params.lendingPool][!params.zeroForOne].interestIndexGlobal, iParams.restPosition, iParams.config);
            require(iParams.hf > Lvs.DivPrecision.toInt256(), "DP6");
        }
    }

    function _swap(SwapParams memory params) internal returns (uint256 amountIn, uint256 amountOut) {
        if (params.exactInput) {
            while (true) {
                bool hasMultiplePools = params.path.hasMultiplePools();

                uint256 amountToPay;
                uint256 amountReceived = params.amountInputOrOutput;
                (amountToPay, amountReceived) = _exactInputInternal(ExactInputInternalParams(
                    amountReceived,
                    address(this),
                    0,
                    SwapCallbackData({
                        path: params.path.getFirstPool(),
                        payer: params.payer,
                        lendingPool: params.lendingPool,
                        imAmount: params.imAmount
                    })
                ));
                if (amountIn == 0) amountIn = amountToPay;
                if (hasMultiplePools) {
                    params.payer = address(this);
                    params.path = params.path.skipToken();
                    params.lendingPool == address(0);
                } else {
                    amountOut = amountReceived;
                    break;
                }
            }
            require(amountOut >= params.limitAmount, 'S0');
        } else {
            _exactOutputInternal(
                params.amountInputOrOutput.sub(params.imAmount),
                address(this),
                0,
                SwapCallbackData({
                    path: params.path,
                    payer: params.payer,
                    lendingPool: params.lendingPool,
                    imAmount: params.imAmount

                })
            );

            amountIn = amountInCached;
            require(amountIn <= params.limitAmount, 'S1');
            amountInCached = DEFAULT_AMOUNT_IN_CACHED;
        }
    }

    function _exactInputInternal(ExactInputInternalParams memory params) private returns (uint256 amountToPay, uint256 amountOut) {
        (address tokenIn, address tokenOut, uint24 fee) = params.data.path.decodeFirstPool();

        bool zeroForOne = tokenIn < tokenOut;

        (int256 amount0, int256 amount1) = getPool(tokenIn, tokenOut, fee).swap(
            params.recipient,
            zeroForOne,
            params.amountIn.toInt256(),
            params.sqrtPriceLimitX96 == 0 ? (zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1) : params.sqrtPriceLimitX96,
            abi.encode(params.data)
        );

        (amountToPay, amountOut) = zeroForOne ? (uint256(amount0), uint256(- amount1)) : (uint256(amount1), uint256(- amount0));
    }

    function _exactOutputInternal(
        uint256 amountOut,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) private returns (uint256 amountIn) {
        (address tokenOut, address tokenIn, uint24 fee) = data.path.decodeFirstPool();

        bool zeroForOne = tokenIn < tokenOut;

        (int256 amount0Delta, int256 amount1Delta) = getPool(tokenIn, tokenOut, fee).swap(
            recipient,
            zeroForOne,
            - amountOut.toInt256(),
            sqrtPriceLimitX96 == 0 ? (zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1) : sqrtPriceLimitX96,
            abi.encode(data)
        );

        uint256 amountOutReceived;
        (amountIn, amountOutReceived) = zeroForOne ? (uint256(amount0Delta), uint256(- amount1Delta)) : (uint256(amount1Delta), uint256(- amount0Delta));

        if (sqrtPriceLimitX96 == 0) require(amountOutReceived == amountOut, "E0");
    }

    function addCollateral(address pool, bool zeroForOne, uint256 deltaCollateral) external payable {
        require(deltaCollateral > 0, "A0");
        bytes32 key = getPositionKey(msg.sender, pool, zeroForOne);
        LvsPosition.Info storage position = positions[key];
        require(position.debt > 0, "A1");
        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();
        address collateralToken;
        if (zeroForOne) {
            collateralToken = token1;
            position.input1 = position.input1.add(deltaCollateral);
        } else {
            collateralToken = token0;
            position.input0 = position.input0.add(deltaCollateral);
        }
        _pay(collateralToken, msg.sender, address(this), deltaCollateral);
        position.collateral = position.collateral.add(deltaCollateral);
    }

    function repayDebt(RepayDebtParams memory params) external payable {
        require(params.repayAmount > 0, "R0");
        bytes32 key = getPositionKey(msg.sender, params.pool, params.zeroForOne);
        LvsPosition.Info memory position = positions[key];
        require(position.debt > 0, "R1");
        address token0 = IUniswapV3Pool(params.pool).token0();
        address token1 = IUniswapV3Pool(params.pool).token1();
        (address debtToken, address collateralToken) = params.zeroForOne ? (token0, token1) : (token1, token0);
        IUniswapV3Pool(params.pool).updateInterest();
        uint256 repayShare = params.repayAmount.rayDiv(pairSlot1[params.pool][params.zeroForOne].interestIndexGlobal);
        if (repayShare >= position.debt) {
            repayShare = position.debt;
            params.repayAmount = position.debt.rayMul(pairSlot1[params.pool][params.zeroForOne].interestIndexGlobal);
        }
        _pay(debtToken, msg.sender, params.pool, params.repayAmount);
        IUniswapV3Pool(params.pool).repay(debtToken, params.repayAmount);
        LvsPosition.Info memory closePosition;
        (closePosition, positions[key]) = position.split(repayShare.mulDiv(Lvs.DivPrecision, position.debt));
        pairSlot1[params.pool][params.zeroForOne].totalDebt = pairSlot1[params.pool][params.zeroForOne].totalDebt.sub(closePosition.debt);
        _pay(collateralToken, address(this), msg.sender, closePosition.collateral);
    }

    function utilizationRatio(address lendingPool, bool zeroForOne, uint256 baseAmount) internal view returns (uint256 util, uint256 lastTotalBorrow) {
        LvsPair.Slot1 memory slot1 = pairSlot1[lendingPool][zeroForOne];
        if (slot1.totalDebt != 0) {
            lastTotalBorrow = slot1.totalDebt.rayMul(slot1.interestIndexGlobal);
            util = lastTotalBorrow.rayDiv(baseAmount);
        }
        return (util, lastTotalBorrow);
    }

    function _getCurrentIG(address lendingPool, bool zeroForOne, uint256 baseAmount) internal view returns (uint256 ig, uint256 payInterest) {
        LvsPair.Slot1 memory slot1 = pairSlot1[lendingPool][zeroForOne];
        (uint256 util, uint256 lastTotalBorrow) = utilizationRatio(lendingPool, zeroForOne, baseAmount);
        uint256 deltaTime = slot1.lastExecutedTimeStamp == 0 ? 0 : block.timestamp.sub(slot1.lastExecutedTimeStamp);
        if (deltaTime == 0) return (slot1.interestIndexGlobal, 0);
        (uint256 ir) = pairConfig[lendingPool].getInterestRatio(util);
        ig = slot1.interestIndexGlobal.rayMul(LvsPair.calculateCompoundedInterest(ir, deltaTime));
        payInterest = slot1.totalDebt.rayMul(ig).sub(lastTotalBorrow);
    }

    function getCurrentIG(address lendingPool, bool zeroForOne) public view returns (uint256 ig) {
        uint256 baseAmount;
        if (zeroForOne) {
            (baseAmount,) = IUniswapV3Pool(lendingPool).getBaseAmount();
        } else {
            (, baseAmount) = IUniswapV3Pool(lendingPool).getBaseAmount();
        }
        (ig,) = _getCurrentIG(lendingPool, zeroForOne, baseAmount);
    }

    function updateIG(
        uint256 baseAmount0,
        uint256 baseAmount1,
        uint160 sqrtPriceX96
    ) public override returns (
        uint256 ig0X128,
        uint256 ig1X128,
        uint256 igDivBySqrtPrice0X128,
        uint256 igMulSqrtPrice1X128
    ){
        address pool = msg.sender;
        LvsPair.Config memory config = pairConfig[pool];

        if (config.isEnabled) {
            LvsPair.Slot1 storage slotA = pairSlot1[pool][true];
            LvsPair.Slot1 storage slotB = pairSlot1[pool][false];
            uint256 payInterest0;
            uint256 payInterest1;
            (slotA.interestIndexGlobal, payInterest0) = _getCurrentIG(pool, true, baseAmount0);
            (slotB.interestIndexGlobal, payInterest1) = _getCurrentIG(pool, false, baseAmount1);

            slotA.lastExecutedTimeStamp = block.timestamp;
            slotB.lastExecutedTimeStamp = block.timestamp;

            if (baseAmount0 != 0) {
                ig0X128 = FullMath.mulDiv(payInterest0, Q128, baseAmount0);
                igDivBySqrtPrice0X128 = FullMath.mulDiv(ig0X128, Q96, sqrtPriceX96);
            }
            if (baseAmount1 != 0) {
                ig1X128 = FullMath.mulDiv(payInterest1, Q128, baseAmount1);
                igMulSqrtPrice1X128 = FullMath.mulDiv(ig1X128, sqrtPriceX96, Q96);
            }
        }
        return (ig0X128, ig1X128, igDivBySqrtPrice0X128, igMulSqrtPrice1X128);
    }

    function setNewController(address _newController) external {
        require(msg.sender == controller, "SNC0");
        controller = _newController;
    }

    function setPairConfig(address pool, LvsPair.Config memory config) external {
        require(msg.sender == controller, "SPC0");
        pairConfig[pool] = config;
        
        if (pairSlot1[pool][true].interestIndexGlobal == 0) {
            pairSlot1[pool][true].interestIndexGlobal = WadRayMath.RAY;
        }

        if (pairSlot1[pool][false].interestIndexGlobal == 0) {
            pairSlot1[pool][false].interestIndexGlobal = WadRayMath.RAY;
        }
    }

    function _pay(
        address token,
        address payer,
        address recipient,
        uint256 value
    ) internal {
        if (token == WETH9 && address(this).balance >= value) {
            IWETH9(WETH9).deposit{value: value}(); // wrap only what is needed to pay
            IWETH9(WETH9).transfer(recipient, value);
        } else if (payer == address(this)) {
            TransferHelperForRouter.safeTransfer(token, recipient, value);
        } else {
            TransferHelperForRouter.safeTransferFrom(token, payer, recipient, value);
        }
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    ) external override {
        require(amount0Delta > 0 || amount1Delta > 0);
        SwapCallbackData memory data = abi.decode(_data, (SwapCallbackData));
        (address tokenIn, address tokenOut, uint24 fee) = data.path.decodeFirstPool();
        CallbackValidation.verifyCallback(factory, tokenIn, tokenOut, fee);

        (bool isExactInput, uint256 amountToPay) =
            amount0Delta > 0 ? (tokenIn < tokenOut, uint256(amount0Delta)) : (tokenOut < tokenIn, uint256(amount1Delta));

        if (isExactInput) {
            if (data.lendingPool != address(0)) {
                _pay(tokenIn, data.payer, msg.sender, data.imAmount);
                IUniswapV3Pool(data.lendingPool).borrow(tokenIn, msg.sender, amountToPay.sub(data.imAmount));
            } else {
                _pay(tokenIn, data.payer, msg.sender, amountToPay);
            }
        } else {
            if (data.path.hasMultiplePools()) {
                data.path = data.path.skipToken();
                _exactOutputInternal(amountToPay, msg.sender, 0, data);
            } else {
                amountInCached = amountToPay;
                if (data.lendingPool != address(0)) {
                    _pay(tokenIn, data.payer, address(this), data.imAmount);
                    IUniswapV3Pool(data.lendingPool).borrow(tokenOut, msg.sender, amountToPay);
                } else {
                    _pay(tokenOut, data.payer, msg.sender, amountToPay);
                }
            }
        }
    }

    function _hf(uint256 ig, LvsPosition.Info memory pos, LvsPair.Config memory conf) internal view returns (int256, uint256){
        uint256 price = LvsPosition.getIndexPrice(conf.priceFeed0, conf.priceFeed1, conf.sequencerUptimeFeed);
        int256 hf = pos.hf(ig, price, conf.maintenanceMarginRatio);
        return (hf, price);
    }

    function hf(address taker, address pool, bool zeroForOne) public view returns (int256, uint256){
        bytes32 key = getPositionKey(taker, pool, zeroForOne);
        LvsPosition.Info memory pos = positions[key];
        LvsPair.Config memory conf = pairConfig[pool];
        
        uint256 ig = getCurrentIG(pool, zeroForOne);
        
        return _hf(ig, pos, conf);
    }

    struct LiquidateInternalVars{
        uint256 debtValue;
        uint256 collateralValue;
        int256 hf;
        uint256 colToLiquidator;// collateral
        uint256 colToTrader;
        uint256 colPenalty;
        address debtToken;
        address colToken;
        uint256 price;
        uint256 ig;
        uint256 liquidateRatio;
        uint256 payDebtAmount;
        uint256 baseAmount;
    }

    function liquidate(address taker, address pool, bool zeroForOne, uint256 payDebt) public {
        bytes32 key = getPositionKey(taker, pool, zeroForOne);
        LvsPosition.Info memory pos = positions[key];
        LvsPair.Config memory conf = pairConfig[pool];
        require(conf.isEnabled, "");
        require(pos.collateral > 0, "");

        LiquidateInternalVars memory tmp;
        LvsPosition.Info memory liquidatedPosition;
        LvsPosition.Info memory remainPosition;
        // update interest index global
        IUniswapV3Pool(pool).updateInterest();

        LvsPair.Slot1 storage slot1 = pairSlot1[pool][zeroForOne];

        (tmp.hf, tmp.price) = _hf(slot1.interestIndexGlobal, pos, conf);
        require(tmp.hf <= Lvs.DivPrecision.toInt256(), "L0");
        

        if (payDebt > pos.debt) {
            payDebt = pos.debt;
        }
        tmp.liquidateRatio = payDebt.mulDiv(Lvs.DivPrecision, pos.debt);
        (liquidatedPosition, remainPosition) = pos.split(tmp.liquidateRatio);

        tmp.colPenalty = liquidatedPosition.collateral.mulDiv(conf.liquidityPenalty, Lvs.RatioPrecision);
        tmp.payDebtAmount = liquidatedPosition.debt.rayMul(slot1.interestIndexGlobal);
        if (zeroForOne) {
            tmp.colToLiquidator = tmp.payDebtAmount.mulDiv(Lvs.PricePrecision, tmp.price);
            tmp.debtToken = IUniswapV3Pool(pool).token0();
            tmp.colToken = IUniswapV3Pool(pool).token1();
        } else {
            tmp.colToLiquidator = tmp.payDebtAmount.mulDiv(tmp.price, Lvs.PricePrecision);
            tmp.debtToken = IUniswapV3Pool(pool).token1();
            tmp.colToken = IUniswapV3Pool(pool).token0();
        }
        tmp.colToLiquidator = tmp.colToLiquidator.mulDiv(Lvs.RatioPrecision.add(conf.liquidityPriceDiscount), Lvs.RatioPrecision);

        if (liquidatedPosition.collateral < tmp.colToLiquidator) {
            tmp.colToTrader = 0;
            tmp.colPenalty = 0;
            ILvsInsuranceFund(insuranceFund).use(pool, tmp.colToken, tmp.colToLiquidator.sub(liquidatedPosition.collateral));
        } else {
            tmp.colToTrader = liquidatedPosition.collateral.sub(tmp.colToLiquidator);
            if (tmp.colToTrader < tmp.colPenalty) {
                tmp.colPenalty = tmp.colToTrader;
                tmp.colToTrader = 0;
            } else {
                tmp.colToTrader = tmp.colToTrader.sub(tmp.colPenalty);
            }
        }

        TransferHelperForRouter.safeTransferFrom(tmp.debtToken, msg.sender, pool, tmp.payDebtAmount);
        IUniswapV3Pool(pool).repay(tmp.debtToken, tmp.payDebtAmount);
        TransferHelperForRouter.safeTransfer(tmp.colToken, msg.sender, tmp.colToLiquidator);
        if (tmp.colToTrader > 0) TransferHelperForRouter.safeTransfer(tmp.colToken, taker, tmp.colToTrader);

        if (tmp.colPenalty > 0) {
            TransferHelperForRouter.safeApprove(tmp.colToken, insuranceFund, tmp.colPenalty);
            ILvsInsuranceFund(insuranceFund).inject(pool, tmp.colToken, tmp.colPenalty);
        }
        
        slot1.totalDebt = slot1.totalDebt.sub(liquidatedPosition.debt);
        positions[key] = remainPosition;
    }

    function getPoolIndexPrice(address pool) public view returns (uint256){
        LvsPair.Config memory conf = pairConfig[pool];
        return LvsPosition.getIndexPrice(conf.priceFeed0, conf.priceFeed1, conf.sequencerUptimeFeed);
    }

    function getLiquidatePrice(address taker, address pool, bool zeroForOne, bool isToken0) external view returns (uint256){
        bytes32 key = getPositionKey(taker, pool, zeroForOne);
        LvsPosition.Info memory pos = positions[key];
        LvsPair.Config memory conf = pairConfig[pool];
        
        uint256 ig = getCurrentIG(pool, zeroForOne);

        return pos.liquidatePrice(isToken0, ig, conf.maintenanceMarginRatio);
    }
}