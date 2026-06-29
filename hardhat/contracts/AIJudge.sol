// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./utils/PrecompileConsumer.sol";

contract AIJudge is PrecompileConsumer {
    struct Bounty {
        address owner;
        string title;
        string description;
        uint256 reward;
        uint256 commitDeadline;
        uint256 revealDeadline;
        bool judged;
        bool finalized;
        address winner;
        bytes aiReview;
        uint256 winnerIndex;
    }

    struct Submission {
        bytes32 commitment;
        string answer;
        bytes32 salt;
        bool revealed;
        bool valid;
    }

    uint256 public nextBountyId = 1;

    mapping(uint256 => Bounty) public bounties;
    mapping(uint256 => address[]) private submittersByBounty;
    mapping(uint256 => address[]) private validSubmittersByBounty;
    mapping(uint256 => mapping(address => Submission)) private submissions;

    event BountyCreated(uint256 indexed bountyId, address indexed owner, uint256 reward, uint256 commitDeadline, uint256 revealDeadline);
    event CommitmentSubmitted(uint256 indexed bountyId, address indexed submitter, bytes32 commitment);
    event AnswerRevealed(uint256 indexed bountyId, address indexed submitter, bool valid);
    event Judged(uint256 indexed bountyId, bytes aiReview);
    event WinnerFinalized(uint256 indexed bountyId, address indexed winner, uint256 winnerIndex, uint256 reward);

    modifier onlyBountyOwner(uint256 bountyId) {
        require(bounties[bountyId].owner == msg.sender, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    function createBounty(string calldata title, string calldata description, uint256 commitDeadline, uint256 revealDeadline) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(commitDeadline > block.timestamp, "bad commit deadline");
        require(revealDeadline > commitDeadline, "bad reveal deadline");

        bountyId = nextBountyId++;
        bounties[bountyId] = Bounty({
            owner: msg.sender,
            title: title,
            description: description,
            reward: msg.value,
            commitDeadline: commitDeadline,
            revealDeadline: revealDeadline,
            judged: false,
            finalized: false,
            winner: address(0),
            aiReview: "",
            winnerIndex: type(uint256).max
        });

        emit BountyCreated(bountyId, msg.sender, msg.value, commitDeadline, revealDeadline);
    }

    function submitCommitment(uint256 bountyId, bytes32 commitment) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];
        require(block.timestamp < bounty.commitDeadline, "commit phase over");
        require(commitment != bytes32(0), "empty commitment");
        require(submissions[bountyId][msg.sender].commitment == bytes32(0), "already committed");

        submissions[bountyId][msg.sender].commitment = commitment;
        submittersByBounty[bountyId].push(msg.sender);

        emit CommitmentSubmitted(bountyId, msg.sender, commitment);
    }

    function revealAnswer(uint256 bountyId, string calldata answer, bytes32 salt) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];
        Submission storage submission = submissions[bountyId][msg.sender];

        require(block.timestamp >= bounty.commitDeadline, "reveal not started");
        require(block.timestamp < bounty.revealDeadline, "reveal phase over");
        require(submission.commitment != bytes32(0), "no commitment");
        require(!submission.revealed, "already revealed");
        require(bytes(answer).length > 0, "empty answer");

        bytes32 recomputed = keccak256(abi.encode(answer, salt, msg.sender, bountyId));
        require(recomputed == submission.commitment, "invalid reveal");

        submission.answer = answer;
        submission.salt = salt;
        submission.revealed = true;
        submission.valid = true;

        validSubmittersByBounty[bountyId].push(msg.sender);
        emit AnswerRevealed(bountyId, msg.sender, true);
    }

    function judgeAll(uint256 bountyId, bytes calldata llmInput) external bountyExists(bountyId) onlyBountyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];
        require(block.timestamp >= bounty.revealDeadline, "reveal phase not over");
        require(!bounty.judged, "already judged");
        require(validSubmittersByBounty[bountyId].length > 0, "no valid submissions");
        require(llmInput.length > 0, "empty llm input");

        bytes memory review = _callLLM(llmInput);
        bounty.aiReview = review;
        bounty.judged = true;
        emit Judged(bountyId, review);
    }

    function finalizeWinner(uint256 bountyId, uint256 winnerIndex) external bountyExists(bountyId) onlyBountyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];
        address[] storage validSubmitters = validSubmittersByBounty[bountyId];

        require(bounty.judged, "not judged");
        require(!bounty.finalized, "already finalized");
        require(winnerIndex < validSubmitters.length, "bad winner index");

        address winner = validSubmitters[winnerIndex];
        uint256 reward = bounty.reward;

        bounty.finalized = true;
        bounty.winner = winner;
        bounty.winnerIndex = winnerIndex;
        bounty.reward = 0;

        (bool ok, ) = winner.call{value: reward}("");
        require(ok, "reward transfer failed");

        emit WinnerFinalized(bountyId, winner, winnerIndex, reward);
    }

    function getBatchJudgingPrompt(uint256 bountyId) external view bountyExists(bountyId) returns (string memory) {
        address[] storage validSubmitters = validSubmittersByBounty[bountyId];
        require(validSubmitters.length > 0, "no valid submissions");
        Bounty storage bounty = bounties[bountyId];

        string memory prompt = string.concat(
            "You are judging an AI bounty. Pick the best submission by index.\n\n",
            "Bounty title: ", bounty.title,
            "\nDescription: ", bounty.description,
            "\n\nSubmissions:\n"
        );

        for (uint256 i = 0; i < validSubmitters.length; i++) {
            Submission storage submission = submissions[bountyId][validSubmitters[i]];
            prompt = string.concat(prompt, "[", _toString(i), "] ", submission.answer, "\n");
        }

        prompt = string.concat(prompt, "\nReturn the winning index and a short explanation.");
        return prompt;
    }

    function getBounty(uint256 bountyId) external view bountyExists(bountyId) returns (Bounty memory) {
        return bounties[bountyId];
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
