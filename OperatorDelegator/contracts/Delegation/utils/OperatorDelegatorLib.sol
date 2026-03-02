// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import "../../EigenLayer/interfaces/IDelegationManager.sol";
import "../../EigenLayer/interfaces/IEigenPodManager.sol";
import "../../Errors/Errors.sol";
import "../../EigenLayer/libraries/BeaconChainProofs.sol";
import "../IOperatorDelegator.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title OperatorDelegatorLib
 * @notice Library containing core functionality for OperatorDelegator contracts
 * @dev Provides functions for managing EigenLayer delegations, withdrawals, validator tracking, and TVL calculations
 */
library OperatorDelegatorLib {
    using BeaconChainProofs for *;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @dev Conversion factor from Gwei to Wei
    uint256 internal constant GWEI_TO_WEI = 1e9;

    /// @dev Address used to represent native ETH in token mappings
    address public constant IS_NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @dev Max stakedButNotVerifiedEth amount cap per validator
    uint256 public constant MAX_STAKE_BUT_NOT_VERIFIED_AMOUNT = 32 ether;

    /**
     * @notice Verifies withdrawal credentials for validators and updates staked ETH tracking
     * @dev Calls EigenPod to verify credentials and accumulates verified ETH amounts
     * @param oracleTimestamp The timestamp of the oracle beacon state
     * @param stateRootProof Proof of the beacon chain state root
     * @param validatorIndices Array of validator indices to verify
     * @param withdrawalCredentialProofs Array of proofs for withdrawal credentials
     * @param validatorFields Array of validator field data
     * @param eigenPod The EigenPod contract instance
     * @param validatorStakedButNotVerifiedEth Mapping of validator pubkey hash to staked but unverified ETH amounts
     * @return totalStakedAndVerifiedEth Total amount of ETH that was verified
     */
    function verifyWithdrawalCredentials(
        uint64 oracleTimestamp,
        BeaconChainProofs.StateRootProof calldata stateRootProof,
        uint40[] calldata validatorIndices,
        bytes[] calldata withdrawalCredentialProofs,
        bytes32[][] calldata validatorFields,
        IEigenPod eigenPod,
        mapping(bytes32 => uint256) storage validatorStakedButNotVerifiedEth
    ) external returns (uint256 totalStakedAndVerifiedEth) {
        eigenPod.verifyWithdrawalCredentials(
            oracleTimestamp,
            stateRootProof,
            validatorIndices,
            withdrawalCredentialProofs,
            validatorFields
        );

        // Increment the staked and verified ETH
        for (uint256 i = 0; i < validatorFields.length; ) {
            bytes32 validatorPubkeyHash = validatorFields[i].getPubkeyHash();
            // Increment total stakedAndVerifiedEth by validatorStakedButNotVerifiedEth
            if (validatorStakedButNotVerifiedEth[validatorPubkeyHash] != 0) {
                totalStakedAndVerifiedEth += validatorStakedButNotVerifiedEth[validatorPubkeyHash];
            } else {
                // fallback to Increment total stakedAndVerifiedEth by MAX_STAKE_BUT_NOT_VERIFIED_AMOUNT
                totalStakedAndVerifiedEth += MAX_STAKE_BUT_NOT_VERIFIED_AMOUNT;
            }

            // set validatorStakedButNotVerifiedEth value to 0
            validatorStakedButNotVerifiedEth[validatorPubkeyHash] = 0;

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Queues a withdrawal request for a specific token through EigenLayer
     * @dev Creates withdrawal parameters and submits to DelegationManager, tracking shares for TVL
     * @param token The token to withdraw (use IS_NATIVE for ETH)
     * @param tokenAmount Amount of tokens to withdraw
     * @param delegationManager The EigenLayer DelegationManager contract
     * @param eigenPodManager The EigenLayer EigenPodManager contract
     * @param tokenStrategyMapping Mapping of tokens to their EigenLayer strategies
     * @param queuedShares Storage mapping tracking queued shares per token for TVL
     * @param queuedWithdrawal Storage mapping tracking whether a withdrawal root is queued
     * @param queuedWithdrawalTokenInfo Storage mapping tracking withdrawal details per root and token
     * @return withdrawalRoot The calculated withdrawal root hash
     * @return nonce The nonce of the queued withdrawal
     * @return queuedWithdrawalParams The withdrawal parameters used
     */
    function queueWithdrawal(
        IERC20 token,
        uint256 tokenAmount,
        IDelegationManager delegationManager,
        IEigenPodManager eigenPodManager,
        mapping(IERC20 => IStrategy) storage tokenStrategyMapping,
        mapping(address => uint256) storage queuedShares,
        mapping(bytes32 => bool) storage queuedWithdrawal,
        mapping(bytes32 => mapping(address => IOperatorDelegator.QueuedWithdrawal))
            storage queuedWithdrawalTokenInfo
    )
        external
        returns (
            bytes32 withdrawalRoot,
            uint96 nonce,
            IDelegationManager.QueuedWithdrawalParams[] memory queuedWithdrawalParams
        )
    {
        uint256 withdrawableShares;
        (queuedWithdrawalParams, withdrawableShares) = _getQueuedWithdrawalParams(
            token,
            tokenAmount,
            delegationManager,
            eigenPodManager,
            tokenStrategyMapping
        );

        // track withdrawable shares of tokens withdraw for TVL
        queuedShares[address(token)] += withdrawableShares;

        // Save the nonce before starting the withdrawal
        nonce = uint96(delegationManager.cumulativeWithdrawalsQueued(address(this)));

        // queue withdrawal in EigenLayer
        withdrawalRoot = delegationManager.queueWithdrawals(queuedWithdrawalParams)[0];

        // track initial withdrawable shares of the token in queuedWithdrawal
        queuedWithdrawalTokenInfo[withdrawalRoot][address(token)]
            .initialWithdrawableShares = withdrawableShares;

        // track protocol queued withdrawals
        queuedWithdrawal[withdrawalRoot] = true;
    }

    /**
     * @notice Tracks missed EigenPod checkpoints and accumulates exit balances
     * @dev Iterates through missed checkpoints, validates they haven't been recorded, and accumulates exit balances
     * @param missedCheckpoints Array of checkpoint timestamps to track
     * @param recordedCheckpoints Storage mapping tracking which checkpoints have been recorded
     * @param eigenPod The EigenPod contract instance to query checkpoint balances
     * @return totalBeaconChainExitBalance Accumulated exit balance from all missed checkpoints (in Wei)
     * @return latestCheckpoint The most recent checkpoint timestamp from the array
     */
    function trackMissedCheckpoint(
        uint64[] calldata missedCheckpoints,
        mapping(uint64 => bool) storage recordedCheckpoints,
        IEigenPod eigenPod
    ) external returns (uint256 totalBeaconChainExitBalance, uint64 latestCheckpoint) {
        for (uint256 i = 0; i < missedCheckpoints.length; ) {
            // revert if checkpoint already recorded
            if (recordedCheckpoints[missedCheckpoints[i]]) revert CheckpointAlreadyRecorded();

            // update totalBeaconChainExitBalance
            uint256 totalBeaconChainExitBalanceGwei = eigenPod.checkpointBalanceExitedGwei(
                missedCheckpoints[i]
            );

            // accumulate total Exit Balance
            totalBeaconChainExitBalance += totalBeaconChainExitBalanceGwei * GWEI_TO_WEI;

            // mark the checkpoint as recorded
            recordedCheckpoints[missedCheckpoints[i]] = true;

            // if current missedCheckpoint is greater than latestCheckpoint
            if (missedCheckpoints[i] > latestCheckpoint) {
                // update the latestCheckpoint
                latestCheckpoint = missedCheckpoints[i];
            }

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Updates beacon chain exit balance accounting for consolidated amounts
     * @dev Deducts consolidated amount from exit balance, handling cases where consolidation exceeds exit balance
     * @param newTotalBeaconChainExitBalance The new total exit balance to adjust
     * @param totalConsolidatedAmount The total amount that has been consolidated
     * @return Updated beacon chain exit balance after consolidation adjustment
     * @return Updated consolidated amount (zero if fully applied, remainder otherwise)
     */
    function updateTotalBeaconChainExitBalance(
        uint256 newTotalBeaconChainExitBalance,
        uint256 totalConsolidatedAmount
    ) external pure returns (uint256, uint256) {
        if (totalConsolidatedAmount > 0) {
            if (totalConsolidatedAmount > newTotalBeaconChainExitBalance) {
                totalConsolidatedAmount -= newTotalBeaconChainExitBalance;
                newTotalBeaconChainExitBalance = 0;
            } else {
                newTotalBeaconChainExitBalance -= totalConsolidatedAmount;
                totalConsolidatedAmount = 0;
            }
        }
        return (newTotalBeaconChainExitBalance, totalConsolidatedAmount);
    }

    /**
     * @notice Tracks slashing deltas for queued withdrawals by comparing initial vs current shares
     * @dev Calculates difference between initial and current shares to determine slashing amount
     * @param withdrawalRoots Array of withdrawal root hashes to check for slashing
     * @param queuedWithdrawal Storage mapping tracking whether withdrawal roots are queued
     * @param queuedWithdrawalTokenInfo Storage mapping with initial shares and slashing data per withdrawal
     * @param totalTokenQueuedSharesSlashedDelta Storage mapping of cumulative slashing delta per token
     * @param delegationManager The EigenLayer DelegationManager to query current shares
     */
    function trackSlashedQueuedWithdrawalDelta(
        bytes32[] calldata withdrawalRoots,
        mapping(bytes32 => bool) storage queuedWithdrawal,
        mapping(bytes32 => mapping(address => IOperatorDelegator.QueuedWithdrawal))
            storage queuedWithdrawalTokenInfo,
        mapping(address => uint256) storage totalTokenQueuedSharesSlashedDelta,
        IDelegationManager delegationManager
    ) external {
        for (uint256 i = 0; i < withdrawalRoots.length; ) {
            // revert if withdrawal not queued
            if (!queuedWithdrawal[withdrawalRoots[i]]) revert WithdrawalNotQueued();

            // get withdrawal and current shares of queuedWithdrawal from EigenLayer DelegationManager
            (
                IDelegationManager.Withdrawal memory withdrawal,
                uint256[] memory currentShares
            ) = delegationManager.getQueuedWithdrawal(withdrawalRoots[i]);

            // loop on every token in the queuedWithdrawal
            for (uint256 j = 0; j < withdrawal.strategies.length; ) {
                address underlyingToken = _getUnderlyingFromStrategy(
                    withdrawal.strategies[j],
                    delegationManager
                );

                // calculate new slashing delta for each token
                uint256 slashingDelta = (queuedWithdrawalTokenInfo[withdrawalRoots[i]][
                    underlyingToken
                ].initialWithdrawableShares > currentShares[j])
                    ? (queuedWithdrawalTokenInfo[withdrawalRoots[i]][underlyingToken]
                        .initialWithdrawableShares - currentShares[j])
                    : 0;

                // reduce totalTokenQueuedSharesSlashedDelta with old slashing delta for queuedWithdrawal
                totalTokenQueuedSharesSlashedDelta[underlyingToken] -= queuedWithdrawalTokenInfo[
                    withdrawalRoots[i]
                ][underlyingToken].sharesSlashedDelta;

                // track new slashed delta for each token
                totalTokenQueuedSharesSlashedDelta[underlyingToken] += slashingDelta;

                // track new slashed delta for queuedWithdrawal
                queuedWithdrawalTokenInfo[withdrawalRoots[i]][underlyingToken]
                    .sharesSlashedDelta = slashingDelta;

                unchecked {
                    ++j;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Calculates the underlying token amount from strategy shares
     * @dev Combines withdrawable shares from EigenLayer with queued shares and converts to underlying tokens
     * @param queuedSharesWithSlashing Queued shares adjusted for slashing
     * @param delegationManager The EigenLayer DelegationManager contract
     * @param strategy The EigenLayer strategy to query
     * @return Total underlying token balance including queued shares
     */
    function getTokenBalanceFromStrategy(
        uint256 queuedSharesWithSlashing,
        IDelegationManager delegationManager,
        IStrategy strategy
    ) external view returns (uint256) {
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = strategy;
        (uint256[] memory withdrawableShares, ) = delegationManager.getWithdrawableShares(
            address(this),
            strategies
        );

        // get withdrawable shares from EigenLayer
        uint256 collateralBalance = withdrawableShares[0];
        // add queued shares for the token with slashing
        collateralBalance += queuedSharesWithSlashing;

        // convert shares to underlying
        return strategy.sharesToUnderlyingView(collateralBalance);
    }

    /**
     * @notice Calculates the total ETH staked in EigenLayer
     * @dev Accounts for withdrawable shares, queued shares, staked but unverified ETH, and partial withdrawal deltas
     * @param queuedSharesWithSlashing Queued ETH shares adjusted for slashing
     * @param stakedButNotVerifiedEth ETH staked in validators but not yet verified
     * @param partialWithdrawalPodDelta Delta from partial withdrawals to subtract
     * @param eigenPodManager The EigenLayer EigenPodManager contract
     * @param delegationManager The EigenLayer DelegationManager contract
     * @return Total staked ETH balance
     */
    function getStakedETHBalance(
        uint256 queuedSharesWithSlashing,
        uint256 stakedButNotVerifiedEth,
        uint256 partialWithdrawalPodDelta,
        IEigenPodManager eigenPodManager,
        IDelegationManager delegationManager
    ) external view returns (uint256) {
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = eigenPodManager.beaconChainETHStrategy();

        (uint256[] memory withdrawableShares, ) = delegationManager.getWithdrawableShares(
            address(this),
            strategies
        );
        // get withdrawable shares from EigenLayer
        uint256 collateralBalance = withdrawableShares[0];

        // accounts for current podOwner shares + stakedButNotVerified ETH + queued withdraw shares - podDelta
        collateralBalance += (queuedSharesWithSlashing + stakedButNotVerifiedEth);

        // subtract the partial withdrawals podDelta
        collateralBalance -= partialWithdrawalPodDelta;

        return collateralBalance;
    }

    /**
     * @notice Calculates total consolidation amount from consolidation requests
     * @dev Sums up restaked balances of all validators in consolidation requests and adds them to tracking set
     * @param requests Array of consolidation requests containing source validator pubkeys
     * @param eigenPod The EigenPod contract to query validator information
     * @param consolidatingValidators Storage set to track validators undergoing consolidation
     * @return _totalConsolidatedAmount Total amount being consolidated across all requests (in Wei)
     */
    function getTotalConsolidationAmount(
        IEigenPodTypes.ConsolidationRequest[] calldata requests,
        IEigenPod eigenPod,
        EnumerableSet.Bytes32Set storage consolidatingValidators
    ) external returns (uint256 _totalConsolidatedAmount) {
        for (uint256 i = 0; i < requests.length; ) {
            bytes32 pubKeyHash = _calcPubkeyHash(requests[i].srcPubkey);
            IEigenPodTypes.ValidatorInfo memory validatorInfo = eigenPod.validatorPubkeyHashToInfo(
                pubKeyHash
            );
            // add consolidated validators to set
            consolidatingValidators.add(pubKeyHash);

            // add validator consolidated amount
            _totalConsolidatedAmount += (validatorInfo.restakedBalanceGwei * GWEI_TO_WEI);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Verifies that validator consolidations have completed by checking balance proofs
     * @dev Verifies balance container proof and individual validator balances, removing validators with zero balance
     * @param balanceContainerProof Proof of the balance container root
     * @param proofs Array of balance proofs for individual validators
     * @param eigenPod The EigenPod contract to query validator information
     * @param consolidatingValidators Storage set tracking validators undergoing consolidation
     */
    function verifyConsolidationComplete(
        BeaconChainProofs.BalanceContainerProof calldata balanceContainerProof,
        BeaconChainProofs.BalanceProof[] calldata proofs,
        IEigenPod eigenPod,
        EnumerableSet.Bytes32Set storage consolidatingValidators
    ) external {
        // verify balance container proofs
        BeaconChainProofs.verifyBalanceContainer({
            beaconBlockRoot: eigenPod.getParentBlockRoot(uint64(block.timestamp)),
            proof: balanceContainerProof
        });
        for (uint256 i = 0; i < proofs.length; ) {
            bytes32 validatorPubkeyHash = proofs[i].pubkeyHash;
            // check if proof validator is present in consolidatingValidators
            if (consolidatingValidators.contains(validatorPubkeyHash)) {
                // get validator info
                IEigenPodTypes.ValidatorInfo memory validatorInfo = eigenPod
                    .validatorPubkeyHashToInfo(validatorPubkeyHash);
                uint40 validatorIndex = uint40(validatorInfo.validatorIndex);
                // verify validator balance
                uint64 newBalanceGwei = BeaconChainProofs.verifyValidatorBalance({
                    balanceContainerRoot: balanceContainerProof.balanceContainerRoot,
                    validatorIndex: validatorIndex,
                    proof: proofs[i]
                });

                // if new balance is 0 then remove from consolidated validator set
                if (newBalanceGwei == 0) {
                    consolidatingValidators.remove(validatorPubkeyHash);
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Calculates the pubkey hash of a validator's pubkey as per SSZ spec
     * @dev Hashes the 48-byte pubkey concatenated with 16 zero bytes per SSZ specification
     * @param validatorPubkey The validator's BLS public key (must be 48 bytes)
     * @return The SHA256 hash of the padded pubkey
     */
    function _calcPubkeyHash(bytes memory validatorPubkey) internal pure returns (bytes32) {
        require(validatorPubkey.length == 48, InvalidPubKeyLength());
        return sha256(abi.encodePacked(validatorPubkey, bytes16(0)));
    }

    /**
     * @notice Tracks withdrawals created during undelegation to avoid double counting in TVL
     * @dev Validates withdrawals exist in EigenLayer and tracks their current shares for TVL accounting
     * @param withdrawalRoots Array of withdrawal root hashes to track
     * @param delegationManager The EigenLayer DelegationManager contract
     * @param queuedWithdrawal Storage mapping tracking whether withdrawal roots are queued
     * @param queuedShares Storage mapping tracking queued shares per token
     * @param queuedWithdrawalTokenInfo Storage mapping tracking withdrawal details per root and token
     */
    function trackUndelegateQueuedWithdrawals(
        bytes32[] calldata withdrawalRoots,
        IDelegationManager delegationManager,
        mapping(bytes32 => bool) storage queuedWithdrawal,
        mapping(address => uint256) storage queuedShares,
        mapping(bytes32 => mapping(address => IOperatorDelegator.QueuedWithdrawal))
            storage queuedWithdrawalTokenInfo
    ) external {
        for (uint256 i = 0; i < withdrawalRoots.length; ) {
            // verify withdrawal is not tracked
            if (queuedWithdrawal[withdrawalRoots[i]]) revert WithdrawalAlreadyTracked();

            // verify withdrawal is pending and protocol not double counting
            if (!delegationManager.pendingWithdrawals(withdrawalRoots[i]))
                revert WithdrawalAlreadyCompleted();

            // get withdrawal and current shares of queuedWithdrawal from EigenLayer DelegationManager
            (
                IDelegationManager.Withdrawal memory withdrawal,
                uint256[] memory currentShares
            ) = delegationManager.getQueuedWithdrawal(withdrawalRoots[i]);

            // check if withdrawal staker is OperatorDelegator
            if (withdrawal.staker != address(this)) revert InvalidStakerAddress();
            // loop on every token in the queuedWithdrawal
            for (uint256 j = 0; j < withdrawal.strategies.length; ) {
                address underlyingToken = _getUnderlyingFromStrategy(
                    withdrawal.strategies[j],
                    delegationManager
                );

                // track queued shares for the token in withdrawable shares
                queuedShares[underlyingToken] += currentShares[j];

                // track initial withdrawable shares of the token in queuedWithdrawal
                queuedWithdrawalTokenInfo[withdrawalRoots[i]][underlyingToken]
                    .initialWithdrawableShares = currentShares[j];
                unchecked {
                    ++j;
                }
            }
            // mark the withdrawal root as tracked to avoid double counting
            queuedWithdrawal[withdrawalRoots[i]] = true;
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Tracks external queued withdrawals to properly account for them in TVL
     * @dev Validates and tracks withdrawals that were queued outside normal flow (e.g., by admin)
     * @param withdrawals Array of withdrawal structs to track
     * @param tokens Array of tokens corresponding to each withdrawal
     * @param delegationManager The EigenLayer DelegationManager contract
     * @param queuedWithdrawal Storage mapping tracking whether withdrawal roots are queued
     * @param queuedShares Storage mapping tracking queued shares per token
     * @param queuedWithdrawalTokenInfo Storage mapping tracking withdrawal details per root and token
     */
    function trackQueuedWithdrawals(
        IDelegationManager.Withdrawal[] calldata withdrawals,
        IERC20[] calldata tokens,
        IDelegationManager delegationManager,
        mapping(bytes32 => bool) storage queuedWithdrawal,
        mapping(address => uint256) storage queuedShares,
        mapping(bytes32 => mapping(address => IOperatorDelegator.QueuedWithdrawal))
            storage queuedWithdrawalTokenInfo
    ) external {
        // verify array lengths
        if (tokens.length != withdrawals.length) revert MismatchedArrayLengths();
        for (uint256 i = 0; i < withdrawals.length; ) {
            _checkZeroAddress(address(tokens[i]));

            // check if withdrawal staker is OperatorDelegator
            if (withdrawals[i].staker != address(this)) revert InvalidStakerAddress();

            // calculate withdrawalRoot
            bytes32 withdrawalRoot = delegationManager.calculateWithdrawalRoot(withdrawals[i]);

            // verify withdrawal is not tracked
            if (queuedWithdrawal[withdrawalRoot]) revert WithdrawalAlreadyTracked();

            // verify withdrawal is pending and protocol not double counting
            if (!delegationManager.pendingWithdrawals(withdrawalRoot))
                revert WithdrawalAlreadyCompleted();

            // verify LST token is not provided if beaconChainETHStrategy in Withdraw Request
            if (
                address(tokens[i]) != IS_NATIVE &&
                withdrawals[i].strategies[0] == delegationManager.beaconChainETHStrategy()
            ) revert IncorrectStrategy();

            // get current shares of queuedWithdrawal from EigenLayer DelegationManager
            (, uint256[] memory currentShares) = delegationManager.getQueuedWithdrawal(
                withdrawalRoot
            );
            // track queued shares for the token in withdrawable shares
            queuedShares[address(tokens[i])] += currentShares[0];

            // track initial withdrawable shares of the token in queuedWithdrawal
            queuedWithdrawalTokenInfo[withdrawalRoot][address(tokens[i])]
                .initialWithdrawableShares = currentShares[0];

            // mark the withdrawal root as tracked to avoid double counting
            queuedWithdrawal[withdrawalRoot] = true;

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Completes a single queued withdrawal from EigenLayer
     * @dev Calls DelegationManager to complete the withdrawal, receiving tokens directly
     * @param withdrawal The withdrawal struct to complete
     * @param tokens Array of token addresses to receive
     * @param delegationManager The EigenLayer DelegationManager contract
     */
    function completeQueuedWithdrawal(
        IDelegationManager.Withdrawal calldata withdrawal,
        IERC20[] calldata tokens,
        IDelegationManager delegationManager
    ) external {
        // complete the queued withdrawal from EigenLayer with receiveAsToken set to true
        delegationManager.completeQueuedWithdrawal(withdrawal, tokens, true);
    }

    /**
     * @notice Completes multiple queued withdrawals from EigenLayer in batch
     * @dev Calls DelegationManager to complete withdrawals, with option to receive as tokens or shares
     * @param withdrawals Array of withdrawal structs to complete
     * @param tokens 2D array of token addresses for each withdrawal
     * @param receiveAsTokens Array of booleans indicating whether to receive as tokens (true) or shares (false)
     * @param delegationManager The EigenLayer DelegationManager contract
     */
    function completeQueuedWithdrawals(
        IDelegationManager.Withdrawal[] calldata withdrawals,
        IERC20[][] calldata tokens,
        bool[] calldata receiveAsTokens,
        IDelegationManager delegationManager
    ) external {
        // complete the queued withdrawal from EigenLayer
        delegationManager.completeQueuedWithdrawals(withdrawals, tokens, receiveAsTokens);
    }

    /**
     * @notice  Reduces queued shares for collateral assets in a completed withdrawal request
     * @dev     This function updates the TVL tracking by deducting shares from queuedShares when a withdrawal is completed.
     *          It also handles slashing adjustments by reducing the totalTokenQueuedSharesSlashedDelta if any slashing occurred.
     *          Reverts if an invalid collateral asset is provided in the withdrawal request (e.g., LST token with beaconChainETHStrategy).
     *          The withdrawal root is calculated from the withdrawal struct and used to look up tracked withdrawal information.
     * @param   withdrawal  The EigenLayer withdrawal struct containing strategies, shares, staker, and other withdrawal details
     * @param   tokens  Array of token addresses in the withdrawal request (use IS_NATIVE constant for native ETH)
     * @param   delegationManager  The EigenLayer DelegationManager contract instance used to calculate withdrawal root
     * @param   queuedShares  Storage mapping tracking total queued shares per token address for TVL calculation
     * @param   queuedWithdrawalTokenInfo  Storage mapping tracking initial withdrawable shares and slashing delta per withdrawal root and token
     * @param   totalTokenQueuedSharesSlashedDelta  Storage mapping tracking cumulative slashing delta across all queued withdrawals per token
     */
    function reduceQueuedShares(
        IDelegationManager.Withdrawal calldata withdrawal,
        IERC20[] memory tokens,
        IDelegationManager delegationManager,
        mapping(address => uint256) storage queuedShares,
        mapping(bytes32 => mapping(address => IOperatorDelegator.QueuedWithdrawal))
            storage queuedWithdrawalTokenInfo,
        mapping(address => uint256) storage totalTokenQueuedSharesSlashedDelta
    ) external {
        for (uint256 i; i < tokens.length; ) {
            _checkZeroAddress(address(tokens[i]));
            if (
                address(tokens[i]) != IS_NATIVE &&
                withdrawal.strategies[i] == delegationManager.beaconChainETHStrategy()
            ) revert IncorrectStrategy();

            // Calculate withdrawal root for the given withdrawal
            bytes32 withdrawalRoot = delegationManager.calculateWithdrawalRoot(withdrawal);

            // deduct queued shares with the initial withdrawable shares queued for tracking TVL
            queuedShares[address(tokens[i])] -= queuedWithdrawalTokenInfo[withdrawalRoot][
                address(tokens[i])
            ].initialWithdrawableShares;
            if (
                queuedWithdrawalTokenInfo[withdrawalRoot][address(tokens[i])].sharesSlashedDelta > 0
            ) {
                // reduce total slashed delta with queuedWithdrawalTokenInfo.sharesSharedDelta
                totalTokenQueuedSharesSlashedDelta[address(tokens[i])] -= queuedWithdrawalTokenInfo[
                    withdrawalRoot
                ][address(tokens[i])].sharesSlashedDelta;

                // delete queuedWithdrawalTokenInfo for the withdrawal root
                delete queuedWithdrawalTokenInfo[withdrawalRoot][address(tokens[i])];
            }

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Validates that an address is not the zero address
     * @dev Reverts with InvalidZeroInput if address is zero
     * @param _potentialAddress The address to validate
     */
    function _checkZeroAddress(address _potentialAddress) internal pure {
        if (_potentialAddress == address(0)) revert InvalidZeroInput();
    }

    /**
     * @notice Gets the underlying token address from a strategy
     * @dev Returns IS_NATIVE for beaconChainETHStrategy, otherwise queries strategy's underlying token
     * @param strategy The EigenLayer strategy contract
     * @param delegationManager The EigenLayer DelegationManager contract
     * @return The underlying token address (IS_NATIVE for ETH)
     */
    function _getUnderlyingFromStrategy(
        IStrategy strategy,
        IDelegationManager delegationManager
    ) internal view returns (address) {
        if (strategy == delegationManager.beaconChainETHStrategy()) {
            return IS_NATIVE;
        } else {
            return address(strategy.underlyingToken());
        }
    }

    /**
     * @notice Constructs queued withdrawal parameters for a token withdrawal
     * @dev Determines the strategy, converts amounts to shares, and builds withdrawal params struct
     * @param token The token to withdraw (use IS_NATIVE for ETH)
     * @param tokenAmount Amount of tokens to withdraw
     * @param delegationManager The EigenLayer DelegationManager contract
     * @param eigenPodManager The EigenLayer EigenPodManager contract
     * @param tokenStrategyMapping Mapping of tokens to their EigenLayer strategies
     * @return queuedWithdrawalParams The constructed withdrawal parameters
     * @return Withdrawable shares amount
     */
    function _getQueuedWithdrawalParams(
        IERC20 token,
        uint256 tokenAmount,
        IDelegationManager delegationManager,
        IEigenPodManager eigenPodManager,
        mapping(IERC20 => IStrategy) storage tokenStrategyMapping
    )
        internal
        view
        returns (IDelegationManager.QueuedWithdrawalParams[] memory queuedWithdrawalParams, uint256)
    {
        // length 1 array for queued withdrawal params struct
        queuedWithdrawalParams = new IDelegationManager.QueuedWithdrawalParams[](1);
        queuedWithdrawalParams[0].strategies = new IStrategy[](1);
        queuedWithdrawalParams[0].depositShares = new uint256[](1);

        // length 1 array for strategies and withdrawableShares
        uint256[] memory withdrawableShares = new uint256[](1);

        if (address(token) == IS_NATIVE) {
            // set beaconChainEthStrategy for ETH
            queuedWithdrawalParams[0].strategies[0] = eigenPodManager.beaconChainETHStrategy();

            // set withdrawable shares for ETH
            withdrawableShares[0] = tokenAmount;
        } else {
            _checkZeroAddress(address(tokenStrategyMapping[token]));

            // set the strategy of the token
            queuedWithdrawalParams[0].strategies[0] = tokenStrategyMapping[token];

            // set the withdrawable shares of the token
            withdrawableShares[0] = tokenStrategyMapping[token].underlyingToSharesView(tokenAmount);
        }

        // set deposit shares for the token
        queuedWithdrawalParams[0].depositShares[0] = delegationManager.convertToDepositShares(
            address(this),
            queuedWithdrawalParams[0].strategies,
            withdrawableShares
        )[0];

        // set withdrawer as this contract address
        queuedWithdrawalParams[0].__deprecated_withdrawer = address(this);

        return (queuedWithdrawalParams, withdrawableShares[0]);
    }
}
