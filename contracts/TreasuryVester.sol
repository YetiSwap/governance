// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * Contract to control the release of YTS.
 */
contract TreasuryVester is Ownable, ReentrancyGuard {
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    address public yts;
    address public recipient;

    // Amount to distribute at each interval
    uint public vestingAmount;

    // Interval to distribute
    uint public vestingCliff;

    // Number of distribution intervals before the distribution amount halves
    uint public halvingPeriod;

    // Countdown till the nest halving
    uint public nextSlash;

    bool public vestingEnabled;

    // Timestamp of latest distribution
    uint public lastUpdate;

    // Amount of YTS required to start distributing
    uint public startingBalance;

    event VestingEnabled();
    event TokensVested(uint amount, address recipient);

    // YTS Distribution plan:
    // According to the YetiSwap Litepaper, we initially will distribute
    // 175342.465753425 YTS per day. Vesting period will be 24 hours: 86400 seconds.
    // Halving will occur every four years. No leap day. 4 years: 1460 distributions

    constructor(
        address yts_,
        uint vestingAmount_,
        uint halvingPeriod_,
        uint vestingCliff_,
        uint startingBalance_
    ) {
        require(vestingAmount_ <= startingBalance_, 'TreasuryVester::constructor: Vesting amount too high');
        require(halvingPeriod_ >= 1, 'TreasuryVester::constructor: Invalid halving period');

        yts = yts_;

        vestingAmount = vestingAmount_;
        halvingPeriod = halvingPeriod_;
        vestingCliff = vestingCliff_;
        startingBalance = startingBalance_;

        lastUpdate = 0;
        nextSlash = halvingPeriod;
    }

    /**
     * Enable distribution. A sufficient amount of YTS >= startingBalance must be transferred
     * to the contract before enabling. The recipient must also be set. Can only be called by
     * the owner.
     */
    function startVesting() external onlyOwner {
        require(!vestingEnabled, 'TreasuryVester::startVesting: vesting already started');
        require(IERC20(yts).balanceOf(address(this)) >= startingBalance, 'TreasuryVester::startVesting: incorrect YTS supply');
        require(recipient != address(0), 'TreasuryVester::startVesting: recipient not set');
        vestingEnabled = true;

        emit VestingEnabled();
    }

    /**
     * Sets the recipient of the vested distributions. In the initial YetiSwap scheme, this
     * should be the address of the LiquidityPoolManager. Can only be called by the contract
     * owner.
     */
    function setRecipient(address recipient_) public onlyOwner {
        recipient = recipient_;
    }

    /**
     * Vest the next YTS allocation. Requires vestingCliff seconds in between calls. YTS will
     * be distributed to the recipient.
     */
    function claim() public nonReentrant returns (uint) {
        require(vestingEnabled, 'TreasuryVester::claim: vesting not enabled');
        require(msg.sender == recipient, 'TreasuryVester::claim: only recipient can claim');
        require(block.timestamp >= lastUpdate + vestingCliff, 'TreasuryVester::claim: not time yet');

        // If we've finished a halving period, reduce the amount
        if (nextSlash == 0) {
            nextSlash = halvingPeriod - 1;
            vestingAmount = vestingAmount / 2;
        } else {
            nextSlash = nextSlash.sub(1);
        }

        // Update the timelock
        lastUpdate = block.timestamp;

        // Distribute the tokens
        emit TokensVested(vestingAmount, recipient);
        IERC20(yts).safeTransfer(recipient, vestingAmount);

        return vestingAmount;
    }
}