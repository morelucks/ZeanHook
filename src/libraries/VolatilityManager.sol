// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {ZeanHookStorage} from "./ZeanHookStorage.sol";

abstract contract VolatilityManager is ZeanHookStorage {
    
    // ========================= Events =========================
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

    // ========================= Internal Functions =========================
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

    function _getCurrentSqrtPrice(PoolId poolId) internal view virtual returns (uint160);
    
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