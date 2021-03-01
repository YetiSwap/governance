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
contract LiquidityPoolManager is Ownable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeMath for uint;

    // Whitelisted pairs that offer YTS rewards
    // Note: AVAX/YTS is an AVAX pair
    EnumerableSet.AddressSet private avaxPairs;
    EnumerableSet.AddressSet private ytsPairs;

    // Maps pairs to their associated StakingRewards contract
    mapping(address => address) public stakes;

    // Known contract addresses for WAVAX and YTS
    address public wavax;
    address public yts;

    // AVAX/YTS pair used to determine YTS liquidity
    address public avaxYtsPair;

    // TreasuryVester contract that distributes YTS
    address public treasuryVester;

    // TODO remove
    uint public numPools = 0;

    bool private readyToDistribute = false;

    // Tokens to distribute to each pool. Indexed by avaxPairs then ytsPairs.
    uint[] public distribution;

    uint public unallocatedYts = 0;

    constructor(address wavax_,
                address yts_,
                address treasuryVester_) {
        wavax = wavax_;
        yts = yts_;
        treasuryVester = treasuryVester_;
    }

    /**
     * Check if the given pair is a whitelisted pair
     *
     * Args:
     *   pair: pair to check if whitelisted
     *
     * Return: True if whitelisted
     */
    function isWhitelisted(address pair) public view returns (bool) {
        return avaxPairs.contains(pair) || ytsPairs.contains(pair);
    }

    /**
     * Check if the given pair is a whitelisted AVAX pair. The AVAX/YTS pair is
     * considered an AVAX pair.
     *
     * Args:
     *   pair: pair to check
     *
     * Return: True if whitelisted and pair contains AVAX
     */
    function isAvaxPair(address pair) public view returns (bool) {
        return avaxPairs.contains(pair);
    }

    /**
     * Check if the given pair is a whitelisted YTS pair. The AVAX/YTS pair is
     * not considered a YTS pair.
     *
     * Args:
     *   pair: pair to check
     *
     * Return: True if whitelisted and pair contains YTS but is not AVAX/YTS pair
     */
    function isYtsPair(address pair) public view returns (bool) {
        return ytsPairs.contains(pair);
    }

    /**
     * Sets the AVAX/YTS pair. Pair's tokens must be AVAX and YTS.
     *
     * Args:
     *   pair: AVAX/YTS pair
     */
    function setAvaxYtsPair(address avaxYtsPair_) public onlyOwner {
        require(avaxYtsPair_ != address(0), 'LiquidityPoolManager::setAvaxYtsPair: Pool cannot be the zero address');
        avaxYtsPair = avaxYtsPair_;
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
    function addWhitelistedPool(address pair) public onlyOwner {
        require(pair != address(0), 'LiquidityPoolManager::addWhitelistedPool: Pool cannot be the zero address');
        require(isWhitelisted(pair) == false, 'LiquidityPoolManager::addWhitelistedPool: Pool already whitelisted');

        address token0 = IYetiSwapPair(pair).token0();
        address token1 = IYetiSwapPair(pair).token1();

        // Create the staking contract and associate it with the pair
        address stakeContract = address(new StakingRewards(yts, pair));
        stakes[pair] = stakeContract;

        // Add as an AVAX or YTS pair
        if (token0 == wavax || token1 == wavax) {
            avaxPairs.add(pair);
        } else if (token0 == yts || token1 == yts) {
            ytsPairs.add(pair);
        } else {
            // The governance contract can be used to deploy an altered
            // LiquidityPoolManager if non-AVAX/YTS pools are desired.
            revert("LiquidityPoolManager::addWhitelistedPool: No AVAX or YTS in the pair");
        }

        numPools = numPools.add(1);
    }

    /**
     * Delists a whitelisted pool. Liquidity providers will not receiving future rewards.
     * Already vested funds can still be claimed. Re-whitelisting a delisted pool will
     * deploy a new staking contract.
     *
     * Args:
     *   pair: pair to remove from whitelist
     */
    function removeWhitelistedPool(address pair) public onlyOwner {
        require(isWhitelisted(pair), 'LiquidityPoolManager::removeWhitelistedPool: Pool not whitelisted');

        address token0 = IYetiSwapPair(pair).token0();
        address token1 = IYetiSwapPair(pair).token1();

        stakes[pair] = address(0);

        if (token0 == wavax || token1 == wavax) {
            avaxPairs.remove(pair);
        } else {
            ytsPairs.remove(pair);
        }
        numPools = numPools.sub(1);
    }

    /**
     * Calculates the amount of liquidity in the pair. For an AVAX pool, the liquidity in the
     * pair is two times the amount of AVAX. Only works for AVAX pairs.
     *
     * Args:
     *   pair: AVAX pair to get liquidity in
     *
     * Returns: the amount of liquidity in the pool in units of AVAX
     */
    function getAvaxLiquidity(address pair) public view returns (uint) {
        (uint reserve0, uint reserve1, ) = IYetiSwapPair(pair).getReserves();

        uint liquidity = 0;

        // add the avax straight up
        if (IYetiSwapPair(pair).token0() == wavax) {
            liquidity = liquidity.add(reserve0);
        } else {
            require(IYetiSwapPair(pair).token1() == wavax, 'LiquidityPoolManager::getAvaxLiquidity: One of the tokens in the pair must be WAVAX');
            liquidity = liquidity.add(reserve1);
        }
        liquidity = liquidity.mul(2);
        return liquidity;
    }

    /**
     * Calculates the amount of liquidity in the pair. For a YTS pool, the liquidity in the
     * pair is two times the amount of YTS multiplied by the price of AVAX per YTS. Only
     * works for YTS pairs.
     *
     * Args:
     *   pair: YTS pair to get liquidity in
     *   conversionFactor: the price of AVAX to YTS
     *
     * Returns: the amount of liquidity in the pool in units of AVAX
     */
    function getYtsLiquidity(address pair, uint conversionFactor) public view returns (uint) {
        (uint reserve0, uint reserve1, ) = IYetiSwapPair(pair).getReserves();

        uint liquidity = 0;

        // add the yts straight up
        if (IYetiSwapPair(pair).token0() == yts) {
            liquidity = liquidity.add(reserve0);
        } else {
            require(IYetiSwapPair(pair).token1() == yts, 'LiquidityPoolManager::getYtsLiquidity: One of the tokens in the pair must be YTS');
            liquidity = liquidity.add(reserve1);
        }

        uint oneToken = 1e18;
        liquidity = liquidity.mul(conversionFactor).div(oneToken);
        liquidity = liquidity.mul(2);
        return liquidity;
    }

    /**
     * Calculates the price of swapping AVAX for 1 YTS
     *
     * Returns: the price of swapping AVAX for 1 YTS
     */
    function getAvaxYtsRatio() public view returns (uint conversionFactor) {
        require(!(avaxYtsPair == address(0)), "LiquidityPoolManager::getAvaxYtsRatio: No AVAX-YTS pair set");
        (uint reserve0, uint reserve1, ) = IYetiSwapPair(avaxYtsPair).getReserves();

        if (IYetiSwapPair(avaxYtsPair).token0() == wavax) {
            conversionFactor = quote(reserve1, reserve0);
        } else {
            conversionFactor = quote(reserve0, reserve1);
        }
    }

    /**
     * Determine how the vested YTS allocation will be distributed to the liquidity
     * pool staking contracts. Must be called before distributeTokens(). Tokens are
     * distributed to pools based on relative liquidity proportional to total
     * liquidity. Should be called after vestAllocation()/
     */
    function calculateReturns() public {
        require(!readyToDistribute, 'LiquidityPoolManager::calculateReturns: Previous returns not distributed. Call distributeTokens()');
        require(unallocatedYts > 0, 'LiquidityPoolManager::calculateReturns: No YTS to allocate. Call vestAllocation().');
        if (ytsPairs.length() > 0) {
            require(!(avaxYtsPair == address(0)), 'LiquidityPoolManager::calculateReturns: Avax/YTS Pair not set');
        }

        // Calculate total liquidity
        distribution = new uint[](numPools);
        uint totalLiquidity = 0;

        // Add liquidity from AVAX pairs
        for (uint i = 0; i < avaxPairs.length(); i++) {
            uint pairLiquidity = getAvaxLiquidity(avaxPairs.at(i));
            distribution[i] = pairLiquidity;
            totalLiquidity = SafeMath.add(totalLiquidity, pairLiquidity);
        }

        // Add liquidity from YTS pairs
        if (ytsPairs.length() > 0) {
            uint conversionRatio = getAvaxYtsRatio();
            for (uint i = 0; i < ytsPairs.length(); i++) {
                uint pairLiquidity = getYtsLiquidity(ytsPairs.at(i), conversionRatio);
                distribution[i + avaxPairs.length()] = pairLiquidity;
                totalLiquidity = SafeMath.add(totalLiquidity, pairLiquidity);
            }
        }

        // Calculate tokens for each pool
        uint transferred = 0;
        for (uint i = 0; i < distribution.length; i++) {
            uint pairTokens = distribution[i].mul(unallocatedYts).div(totalLiquidity);
            distribution[i] = pairTokens;
            transferred = transferred + pairTokens;
        }
        readyToDistribute = true;
    }

    /**
     * After token distributions have been calculated, actually distribute the vested YTS
     * allocation to the staking pools. Must be called after calculateReturns().
     */
    function distributeTokens() public nonReentrant {
        require(readyToDistribute, 'LiquidityPoolManager::distributeTokens: Previous returns not allocated. Call calculateReturns()');
        readyToDistribute = false;
        address stakeContract;
        uint rewardTokens;
        for (uint i = 0; i < distribution.length; i++) {
            if (i < avaxPairs.length()) {
                stakeContract = stakes[avaxPairs.at(i)];
            } else {
                stakeContract = stakes[ytsPairs.at(i - avaxPairs.length())];
            }
            rewardTokens = distribution[i];
            if (rewardTokens > 0) {
                require(IYTS(yts).transfer(stakeContract, rewardTokens), 'LiquidityPoolManager::distributeTokens: Transfer failed');
                StakingRewards(stakeContract).notifyRewardAmount(rewardTokens);
            }
        }
        unallocatedYts = 0;
    }

    /**
     * Fallback for distributeTokens in case of gas overflow. Distributes YTS tokens to a single pool.
     * distibuteTokens() must still be called once to reset the contract state before calling vestAllocation.
     *
     * Args:
     *   pairIndex: index of pair to distribute tokens to, AVAX pairs come first in the ordering
     */
    function distributeTokensSinglePool(uint pairIndex) public nonReentrant {
        require(readyToDistribute, 'LiquidityPoolManager::distributeTokensSinglePool: Previous returns not allocated. Call calculateReturns()');
        require(pairIndex < numPools, 'LiquidityPoolManager::distributeTokensSinglePool: Index out of bounds');

        address stakeContract;
        if (pairIndex < avaxPairs.length()) {
            stakeContract = stakes[avaxPairs.at(pairIndex)];
        } else {
            stakeContract = stakes[ytsPairs.at(pairIndex - avaxPairs.length())];
        }

        uint rewardTokens = distribution[pairIndex];
        if (rewardTokens > 0) {
            distribution[pairIndex] = 0;
            require(IYTS(yts).transfer(stakeContract, rewardTokens), 'LiquidityPoolManager::distributeTokens: Transfer failed');
            StakingRewards(stakeContract).notifyRewardAmount(rewardTokens);
        }
    }

    /**
     * Calculate pool token distribution and distribute tokens. Methods are separate
     * to use risk of approaching the gas limit. There must be vested tokens to
     * distribute, so this method should be called after vestAllocation.
     */
    function calculateAndDistribute() public {
        calculateReturns();
        distributeTokens();
    }

    /**
     * Claim today's vested tokens for the manager to distribute. Moves tokens from
     * the TreasuryVester to the LiquidityPoolManager. Can only be called if all
     * previously allocated tokens have been distributed. Call distributeTokens() if
     * that is not the case. If any additional YTS tokens have been transferred to this
     * this contract, they will be marked as unallocated and prepared for distribution.
     */
    function vestAllocation() public {
        require(unallocatedYts == 0, 'LiquidityPoolManager::vestAllocation: Old YTS is unallocated. Call distributeTokens().');
        unallocatedYts = ITreasuryVester(treasuryVester).claim();
        require(unallocatedYts > 0, 'LiquidityPoolManager::vestAllocation: No YTS to claim. Try again tomorrow.');

        // Check if we've received extra tokens or didn't receive enough
        uint actualBalance = IYTS(yts).balanceOf(address(this));
        require(actualBalance >= unallocatedYts, "LiquidityPoolManager::vestAllocation: Insufficient YTS transferred");
        unallocatedYts = actualBalance;
    }

    /**
     * Calculate the equivalent of 1e18 of token A denominated in token B for a pair
     * with reserveA and reserveB reserves.
     *
     * Args:
     *   reserveA: reserves of token A
     *   reserveB: reserves of token B
     *
     * Returns: the amount of token B equivalent to 1e18 of token A
     */
    function quote(uint reserveA, uint reserveB) internal pure returns (uint amountB) {
        require(reserveA > 0 && reserveB > 0, 'YetiSwapLibrary: INSUFFICIENT_LIQUIDITY');
        uint oneToken = 1e18;
        amountB = SafeMath.div(SafeMath.mul(oneToken, reserveB), reserveA);
    }

}

interface ITreasuryVester {
    function claim() external returns (uint);
}

interface IYTS {
    function balanceOf(address account) external view returns (uint);
    function transfer(address dst, uint rawAmount) external returns (bool);
}

interface IYetiSwapPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function balanceOf(address owner) external view returns (uint);
    function transfer(address to, uint value) external returns (bool);
    function burn(address to) external returns (uint amount0, uint amount1);
    function getReserves() external view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast);
}
