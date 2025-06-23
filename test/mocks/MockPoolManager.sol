// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

contract MockPoolManager {
    mapping(PoolId => uint160) private mockSqrtPrices;
    mapping(PoolId => bytes32) private mockPoolStates;
    BalanceDelta private mockDelta;
    
    function setMockSqrtPrice(PoolId poolId, uint160 sqrtPrice) external {
        mockSqrtPrices[poolId] = sqrtPrice;
        
        // Create a mock pool state that StateLibrary.getSlot0 can decode
        // Format: 24 bits protocolFee | 24 bits lpFee | 24 bits tick | 160 bits sqrtPriceX96
        bytes32 poolState = bytes32(uint256(sqrtPrice)) | 
                           bytes32(uint256(3000) << 208) | // lpFee = 3000
                           bytes32(uint256(0) << 184);     // tick = 0
        
        mockPoolStates[poolId] = poolState;
    }
    
    function setMockDelta(BalanceDelta delta) external {
        mockDelta = delta;
    }
    
    function getBalanceDelta() external view returns (BalanceDelta) {
        return mockDelta;
    }
    
    // Mock implementation of extsload to return pool state for StateLibrary
    function extsload(bytes32 slot) external view returns (bytes32) {
        // StateLibrary.getSlot0 calls extsload with the pool state slot
        // We need to map this back to our pool ID
        for (uint256 i = 0; i < 1000; i++) { // Reasonable range for pool IDs
            PoolId testPoolId = PoolId.wrap(bytes32(i));
            bytes32 expectedSlot = StateLibrary.POOLS_SLOT;
            if (slot == expectedSlot) {
                return mockPoolStates[testPoolId];
            }
        }
        
        // If not found, return the sqrt price directly for backward compatibility
        PoolId poolId = PoolId.wrap(slot);
        uint160 sqrtPrice = mockSqrtPrices[poolId];
        return bytes32(uint256(sqrtPrice));
    }
    
    // Mock implementation for multiple extsload calls
    function extsload(bytes32 slot, uint256 count) external view returns (bytes32[] memory) {
        bytes32[] memory result = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = this.extsload(bytes32(uint256(slot) + i));
        }
        return result;
    }
    
    // Required IPoolManager functions - minimal implementations
    function initialize(PoolKey memory, uint160, bytes calldata) external pure returns (int24) {
        return 0;
    }
    
    function modifyLiquidity(PoolKey memory, ModifyLiquidityParams memory, bytes calldata) 
        external pure returns (BalanceDelta, BalanceDelta) {
        return (BalanceDelta.wrap(0), BalanceDelta.wrap(0));
    }
    
    function swap(PoolKey memory, SwapParams memory, bytes calldata) 
        external view returns (BalanceDelta) {
        // Return a mock delta that represents a successful swap
        // For zeroForOne swaps, return negative amount0 (token0 out) and positive amount1 (token1 in)
        // For oneForZero swaps, return positive amount0 (token0 in) and negative amount1 (token1 out)
        return BalanceDelta.wrap(0);
    }
    
    function donate(PoolKey memory, uint256, uint256, bytes calldata) 
        external pure returns (BalanceDelta) {
        return BalanceDelta.wrap(0);
    }
    
    function sync(Currency) external pure {}
    
    function take(Currency, address, uint256) external pure {}
    
    function settle() external payable returns (uint256) {
        return 0;
    }
    
    function settleFor(address) external payable returns (uint256) {
        return 0;
    }
    
    function clear(Currency, uint256) external pure {}
    
    function mint(address, uint256, Currency, uint256) external pure {}
    
    function burn(address, uint256, Currency, uint256) external pure {}
    
    function updateDynamicLPFee(PoolKey memory, uint24) external pure {}
    
    function getLiquidity(PoolId) external pure returns (uint128) {
        return 0;
    }
    
    function getLiquidity(PoolId, address, int24, int24, bytes32) external pure returns (uint128) {
        return 0;
    }
    
    function getPosition(PoolId, address, int24, int24, bytes32) 
        external pure returns (uint128, uint256, uint256) {
        return (0, 0, 0);
    }
    
    function getPoolBitmapInfo(bytes32) external pure returns (uint256) {
        return 0;
    }
    
    function getSlot0(PoolId poolId) external view returns (uint160, int24, uint24, uint24) {
        uint160 sqrtPrice = mockSqrtPrices[poolId];
        return (sqrtPrice, 0, 0, 3000);
    }
    
    function currencyDelta(address, Currency) external pure returns (int256) {
        return 0;
    }
    
    function accountPoolBalanceDelta(PoolKey memory, BalanceDelta, address) external pure {}
    
    function accountAppBalanceDelta(PoolKey memory, BalanceDelta, address) external pure {}

    // Simulation functions for testing hooks as PoolManager
    function simulateSwap(
        address hook,
        address sender,
        PoolKey memory key,
        SwapParams memory params,
        bytes memory hookData
    ) external {
        // Call beforeSwap as PoolManager
        (bool success, bytes memory returndata) = hook.call(
            abi.encodeWithSignature(
                "beforeSwap(address,(address,address,uint24,int24,address),(bool,int256,uint160),bytes)",
                sender,
                key,
                params,
                hookData
            )
        );
        require(success, string(returndata));
    }

    function simulateAfterSwap(
        address hook,
        address sender,
        PoolKey memory key,
        SwapParams memory params,
        BalanceDelta delta,
        bytes memory hookData
    ) external {
        // Call afterSwap as PoolManager
        (bool success, bytes memory returndata) = hook.call(
            abi.encodeWithSignature(
                "afterSwap(address,(address,address,uint24,int24,address),(bool,int256,uint160),int256,bytes)",
                sender,
                key,
                params,
                BalanceDelta.unwrap(delta),
                hookData
            )
        );
        require(success, string(returndata));
    }
} 