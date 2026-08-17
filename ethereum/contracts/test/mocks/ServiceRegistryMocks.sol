// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import { IServiceRequirement } from "../../src/interfaces/IServiceRequirement.sol";

/**
 * @dev A NodeSafeRegistry stand-in with a real mapping.
 *
 * A real mapping is better here than `vm.mockCall`. It survives a reentrant call and it survives
 * the invariant handler, and both of those clear or bypass mocked calls.
 */
contract MockNodeSafeRegistry {
    mapping(address => address) internal _nodeToSafe;

    function setBinding(address node, address safe) external {
        _nodeToSafe[node] = safe;
    }

    function nodeToSafe(address nodeAddress) external view returns (address) {
        return _nodeToSafe[nodeAddress];
    }
}

/**
 * @dev A NodeSafeRegistry stand-in that always reverts.
 *
 * The registry uses no try/catch, so this error must reach the caller of the registry unchanged.
 */
contract RevertingNodeSafeRegistry {
    error NodeSafeRegistryIsDown();

    function nodeToSafe(address) external pure returns (address) {
        revert NodeSafeRegistryIsDown();
    }
}

/**
 * @dev A NodeSafeRegistry stand-in that answers with 4 bytes instead of 32.
 *
 * The ABI decoder of the registry rejects the short answer, so the write reverts.
 */
contract MalformedNodeSafeRegistry {
    fallback() external {
        assembly {
            mstore(0x00, 0xdeadbeef)
            return(0x00, 0x04)
        }
    }
}

/**
 * @dev A requirement contract with settable answers and settable failure modes.
 *
 * The registry staticcalls a requirement, so a mock cannot record a call in storage. `EchoArgs`
 * solves this: the mock reverts with the arguments that it received, and a test reads them from
 * the revert data. `vm.expectCall` covers the same ground without a revert.
 */
contract ConfigurableRequirement is IServiceRequirement {
    enum Mode {
        ReturnValue,
        Revert,
        EchoArgs,
        ReturnMalformed
    }

    error RequirementIsDown();
    error CanRegisterArgs(bytes32 serviceType, address caller, address node);
    error ValidateMetadataArgs(bytes32 serviceType, address node, bytes metadata);

    bool public canRegisterResult;
    bool public validateMetadataResult;
    Mode public canRegisterMode;
    Mode public validateMetadataMode;

    constructor(bool canRegisterResult_, bool validateMetadataResult_) {
        canRegisterResult = canRegisterResult_;
        validateMetadataResult = validateMetadataResult_;
    }

    function setCanRegisterResult(bool result) external {
        canRegisterResult = result;
    }

    function setValidateMetadataResult(bool result) external {
        validateMetadataResult = result;
    }

    function setCanRegisterMode(Mode mode) external {
        canRegisterMode = mode;
    }

    function setValidateMetadataMode(Mode mode) external {
        validateMetadataMode = mode;
    }

    function canRegister(bytes32 serviceType, address caller, address node) external view returns (bool) {
        if (canRegisterMode == Mode.Revert) {
            revert RequirementIsDown();
        }
        if (canRegisterMode == Mode.EchoArgs) {
            revert CanRegisterArgs(serviceType, caller, node);
        }
        if (canRegisterMode == Mode.ReturnMalformed) {
            assembly {
                mstore(0x00, 0x01)
                return(0x00, 0x04)
            }
        }
        return canRegisterResult;
    }

    function validateMetadata(bytes32 serviceType, address node, bytes calldata metadata) external view returns (bool) {
        if (validateMetadataMode == Mode.Revert) {
            revert RequirementIsDown();
        }
        if (validateMetadataMode == Mode.EchoArgs) {
            revert ValidateMetadataArgs(serviceType, node, metadata);
        }
        if (validateMetadataMode == Mode.ReturnMalformed) {
            assembly {
                mstore(0x00, 0x01)
                return(0x00, 0x04)
            }
        }
        return validateMetadataResult;
    }
}

/// @dev A requirement that accepts every registration and every metadata value.
contract PermissiveRequirement is ConfigurableRequirement {
    constructor() ConfigurableRequirement(true, true) { }
}

/// @dev A requirement that rejects `canRegister` and accepts `validateMetadata`.
contract DenyRegisterRequirement is ConfigurableRequirement {
    constructor() ConfigurableRequirement(false, true) { }
}

/// @dev A requirement that accepts `canRegister` and rejects `validateMetadata`.
contract DenyMetadataRequirement is ConfigurableRequirement {
    constructor() ConfigurableRequirement(true, false) { }
}

/// @dev The emergency stop of one type. It rejects both questions.
contract DenyAllRequirement is ConfigurableRequirement {
    constructor() ConfigurableRequirement(false, false) { }
}
