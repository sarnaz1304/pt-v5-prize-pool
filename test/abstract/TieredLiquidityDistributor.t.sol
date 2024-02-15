// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import { TierCalculationLib } from "../../src/libraries/TierCalculationLib.sol";
import { TieredLiquidityDistributorWrapper } from "./helper/TieredLiquidityDistributorWrapper.sol";
import { UD60x18, NumberOfTiersLessThanMinimum, NumberOfTiersGreaterThanMaximum, InsufficientLiquidity, fromUD34x4toUD60x18, convert, SD59x18, MAXIMUM_NUMBER_OF_TIERS, MINIMUM_NUMBER_OF_TIERS } from "../../src/abstract/TieredLiquidityDistributor.sol";

contract TieredLiquidityDistributorTest is Test {
  TieredLiquidityDistributorWrapper public distributor;

  uint24 grandPrizePeriodDraws;
  uint8 numberOfTiers;
  uint8 tierShares;
  uint8 reserveShares;
  uint256 tierLiquidityUtilizationRate;

  function setUp() external {
    numberOfTiers = 3;
    tierShares = 100;
    reserveShares = 10;
    grandPrizePeriodDraws = 365;
    tierLiquidityUtilizationRate = 1e18;

    distributor = new TieredLiquidityDistributorWrapper(
      tierLiquidityUtilizationRate,
      numberOfTiers,
      tierShares,
      reserveShares,
      grandPrizePeriodDraws
    );
  }

  function testAwardDraw_invalid_num_tiers() public {
    vm.expectRevert(abi.encodeWithSelector(NumberOfTiersLessThanMinimum.selector, 1));
    distributor.awardDraw(1, 100);
  }

  function testAwardDraw_liquidity_shrinkTiers1() public {
    distributor.awardDraw(5, 510e18); // will reclaim 3 tiers
    distributor.awardDraw(4, 110e18);

    assertEq(distributor.remainingTierLiquidity(0), 200e18);
    assertEq(distributor.remainingTierLiquidity(1), 200e18);
    assertEq(distributor.remainingTierLiquidity(2), 100e18);
    assertEq(distributor.remainingTierLiquidity(3), 100e18);
    assertEq(distributor.remainingTierLiquidity(4), 0);
    assertEq(distributor.reserve(), 20e18);

    assertEq(_computeLiquidity(), 620e18);
  }

  function testAwardDraw_liquidity_shrinkTiers2() public {
    distributor.awardDraw(7, 710e18); // will reclaim 4 tiers: (3,4,5,6)
    distributor.awardDraw(5, 110e18);

    assertEq(distributor.remainingTierLiquidity(0), 200e18);
    assertEq(distributor.remainingTierLiquidity(1), 200e18);
    assertEq(distributor.remainingTierLiquidity(2), 200e18);
    assertEq(distributor.remainingTierLiquidity(3), 100e18);
    assertEq(distributor.remainingTierLiquidity(4), 100e18);
    assertEq(distributor.remainingTierLiquidity(5), 0);
    assertEq(distributor.reserve(), 20e18);

    assertEq(_computeLiquidity(), 820e18);
  }

  function testAwardDraw_liquidity_sameTiers() public {
    distributor.awardDraw(5, 100e18);
    distributor.awardDraw(5, 100e18);
    assertEq(_computeLiquidity(), 200e18);
  }

  function testAwardDraw_liquidity_growTiers1() public {
    distributor.awardDraw(5, 100e18);
    distributor.awardDraw(6, 100e18);
    assertEq(_computeLiquidity(), 200e18);
  }

  function testAwardDraw_liquidity_growTiers2() public {
    distributor.awardDraw(5, 510e18); // will reclaim canary + 100e18
    distributor.awardDraw(7, 610e18);

    assertEq(distributor.remainingTierLiquidity(0), 200e18, "old tier continues to accrue");
    assertEq(distributor.remainingTierLiquidity(1), 200e18, "old tier continues to accrue");
    assertEq(distributor.remainingTierLiquidity(2), 200e18, "old tier continues to accrue");
    assertEq(distributor.remainingTierLiquidity(3), 200e18, "old tier continues to accrue");
    assertEq(distributor.remainingTierLiquidity(4), 100e18, "old canary gets reclaimed");
    assertEq(distributor.remainingTierLiquidity(5), 100e18, "new tier who dis");
    assertEq(distributor.remainingTierLiquidity(6), 100e18, "new tier who dis");

    assertEq(_computeLiquidity(), 1120e18);
  }

  function testConstructor_numberOfTiersTooLarge() public {
    vm.expectRevert(abi.encodeWithSelector(NumberOfTiersGreaterThanMaximum.selector, 16));
    new TieredLiquidityDistributorWrapper(tierLiquidityUtilizationRate, 16, tierShares, reserveShares, 365);
  }

  function testConstructor_numberOfTiersTooSmall() public {
    vm.expectRevert(abi.encodeWithSelector(NumberOfTiersLessThanMinimum.selector, 1));
    new TieredLiquidityDistributorWrapper(tierLiquidityUtilizationRate, 1, tierShares, reserveShares, 365);
  }

  function testRemainingTierLiquidity() public {
    distributor.awardDraw(3, 310e18);
    assertEq(distributor.remainingTierLiquidity(0), 100e18);
    assertEq(distributor.remainingTierLiquidity(1), 100e18);
    assertEq(distributor.remainingTierLiquidity(2), 100e18);
  }

  function testConsumeLiquidity_partial() public {
    distributor.awardDraw(3, 310e18);
    distributor.consumeLiquidity(1, 50e18); // consume full liq for tier 1
    assertEq(distributor.remainingTierLiquidity(1), 50e18);
  }

  function testConsumeLiquidity_full() public {
    distributor.awardDraw(3, 310e18);
    distributor.consumeLiquidity(1, 100e18); // consume full liq for tier 1
    assertEq(distributor.remainingTierLiquidity(1), 0);
  }

  function testConsumeLiquidity_and_empty_reserve() public {
    distributor.awardDraw(3, 310e18); // reserve should be 10e18
    uint256 reserve = distributor.reserve();
    distributor.consumeLiquidity(1, 110e18); // consume full liq for tier 1 and reserve
    assertEq(distributor.remainingTierLiquidity(1), 0);
    assertEq(distributor.reserve(), 0);
    assertLt(distributor.reserve(), reserve);
  }

  function testConsumeLiquidity_and_partial_reserve() public {
    distributor.awardDraw(3, 310e18); // reserve should be 10e18
    uint256 reserve = distributor.reserve();
    distributor.consumeLiquidity(1, 105e18); // consume full liq for tier 1 and reserve
    assertEq(distributor.remainingTierLiquidity(1), 0);
    assertEq(distributor.reserve(), 5e18);
    assertLt(distributor.reserve(), reserve);
  }

  function testConsumeLiquidity_insufficient() public {
    distributor.awardDraw(3, 310e18); // reserve should be 10e18
    vm.expectRevert(abi.encodeWithSelector(InsufficientLiquidity.selector, 120e18));
    distributor.consumeLiquidity(1, 120e18);
  }

  function testGetTierPrizeSize_noDraw() public {
    assertEq(distributor.getTierPrizeSize(4), 0);
  }

  function testGetTierPrizeSize_invalid() public {
    distributor.awardDraw(3, 310e18);
    assertEq(distributor.getTierPrizeSize(4), 0);
  }

  function testGetTierPrizeSize_grandPrize() public {
    distributor.awardDraw(3, 310e18);
    assertEq(distributor.getTierPrizeSize(0), 100e18);
  }

  function testGetTierPrizeSize_grandPrize_utilizationLower() public {
    tierLiquidityUtilizationRate = 0.5e18;
    distributor = new TieredLiquidityDistributorWrapper(tierLiquidityUtilizationRate, numberOfTiers, tierShares, reserveShares, grandPrizePeriodDraws);
    distributor.awardDraw(3, 310e18);
    assertEq(distributor.getTierPrizeSize(0), 50e18);
    assertEq(distributor.getTierRemainingLiquidity(0), 100e18);
  }

  function testGetTierPrizeSize_overflow() public {
    distributor = new TieredLiquidityDistributorWrapper(tierLiquidityUtilizationRate, numberOfTiers, tierShares, 0, 365);

    distributor.awardDraw(3, type(uint104).max);
    distributor.awardDraw(4, type(uint104).max);
    distributor.awardDraw(5, type(uint104).max);
    distributor.awardDraw(6, type(uint104).max);

    assertEq(distributor.getTierPrizeSize(0), type(uint104).max);
  }

  function testGetRemainingTierLiquidity() public {
    distributor.awardDraw(3, 310e18);
    assertEq(distributor.getTierRemainingLiquidity(0), 100e18);
  }

  function testGetTierRemainingLiquidity() public {
    distributor.awardDraw(3, 310e18);
    assertEq(distributor.getTierRemainingLiquidity(0), 100e18);
  }

  function testGetTierRemainingLiquidity_invalid() public {
    distributor.awardDraw(3, 310e18);
    assertEq(distributor.getTierRemainingLiquidity(5), 0);
  }

  function testExpansionTierLiquidity() public {
    distributor.awardDraw(3, 310e18); // canary gets 100e18
    assertEq(distributor.getTierRemainingLiquidity(0), 100e18, "grand prize liquidity");
    assertEq(distributor.getTierRemainingLiquidity(1), 100e18, "tier 1 liquidity");
    assertEq(distributor.getTierRemainingLiquidity(2), 100e18, "canary liquidity");
    assertEq(distributor.getTierRemainingLiquidity(3), 0, "last tier");
    assertEq(distributor.reserve(), 10e18, "reserve");

    // 200e18 will be reclaimed from tier 1 and canary
    distributor.awardDraw(4, 310e18); // total will be 200e18 + 210e18 = 410e18

    assertEq(distributor.getTierRemainingLiquidity(0), 200e18, "grand prize liquidity");
    assertEq(distributor.getTierRemainingLiquidity(1), 200e18, "tier 1 liquidity");
    assertEq(distributor.getTierRemainingLiquidity(2), 100e18, "tier 2 liquidity");
    assertEq(distributor.getTierRemainingLiquidity(3), 100e18, "tier 3 liquidity");
    assertEq(distributor.getTierRemainingLiquidity(4), 0, "last tier out");
  }

  function testExpansionTierLiquidity_max() public {
    uint96 amount = 79228162514264337593543950333;
    // uint96 amount = 100e18;
    distributor.awardDraw(15, amount);

    UD60x18 prizeTokenPerShare = fromUD34x4toUD60x18(distributor.prizeTokenPerShare());
    uint256 total = convert(
      prizeTokenPerShare.mul(convert(distributor.getTotalShares() - distributor.reserveShares()))
    ) + distributor.reserve();
    assertEq(total, amount, "prize token per share against total shares");

    uint256 summed;
    for (uint8 t = 0; t < distributor.numberOfTiers(); t++) {
      summed += distributor.getTierRemainingLiquidity(t);
    }
    summed += distributor.reserve();

    assertEq(summed, amount, "summed amount across prize tiers");
  }

  function testGetTierOdds_AllAvailable() public {
    SD59x18 odds;
    grandPrizePeriodDraws = distributor.grandPrizePeriodDraws();
    for (
      uint8 numTiers = MINIMUM_NUMBER_OF_TIERS;
      numTiers <= MAXIMUM_NUMBER_OF_TIERS;
      numTiers++
    ) {
      for (uint8 tier = 0; tier < numTiers; tier++) {
        odds = distributor.getTierOdds(tier, numTiers);
      }
    }
  }

  function testGetTierPrizeCount() public {
    assertEq(distributor.getTierPrizeCount(0), 1);
    assertEq(distributor.getTierPrizeCount(1), 4);
    assertEq(distributor.getTierPrizeCount(2), 16);
  }

  function testTierOdds_zero_when_outside_bounds() public {
    SD59x18 odds;
    for (
      uint8 numTiers = MINIMUM_NUMBER_OF_TIERS;
      numTiers <= MAXIMUM_NUMBER_OF_TIERS;
      numTiers++
    ) {
      odds = distributor.getTierOdds(numTiers, numTiers);
      assertEq(SD59x18.unwrap(odds), 0);
    }
  }

  function testEstimateNumberOfTiersUsingPrizeCountPerDraw_allTiers() public {
    uint32 prizeCount;
    for (
      uint8 numTiers = MINIMUM_NUMBER_OF_TIERS;
      numTiers <= MAXIMUM_NUMBER_OF_TIERS;
      numTiers++
    ) {
      prizeCount = distributor.estimatedPrizeCount(numTiers);
      assertEq(
        distributor.estimateNumberOfTiersUsingPrizeCountPerDraw(prizeCount - 1),
        numTiers,
        "slightly under"
      );
      assertEq(
        distributor.estimateNumberOfTiersUsingPrizeCountPerDraw(prizeCount),
        numTiers,
        "match"
      );
      assertEq(
        distributor.estimateNumberOfTiersUsingPrizeCountPerDraw(prizeCount + 1),
        numTiers,
        "slightly over"
      );
    }

    assertEq(distributor.estimatedPrizeCount(11), 0, "exceeds bounds");
  }

  function testEstimateNumberOfTiersUsingPrizeCountPerDraw_loose() public {
    // 270 prizes for num tiers = 5
    assertEq(
      distributor.estimateNumberOfTiersUsingPrizeCountPerDraw(250),
      5,
      "matches slightly under"
    );
    assertEq(distributor.estimateNumberOfTiersUsingPrizeCountPerDraw(270), 5, "matches exact");
    assertEq(
      distributor.estimateNumberOfTiersUsingPrizeCountPerDraw(280),
      5,
      "matches slightly over"
    );
    assertEq(
      distributor.estimateNumberOfTiersUsingPrizeCountPerDraw(540),
      5,
      "matches significantly over"
    );
  }

  function testEstimatedPrizeCount_noParam() public {
    assertEq(distributor.estimatedPrizeCount(), 20);
  }

  function testEstimatedPrizeCount_allTiers() public {
    assertEq(distributor.estimatedPrizeCount(3), 20);
    assertEq(distributor.estimatedPrizeCount(4), 80);
    assertEq(distributor.estimatedPrizeCount(5), 322);
    assertEq(distributor.estimatedPrizeCount(6), 1294);
    assertEq(distributor.estimatedPrizeCount(7), 5204);
    assertEq(distributor.estimatedPrizeCount(8), 20901);
    assertEq(distributor.estimatedPrizeCount(9), 83894);
    assertEq(distributor.estimatedPrizeCount(10), 336579);
    assertEq(distributor.estimatedPrizeCount(11), 0);
  }

  function testSumTierPrizeCounts() public {
    assertEq(distributor.sumTierPrizeCounts(3), 20);
    assertEq(distributor.sumTierPrizeCounts(4), 80);
    assertEq(distributor.sumTierPrizeCounts(5), 322);
    assertEq(distributor.sumTierPrizeCounts(6), 1294);
    assertEq(distributor.sumTierPrizeCounts(7), 5204);
    assertEq(distributor.sumTierPrizeCounts(8), 20901);
    assertEq(distributor.sumTierPrizeCounts(9), 83894);
    assertEq(distributor.sumTierPrizeCounts(10), 336579);
    assertEq(distributor.sumTierPrizeCounts(11), 0);
  }

  function testExpansionTierLiquidity_regression() public {
    uint96 amount1 = 253012247290373118207;
    uint96 amount2 = 99152290762372054017;
    uint96 amount3 = 79228162514264337593543950333;
    uint total = amount1 + amount2 + uint(amount3);

    distributor.awardDraw(3, amount1);

    assertEq(summedLiquidity(), amount1, "after amount1");

    distributor.awardDraw(3, amount2);

    assertEq(summedLiquidity(), amount1 + uint(amount2), "after amount2");

    distributor.awardDraw(15, amount3);

    assertEq(summedLiquidity(), total, "after amount3");
  }

  function summedLiquidity() public view returns (uint256) {
    uint256 summed;
    for (uint8 t = 0; t < distributor.numberOfTiers(); t++) {
      summed += distributor.getTierRemainingLiquidity(t);
    }
    summed += distributor.reserve();
    return summed;
  }

  function _computeLiquidity() internal view returns (uint256) {
    uint256 liquidity = _getTierLiquidity(distributor.numberOfTiers());
    liquidity += distributor.reserve();
    return liquidity;
  }

  function _getTierLiquidity(uint8 _numberOfTiers) internal view returns (uint256) {
    uint256 liquidity = 0;
    for (uint8 i = 0; i < _numberOfTiers; i++) {
      liquidity += distributor.getTierRemainingLiquidity(i);
    }
    return liquidity;
  }
}
