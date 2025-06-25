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
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {VolatilityManager} from "./libraries/VolatilityManager.sol";
import {BatchManager} from "./libraries/BatchManager.sol";
import {CommitRevealManager} from "./libraries/CommitRevealManager.sol";
import {IZeanHook} from "./interfaces/IZeanHook.sol";

interface IAVS {
    function validateAction(bytes calldata data, bytes calldata avsProof) external view returns (bool);
}

/**
 * @title ZeanHook - Base contract for Uniswap V4 hooks
 * @notice This contract provides the foundation for implementing custom Uniswap V4 hooks.
 */
contract ZeanHook is BaseHook, VolatilityManager, BatchManager, CommitRevealManager, IZeanHook {
    using PoolIdLibrary for PoolKey;

    IAVS public avs;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyAVSApproved(bytes memory data, bytes calldata avsProof) {
        require(avs.validateAction(data, avsProof), "AVS: Not approved");
        _;
    }

    /**
     * @notice Constructor initializes the hook with a PoolManager and AVS
     * @param _manager The address of the Uniswap V4 PoolManager contract
     * @param _avs The address of the AVS contract
     * @dev Inherits from BaseHook which provides core functionality
     */
    constructor(IPoolManager _manager, address _avs) BaseHook(_manager) {
        owner = msg.sender;
        authorizedExecutors[msg.sender] = true;
        avs = IAVS(_avs);
    }

    function setAVS(address _avs) external onlyOwner {
        require(_avs != address(0), "Invalid AVS address");
        avs = IAVS(_avs);
    }

    // ========================= Hook Permissions =========================
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
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

    // ========================= Hook Implementation =========================
    function _afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();

        priceHistory[poolId].push(PriceData({sqrtPriceX96: sqrtPriceX96, timestamp: block.timestamp}));

        volatilityMetrics[poolId] =
            VolatilityMetrics({volatility: MIN_SLIPPAGE, lastUpdate: block.timestamp, sampleCount: 1});

        emit PriceRecorded(poolId, sqrtPriceX96, block.timestamp);

        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Extract avsProof from hookData (assume first 96 bytes for proof, rest is other data)
        bytes calldata avsProof = hookData[:96];
        bytes memory dataToValidate = abi.encode(sender, key, params);
        require(avs.validateAction(dataToValidate, avsProof), "AVS: Swap not approved");
        PoolId poolId = key.toId();

        uint256 adjustedSlippage = calculateVolatilityAdjustedSlippage(poolId);

        _validateSwapSlippage(adjustedSlippage, hookData);

        _queueSwap(poolId, key, sender, params, hookData);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();

        uint160 currentSqrtPrice = _getCurrentSqrtPrice(poolId);
        _recordPriceData(poolId, currentSqrtPrice);

        _updateVolatilityMetrics(poolId);

        lastSwapTimestamp[poolId] = block.timestamp;

        return (BaseHook.afterSwap.selector, 0);
    }

    // ========================= Commit-Reveal Batch Execution =========================
    function executeBatchAfterReveal(PoolKey calldata key, bytes calldata avsProof)
        external
        override
        onlyAuthorizedExecutor
        noReentrant
    {
        bytes memory dataToValidate = abi.encode(msg.sender, key, "executeBatchAfterReveal");
        require(avs.validateAction(dataToValidate, avsProof), "AVS: Batch not approved");

        PoolId poolId = key.toId();
        BatchState storage batchState = batchStates[poolId];

        require(batchState.revealPhaseActive, "No active reveal phase");
        require(block.timestamp >= batchState.revealPhaseStart + REVEAL_PHASE_DURATION, "Reveal phase not ended");

        // Convert revealed commits to batched swaps
        _processRevealedCommits(poolId, key);

        // Execute the batch
        uint160 executionPrice = _getCurrentPrice(key);
        uint256 executedCount = _executeSwapBatch(key, poolId, executionPrice);

        // Update state
        batchState.batchCount++;
        batchState.totalQueuedSwaps += executedCount;
        batchState.revealPhaseActive = false;

        // Clear commit data
        _clearCommitData(poolId);

        emit BatchExecuted(poolId, executedCount, executionPrice, block.timestamp);
    }

    // ========================= Admin Functions =========================
    function setExecutorAuthorization(address executor, bool authorized) external override onlyOwner {
        authorizedExecutors[executor] = authorized;
        emit ExecutorAuthorized(executor, authorized);
    }

    function transferOwnership(address newOwner) external override onlyOwner {
        require(newOwner != address(0), "Invalid new owner");
        owner = newOwner;
        authorizedExecutors[newOwner] = true;
    }

    function emergencyExecuteBatch(PoolKey calldata key, bytes calldata avsProof)
        external
        override
        onlyOwner
        noReentrant
    {
        bytes memory dataToValidate = abi.encode(msg.sender, key, "emergencyExecuteBatch");
        require(avs.validateAction(dataToValidate, avsProof), "AVS: Emergency batch not approved");

        PoolId poolId = key.toId();
        BatchState storage batchState = batchStates[poolId];

        require(batchState.batchActive, "No active batch");
        require(poolBatches[poolId].length > 0, "Empty batch");

        uint160 executionPrice = batchState.referenceSqrtPriceX96;
        uint256 executedCount = _executeSwapBatch(key, poolId, executionPrice);

        // Update state
        batchState.batchCount++;
        batchState.totalQueuedSwaps += executedCount;

        if (poolBatches[poolId].length == 0) {
            batchState.batchActive = false;
        } else {
            batchState.batchStartTime = block.timestamp;
            batchState.referenceSqrtPriceX96 = _getCurrentPrice(key);
        }

        emit BatchExecuted(poolId, executedCount, executionPrice, block.timestamp);
    }

    // ========================= View Functions =========================
    function isAuthorizedExecutor(address executor) external view override returns (bool) {
        return authorizedExecutors[executor];
    }

    function getUserCommit(PoolId poolId, address user, uint256 index) external view returns (SwapCommit memory) {
        return userCommits[poolId][user][index];
    }

    function getBatchState(PoolId poolId) external view returns (BatchState memory) {
        return batchStates[poolId];
    }

    // ========================= Internal Overrides =========================
    function _getPoolManager() internal view override(BatchManager) returns (IPoolManager) {
        return poolManager;
    }

    function _getCurrentSqrtPrice(PoolId poolId)
        internal
        view
        override(BatchManager, VolatilityManager)
        returns (uint160)
    {
        bytes32 slot0 = poolManager.extsload(bytes32(uint256(PoolId.unwrap(poolId))));
        uint160 sqrtPriceX96 = uint160(uint256(slot0));
        return sqrtPriceX96;
    }
}
