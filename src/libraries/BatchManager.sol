// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {ZeanHookStorage} from "./ZeanHookStorage.sol";

abstract contract BatchManager is ZeanHookStorage {
    
    // ========================= Events =========================
    event SwapQueued(
        PoolId indexed poolId,
        address indexed user,
        uint256 batchIndex,
        uint256 queueTime
    );

    event BatchExecuted(
        PoolId indexed poolId,
        uint256 swapsExecuted,
        uint160 executionPrice,
        uint256 timestamp
    );

    event SwapFailed(
        PoolId indexed poolId,
        address indexed user,
        uint256 batchIndex,
        string reason
    );

    event BatchInitialized(
        PoolId indexed poolId,
        uint160 referencePrice,
        uint256 startTime
    );

    // ========================= Modifiers =========================
    modifier noReentrant() {
        require(!_executing, "Reentrant call");
        _executing = true;
        _;
        _executing = false;
    }

    // ========================= External Functions =========================
    function queueSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        uint256 minAmountOut,
        uint160 maxSqrtPriceX96,
        uint160 minSqrtPriceX96,
        bytes calldata hookData
    ) external {
        PoolId poolId = key.toId();

        // Validate price limits
        if (maxSqrtPriceX96 > 0 && minSqrtPriceX96 > 0) {
            require(maxSqrtPriceX96 > minSqrtPriceX96, "Invalid price limits");
        }

        _addSwapToBatch(
            poolId,
            key,
            msg.sender,
            params,
            minAmountOut,
            maxSqrtPriceX96,
            minSqrtPriceX96,
            hookData
        );
    }

    // ========================= Internal Functions =========================
    function _queueSwap(
        PoolId poolId,
        PoolKey calldata key,
        address user,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal {
        // Decode additional parameters from hookData if provided
        (
            uint256 minAmountOut,
            uint160 maxSqrtPriceX96,
            uint160 minSqrtPriceX96
        ) = hookData.length >= 96
                ? abi.decode(hookData, (uint256, uint160, uint160))
                : (0, uint160(0), uint160(0));

        _addSwapToBatch(
            poolId,
            key,
            user,
            params,
            minAmountOut,
            maxSqrtPriceX96,
            minSqrtPriceX96,
            hookData
        );
    }

    function _addSwapToBatch(
        PoolId poolId,
        PoolKey calldata key,
        address user,
        SwapParams calldata params,
        uint256 minAmountOut,
        uint160 maxSqrtPriceX96,
        uint160 minSqrtPriceX96,
        bytes calldata hookData
    ) internal {
        // Validate swap parameters
        require(params.amountSpecified != 0, "Invalid amount");

        BatchedSwap memory newSwap = BatchedSwap({
            user: user,
            params: params,
            queueTime: block.timestamp,
            minAmountOut: minAmountOut,
            maxSqrtPriceX96: maxSqrtPriceX96,
            minSqrtPriceX96: minSqrtPriceX96,
            isExecuted: false,
            hookData: hookData
        });

        poolBatches[poolId].push(newSwap);
        userPendingSwaps[poolId][user]++;

        // Initialize or update batch state
        BatchState storage batchState = batchStates[poolId];
        if (!batchState.batchActive) {
            batchState.batchActive = true;
            batchState.batchStartTime = block.timestamp;
            batchState.referenceSqrtPriceX96 = _getCurrentSqrtPrice(poolId);
            emit BatchInitialized(
                poolId,
                batchState.referenceSqrtPriceX96,
                block.timestamp
            );
        }

        emit SwapQueued(
            poolId,
            user,
            poolBatches[poolId].length - 1,
            block.timestamp
        );
    }

    function _executeSwapAtReferencePrice(
        PoolKey calldata key,
        BatchedSwap memory swapData,
        uint160 referenceSqrtPriceX96
    ) internal returns (bool success) {
        // Validate price limits before execution
        if (!_validatePriceLimits(swapData, referenceSqrtPriceX96)) {
            return false;
        }

        // Create swap params with reference price as limit
        SwapParams memory batchParams = SwapParams({
            zeroForOne: swapData.params.zeroForOne,
            amountSpecified: swapData.params.amountSpecified,
            sqrtPriceLimitX96: referenceSqrtPriceX96
        });

        try _getPoolManager().swap(key, batchParams, swapData.hookData) returns (
            BalanceDelta delta
        ) {
            // Validate minimum output if specified
            if (swapData.minAmountOut > 0) {
                int256 outputAmount = swapData.params.zeroForOne
                    ? -delta.amount1()
                    : -delta.amount0();
                if (
                    outputAmount < 0 ||
                    uint256(outputAmount) < swapData.minAmountOut
                ) {
                    return false;
                }
            }
            return true;
        } catch {
            return false;
        }
    }

    function _executeSwapBatch(
        PoolKey calldata key,
        PoolId poolId,
        uint160 executionPrice
    ) internal returns (uint256 executedCount) {
        BatchedSwap[] storage batch = poolBatches[poolId];
        executedCount = 0;

        // Execute swaps up to maximum batch size
        for (
            uint256 i = 0;
            i < batch.length && executedCount < MAX_BATCH_SIZE;
            i++
        ) {
            if (!batch[i].isExecuted) {
                if (
                    _executeSwapAtReferencePrice(key, batch[i], executionPrice)
                ) {
                    batch[i].isExecuted = true;
                    executedCount++;
                    userPendingSwaps[poolId][batch[i].user]--;
                } else {
                    emit SwapFailed(
                        poolId,
                        batch[i].user,
                        i,
                        "Execution failed"
                    );
                }
            }
        }

        // Clean up executed swaps
        _cleanupBatch(poolId);

        return executedCount;
    }

    function _validatePriceLimits(
        BatchedSwap memory swapData,
        uint160 referenceSqrtPriceX96
    ) internal pure returns (bool) {
        // Check price limits based on swap direction
        if (swapData.params.zeroForOne) {
            // For zeroForOne swaps, check minimum price
            if (
                swapData.minSqrtPriceX96 > 0 &&
                referenceSqrtPriceX96 < swapData.minSqrtPriceX96
            ) {
                return false;
            }
        } else {
            // For oneForZero swaps, check maximum price
            if (
                swapData.maxSqrtPriceX96 > 0 &&
                referenceSqrtPriceX96 > swapData.maxSqrtPriceX96
            ) {
                return false;
            }
        }
        return true;
    }

    function _getCurrentPrice(
        PoolKey calldata key
    ) internal view returns (uint160) {
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(
            _getPoolManager(),
            poolId
        );
        return sqrtPriceX96;
    }

    function _isPriceWithinThreshold(
        uint160 referencePrice,
        uint160 currentPrice
    ) internal pure returns (bool) {
        if (referencePrice == 0 || currentPrice == 0) return false;

        uint256 priceDiff = referencePrice > currentPrice
            ? referencePrice - currentPrice
            : currentPrice - referencePrice;

        uint256 threshold = (uint256(referencePrice) *
            PRICE_DEVIATION_THRESHOLD) / BASIS_POINTS;

        return priceDiff <= threshold;
    }

    function _cleanupBatch(PoolId poolId) internal {
        BatchedSwap[] storage batch = poolBatches[poolId];
        uint256 writeIndex = 0;

        // Compact array by moving unexecuted swaps to front
        for (uint256 readIndex = 0; readIndex < batch.length; readIndex++) {
            if (!batch[readIndex].isExecuted) {
                if (writeIndex != readIndex) {
                    batch[writeIndex] = batch[readIndex];
                }
                writeIndex++;
            }
        }

        // Remove executed swaps from the end
        while (batch.length > writeIndex) {
            batch.pop();
        }
    }

    // ========================= View Functions =========================
    function getBatchInfo(
        PoolId poolId
    )
        external
        view
        returns (
            uint256 pendingSwaps,
            uint256 batchStartTime,
            uint256 timeUntilExecution,
            uint160 referencePrice,
            bool batchActive,
            uint256 batchCount,
            uint256 totalQueuedSwaps
        )
    {
        BatchState memory state = batchStates[poolId];
        uint256 currentTime = block.timestamp;

        return (
            poolBatches[poolId].length,
            state.batchStartTime,
            state.batchStartTime + BATCH_INTERVAL > currentTime
                ? state.batchStartTime + BATCH_INTERVAL - currentTime
                : 0,
            state.referenceSqrtPriceX96,
            state.batchActive,
            state.batchCount,
            state.totalQueuedSwaps
        );
    }

    function getUserPendingSwaps(
        PoolId poolId,
        address user
    ) external view returns (uint256) {
        return userPendingSwaps[poolId][user];
    }

    function canExecuteBatch(PoolId poolId) external view returns (bool) {
        BatchState memory state = batchStates[poolId];
        return
            state.batchActive &&
            block.timestamp >= state.batchStartTime + BATCH_INTERVAL &&
            poolBatches[poolId].length > 0;
    }

    function getBatchDetails(
        PoolId poolId,
        uint256 startIndex,
        uint256 count
    ) external view returns (BatchedSwap[] memory) {
        BatchedSwap[] storage batch = poolBatches[poolId];
        require(startIndex < batch.length, "Start index out of bounds");

        uint256 endIndex = startIndex + count;
        if (endIndex > batch.length) {
            endIndex = batch.length;
        }

        BatchedSwap[] memory result = new BatchedSwap[](endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = batch[i];
        }

        return result;
    }

    function getNextExecutionTime(
        PoolId poolId
    ) external view returns (uint256) {
        BatchState memory state = batchStates[poolId];
        if (!state.batchActive) {
            return 0;
        }
        return state.batchStartTime + BATCH_INTERVAL;
    }

    // ========================= Abstract Functions =========================
    function _getPoolManager() internal view virtual returns (IPoolManager);
    function _getCurrentSqrtPrice(PoolId poolId) internal view virtual returns (uint160);
} 