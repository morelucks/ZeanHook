// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";

contract MockPoolManager {
    mapping(PoolId => uint160) private mockSqrtPrices;
    BalanceDelta private mockDelta;
    
    function setMockSqrtPrice(PoolId poolId, uint160 sqrtPrice) external {
        mockSqrtPrices[poolId] = sqrtPrice;
    }
    
    function setMockDelta(BalanceDelta delta) external {
        mockDelta = delta;
    }
    
    function getBalanceDelta() external view returns (BalanceDelta) {
        return mockDelta;
    }
    
    // Mock implementation of extsload to return sqrt price
    function extsload(bytes32 slot) external view returns (bytes32) {
        PoolId poolId = PoolId.wrap(slot);
        uint160 sqrtPrice = mockSqrtPrices[poolId];
        return bytes32(uint256(sqrtPrice));
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
        external pure returns (BalanceDelta) {
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
    
    function getSlot0(PoolId) external pure returns (uint160, int24, uint24, uint24) {
        return (0, 0, 0, 0);
    }
    
    function currencyDelta(address, Currency) external pure returns (int256) {
        return 0;
    }
    
    function accountPoolBalanceDelta(PoolKey memory, BalanceDelta, address) external pure {}
    
    function accountAppBalanceDelta(PoolKey memory, BalanceDelta, address) external pure {}
} 