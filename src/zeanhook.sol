// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
 
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/**
 * @title ZeanHook - Base contract for Uniswap V4 hooks
 * @notice This contract provides the foundation for implementing custom Uniswap V4 hooks.
 */
 
contract ZeanHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint256;

    /**
     * Constants for slippage bounds (in basis points)
     * MIN_SLIPPAGE = 10 (0.1%)
     * MAX_SLIPPAGE = 500 (5%)
     */
    uint256 public constant MIN_SLIPPAGE = 10;
    uint256 public constant MAX_SLIPPAGE = 500;
    uint256 public constant BASIS_POINTS = 10000;

    /**
     * Parameters for volatility calculation
     */
    uint256 public constant VOLATILITY_WINDOW = 24 hours;
    uint256 public constant MIN_SAMPLES = 5;
    uint256 public constant VOLATILITY_MULTIPLIER = 100;

    struct PriceData {
        uint160 sqrtPriceX96;
        uint256 timestamp;
    }

    struct VolatilityMetrics {
        uint256 volatility;
        uint256 lastUpdate;
        uint256 sampleCount;
    }

    mapping(PoolId => PriceData[]) public priceHistory;
    mapping(PoolId => VolatilityMetrics) public volatilityMetrics;
    mapping(PoolId => uint256) public lastSwapTimestamp;

    event SlippageCalculated(
        PoolId indexed poolId,
        uint256 volatility,
        uint256 adjustedSlippage,
        uint256 timestamp
    );
    
    event PriceRecorded(
        PoolId indexed poolId,
        uint160 sqrtPriceX96,
        uint256 timestamp
    );

     /**
     * @notice Constructor initializes the hook with a PoolManager
     * @param _manager The address of the Uniswap V4 PoolManager contract
     * @dev Inherits from BaseHook which provides core functionality
     */
    constructor(
        IPoolManager _manager
    ) BaseHook(_manager) {}
 
	// Set up hook permissions to return `true`
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24,
        bytes calldata
    ) external returns (bytes4) {
        PoolId poolId = key.toId();
        
        priceHistory[poolId].push(PriceData({
            sqrtPriceX96: sqrtPriceX96,
            timestamp: block.timestamp
        }));
        
        volatilityMetrics[poolId] = VolatilityMetrics({
            volatility: MIN_SLIPPAGE,
            lastUpdate: block.timestamp,
            sampleCount: 1
        });
        
        emit PriceRecorded(poolId, sqrtPriceX96, block.timestamp);
        
        return BaseHook.afterInitialize.selector;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        
        uint256 adjustedSlippage = calculateVolatilityAdjustedSlippage(poolId);
        
        _validateSwapSlippage(params, adjustedSlippage, hookData);
        
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        
        uint160 currentSqrtPrice = _getCurrentSqrtPrice(poolId);
        _recordPriceData(poolId, currentSqrtPrice);
        
        _updateVolatilityMetrics(poolId);
        
        lastSwapTimestamp[poolId] = block.timestamp;
        
        return (BaseHook.afterSwap.selector, 0);
    }

    /**
     * @dev Calculate volatility-adjusted slippage based on recent price movements
     * @param poolId The pool identifier
     * @return adjustedSlippage The calculated slippage in basis points
     */
    function calculateVolatilityAdjustedSlippage(PoolId poolId) 
        public 
        view 
        returns (uint256 adjustedSlippage) 
    {
        VolatilityMetrics memory metrics = volatilityMetrics[poolId];
        
        if (metrics.sampleCount < MIN_SAMPLES) {
            return MIN_SLIPPAGE;
        }
        
        adjustedSlippage = MIN_SLIPPAGE;
        
        uint256 volatilityAdjustment = (metrics.volatility * VOLATILITY_MULTIPLIER) / BASIS_POINTS;
        adjustedSlippage += volatilityAdjustment;
        
        if (adjustedSlippage > MAX_SLIPPAGE) {
            adjustedSlippage = MAX_SLIPPAGE;
        }
        
        return adjustedSlippage;
    }

    /**
     * @dev Calculate current volatility based on price history
     * @param poolId The pool identifier
     * @return volatility The calculated volatility in basis points
     */
    function calculateVolatility(PoolId poolId) public view returns (uint256 volatility) {
        PriceData[] memory history = priceHistory[poolId];
        uint256 historyLength = history.length;
        
        if (historyLength < 2) {
            return 0;
        }
        
        uint256 cutoffTime = block.timestamp - VOLATILITY_WINDOW;
        uint256 validSamples = 0;
        uint256 sumSquaredReturns = 0;
        uint256 sumReturns = 0;
        
        for (uint256 i = 1; i < historyLength; i++) {
            if (history[i-1].timestamp < cutoffTime) continue;
            
            uint256 currentPrice = uint256(history[i].sqrtPriceX96);
            uint256 previousPrice = uint256(history[i-1].sqrtPriceX96);
            
            if (previousPrice == 0) continue;
            
            int256 return_ = int256((currentPrice * BASIS_POINTS) / previousPrice) - int256(BASIS_POINTS);
            uint256 absReturn = uint256(return_ < 0 ? -return_ : return_);
            
            sumReturns += absReturn;
            sumSquaredReturns += (absReturn * absReturn) / BASIS_POINTS;
            validSamples++;
        }
        
        if (validSamples < 2) {
            return 0;
        }
        
        uint256 meanReturn = sumReturns / validSamples;
        uint256 variance = (sumSquaredReturns / validSamples) - (meanReturn * meanReturn) / BASIS_POINTS;
        
        volatility = _sqrt(variance);
        
        return volatility;
    }

    /**
     * @dev Get the recommended slippage for a pool
     * @param poolId The pool identifier
     * @return slippage The recommended slippage in basis points
     */
    function getRecommendedSlippage(PoolId poolId) external view returns (uint256 slippage) {
        return calculateVolatilityAdjustedSlippage(poolId);
    }

    /**
     * @dev Get volatility metrics for a pool
     * @param poolId The pool identifier
     * @return metrics The current volatility metrics
     */
    function getVolatilityMetrics(PoolId poolId) 
        external 
        view 
        returns (VolatilityMetrics memory metrics) 
    {
        return volatilityMetrics[poolId];
    }

    /**
     * @dev Get recent price history for a pool
     * @param poolId The pool identifier
     * @param limit Maximum number of recent entries to return
     * @return history Array of recent price data
     */
    function getPriceHistory(PoolId poolId, uint256 limit) 
        external 
        view 
        returns (PriceData[] memory history) 
    {
        PriceData[] memory fullHistory = priceHistory[poolId];
        uint256 length = fullHistory.length;
        
        if (length == 0) {
            return new PriceData[](0);
        }
        
        uint256 returnLength = length > limit ? limit : length;
        history = new PriceData[](returnLength);
        
        uint256 startIndex = length - returnLength;
        for (uint256 i = 0; i < returnLength; i++) {
            history[i] = fullHistory[startIndex + i];
        }
        
        return history;
    }

    //== Internal functions ==//
    function _recordPriceData(PoolId poolId, uint160 sqrtPriceX96) internal {
        PriceData[] storage history = priceHistory[poolId];
        
        history.push(PriceData({
            sqrtPriceX96: sqrtPriceX96,
            timestamp: block.timestamp
        }));
        
        if (history.length > 100) {
            for (uint256 i = 0; i < history.length - 1; i++) {
                history[i] = history[i + 1];
            }
            history.pop();
        }
        
        emit PriceRecorded(poolId, sqrtPriceX96, block.timestamp);
    }
    
    function _updateVolatilityMetrics(PoolId poolId) internal {
        uint256 currentVolatility = calculateVolatility(poolId);
        uint256 adjustedSlippage = calculateVolatilityAdjustedSlippage(poolId);
        
        volatilityMetrics[poolId] = VolatilityMetrics({
            volatility: currentVolatility,
            lastUpdate: block.timestamp,
            sampleCount: priceHistory[poolId].length
        });
        
        emit SlippageCalculated(poolId, currentVolatility, adjustedSlippage, block.timestamp);
    }
    
    function _validateSwapSlippage(
        IPoolManager.SwapParams calldata params,
        uint256 recommendedSlippage,
        bytes calldata hookData
    ) internal pure {
        
        if (hookData.length >= 32) {
            uint256 userMaxSlippage = abi.decode(hookData, (uint256));
            require(
                userMaxSlippage >= recommendedSlippage,
                "User slippage below recommended minimum"
            );
            require(userMaxSlippage <= MAX_SLIPPAGE, "User slippage exceeds maximum");
        }
    }
    
    function _getCurrentSqrtPrice(PoolId poolId) internal view returns (uint160) {
        //TODO: This would get the current sqrt price from the pool manager
        return 0;
    }
    
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        
        return y;
    }	
}