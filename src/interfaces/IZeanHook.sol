// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

interface IZeanHook {
    // ========================= Events =========================
    event ExecutorAuthorized(address indexed executor, bool authorized);

    // ========================= ZeanHook Specific Functions =========================
    function setExecutorAuthorization(address executor, bool authorized) external;
    function transferOwnership(address newOwner) external;
    function emergencyExecuteBatch(PoolKey calldata key) external;
    function executeBatchAfterReveal(PoolKey calldata key) external;
    function isAuthorizedExecutor(address executor) external view returns (bool);
} 