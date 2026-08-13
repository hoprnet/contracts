// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import { Test, stdStorage, stdJson, StdStorage } from "forge-std/Test.sol";
import { NetworkConfig } from "./utils/NetworkConfig.s.sol";
import { BoostUtilsLib } from "./utils/BoostUtilsLib.sol";
import {
    Clearance,
    CapabilityPermission,
    Target,
    TargetType,
    TargetUtils,
    TargetPermission
} from "../src/utils/TargetUtils.sol";
import { HoprNodeSafeRegistry } from "../src/node-stake/NodeSafeRegistry.sol";
import { Enum, IAvatar } from "../src/interfaces/IAvatar.sol";
import { SafeSuiteLibV141 } from "../src/utils/SafeSuiteLibV141.sol";

abstract contract IFactory {
    function clone(
        address moduleSingletonAddress,
        address[] memory admins,
        uint256 nonce,
        bytes32 defaultTarget
    )
        public
        virtual
        returns (address, address payable);
}

abstract contract IModule {
    function tryGetTarget(address targetAddress) external view virtual returns (bool, Target);
}

/// Failed to read balance of a token contract
/// @param token token address.
error FailureInReadBalance(address token);

/**
 * @dev script to interact with contract(s) of a given environment where the msg.sender comes from the environment
 * variable `PRIVATE_KEY`
 * Private key of the caller must be saved under the environment variable `PRIVATE_KEY`
 * Wrapper of contracts (incl. NetworkRegistery, HoprStake) with detection of contract address per
 * network/environment_type
 */
