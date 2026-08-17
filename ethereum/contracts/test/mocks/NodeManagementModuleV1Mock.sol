// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import { Enum } from "safe-contracts-1.4.1/common/Enum.sol";
import { SimplifiedModule } from "../../src/node-stake/permissioned-module/SimplifiedModule.sol";
import {
    HoprCapabilityPermissions,
    Role,
    GranularPermission
} from "../../src/node-stake/permissioned-module/CapabilityPermissions.sol";
import { HoprChannels } from "../../src/Channels.sol";
import { EnumerableTargetSet, TargetSet, TargetUtils, Target } from "../../src/utils/EnumerableTargetSet.sol";

/**
 * @dev Stand-in for the module implementation that already-deployed Safes have today, before
 * service-registry scoping landed.
 *
 * It mirrors `HoprNodeManagementModule` as it stood immediately before that change: the
 * initializer decodes four words, not five, and there is no `scopeTargetServiceRegistry`
 * function. `Role` and every other state variable are declared in the same order as the current
 * module, so a UUPS upgrade from this contract to `HoprNodeManagementModule` exercises the exact
 * storage layout that an already-deployed Safe carries into that upgrade.
 */
contract HoprNodeManagementModuleV1 is SimplifiedModule {
    using TargetUtils for Target;
    using EnumerableTargetSet for TargetSet;

    string public constant VERSION = "1.0.0";

    // address to send delegated multisend calls to
    address public multisend;
    // from HoprCapabilityPermissions. This module is a Role where members are NODE_CHAIN_KEYs
    Role internal role;
    // to indicate that this is a NodeManagementModule, to be compatible with v3.x network
    // forge-lint: disable-next-line(screaming-snake-case-const)
    bool public constant isHoprNodeManagementModule = true;

    event SetMultisendAddress(address indexed multisendAddress);
    event NodeAdded(address indexed node);
    event NodeRemoved(address indexed node);

    error WithMembership();
    error SafeMultisendSameAddress();
    error FailedToSendEthToNode();
    error LengthIsZero();

    modifier nodeOnly() {
        if (!role.members[_msgSender()]) {
            revert HoprCapabilityPermissions.NoMembership();
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev The pre-upgrade initializer. It has no service-registry parameter.
    function initialize(bytes memory initParams) public initializer {
        (address _safe, address _multisend, bytes32 _defaultAnnouncementTarget, bytes32 _defaultTokenChannelsTarget) =
            abi.decode(initParams, (address, address, bytes32, bytes32));

        if (_safe == address(0) || _multisend == address(0)) {
            revert HoprCapabilityPermissions.AddressIsZero();
        }
        if (_safe == _multisend) {
            revert SafeMultisendSameAddress();
        }

        multisend = _multisend;

        if (_defaultAnnouncementTarget != bytes32(0)) {
            HoprCapabilityPermissions.scopeTargetToken(role, Target.wrap(uint256(_defaultAnnouncementTarget)));
        }
        _addChannelsAndTokenTarget(Target.wrap(uint256(_defaultTokenChannelsTarget)));

        __Ownable_init_unchained(_safe);
        emit SetMultisendAddress(_multisend);
    }

    function tryGetTarget(address targetAddress) external view returns (bool, Target) {
        return role.targets.tryGet(targetAddress);
    }

    function getTargets() external view returns (Target[] memory) {
        return role.targets.values();
    }

    function isNode(address nodeAddress) external view returns (bool) {
        return role.members[nodeAddress];
    }

    function addNode(address nodeAddress) external payable onlyOwner {
        _addNode(nodeAddress);
        if (msg.value > 0) {
            (bool success,) = nodeAddress.call{ value: msg.value, gas: 0 }("");
            require(success, FailedToSendEthToNode());
        }
    }

    function includeNode(Target nodeDefaultTarget) external onlyOwner {
        address nodeAddress = nodeDefaultTarget.getTargetAddress();
        _addNode(nodeAddress);
        HoprCapabilityPermissions.scopeTargetSend(role, nodeDefaultTarget);
        HoprCapabilityPermissions.scopeSendCapability(role, nodeAddress, nodeAddress, GranularPermission.ALLOW);
    }

    function scopeTargetChannels(Target defaultTarget) external onlyOwner {
        HoprCapabilityPermissions.scopeTargetChannels(role, defaultTarget);
    }

    function scopeTargetToken(Target defaultTarget) external onlyOwner {
        HoprCapabilityPermissions.scopeTargetToken(role, defaultTarget);
    }

    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation
    )
        public
        nodeOnly
        returns (bool success)
    {
        HoprCapabilityPermissions.check(role, multisend, to, value, data, operation);
        return exec(to, value, data, operation);
    }

    function _addChannelsAndTokenTarget(Target defaultTarget) private {
        address hoprChannelsAddress = defaultTarget.getTargetAddress();
        address hoprTokenAddress = address(HoprChannels(hoprChannelsAddress).TOKEN());

        HoprCapabilityPermissions.scopeTargetChannels(role, defaultTarget.forceWriteTargetAddress(hoprChannelsAddress));
        HoprCapabilityPermissions.scopeTargetToken(role, defaultTarget.forceWriteTargetAddress(hoprTokenAddress));
    }

    function _addNode(address nodeAddress) private {
        if (role.members[nodeAddress]) {
            revert WithMembership();
        }
        role.members[nodeAddress] = true;
        emit NodeAdded(nodeAddress);
    }
}
