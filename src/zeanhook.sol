// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
 
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

/**
 * @title ZeanHook - Base contract for Uniswap V4 hooks
 * @notice This contract provides the foundation for implementing custom Uniswap V4 hooks.
 */
 
contract ZeanHook is BaseHook {

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
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

	
}