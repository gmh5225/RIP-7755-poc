// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";

import {CrossChainCall, Call} from "./RIP7755Structs.sol";
import {RIP7755Verifier} from "./RIP7755Verifier.sol";

/// @title RIP7755Source
///
/// @author Coinbase (https://github.com/base-org/RIP-7755-poc)
///
/// @notice A source contract for initiating RIP-7755 Cross Chain Requests as well as reward fulfillment to Fillers that
/// submit the cross chain calls to destination chains.
abstract contract RIP7755Source {
    using Address for address payable;
    using SafeERC20 for IERC20;

    /// @notice A cross chain call request formatted following the RIP-7755 spec
    struct CrossChainRequest {
        /// @dev The account submitting the cross chain request
        address requester;
        /// @dev Array of calls to make on the destination chain
        Call[] calls;
        /// @dev The chainId of the destination chain
        uint256 destinationChainId;
        /// @dev The L2 contract on destination chain that's storage will be used to verify whether or not this call was made
        address verifyingContract;
        /// @dev The L1 address of the contract that should have L2 block info stored
        address l2Oracle;
        /// @dev The storage key at which we expect to find the L2 block info on the l2Oracle
        bytes32 l2OracleStorageKey;
        /// @dev The address of the ERC20 reward asset to be paid to whoever proves they filled this call
        /// @dev Native asset specified as in ERC-7528 format
        address rewardAsset;
        /// @dev The reward amount to pay
        uint256 rewardAmount;
        /// @dev The minimum age of the L1 block used for the proof
        uint256 finalityDelaySeconds;
        /// @dev The nonce of this call, to differentiate from other calls with the same values
        uint256 nonce;
        /// @dev The timestamp at which this request will expire
        uint256 expiry;
        /// @dev An optional pre-check contract address on the destination chain
        /// @dev Zero address represents no pre-check contract desired
        /// @dev Can be used for arbitrary validation of fill conditions
        address precheckContract;
        /// @dev Arbitrary encoded precheck data
        bytes precheckData;
    }

    /// @notice An enum representing the status of an RIP-7755 cross chain call
    enum CrossChainCallStatus {
        None,
        Requested,
        Canceled,
        Completed
    }

    /// @notice A mapping from the keccak256 hash of a `CrossChainRequest` to its current status
    mapping(bytes32 requestHash => CrossChainCallStatus status) private _requestStatus;

    /// @notice The address representing the native currency of the blockchain this contract is deployed on following ERC-7528
    address private constant _NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice The duration, in excess of CrossChainRequest.expiry, which must pass before a request can be canceled
    uint256 public constant CANCEL_DELAY_SECONDS = 1 days;

    /// @notice An incrementing nonce value to ensure no two `CrossChainRequest` can be exactly the same
    uint256 private _nonce;

    /// @notice Event emitted when a user requests a cross chain call to be made by a filler
    /// @param requestHash The keccak256 hash of a `CrossChainRequest`
    /// @param request The requested cross chain call
    event CrossChainCallRequested(bytes32 indexed requestHash, CrossChainRequest request);

    /// @notice Event emitted when an expired cross chain call request is canceled
    /// @param requestHash The keccak256 hash of a `CrossChainRequest`
    event CrossChainCallCanceled(bytes32 indexed requestHash);

    /// @notice This error is thrown when a cross chain request specifies the native currency as the reward type but
    /// does not send the correct `msg.value`
    /// @param expected The expected `msg.value` that should have been sent with the transaction
    /// @param received The actual `msg.value` that was sent with the transaction
    error InvalidValue(uint256 expected, uint256 received);

    /// @notice This error is thrown if a user attempts to cancel a request or a Filler attempts to claim a reward for
    /// a request that is not in the `CrossChainCallStatus.Requested` state
    /// @param expected The expected status during the transaction
    /// @param actual The actual request status during the transaction
    error InvalidStatus(CrossChainCallStatus expected, CrossChainCallStatus actual);

    /// @notice This error is thrown if an attempt to cancel a request is made before the request's expiry timestamp
    /// @param currentTimestamp The current block timestamp
    /// @param expiry The timestamp at which the request expires
    error CannotCancelRequestBeforeExpiry(uint256 currentTimestamp, uint256 expiry);

    /// @notice This error is thrown if an account attempts to cancel a request that did not originate from that account
    /// @param caller The account attempting the request cancellation
    /// @param expectedCaller The account that created the request
    error InvalidCaller(address caller, address expectedCaller);

    /// @notice This error is thrown if a request expiry does not give enough time for `CrossChainRequest.finalityDelaySeconds` to pass
    error ExpiryTooSoon();

    /// @notice Submits an RIP-7755 request for a cross chain call
    ///
    /// @param request A cross chain request structured as a `CrossChainRequest`
    function requestCrossChainCall(CrossChainRequest memory request) external payable {
        request.nonce = _getNextNonce();
        request.requester = msg.sender;
        bool usingNativeCurrency = request.rewardAsset == _NATIVE_ASSET;
        uint256 expectedValue = usingNativeCurrency ? request.rewardAmount : 0;

        if (msg.value != expectedValue) {
            revert InvalidValue(expectedValue, msg.value);
        }
        if (request.expiry < block.timestamp + request.finalityDelaySeconds) {
            revert ExpiryTooSoon();
        }

        bytes32 requestHash = hashRequestMemory(request);
        _requestStatus[requestHash] = CrossChainCallStatus.Requested;

        if (!usingNativeCurrency) {
            _pullERC20({owner: msg.sender, asset: request.rewardAsset, amount: request.rewardAmount});
        }

        emit CrossChainCallRequested(requestHash, request);
    }

    /// @notice To be called by a Filler that successfully submitted a cross chain request to the destination chain and
    /// can prove it with a valid nested storage proof
    ///
    /// @param request A cross chain request structured as a `CrossChainRequest`
    /// @param fillInfo The fill info that should be in storage in `RIP7755Verifier` on destination chain
    /// @param storageProofData A storage proof that cryptographically verifies that `fillInfo` does, indeed, exist in
    /// storage on the destination chain
    /// @param payTo The address the Filler wants to receive the reward
    function claimReward(
        CrossChainRequest calldata request,
        RIP7755Verifier.FulfillmentInfo calldata fillInfo,
        bytes calldata storageProofData,
        address payTo
    ) external {
        bytes32 requestHash = hashRequest(request);
        bytes32 storageKey = keccak256(
            abi.encodePacked(
                requestHash,
                uint256(0) // Must be at slot 0
            )
        );

        _checkValidStatus({requestHash: requestHash, expectedStatus: CrossChainCallStatus.Requested});

        _validate(storageKey, fillInfo, request, storageProofData);
        _requestStatus[requestHash] = CrossChainCallStatus.Completed;

        _sendReward(request, payTo);
    }

    /// @notice Cancels a pending request that has expired
    ///
    /// @dev Can only be called if the request is in the `CrossChainCallStatus.Requested` state
    ///
    /// @param request A cross chain request structured as a `CrossChainRequest`
    function cancelRequest(CrossChainRequest calldata request) external {
        bytes32 requestHash = hashRequest(request);

        _checkValidStatus({requestHash: requestHash, expectedStatus: CrossChainCallStatus.Requested});
        if (msg.sender != request.requester) {
            revert InvalidCaller(msg.sender, request.requester);
        }
        if (block.timestamp < request.expiry + CANCEL_DELAY_SECONDS) {
            revert CannotCancelRequestBeforeExpiry(block.timestamp, request.expiry);
        }

        _requestStatus[requestHash] = CrossChainCallStatus.Canceled;
        emit CrossChainCallCanceled(requestHash);

        // Return the stored reward back to the original requester
        _sendReward(request, request.requester);
    }

    /// @notice Returns the cross chain call request status for a hashed request
    ///
    /// @param requestHash The keccak256 hash of a `CrossChainRequest`
    ///
    /// @return _ The `CrossChainCallStatus` status for the associated cross chain call request
    function getRequestStatus(bytes32 requestHash) external view returns (CrossChainCallStatus) {
        return _requestStatus[requestHash];
    }

    /// @notice Converts a `CrossChainRequest` to a `CrossChainCall`
    ///
    /// @param request A cross chain request structured as a `CrossChainRequest`
    ///
    /// @return _ The converted `CrossChainCall` to be submitted to destination chain
    function convertToCrossChainCall(CrossChainRequest calldata request) public view returns (CrossChainCall memory) {
        return CrossChainCall({
            calls: request.calls,
            originationContract: address(this),
            originChainId: block.chainid,
            destinationChainId: request.destinationChainId,
            nonce: request.nonce,
            verifyingContract: request.verifyingContract,
            precheckContract: request.precheckContract,
            precheckData: request.precheckData
        });
    }

    /// @notice Hashes a `CrossChainRequest` request to use as a request identifier
    ///
    /// @param request A cross chain request structured as a `CrossChainRequest`
    ///
    /// @return _ A keccak256 hash of the `CrossChainRequest`
    function hashRequest(CrossChainRequest calldata request) public pure returns (bytes32) {
        return keccak256(abi.encode(request));
    }

    /// @notice Hashes a `CrossChainRequest` request to use as a request identifier
    ///
    /// @param request A cross chain request structured as a `CrossChainRequest`
    ///
    /// @return _ A keccak256 hash of the `CrossChainRequest`
    function hashRequestMemory(CrossChainRequest memory request) public pure returns (bytes32) {
        return keccak256(abi.encode(request));
    }

    /// @notice Validates storage proofs and verifies fill
    ///
    /// @custom:reverts If storage proof invalid.
    /// @custom:reverts If fillInfo not found at verifyingContractStorageKey on crossChainCall.verifyingContract
    /// @custom:reverts If fillInfo.timestamp is less than
    /// crossChainCall.finalityDelaySeconds from current destination chain block timestamp.
    ///
    /// @dev Implementation will vary by L2
    function _validate(
        bytes32 verifyingContractStorageKey,
        RIP7755Verifier.FulfillmentInfo calldata fillInfo,
        CrossChainRequest calldata crossChainCall,
        bytes calldata storageProofData
    ) internal view virtual;

    /// @notice Pulls `amount` of `asset` from `owner` to address(this)
    function _pullERC20(address owner, address asset, uint256 amount) private {
        IERC20(asset).safeTransferFrom(owner, address(this), amount);
    }

    /// @notice Sends `amount` of `asset` to `to`
    function _sendERC20(address to, address asset, uint256 amount) private {
        IERC20(asset).safeTransfer(to, amount);
    }

    function _getNextNonce() private returns (uint256) {
        unchecked {
            // It would take ~3,671,743,063,080,802,746,815,416,825,491,118,336,290,905,145,409,708,398,004 years
            // with a sustained request rate of 1 trillion requests per second to overflow the nonce counter
            return ++_nonce;
        }
    }

    function _checkValidStatus(bytes32 requestHash, CrossChainCallStatus expectedStatus) private view {
        CrossChainCallStatus status = _requestStatus[requestHash];

        if (status != expectedStatus) {
            revert InvalidStatus({expected: expectedStatus, actual: status});
        }
    }

    function _sendReward(CrossChainRequest calldata request, address to) private {
        if (request.rewardAsset == _NATIVE_ASSET) {
            payable(to).sendValue(request.rewardAmount);
        } else {
            _sendERC20(to, request.rewardAsset, request.rewardAmount);
        }
    }
}
