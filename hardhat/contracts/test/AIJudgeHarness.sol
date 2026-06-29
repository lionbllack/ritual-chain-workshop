// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../AIJudge.sol";

contract AIJudgeHarness is AIJudge {
    function forceJudged(uint256 bountyId, bytes calldata review) external {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        bounties[bountyId].judged = true;
        bounties[bountyId].aiReview = review;
    }
}
