// SPDX-License-Identifier: MIT





pragma solidity ^0.7.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";


import "./StakingRewards.sol";

/**
 * Contract to distribute YTS tokens to whitelisted trading pairs. After deploying,
 * whitelist the desired pairs and set the avaxYtsPair. When initial administration
 * is complete. Ownership should be transferred to the Timelock governance contract.
 */
contract YTSNewLiqPoolManager is Ownable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeMath for uint;

    // Whitelisted pairs that offer YTS rewards
    EnumerableSet.AddressSet private pools;
    mapping(address => uint) public rewardAmount;

    // TreasuryVester contract that distributes YTS
    address public treasuryVester;

    address public yts;

    // TODO remove
    uint public numPools = 0;

    constructor(address yts_,address treasuryVester_) {
        treasuryVester = treasuryVester_;
        yts = yts_;
    }

    /**
     * Check if the given stakeContract is a whitelisted stakeContract
     *
     * Args:
     *   stakeContract: stakeContract to check if whitelisted
     *
     * Return: True if whitelisted
     */
    function isWhitelisted(address stakeContract) public view returns (bool) {
        return pools.contains(stakeContract);
    }


    function getPool(uint index) public view returns (address) {
        return pools.at(index);
    }

    /**
     * Adds a new whitelisted liquidity pool pair. Generates a staking contract.
     * Liquidity providers may stake this liquidity provider reward token and
     * claim YTS rewards proportional to their stake. Pair must contain either
     * AVAX or YTS.
     *
     * Args:
     *   pair: pair to whitelist
     */
    function addWhitelistedPool(address stakeContract, uint _rewardAmount) public onlyOwner {
        require(stakeContract != address(0), 'LiquidityPoolManager::addWhitelistedPool: stakeContract cannot be the zero address');
        require(isWhitelisted(stakeContract) == false, 'LiquidityPoolManager::addWhitelistedPool: stakeContract already whitelisted');


        pools.add(stakeContract);
        rewardAmount[stakeContract] = _rewardAmount;

        numPools = numPools.add(1);
    }

    /**
     * Delists a whitelisted pool. Liquidity providers will not receiving future rewards.
     * Already vested funds can still be claimed. Re-whitelisting a delisted pool will
     * deploy a new staking contract.
     *
     * Args:
     *   stakeContract: stakeContract to remove from whitelist
     */
    function removeWhitelistedPool(address stakeContract) public onlyOwner {
        require(isWhitelisted(stakeContract), 'LiquidityPoolManager::removeWhitelistedPool: Pool not whitelisted');

        pools.remove(stakeContract);
        rewardAmount[stakeContract] = 0;

        numPools = numPools.sub(1);
    }

    function updateAmount(address stakeContract, uint amount) public onlyOwner {
        require(isWhitelisted(stakeContract), 'LiquidityPoolManager::updateAmount: Pool not whitelisted');
        require(amount>0, 'LiquidityPoolManager::updateAmount: Amount must be bigger than 0');

        rewardAmount[stakeContract] = amount;
    }

    /**
     * After token distributions have been calculated, actually distribute the vested YTS
     * allocation to the staking pools. Must be called after calculateReturns().
     */
    function distributeTokens() public onlyOwner  {

        address stakeContract;
        uint rewardTokens;

        for (uint i = 0; i < pools.length(); i++) {
            stakeContract = pools.at(i);
           
            rewardTokens = rewardAmount[stakeContract];
            if (rewardTokens > 0) {
                require(IYTS(yts).transfer(stakeContract, rewardTokens), 'LiquidityPoolManager::distributeTokens: Transfer failed');
                StakingRewards(stakeContract).notifyRewardAmount(rewardTokens);
            }
        }
    }

    /**
     * Fallback for distributeTokens in case of gas overflow. Distributes YTS tokens to a single pool.
     * distibuteTokens() must still be called once to reset the contract state before calling vestAllocation.
     *
     * Args:
     *   pairIndex: index of pair to distribute tokens to, AVAX pairs come first in the ordering
     */
    function distributeTokensSinglePool(uint pairIndex) public onlyOwner {
        require(pairIndex < numPools, 'LiquidityPoolManager::distributeTokensSinglePool: Index out of bounds');

        address stakeContract;
        stakeContract = pools.at(pairIndex);

        uint rewardTokens = rewardAmount[stakeContract];
        if (rewardTokens > 0) {
            require(IYTS(yts).transfer(stakeContract, rewardTokens), 'LiquidityPoolManager::distributeTokens: Transfer failed');
            StakingRewards(stakeContract).notifyRewardAmount(rewardTokens);
        }
    }

    function vestAllocation() public onlyOwner  {
        ITreasuryVester(treasuryVester).claim();
    }

}

interface ITreasuryVester {
    function claim() external returns (uint);
}

interface IYTS {
    function balanceOf(address account) external view returns (uint);
    function transfer(address dst, uint rawAmount) external returns (bool);
}
