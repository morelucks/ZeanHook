// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {ZeanHook} from "src/ZeanHook.sol";

contract DeployZeanHookScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    IPoolManager constant POOLMANAGER = IPoolManager(address(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543));
    address constant AVS = address(0xa789c91ECDdae96865913130B786140Ee17aF545);

    function setUp() public {}

    function run() public {
        // Set the flags for ZeanHook (update if you add more hook points)
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        bytes memory constructorArgs = abi.encode(POOLMANAGER, AVS);

        // Mine a salt for the correct address
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(ZeanHook).creationCode, constructorArgs);

        // Deploy ZeanHook using CREATE2
        vm.broadcast();
        ZeanHook hook = new ZeanHook{salt: salt}(POOLMANAGER, AVS);
        require(address(hook) == hookAddress, "DeployZeanHook: hook address mismatch");

        console.log("ZeanHook deployed at:", address(hook));
    }
}
