// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import { SafeCast } from "openzeppelin/utils/math/SafeCast.sol";
import { RingBufferLib } from "ring-buffer-lib/RingBufferLib.sol";

/// @notice Emitted when adding balance for draw zero.
error AddToDrawZero();

/// @notice Emitted when an action can't be done on a closed draw.
/// @param drawId The ID of the closed draw
/// @param newestDrawId The newest draw ID
error DrawAwarded(uint24 drawId, uint24 newestDrawId);

/// @notice Emitted when a draw range is not strictly increasing.
/// @param startDrawId The start draw ID of the range
/// @param endDrawId The end draw ID of the range
error InvalidDrawRange(uint24 startDrawId, uint24 endDrawId);

struct Observation {
  uint96 available; // track the total amount available as of this Observation
  uint160 disbursed; // track the total accumulated previously
}

/// @title Draw Accumulator Lib
/// @author G9 Software Inc.
/// @notice This contract distributes tokens over time according to an exponential weighted average. Time is divided into discrete "draws", of which each is allocated tokens.
library DrawAccumulatorLib {
  /// @notice The maximum number of observations that can be recorded.
  uint16 internal constant MAX_CARDINALITY = 366;

  /// @notice The metadata for using the ring buffer.
  struct RingBufferInfo {
    uint16 nextIndex;
    uint16 cardinality;
  }

  /// @notice An accumulator for a draw.
  struct Accumulator {
    RingBufferInfo ringBufferInfo; // 32 bits
    uint24[366] drawRingBuffer; // 8784 bits
    // 8784 + 32 = 8816 bits in total
    // 256 * 35 = 8960
    // 8960 - 8816 = 144 bits left over
    mapping(uint256 drawId => Observation observation) observations;
  }

  /// @notice A pair of uint24s.
  struct Pair48 {
    uint24 first;
    uint24 second;
  }

  /// @notice Adds balance for the given draw id to the accumulator.
  /// @param accumulator The accumulator to add to
  /// @param _amount The amount of balance to add
  /// @param _drawId The draw id to which to add balance to. This must be greater than or equal to the previous addition's draw id.
  /// @return True if a new observation was created, false otherwise.
  function add(
    Accumulator storage accumulator,
    uint256 _amount,
    uint24 _drawId
  ) internal returns (bool) {
    if (_drawId == 0) {
      revert AddToDrawZero();
    }
    RingBufferInfo memory ringBufferInfo = accumulator.ringBufferInfo;

    uint24 newestDrawId_ = accumulator.drawRingBuffer[
      RingBufferLib.newestIndex(ringBufferInfo.nextIndex, MAX_CARDINALITY)
    ];

    if (_drawId < newestDrawId_) {
      revert DrawAwarded(_drawId, newestDrawId_);
    }

    mapping(uint256 drawId => Observation observation) storage accumulatorObservations = accumulator
      .observations;
    Observation memory newestObservation_ = accumulatorObservations[newestDrawId_];
    if (_drawId != newestDrawId_) {
      uint16 cardinality = ringBufferInfo.cardinality;
      if (ringBufferInfo.cardinality < MAX_CARDINALITY) {
        cardinality += 1;
      } else {
        // Delete the old observation to save gas (older than 1 year)
        delete accumulatorObservations[accumulator.drawRingBuffer[ringBufferInfo.nextIndex]];
      }

      accumulator.drawRingBuffer[ringBufferInfo.nextIndex] = _drawId;
      accumulatorObservations[_drawId] = Observation({
        available: SafeCast.toUint96(_amount),
        disbursed: SafeCast.toUint160(
          newestObservation_.disbursed +
            newestObservation_.available
        )
      });

      accumulator.ringBufferInfo = RingBufferInfo({
        nextIndex: uint16(RingBufferLib.nextIndex(ringBufferInfo.nextIndex, MAX_CARDINALITY)),
        cardinality: cardinality
      });

      return true;
    } else {
      accumulatorObservations[newestDrawId_] = Observation({
        available: SafeCast.toUint96(newestObservation_.available + _amount),
        disbursed: newestObservation_.disbursed
      });

      return false;
    }
  }

  /// @notice Returns the newest draw id from the accumulator.
  /// @param accumulator The accumulator to get the newest draw id from
  /// @return The newest draw id
  function newestDrawId(Accumulator storage accumulator) internal view returns (uint256) {
    return
      accumulator.drawRingBuffer[
        RingBufferLib.newestIndex(accumulator.ringBufferInfo.nextIndex, MAX_CARDINALITY)
      ];
  }

  /// @notice Gets the balance that was disbursed between the given start and end draw ids, inclusive.
  /// @param _accumulator The accumulator to get the disbursed balance from
  /// @param _startDrawId The start draw id, inclusive
  /// @param _endDrawId The end draw id, inclusive
  /// @return The disbursed balance between the given start and end draw ids, inclusive
  function getDisbursedBetween(
    Accumulator storage _accumulator,
    uint24 _startDrawId,
    uint24 _endDrawId
  ) internal view returns (uint256) {
    if (_startDrawId > _endDrawId) {
      revert InvalidDrawRange(_startDrawId, _endDrawId);
    }

    RingBufferInfo memory ringBufferInfo = _accumulator.ringBufferInfo;

    if (ringBufferInfo.cardinality == 0) {
      return 0;
    }

    Pair48 memory indexes = computeIndices(ringBufferInfo);
    Pair48 memory drawIds = readDrawIds(_accumulator, indexes);

    if (_endDrawId < drawIds.first || _startDrawId > drawIds.second) {
      // if out of range, return 0
      return 0;
    }

    uint24 firstObservationDrawIdOccurringAtOrAfterStart;
    if (_startDrawId <= drawIds.first || ringBufferInfo.cardinality == 1) {
      firstObservationDrawIdOccurringAtOrAfterStart = drawIds.first;
    } else {
      // The start must be between newest and oldest
      // binary search
      (
        ,
        ,
        ,
        firstObservationDrawIdOccurringAtOrAfterStart
      ) = binarySearch(
        _accumulator.drawRingBuffer,
        uint16(indexes.first),
        uint16(indexes.second),
        ringBufferInfo.cardinality,
        _startDrawId
      );
    }

    uint24 lastObservationDrawIdOccurringAtOrBeforeEnd;
    if (_endDrawId >= drawIds.second || ringBufferInfo.cardinality == 1) {
      // then it must be the end
      lastObservationDrawIdOccurringAtOrBeforeEnd = drawIds.second;
    } else {
      (, lastObservationDrawIdOccurringAtOrBeforeEnd, ,) = binarySearch(
        _accumulator.drawRingBuffer,
        uint16(indexes.first),
        uint16(indexes.second),
        ringBufferInfo.cardinality,
        _endDrawId
      );
    }

    /*

    uint24 lastObservationDrawIdOccurringAtOrBeforeEnd;
    if (_endDrawId >= drawIds.second) {
      // then it must be the end
      lastObservationDrawIdOccurringAtOrBeforeEnd = drawIds.second;
    } else if (_endDrawId == drawIds.first) {
      // then it must be the first
      lastObservationDrawIdOccurringAtOrBeforeEnd = drawIds.first;
    } else if (_endDrawId == drawIds.second - 1) {
      // then it must be the one before the end
      // (we check this case since it is common and we want to avoid the extra binary search)
      lastObservationDrawIdOccurringAtOrBeforeEnd = _accumulator.drawRingBuffer[
        uint16(RingBufferLib.offset(indexes.second, 1, ringBufferInfo.cardinality))
      ];
    } else {
      // The last obs before or at end must be between newest and oldest
      // binary search
      (, uint24 beforeOrAtDrawId, , uint24 afterOrAtDrawId) = binarySearch(
        _accumulator.drawRingBuffer,
        uint16(indexes.first),
        uint16(indexes.second),
        ringBufferInfo.cardinality,
        _endDrawId
      );
      lastObservationDrawIdOccurringAtOrBeforeEnd = afterOrAtDrawId == _endDrawId
        ? afterOrAtDrawId
        : beforeOrAtDrawId;
    }

    uint24 observationDrawIdBeforeOrAtStart;
    uint24 firstObservationDrawIdOccurringAtOrAfterStart;
    // if there is only one observation, or startId is after the newest record
    if (_startDrawId >= drawIds.second) {
      // then use the newest record
      observationDrawIdBeforeOrAtStart = drawIds.second;
    } else if (_startDrawId <= drawIds.first) {
      // if the start is before the oldest record
      // then set to the oldest record.
      firstObservationDrawIdOccurringAtOrAfterStart = drawIds.first;
    } else {
      // The start must be between newest and oldest
      // binary search
      (
        ,
        observationDrawIdBeforeOrAtStart,
        ,
        firstObservationDrawIdOccurringAtOrAfterStart
      ) = binarySearch(
        _accumulator.drawRingBuffer,
        uint16(indexes.first),
        uint16(indexes.second),
        ringBufferInfo.cardinality,
        _startDrawId
      );
    }
*/
    // if at or after != at or before

    /**
      * 1. at or after start 
      * 2. if the start and end are different, then the total disbursed is the difference between the two   
     */

    if (firstObservationDrawIdOccurringAtOrAfterStart == lastObservationDrawIdOccurringAtOrBeforeEnd) {
      return _accumulator.observations[lastObservationDrawIdOccurringAtOrBeforeEnd].available;
    } else {
      Observation memory atOrAfterStart = _accumulator.observations[
        firstObservationDrawIdOccurringAtOrAfterStart
      ];
      Observation memory atOrBeforeEnd = _accumulator.observations[
        lastObservationDrawIdOccurringAtOrBeforeEnd
      ];

      return atOrBeforeEnd.available + atOrAfterStart.disbursed - atOrBeforeEnd.disbursed;
    }
  }

  /// @notice Computes the first and last indices of observations for the given ring buffer info.
  /// @param ringBufferInfo The ring buffer info to compute for
  /// @return A pair of indices, where the first is the oldest index and the second is the newest index
  function computeIndices(
    RingBufferInfo memory ringBufferInfo
  ) internal pure returns (Pair48 memory) {
    return
      Pair48({
        first: uint16(
          RingBufferLib.oldestIndex(
            ringBufferInfo.nextIndex,
            ringBufferInfo.cardinality,
            MAX_CARDINALITY
          )
        ),
        second: uint16(
          RingBufferLib.newestIndex(ringBufferInfo.nextIndex, ringBufferInfo.cardinality)
        )
      });
  }

  /// @notice Retrieves the draw ids for the given accumulator observation indices.
  /// @param accumulator The accumulator to retrieve from
  /// @param indices The indices to retrieve
  /// @return A pair of draw ids, where the first is the draw id of the pair's first index and the second is the draw id of the pair's second index
  function readDrawIds(
    Accumulator storage accumulator,
    Pair48 memory indices
  ) internal view returns (Pair48 memory) {
    return
      Pair48({
        first: accumulator.drawRingBuffer[indices.first],
        second: accumulator.drawRingBuffer[indices.second]
      });
  }

  /// @notice Binary searches an array of draw ids for the given target draw id.
  /// @dev The _targetDrawId MUST exist between the range of draws at _oldestIndex and _newestIndex (inclusive)
  /// @param _drawRingBuffer The array of draw ids to search
  /// @param _oldestIndex The oldest index in the ring buffer
  /// @param _newestIndex The newest index in the ring buffer
  /// @param _cardinality The number of items in the ring buffer
  /// @param _targetDrawId The target draw id to search for
  /// @return beforeOrAtIndex The index of the observation occurring at or before the target draw id
  /// @return beforeOrAtDrawId The draw id of the observation occurring at or before the target draw id
  /// @return afterOrAtIndex The index of the observation occurring at or after the target draw id
  /// @return afterOrAtDrawId The draw id of the observation occurring at or after the target draw id
  function binarySearch(
    uint24[366] storage _drawRingBuffer,
    uint16 _oldestIndex,
    uint16 _newestIndex,
    uint16 _cardinality,
    uint24 _targetDrawId
  )
    internal
    view
    returns (
      uint16 beforeOrAtIndex,
      uint24 beforeOrAtDrawId,
      uint16 afterOrAtIndex,
      uint24 afterOrAtDrawId
    )
  {
    uint16 leftSide = _oldestIndex;
    uint16 rightSide = _newestIndex < leftSide ? leftSide + _cardinality - 1 : _newestIndex;
    uint16 currentIndex;

    while (true) {
      // We start our search in the middle of the `leftSide` and `rightSide`.
      // After each iteration, we narrow down the search to the left or the right side while still starting our search in the middle.
      currentIndex = (leftSide + rightSide) / 2;

      beforeOrAtIndex = uint16(RingBufferLib.wrap(currentIndex, _cardinality));
      beforeOrAtDrawId = _drawRingBuffer[beforeOrAtIndex];

      afterOrAtIndex = uint16(RingBufferLib.nextIndex(currentIndex, _cardinality));
      afterOrAtDrawId = _drawRingBuffer[afterOrAtIndex];

      bool targetAtOrAfter = beforeOrAtDrawId <= _targetDrawId;

      // Check if we've found the corresponding Observation.
      if (targetAtOrAfter && _targetDrawId <= afterOrAtDrawId) {
        break;
      }

      // If `beforeOrAtTimestamp` is greater than `_target`, then we keep searching lower. To the left of the current index.
      if (!targetAtOrAfter) {
        rightSide = currentIndex - 1;
      } else {
        // Otherwise, we keep searching higher. To the left of the current index.
        leftSide = currentIndex + 1;
      }
    }
  }
}
