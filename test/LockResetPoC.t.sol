// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * Morpheus Bug Bounty — Finding: Lock Period Reset on Top-Up
 *
 * TARGET:  DepositPool @ 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790 (stETH pool)
 *          implementation 0xdB10dAEF167eA2233Ba6811457dD24D676FbD670
 *          Ethereum mainnet, block 26433200
 *
 * INVARIANT: adding capital to an existing staked position must not reduce the
 *            staker's lock multiplier or their reward-bearing virtual balance.
 *
 * BUG: DepositPool._stake() resets claimLockStart = block.timestamp on every
 *      stake (L385 + L415), destroying accumulated lock progress for the ENTIRE
 *      deposit. A user who tops up halfway through a lock loses 26% of their
 *      multiplier even though they added more capital.
 *
 * RUN (one command):
 *   forge test --match-test testLockReset -vvv
 *
 * No privileged accounts are used anywhere in this test.
 */

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface IDepositPool {
    function stake(uint256, uint256, uint128, address) external;
    function getCurrentUserMultiplier(uint256, address) external view returns (uint256);
    function usersData(address, uint256) external view returns (
        uint128 lastStake, uint256 deposited, uint256 rate, uint256 pendingRewards,
        uint128 claimLockStart, uint128 claimLockEnd, uint256 virtualDeposited,
        uint128 lastClaim, address referrer
    );
    function totalDepositedInPublicPools() external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface ILido {
    function submit(address) external payable returns (uint256);
}

contract LockResetPoC is Test {
    IDepositPool constant STETH_POOL = IDepositPool(0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790);
    IERC20     constant STETH      = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    ILido      constant LIDO       = ILido(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    address constant DISTRIBUTOR   = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;

    uint256 constant REWARD_POOL_ID = 0;
    uint256 constant FORK_BLOCK = 26433200;

    address attacker;

    function setUp() public {
        vm.createSelectFork("https://eth.drpc.org", FORK_BLOCK);

        vm.deal(address(this), 200 ether);
        LIDO.submit{value: 200 ether}(address(0));

        STETH.approve(address(STETH_POOL), type(uint256).max);
        STETH.approve(DISTRIBUTOR, type(uint256).max);

        attacker = address(this);
    }

    /// Mock each Chainlink aggregator to return a *fresh* round so time warps
    /// do not trip the staleness guard. Oracle simulation, not a privileged role.
    function _mockFreshOracle() internal {
        bytes4 sel = 0xfeaf968c;   // latestRoundData()
        bytes4 selDec = 0x313ce567; // decimals()
        (uint80 roundId, int256 answer, uint256 updatedAt) = (1, int256(1e8), block.timestamp);
        bytes memory rd = abi.encode(roundId, answer, uint256(0), updatedAt, roundId);
        bytes memory dec = abi.encode(uint8(8));

        address[6] memory feeds = [
            0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8, // stETH/USD
            0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23, // wBTC/BTC
            0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c, // BTC/USD
            0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419, // wETH/USD
            0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6, // USDC/USD
            0x3E7d1eAB13ad0104d2750B8863b489D65364e32D  // USDT/USD
        ];
        for (uint256 i = 0; i < feeds.length; i++) {
            vm.mockCall(feeds[i], abi.encodeWithSelector(sel), rd);
            vm.mockCall(feeds[i], abi.encodeWithSelector(selDec), dec);
        }
    }

    /// FINDING: Lock Period Reset on Top-Up
    function testLockReset() public {
        _mockFreshOracle();

        console.log("\n=== Lock Period Reset on Top-Up (Finding) ===");
        console.log("Target: stETH DepositPool 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790");
        console.log("Block:", block.number);

        // --- STEP 1: Stake 50 stETH with 2-year claim lock ---
        uint128 lockEnd = uint128(block.timestamp + 730 days);
        STETH_POOL.stake(REWARD_POOL_ID, 50 ether, lockEnd, address(0));

        uint256 m1 = STETH_POOL.getCurrentUserMultiplier(REWARD_POOL_ID, attacker);
        (,,, ,uint128 cs1, ,uint256 vd1,,) = STETH_POOL.usersData(attacker, REWARD_POOL_ID);

        console.log("\n--- After 50 stETH, 2-year lock ---");
        console.log("multiplier:", m1);
        console.log("claimLockStart:", cs1);
        console.log("virtualDeposited (x1e18):", vd1 / 1e18);

        // --- STEP 2: Warp 6 months ---
        vm.warp(block.timestamp + 180 days);
        _mockFreshOracle(); // refresh mock for new timestamp

        // --- STEP 3: Top up 10 stETH (ADDS capital) ---
        STETH_POOL.stake(REWARD_POOL_ID, 10 ether, 0, address(0));

        uint256 m2 = STETH_POOL.getCurrentUserMultiplier(REWARD_POOL_ID, attacker);
        (,,, ,uint128 cs2, ,uint256 vd2,,) = STETH_POOL.usersData(attacker, REWARD_POOL_ID);

        console.log("\n--- After top-up 10 stETH (more capital) ---");
        console.log("multiplier:", m2);
        console.log("claimLockStart RESET:", cs2);
        console.log("(was", cs1, ")");
        console.log("virtualDeposited (x1e18):", vd2 / 1e18);

        // --- ASSERT THE LOSS ---
        // Multiplier dropped despite ADDING capital.
        uint256 dropBps = ((m1 - m2) * 10000) / m1;
        console.log("\nMultiplier drop (bps):", dropBps);
        console.log("Multiplier drop (%):", dropBps / 100);

        assertTrue(m2 < m1, "FAIL: multiplier did not decrease");
        assertTrue(cs2 > cs1, "FAIL: claimLockStart not reset");
        // Loss quantified: virtual balance fell even though more was deposited.
        assertLt(vd2, vd1, "FAIL: virtual balance should have fallen (loss)");

        console.log("\n[PASS] LOCK RESET VERIFIED");
        console.log("  added 10 stETH but lost", dropBps, "bps of lock multiplier");
        console.log("=== PoC COMPLETE ===");
    }
}