contract SingleActionFromPrivateKeyScript is Test, NetworkConfig {
    using stdJson for string;
    using stdStorage for StdStorage;

    using BoostUtilsLib for address;
    using TargetUtils for Target;

    address msgSender;
    string[] private unregisteredIds;
    address[] private accounts;
    address[] private nodes;

    function getNetworkAndMsgSender() private {
        // 1. Network check
        // get environment of the script
        getNetwork();
        // read records of deployed files
        readCurrentNetwork();

        // 2. Get private key of caller
        // Set to default when it's in development environment (uint for
        // 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        uint256 privateKey = currentEnvironmentType == EnvironmentType.LOCAL
            ? 77_814_517_325_470_205_911_140_941_194_401_928_579_557_062_014_761_831_930_645_393_041_380_819_009_408
            : vm.envUint("PRIVATE_KEY");
        msgSender = vm.addr(privateKey);
        emit log_named_address("msgSender address", msgSender);
        vm.startBroadcast(privateKey);
    }

    /**
     * @dev Move nodes that are associated to an old safe to a new safe
     * Use admin key (of the old Safe) to
     * - Deregister node from Node-safe registry
     *
     * Use admin key (of the new Safe) to
     * - Include node to module
     *
     * Use manager to
     * - Deregister nodes from Network Registry
     * - Re-register nodes with the new safe in Network Registry
     *
     * @notice Assume the private keys of the admin of old & new safes are the same
     *
     * @param nodeAddresses array of node addresses
     * @param safeAddress new safe addresses that nodes attach to
     * @param moduleAddress new module addresses that nodes attach to
     */
    function moveNodesToSafeModule(
        address[] memory nodeAddresses,
        address safeAddress,
        address moduleAddress
    )
        external
    {
        // 1. get environment and msg.sender
        getNetworkAndMsgSender();

        // 2. include nodes to the module, as an owner of safe
        includeNodesToModuleBySafe(nodeAddresses, safeAddress, moduleAddress);

        // 3. deregister nodes from the nodes-safe registry
        deregisterNodesFromNodeSafeRegistry(nodeAddresses);
        // addition will be done by nodes on-start

        vm.stopBroadcast();
    }

    /**
     * @dev create a safe proxy and moodule proxy.
     * Perform the following actions as the owner of safe:
     * - include nodes to the module
     * - approve token transfer
     * - add announcement contract as target
     * As manager of network registry, add nodes and safe to network registry
     * Perform the following actions, as deployer
     * - transfer some tokens to safe
     * - transfer some xDAI to nodes
     *
     * @notice Deployer is the single owner of safe
     * nonce is the current nonce of deployer account
     * Default fallback permission for module is to
     * 1. allow all data to Channels contract
     * 2. allow all data to Token contract
     * 3. allow nodes to send native tokens to itself
     *
     * Give Channels max allowance to transfer Token for safe
     *
     * Add node safes to network registry, as a manager
     * @param nodeAddresses array of node addresses to be added to the module
     * @param hoprTokenAmountInWei, The amount of HOPR tokens that recipient is desired to receive
     * @param nativeTokenAmountInWei The amount of native tokens that recipient is desired to receive
     */
    function expressSetupSafeModule(
        address[] memory nodeAddresses,
        uint256 hoprTokenAmountInWei,
        uint256 nativeTokenAmountInWei
    )
        external
        returns (address safe, address module)
    {
        // 1. get environment and msg.sender
        getNetworkAndMsgSender();

        // 2. prepare parameters for proxy deployment
        address[] memory admins = new address[](1);
        admins[0] = msgSender;
        /**
         * Array of capability permissions
         *     [
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, // defaultRedeemTicketSafeFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, // RESERVED
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, // defaultCloseIncomingChannelSafeFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, //
         * defaultInitiateOutgoingChannelClosureSafeFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, //
         * defaultFinalizeOutgoingChannelClosureSafeFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, // defaultFundChannelMultiFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, // defaultSetCommitmentSafeFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, // defaultApproveFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW // defaultSendFunctionPermisson
         *     ]
         */
        CapabilityPermission[] memory defaultChannelsCapabilityPermissions = new CapabilityPermission[](9);
        for (uint256 i = 0; i < defaultChannelsCapabilityPermissions.length; i++) {
            defaultChannelsCapabilityPermissions[i] = CapabilityPermission.SPECIFIC_FALLBACK_ALLOW;
        }
        Target defaultModulePermission = TargetUtils.encodeDefaultPermissions(
            currentNetworkDetail.addresses.channelsContractAddress,
            Clearance.FUNCTION,
            TargetType.CHANNELS,
            TargetPermission.ALLOW_ALL,
            defaultChannelsCapabilityPermissions
        );

        bytes32 saltNonce = keccak256(abi.encodePacked(msgSender, vm.getNonce(msgSender)));

        // 3. deploy two proxy instances
        (module, safe) = IFactory(currentNetworkDetail.addresses.nodeStakeFactoryAddress)
            .clone(
                currentNetworkDetail.addresses.moduleImplementationAddress,
                admins,
                uint256(saltNonce),
                bytes32(Target.unwrap(defaultModulePermission))
            );

        emit log_string(string(
                abi.encodePacked("--safeAddress ", vm.toString(safe), " --moduleAddress ", vm.toString(module))
            ));

        // 4. include nodes to the module, as an owner of safe
        includeNodesToModuleBySafe(nodeAddresses, safe, module);

        // 5. approve token transfer, as an owner of safe
        approveChannelsForTokenTransferBySafe(safe);

        // 6. add announcement contract as target, as an owner of safe
        addAllAllowedTargetToModuleBySafe(currentNetworkDetail.addresses.announcements, safe, module);
        // bytes memory
        vm.stopBroadcast();

        // Use a different private key to send funds
        _helperGetDeployerInternalKey();
        // 7. transfer some tokens to safe
        transferOrMintHoprAndSendNativeToAmount(safe, hoprTokenAmountInWei, nativeTokenAmountInWei);

        // 8. transfer some xDAI to nodes
        for (uint256 n = 0; n < nodeAddresses.length; n++) {
            transferOrMintHoprAndSendNativeToAmount(nodeAddresses[n], 0, nativeTokenAmountInWei);
        }
    }

    /**
     * @dev Configure a safe proxy and module proxy.
     * Perform the following actions as the owner of safe:
     * - include nodes to the module
     * - add announcement contract as target
     * As manager of network registry, add nodes and safe to network registry
     *
     * @notice Deployer is the single owner of safe
     * nonce is the current nonce of deployer account
     * Default fallback permission for module is to
     * 1. allow all data to Channels contract
     * 2. allow all data to Token contract
     * 3. allow nodes to send native tokens to itself
     *
     * Add node safes to network registry, as a manager
     * @param nodeAddresses array of node addresses to be added to the module
     * @param safe safe address of node
     * @param module module address of node
     */
    function configureSafeModule(address[] memory nodeAddresses, address safe, address module) external {
        // 1. get environment and msg.sender
        getNetworkAndMsgSender();

        /**
         * Array of capability permissions
         *     [
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, // defaultRedeemTicketSafeFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, // RESERVED
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, // defaultCloseIncomingChannelSafeFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, //
         * defaultInitiateOutgoingChannelClosureSafeFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, //
         * defaultFinalizeOutgoingChannelClosureSafeFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, // defaultFundChannelMultiFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, // defaultSetCommitmentSafeFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, // defaultApproveFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW // defaultSendFunctionPermisson
         *     ]
         */
        CapabilityPermission[] memory defaultChannelsCapabilityPermissions = new CapabilityPermission[](9);
        for (uint256 i = 0; i < defaultChannelsCapabilityPermissions.length; i++) {
            defaultChannelsCapabilityPermissions[i] = CapabilityPermission.SPECIFIC_FALLBACK_ALLOW;
        }
        // 1. include nodes to the module, as an owner of safe
        includeNodesToModuleBySafe(nodeAddresses, safe, module);

        // 2. approve token transfer, as an owner of safe
        approveChannelsForTokenTransferBySafe(safe);

        // 3. add announcement contract as target, as an owner of safe
        addAllAllowedTargetToModuleBySafe(currentNetworkDetail.addresses.announcements, safe, module);
        // bytes memory
        vm.stopBroadcast();

        // 4. add nodes and safe to network registry, as a manager of network registry
        address[] memory stakingSafeAddresses = new address[](nodeAddresses.length);
        for (uint256 m = 0; m < nodeAddresses.length; m++) {
            stakingSafeAddresses[m] = safe;
        }
        _helperGetDeployerInternalKey();

        vm.stopBroadcast();
    }

    /**
     * @dev Given existing node(s), safe and module, migrate them to a different network
     * Perform the following actions as the owner of safe:
     * - scope new channel contract
     * - approve token transfer
     * - add announcement contract as target
     * As manager of network registry, add nodes and safe to network registry
     *
     * @notice Deployer is the single owner of safe
     * nonce is the current nonce of deployer account
     * Default fallback permission for module is to
     * 1. allow all data to Channels contract
     * 2. allow all data to Token contract
     * 3. allow nodes to send native tokens to itself
     *
     * Give Channels max allowance to transfer Token for safe
     *
     * Add node safes to network registry, as a manager
     * @param safe safe address of node
     * @param module module address of node
     */
    function migrateSafeModule(address safe, address module) external {
        // 1. get environment and msg.sender
        getNetworkAndMsgSender();

        // 2. scope channel contract of the new network
        addNetworkChannelsTargetToModuleBySafe(safe, module);

        // 3. approve token transfer, as an owner of safe
        approveChannelsForTokenTransferBySafe(safe);

        // 4. add announcement contract as target, as an owner of safe
        addAllAllowedTargetToModuleBySafe(currentNetworkDetail.addresses.announcements, safe, module);
        // bytes memory
        vm.stopBroadcast();
    }

    function includeNodesToModuleBySafe(address[] memory nodeAddresses, address safe, address module) public {
        // 1. get the msgSender if not set. This msgSender should be the owner of safe to execute the tx
        if (msgSender == address(0)) {
            // get environment and msg.sender
            getNetworkAndMsgSender();
        }

        // 2. prepare target permission data
        /**
         * Array of node permissions, where nothing is specified and falls back to the default
         *     [
         *       CapabilityPermission.NONE,
         *       CapabilityPermission.NONE,
         *       CapabilityPermission.NONE,
         *       CapabilityPermission.NONE,
         *       CapabilityPermission.NONE,
         *       CapabilityPermission.NONE,
         *       CapabilityPermission.NONE,
         *       CapabilityPermission.NONE,
         *       CapabilityPermission.NONE
         *     ]
         */
        CapabilityPermission[] memory nodeDefaultPermission = new CapabilityPermission[](9);
        for (uint256 i = 0; i < nodeDefaultPermission.length; i++) {
            nodeDefaultPermission[i] = CapabilityPermission.NONE;
        }
        // allow node to send native tokens to itself
        Target[] memory defaultNodeTargets = new Target[](nodeAddresses.length);
        for (uint256 j = 0; j < nodeAddresses.length; j++) {
            defaultNodeTargets[j] = TargetUtils.encodeDefaultPermissions(
                nodeAddresses[j], Clearance.FUNCTION, TargetType.SEND, TargetPermission.ALLOW_ALL, nodeDefaultPermission
            );
        }

        // 4. include nodes to the module, as an owner of safe
        for (uint256 k = 0; k < nodeAddresses.length; k++) {
            // check if node is included in module
            (bool successReadIncluded, bytes memory returndataReadIncluded) =
                module.staticcall(abi.encodeWithSignature("isNode(address)", nodeAddresses[k]));
            if (!successReadIncluded) {
                revert("Cannot read isNode from module contract.");
            }
            bool included = abi.decode(returndataReadIncluded, (bool));
            if (!included) {
                bytes memory includeNodeData =
                    abi.encodeWithSignature("includeNode(uint256)", Target.unwrap(defaultNodeTargets[k]));
                uint256 safeNonce = IAvatar(payable(safe)).nonce();
                _helperSignSafeTxAsOwner(IAvatar(payable(safe)), module, safeNonce, includeNodeData);
            }
        }
    }

    function approveChannelsForTokenTransferBySafe(address safe) public {
        // 1. get the msgSender if not set. This msgSender should be the owner of safe to execute the tx
        if (msgSender == address(0)) {
            // get environment and msg.sender
            getNetworkAndMsgSender();
        }

        // 2. prepare data payload for approve
        bytes memory approveData = abi.encodeWithSignature(
            "approve(address,uint256)", currentNetworkDetail.addresses.channelsContractAddress, type(uint256).max
        );
        _helperSignSafeTxAsOwner(
            IAvatar(payable(safe)),
            currentNetworkDetail.addresses.tokenContractAddress,
            IAvatar(payable(safe)).nonce(),
            approveData
        );
    }

    /**
     * @dev Claim one service type in the registry, as an owner of the Safe that becomes the type
     * owner.
     *
     * Type ids go to the first payer, so the launch procedure of section 9.4 claims every
     * canonical id before the address of the registry is announced. `DeployAll.s.sol` claims
     * `gvpn:exit` in LOCAL only, and every other environment uses this action.
     *
     * The approval and the claim travel in one MultiSend bundle, so the Safe executes one
     * transaction. The approval is exactly the fee that this script reads at build time. A fee
     * that rises at the same time therefore reverts on the allowance instead of an overpayment.
     *
     * @param safe the Safe that pays the fee and becomes the type owner
     * @param serviceType the `bytes32` id to claim, by convention right-padded ASCII
     * @param requirement the policy contract of the type, or `address(0)` for an open type
     * @param registrationBurn the `selfRegister` burn of the type
     * @param updateBurn the `selfUpdate` burn of the type
     */
    function registerServiceType(
        address safe,
        bytes32 serviceType,
        address requirement,
        uint256 registrationBurn,
        uint256 updateBurn
    )
        public
    {
        // 1. get the msgSender if not set. This msgSender should be the owner of safe to execute the tx
        if (msgSender == address(0)) {
            getNetworkAndMsgSender();
        }

        address registry = currentNetworkDetail.addresses.serviceRegistryAddress;
        require(isValidAddress(registry), "HoprServiceRegistry is not deployed on this network");

        // 2. read the fee that the registry burns right now, and approve exactly that amount
        uint256 typeRegistrationFee = _helperReadTypeRegistrationFee(registry);

        bytes memory multiSendData = buildRegisterServiceTypePayload(
            currentNetworkDetail.addresses.tokenContractAddress,
            registry,
            typeRegistrationFee,
            serviceType,
            requirement,
            registrationBurn,
            updateBurn
        );

        // 3. a MultiSend bundle must run in the context of the Safe, so it needs a delegate call
        _helperSignSafeTxAsOwner(
            IAvatar(payable(safe)),
            SafeSuiteLibV141.SAFE_MultiSendCallOnly_ADDRESS,
            IAvatar(payable(safe)).nonce(),
            multiSendData,
            Enum.Operation.DelegateCall
        );
    }

    /**
     * @dev Build the MultiSend payload that approves the fee and then claims the type.
     *
     * This function is pure and public so that a test can assert the encoding without a live Safe.
     *
     * @return the calldata of `multiSend(bytes)`, for a delegate call from the Safe
     */
    function buildRegisterServiceTypePayload(
        address token,
        address registry,
        uint256 typeRegistrationFee,
        bytes32 serviceType,
        address requirement,
        uint256 registrationBurn,
        uint256 updateBurn
    )
        public
        pure
        returns (bytes memory)
    {
        uint8[] memory txOperations = new uint8[](2);
        address[] memory txTos = new address[](2);
        uint256[] memory txValues = new uint256[](2);
        uint256[] memory dataLengths = new uint256[](2);
        bytes[] memory data = new bytes[](2);

        data[0] = abi.encodeWithSignature("approve(address,uint256)", registry, typeRegistrationFee);
        data[1] = abi.encodeWithSignature(
            "registerServiceType(bytes32,address,uint256,uint256)",
            serviceType,
            requirement,
            registrationBurn,
            updateBurn
        );

        txTos[0] = token;
        txTos[1] = registry;

        for (uint256 i = 0; i < data.length; i++) {
            // 0 is Call. MultiSendCallOnly rejects a delegate call inside the bundle.
            txOperations[i] = 0;
            txValues[i] = 0;
            dataLengths[i] = data[i].length;
        }

        return _helperBuildMultiSendTx(txOperations, txTos, txValues, dataLengths, data);
    }

    /// @dev Read the current type-registration fee of the registry.
    function _helperReadTypeRegistrationFee(address registry) private view returns (uint256) {
        (bool success, bytes memory returnData) = registry.staticcall(abi.encodeWithSignature("typeRegistrationFee()"));
        require(success && returnData.length == 32, "cannot read typeRegistrationFee from the registry");
        return abi.decode(returnData, (uint256));
    }

    function deregisterNodesFromNodeSafeRegistry(address[] memory nodeAddresses) public {
        // 1. get the msgSender if not set. This msgSender should be the owner of safe to execute the tx
        if (msgSender == address(0)) {
            // get environment and msg.sender
            getNetworkAndMsgSender();
        }

        // 2. prepare data payload for the deregistration
        for (uint256 i = 0; i < nodeAddresses.length; i++) {
            address safe = HoprNodeSafeRegistry(currentNetworkDetail.addresses.nodeSafeRegistryAddress)
                .nodeToSafe(nodeAddresses[i]);

            bytes memory safeTxData =
                abi.encodeWithSelector(HoprNodeSafeRegistry.deregisterNodeBySafe.selector, nodeAddresses[i]);

            _helperSignSafeTxAsOwner(
                IAvatar(payable(safe)),
                currentNetworkDetail.addresses.nodeSafeRegistryAddress,
                IAvatar(payable(safe)).nonce(),
                safeTxData
            );
        }
    }

    /**
     * add an ALL_ALLOWED target to the module, by the safe
     * Abuse TOKEN type
     */
    function addAllAllowedTargetToModuleBySafe(address targetAddress, address safe, address module) public {
        // 1. get the msgSender if not set. This msgSender should be the owner of safe to execute the tx
        if (msgSender == address(0)) {
            // get environment and msg.sender
            getNetworkAndMsgSender();
        }

        // 2. prepare target permission data
        /**
         * Array of node permissions, where nothing is specified and falls back to the default
         *     [
         *       CapabilityPermission.NONE,
         *       CapabilityPermission.NONE,
         *       CapabilityPermission.NONE,
         *       CapabilityPermission.NONE,
         *       CapabilityPermission.NONE,
         *       CapabilityPermission.NONE,
         *       CapabilityPermission.NONE,
         *       CapabilityPermission.NONE,
         *       CapabilityPermission.NONE
         *     ]
         */
        CapabilityPermission[] memory defaultPermission = new CapabilityPermission[](9);
        for (uint256 i = 0; i < defaultPermission.length; i++) {
            defaultPermission[i] = CapabilityPermission.NONE;
        }
        // abuse the fast return and assign target as 0
        Target target = TargetUtils.encodeDefaultPermissions(
            targetAddress, Clearance.FUNCTION, TargetType.TOKEN, TargetPermission.ALLOW_ALL, defaultPermission
        );

        // 4. include the target to the module, as an owner of safe
        // check if target has been included in module.
        try IModule(module).tryGetTarget(targetAddress) returns (bool successReadTryGetTarget, Target) {
            if (successReadTryGetTarget) {
                // already included, skip
                return;
            }
            bytes memory scopeTargetData = abi.encodeWithSignature("scopeTargetToken(uint256)", Target.unwrap(target));
            uint256 safeNonce = IAvatar(payable(safe)).nonce();

            _helperSignSafeTxAsOwner(IAvatar(payable(safe)), module, safeNonce, scopeTargetData);
        } catch {
            // either it's an old module where tryGetTarget was not implemented, or the module is not valid
            emit log_string("Cannot read tryGetTarget from module contract. Either it's an old module where tryGetTarget was not implemented, or the module is not valid");
        }
    }

    /**
     * add an ALL_ALLOWED Channels target of the current network's channels contract to the module, by the safe
     */
    function addNetworkChannelsTargetToModuleBySafe(address safe, address module) public {
        // 1. get the msgSender if not set. This msgSender should be the owner of safe to execute the tx
        if (msgSender == address(0)) {
            // get environment and msg.sender
            getNetworkAndMsgSender();
        }
        address targetAddress = currentNetworkDetail.addresses.channelsContractAddress;
        // 2. scope channel contract
        /**
         * Array of capability permissions
         *     [
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, // defaultRedeemTicketSafeFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, // RESERVED
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, // defaultCloseIncomingChannelSafeFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, //
         * defaultInitiateOutgoingChannelClosureSafeFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, //
         * defaultFinalizeOutgoingChannelClosureSafeFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, // defaultFundChannelMultiFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, // defaultSetCommitmentSafeFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW, // defaultApproveFunctionPermisson
         *       CapabilityPermission.SPECIFIC_FALLBACK_ALLOW // defaultSendFunctionPermisson
         *     ]
         */
        CapabilityPermission[] memory channelsCapabilityPermissions = new CapabilityPermission[](9);
        for (uint256 i = 0; i < channelsCapabilityPermissions.length; i++) {
            channelsCapabilityPermissions[i] = CapabilityPermission.SPECIFIC_FALLBACK_ALLOW;
        }
        Target target = TargetUtils.encodeDefaultPermissions(
            targetAddress,
            Clearance.FUNCTION,
            TargetType.CHANNELS,
            TargetPermission.ALLOW_ALL,
            channelsCapabilityPermissions
        );

        // 3. include the target to the module, as an owner of safe
        // check if target has been included in module.
        try IModule(module).tryGetTarget(targetAddress) returns (bool successReadTryGetTarget, Target) {
            if (successReadTryGetTarget) {
                // already included, skip
                return;
            }
            // or scope the target
            bytes memory scopeTargetData =
                abi.encodeWithSignature("scopeTargetChannels(uint256)", Target.unwrap(target));
            uint256 safeNonce = IAvatar(payable(safe)).nonce();

            _helperSignSafeTxAsOwner(IAvatar(payable(safe)), module, safeNonce, scopeTargetData);
        } catch {
            // either it's an old module where tryGetTarget was not implemented, or the module is not valid
            emit log_string("Cannot read tryGetTarget from module contract. Either it's an old module where tryGetTarget was not implemented, or the module is not valid");
        }
    }

    /**
     * Scope the current network's service registry on an already-deployed node module.
     * The module itself restricts this target to selfRegister, selfUpdate and selfDeregister,
     * with the node argument required to match the calling module member.
     */
    function addNetworkServiceRegistryTargetToModuleBySafe(address safe, address module) public {
        if (msgSender == address(0)) {
            getNetworkAndMsgSender();
        }

        address targetAddress = currentNetworkDetail.addresses.serviceRegistryAddress;
        try IModule(module).tryGetTarget(targetAddress) returns (bool successReadTryGetTarget, Target) {
            if (successReadTryGetTarget) {
                return;
            }

            bytes memory scopeTargetData = abi.encodeWithSignature("scopeTargetServiceRegistry(address)", targetAddress);
            _helperSignSafeTxAsOwner(IAvatar(payable(safe)), module, IAvatar(payable(safe)).nonce(), scopeTargetData);
        } catch {
            emit log_string("Cannot read tryGetTarget from module contract. Upgrade the module before scoping the service registry");
        }
    }

    /**
     * @dev get the deployer key
     * Set to default when it's in development environment
     * (uint for 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
     */
    function _helperGetDeployerInternalKey() private {
        uint256 deployerPrivateKey = currentEnvironmentType == EnvironmentType.LOCAL
            ? 77_814_517_325_470_205_911_140_941_194_401_928_579_557_062_014_761_831_930_645_393_041_380_819_009_408
            : vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);
        emit log_named_address("deployerAddress", deployerAddress);
        vm.startBroadcast(deployerPrivateKey);
    }

    /**
     * @dev when caller is owner of safe instance, prepare a signature and execute the transaction
     */
    function _helperSignSafeTxAsOwner(IAvatar safe, address target, uint256 nonce, bytes memory data) private {
        _helperSignSafeTxAsOwner(safe, target, nonce, data, Enum.Operation.Call);
    }

    /**
     * @dev The same as above, with an explicit operation.
     *
     * A MultiSend bundle needs `DelegateCall`, because the bundle must run in the context of the
     * Safe. Every other action here uses `Call`.
     */
    function _helperSignSafeTxAsOwner(
        IAvatar safe,
        address target,
        uint256 nonce,
        bytes memory data,
        Enum.Operation operation
    )
        private
    {
        bytes32 dataHash = safe.getTransactionHash(target, 0, data, operation, 0, 0, 0, address(0), msgSender, nonce);

        // sign dataHash
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(vm.envUint("PRIVATE_KEY"), dataHash);
        safe.execTransaction(
            target, 0, data, operation, 0, 0, 0, address(0), payable(address(msgSender)), abi.encodePacked(r, s, v)
        );
    }

    /**
     * @dev This function funds a recipient wallet with HOPR tokens and native tokens, but only when the recipient has
     * not yet received
     * enough value.
     * First, HOPR tokens are prioritized to be transferred than minted to the recipient
     * Native tokens are transferred to the recipient
     * @param recipient The address of the recipient wallet.
     * @param hoprTokenAmountInWei, The amount of HOPR tokens that recipient is desired to receive
     * @param nativeTokenAmountInWei The amount of native tokens that recipient is desired to receive
     */
    function transferOrMintHoprAndSendNativeToAmount(
        address recipient,
        uint256 hoprTokenAmountInWei,
        uint256 nativeTokenAmountInWei
    )
        public
        payable
    {
        // 1. get environment and msg.sender
        getNetworkAndMsgSender();

        // 2. transfer or mint hopr tokens
        _transferOrMintHoprToAmount(
            currentNetworkDetail.addresses.tokenContractAddress, recipient, hoprTokenAmountInWei
        );

        // 3. transfer native balance to the recipient
        if (nativeTokenAmountInWei > recipient.balance) {
            (bool nativeTokenTransferSuccess,) = recipient.call{ value: nativeTokenAmountInWei - recipient.balance }("");
            require(nativeTokenTransferSuccess, "Cannot send native tokens to the recipient");
        }
        vm.stopBroadcast();
    }

    /**
     * Get the token balance of a wallet
     */
    function _getTokenBalanceOf(address tokenAddress, address wallet) internal view returns (uint256) {
        (bool successReadOwnedTokens, bytes memory returndataReadOwnedTokens) =
            tokenAddress.staticcall(abi.encodeWithSignature("balanceOf(address)", wallet));
        if (!successReadOwnedTokens) {
            revert FailureInReadBalance(tokenAddress);
        }
        return abi.decode(returndataReadOwnedTokens, (uint256));
    }

    function _transferOrMintHoprToAmount(
        address hoprTokenContractAddress,
        address recipient,
        uint256 hoprTokenAmountInWei
    )
        private
    {
        // 1. get recipient balance
        uint256 recipientTokenBalance = _getTokenBalanceOf(hoprTokenContractAddress, recipient);

        // 2. transfer some Hopr tokens to the recipient, or mint tokens
        if (hoprTokenAmountInWei > recipientTokenBalance) {
            // get the difference to transfer
            uint256 hoprTokenToTransfer = hoprTokenAmountInWei - recipientTokenBalance;
            // check the hopr token balance
            uint256 senderHoprTokenBalance = _getTokenBalanceOf(hoprTokenContractAddress, msgSender);

            if (senderHoprTokenBalance >= hoprTokenToTransfer) {
                // call transfer
                (bool successTransferTokens,) = hoprTokenContractAddress.call(
                    abi.encodeWithSignature("transfer(address,uint256)", recipient, hoprTokenToTransfer)
                );
                if (!successTransferTokens) {
                    emit log_string("Cannot transfer HOPR tokens to the recipient");
                } else {
                    emit log_string(string(
                            abi.encodePacked(
                                "Transferred ", vm.toString(hoprTokenToTransfer), " weiHOPR to ", vm.toString(recipient)
                            )
                        ));
                }
            } else {
                // if transfer cannot be called, try minting token as a minter
                (bool successHasRole, bytes memory returndataHasRole) = hoprTokenContractAddress.staticcall(
                    abi.encodeWithSignature("hasRole(bytes32,address)", MINTER_ROLE, msgSender)
                );
                if (!successHasRole) {
                    revert("Cannot check role for Hopr token.");
                }
                bool isMinter = abi.decode(returndataHasRole, (bool));
                require(isMinter, "Caller is not a minter");

                (bool successMintTokens,) = hoprTokenContractAddress.call(
                    abi.encodeWithSignature(
                        "mint(address,uint256,bytes,bytes)", recipient, hoprTokenToTransfer, hex"00", hex"00"
                    )
                );
                emit log_string(string(
                        abi.encodePacked(
                            "Minted ", vm.toString(hoprTokenToTransfer), " weiHOPR to ", vm.toString(recipient)
                        )
                    ));

                if (!successMintTokens) {
                    emit log_string("Cannot mint HOPR tokens to the recipient");
                }
            }
        } else {
            emit log_string(string(
                    abi.encodePacked(
                        "Skipping HOPR funding, balance ",
                        vm.toString(recipientTokenBalance),
                        " weiHOPR > requested funds ",
                        vm.toString(hoprTokenAmountInWei),
                        " weiHOPR"
                    )
                ));
        }
    }

    /**
     * @dev helper function to build multisend tx
     */
    function _helperBuildMultiSendTx(
        uint8[] memory txOperations,
        address[] memory txTos,
        uint256[] memory txValues,
        uint256[] memory dataLengths,
        bytes[] memory data
    )
        private
        pure
        returns (bytes memory)
    {
        bytes memory encodePacked;
        for (uint256 i = 0; i < txOperations.length; i++) {
            encodePacked =
                abi.encodePacked(encodePacked, txOperations[i], txTos[i], txValues[i], dataLengths[i], data[i]);
        }
        return abi.encodeWithSignature("multiSend(bytes)", encodePacked);
    }
}
