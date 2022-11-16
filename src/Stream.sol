// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.17;

import { IStream } from "./IStream.sol";
import { Clone } from "solady/utils/Clone.sol";
import { IERC20 } from "openzeppelin-contracts/interfaces/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Stream
 * @notice Allows a payer to pay a recipient an amount of tokens over time, at a regular rate per second.
 * Once the stream begins vested tokens can be withdrawn at any time.
 * Either party can choose to cancel, in which case the stream distributes each party's fair share of tokens.
 * @dev A fork of Sablier https://github.com/sablierhq/sablier/blob/%40sablier/protocol%401.1.0/packages/protocol/contracts/Sablier.sol.
 * Inherits from `Clone`, which allows Stream to read immutable arguments from its code section rather than state, resulting
 * in significant gas savings for users.
 */
contract Stream is IStream, Clone {
    using SafeERC20 for IERC20;

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   ERRORS
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    error OnlyFactory();
    error CantWithdrawZero();
    error AmountExceedsBalance();
    error CallerNotPayerOrRecipient();

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   EVENTS
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    event TokensWithdrawn(address indexed recipient, uint256 amount);

    event StreamCancelled(
        address indexed payer,
        address indexed recipient,
        uint256 payerBalance,
        uint256 recipientBalance
    );

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   IMMUTABLES
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    /**
     * @notice Used to add precision to `ratePerSecond`, to minimize the impact of rounding down.
     * See `ratePerSecond()` implementation for more information.
     */
    uint256 public constant RATE_DECIMALS_MULTIPLIER = 1e6;

    /**
     * @notice Get the address of the factory contract that cloned this Stream instance.
     * @dev Uses clone-with-immutable-args to read the value from the contract's code region rather than state to save gas.
     */
    function factory() public pure returns (address) {
        return _getArgAddress(0);
    }

    /**
     * @notice Get this stream's payer address.
     * @dev Uses clone-with-immutable-args to read the value from the contract's code region rather than state to save gas.
     */
    function payer() public pure returns (address) {
        return _getArgAddress(20);
    }

    /**
     * @notice Get this stream's recipient address.
     * @dev Uses clone-with-immutable-args to read the value from the contract's code region rather than state to save gas.
     */
    function recipient() public pure returns (address) {
        return _getArgAddress(40);
    }

    /**
     * @notice Get this stream's total token amount.
     * @dev Uses clone-with-immutable-args to read the value from the contract's code region rather than state to save gas.
     */
    function tokenAmount() public pure returns (uint256) {
        return _getArgUint256(60);
    }

    /**
     * @notice Get this stream's ERC20 token.
     * @dev Uses clone-with-immutable-args to read the value from the contract's code region rather than state to save gas.
     */
    function token() public pure returns (IERC20) {
        return IERC20(_getArgAddress(92));
    }

    /**
     * @notice Get this stream's start timestamp in seconds.
     * @dev Uses clone-with-immutable-args to read the value from the contract's code region rather than state to save gas.
     */
    function startTime() public pure returns (uint256) {
        return _getArgUint256(112);
    }

    /**
     * @notice Get this stream's end timestamp in seconds.
     * @dev Uses clone-with-immutable-args to read the value from the contract's code region rather than state to save gas.
     */
    function stopTime() public pure returns (uint256) {
        return _getArgUint256(144);
    }

    /**
     * @notice Get this stream's token streaming rate per second.
     * @dev Uses clone-with-immutable-args to read the value from the contract's code region rather than state to save gas.
     */
    function ratePerSecond() public pure returns (uint256) {
        uint256 duration = stopTime() - startTime();

        // ratePerSecond can lose precision as its being rounded down here
        // the value lost in rounding down results in less income per second for recipient
        // max round down impact is duration - 1; e.g. one year, that's 31_557_599
        // e.g. using USDC (w/ 6 decimals) that's ~32 USDC
        // since ratePerSecond has 6 decimals, 31_557_599 / 1e6 = 0.00003156; round down impact becomes negligible
        // finally, this remainder dust becomes available to recipient when stream duration is fully elapsed
        // see `_recipientBalance` where `blockTime >= stopTime`
        return RATE_DECIMALS_MULTIPLIER * tokenAmount() / duration;
    }

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   STORAGE VARIABLES
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    /**
     * @notice the maximum token balance remaining in the stream when taking withdrawals into account.
     * @dev using remaining balance rather than a growing sum of withdrawals for gas optimization reasons.
     * This approach warms up this slot upon stream creation, so that withdrawals cost less gas.
     * If this were the sum of withdrawals, recipient would pay 20K extra gas on their first withdrawal.
     */
    // CR: maybe add to natpsec: this should be equal to this contract's ERC20 token's balance once the contract has been fully funded
    uint256 public remainingBalance;

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   MODIFIERS
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    /**
     * @dev Reverts if the caller is not the payer or the recipient of the stream.
     */
    modifier onlyPayerOrRecipient() {
        if (msg.sender != recipient() && msg.sender != payer()) {
            revert CallerNotPayerOrRecipient();
        }

        _;
    }

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   INITIALIZER
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    /**
     * @dev Limiting calls to factory only to prevent abuse. This approach is more gas efficient than using
     * OpenZeppelin's Initializable since we avoid the storage writes that entails.
     * This does create the possibility for the factory to initialize the same stream twice; this risk seems low
     * and worth the gas savings.
     */
    function initialize() external {
        if (msg.sender != factory()) revert OnlyFactory();

        remainingBalance = tokenAmount();
    }

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   EXTERNAL TXS
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    /**
     * @notice Withdraw tokens to recipient's account.
     * Execution fails if the requested amount is greater than recipient's withdrawable balance.
     * Only this stream's payer or recipient can call this function.
     * @param amount the amount of tokens to withdraw.
     */
    function withdraw(uint256 amount) external onlyPayerOrRecipient {
        if (amount == 0) revert CantWithdrawZero();
        address recipient_ = recipient();

        uint256 balance = balanceOf(recipient_);
        if (balance < amount) revert AmountExceedsBalance();

        remainingBalance = remainingBalance - amount;

        token().safeTransfer(recipient_, amount);
        emit TokensWithdrawn(recipient_, amount);
    }

    /**
     * @notice Cancel the stream and send payer and recipient their fair share of the funds.
     * If the stream is sufficiently funded to pay recipient, execution will always succeed.
     * Payer receives the stream's token balance after paying recipient, which is fair if payer
     * hadn't fully funded the stream.
     * Only this stream's payer or recipient can call this function.
     */
    function cancel() external onlyPayerOrRecipient {
        address payer_ = payer();
        address recipient_ = recipient();
        IERC20 token_ = token();

        uint256 recipientBalance = balanceOf(recipient_);

        // This zeroing is important because without it, it's possible for recipient to obtain additional funds
        // from this contract if anyone (e.g. payer) sends it tokens after cancellation.
        // Thanks to this state update, `balanceOf(recipient_)` will only return zero in future calls.
        remainingBalance = 0;

        if (recipientBalance > 0) token_.safeTransfer(recipient_, recipientBalance);

        // Using the stream's token balance rather than any other calculated field because it gracefully
        // supports cancelling the stream even if payer hasn't fully funded it.
        uint256 payerBalance = tokenBalance();
        if (payerBalance > 0) {
            token_.safeTransfer(payer_, payerBalance);
        }

        emit StreamCancelled(payer_, recipient_, payerBalance, recipientBalance);
    }

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   VIEW FUNCTIONS
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    /**
     * @notice Returns the available funds to withdraw.
     * @param who The address for which to query the balance.
     * @return uint256 The total funds allocated to `who` as uint256.
     */
    function balanceOf(address who) public view returns (uint256) {
        uint256 recipientBalance = _recipientBalance();

        if (who == recipient()) return recipientBalance;
        if (who == payer()) {
            return remainingBalance - recipientBalance;
        }
        return 0;
    }

    /**
     * @notice Returns the time elapsed in this stream, or zero if it hasn't started yet.
     */
    function elapsedTime() public view returns (uint256) {
        uint256 startTime_ = startTime();
        if (block.timestamp <= startTime_) return 0;

        uint256 stopTime_ = stopTime();
        if (block.timestamp < stopTime_) return block.timestamp - startTime_;

        return stopTime_ - startTime_;
    }

    /**
     * @notice Get this stream's token balance vs the token amount required to meet the commitment
     * to recipient.
     */
    function tokenAndOutstandingBalance() public view returns (uint256, uint256) {
        return (tokenBalance(), remainingBalance);
    }

    /**
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     *   INTERNAL FUNCTIONS
     * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
     */

    /**
     * @dev Helper function for `balanceOf` in calculating recipient's fair share of tokens, taking withdrawals into account.
     */
    function _recipientBalance() internal view returns (uint256) {
        uint256 startTime_ = startTime();
        uint256 blockTime = block.timestamp;

        if (blockTime <= startTime_) return 0;

        uint256 tokenAmount_ = tokenAmount();
        uint256 balance;
        if (blockTime >= stopTime()) {
            balance = tokenAmount_;
        } else {
            uint256 elapsedTime_ = blockTime - startTime_;
            balance = (elapsedTime_ * ratePerSecond()) / RATE_DECIMALS_MULTIPLIER;
        }

        uint256 remainingBalance_ = remainingBalance;

        // When this function is called after the stream has been cancelled, when balance is less than
        // tokenAmount, without this early exit, the withdrawal calculation below results in an underflow error.
        if (remainingBalance_ == 0) return 0;

        // Take withdrawals into account
        if (tokenAmount_ > remainingBalance_) {
            uint256 withdrawalAmount = tokenAmount_ - remainingBalance_;
            balance -= withdrawalAmount;
        }

        return balance;
    }

    /**
     * @dev Helper function that makes the rest of the code look nicer.
     */
    function tokenBalance() internal view returns (uint256) {
        return token().balanceOf(address(this));
    }
}
