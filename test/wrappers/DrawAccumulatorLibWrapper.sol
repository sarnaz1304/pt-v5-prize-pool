// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.17;

import "forge-std/console2.sol";

import { DrawAccumulatorLib, Observation } from "src/libraries/DrawAccumulatorLib.sol";
import { RingBufferLib } from "src/libraries/RingBufferLib.sol";
import { E, SD59x18, sd, unwrap, toSD59x18, fromSD59x18 } from "prb-math/SD59x18.sol";

// Note: Need to store the results from the library in a variable to be picked up by forge coverage
// See: https://github.com/foundry-rs/foundry/pull/3128#issuecomment-1241245086
contract DrawAccumulatorLibWrapper {

    DrawAccumulatorLib.Accumulator public accumulator;

    function setDrawRingBuffer(uint16 index, uint8 value) public {
        accumulator.drawRingBuffer[index] = value;
    }

    function setRingBufferInfo(uint16 nextIndex, uint16 cardinality) public {
        accumulator.ringBufferInfo.cardinality = cardinality;
        accumulator.ringBufferInfo.nextIndex = nextIndex;
    }

    function add(uint256 _amount, uint32 _drawId, SD59x18 _alpha) public returns (bool) {
        bool result = DrawAccumulatorLib.add(accumulator, _amount, _drawId, _alpha);
        return result;
    }

    function getTotalRemaining(uint32 _endDrawId, SD59x18 _alpha) public view returns (uint256) {
        uint256 result = DrawAccumulatorLib.getTotalRemaining(accumulator, _endDrawId, _alpha);
        return result;
    }

    function newestObservation() public view returns (Observation memory) {
        Observation memory result = DrawAccumulatorLib.newestObservation(accumulator);
        return result;
    }

    function getAvailableAt(uint32 _drawId, SD59x18 _alpha) public view returns (uint256) {
        uint256 result = DrawAccumulatorLib.getAvailableAt(accumulator, _drawId, _alpha);
        return result;
    }

    /**
     * Requires endDrawId to be greater than (the newest draw id - 1)
     */
    function getDisbursedBetween(
        uint32 _startDrawId,
        uint32 _endDrawId,
        SD59x18 _alpha
    ) public view returns (uint256) {
        uint256 result = DrawAccumulatorLib.getDisbursedBetween(accumulator, _startDrawId, _endDrawId, _alpha);
        return result;
    }

    /**
     * @notice Returns the remaining prize tokens available from relative draw _x
     */
    function integrateInf(SD59x18 _alpha, uint _x, uint _k) public pure returns (uint256) {
        uint256 result = DrawAccumulatorLib.integrateInf(_alpha, _x, _k);
        return result;
    }

    /**
     * @notice returns the number of tokens that were given out between draw _start and draw _end
     */
    function integrate(SD59x18 _alpha, uint _start, uint _end, uint _k) public pure returns (uint256) {
        uint256 result = DrawAccumulatorLib.integrate(_alpha, _start, _end, _k);
        return result;
    }

    function computeC(SD59x18 _alpha, uint _x, uint _k) public pure returns (SD59x18) {
        SD59x18 result = DrawAccumulatorLib.computeC(_alpha, _x, _k);
        return result;
    }

    /**
     */
    function binarySearch(
        uint32 _oldestIndex,
        uint32 _newestIndex,
        uint32 _cardinality,
        uint32 _targetLastCompletedDrawId
    ) public view returns (
        uint32 beforeOrAtIndex,
        uint32 beforeOrAtDrawId,
        uint32 afterOrAtIndex,
        uint32 afterOrAtDrawId
    ) {
        (beforeOrAtIndex, beforeOrAtDrawId, afterOrAtIndex, afterOrAtDrawId) = DrawAccumulatorLib.binarySearch(
            accumulator.drawRingBuffer, _oldestIndex, _newestIndex, _cardinality, _targetLastCompletedDrawId
        );
    }
}
