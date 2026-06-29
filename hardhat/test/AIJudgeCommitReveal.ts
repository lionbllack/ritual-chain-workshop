import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { network } from "hardhat";
import { encodeAbiParameters, keccak256, parseAbiParameters, parseEther, toHex } from "viem";

async function deployFixture() {
  const connection = await network.connect();
  const [owner, alice, bob] = await connection.viem.getWalletClients();
  const publicClient = await connection.viem.getPublicClient();

  const judge = await connection.viem.deployContract("AIJudgeHarness");

  const now = BigInt((await publicClient.getBlock()).timestamp);
  const commitDeadline = now + 1000n;
  const revealDeadline = now + 2000n;

  await judge.write.createBounty(
    ["Privacy Bounty", "Pick the clearest and safest solution", commitDeadline, revealDeadline],
    { account: owner.account, value: parseEther("1") }
  );

  return { connection, publicClient, judge, owner, alice, bob };
}

function makeCommitment(answer, salt, submitter, bountyId) {
  return keccak256(encodeAbiParameters(parseAbiParameters("string, bytes32, address, uint256"), [answer, salt, submitter, bountyId]));
}

async function increaseTime(connection, seconds) {
  await connection.networkHelpers.time.increase(Number(seconds));
}

describe("AIJudge commit-reveal bounty", () => {
  it("accepts commitment", async () => { 
    const { judge, alice } = await deployFixture(); 
    const c = makeCommitment("a", toHex("s", { size: 32 }), alice.account.address, 1n); 
    await judge.write.submitCommitment([1n, c], { account: alice.account }); 
    assert.ok(true); 
  });

  it("rejects duplicate commitment", async () => { 
    const { judge, alice } = await deployFixture(); 
    const c = makeCommitment("a", toHex("s", { size: 32 }), alice.account.address, 1n); 
    await judge.write.submitCommitment([1n, c], { account: alice.account }); 
    await assert.rejects(judge.write.submitCommitment([1n, c], { account: alice.account })); 
  });

  it("accepts valid reveal", async () => { 
    const { connection, judge, alice } = await deployFixture(); 
    const a = "correct"; 
    const s = toHex("s", { size: 32 }); 
    const c = makeCommitment(a, s, alice.account.address, 1n); 
    await judge.write.submitCommitment([1n, c], { account: alice.account }); 
    await increaseTime(connection, 1001n); 
    await judge.write.revealAnswer([1n, a, s], { account: alice.account }); 
    assert.ok(true); 
  });

  it("rejects wrong salt", async () => { 
    const { connection, judge, alice } = await deployFixture(); 
    const a = "a"; 
    const s = toHex("correct", { size: 32 }); 
    const ws = toHex("wrong", { size: 32 }); 
    const c = makeCommitment(a, s, alice.account.address, 1n); 
    await judge.write.submitCommitment([1n, c], { account: alice.account }); 
    await increaseTime(connection, 1001n); 
    await assert.rejects(judge.write.revealAnswer([1n, a, ws], { account: alice.account })); 
  });

  it("rejects reveal before deadline", async () => { 
    const { judge, alice } = await deployFixture(); 
    const a = "a"; 
    const s = toHex("s", { size: 32 }); 
    const c = makeCommitment(a, s, alice.account.address, 1n); 
    await judge.write.submitCommitment([1n, c], { account: alice.account }); 
    await assert.rejects(judge.write.revealAnswer([1n, a, s], { account: alice.account })); 
  });

  it("rejects reveal from wrong wallet", async () => { 
    const { connection, judge, alice, bob } = await deployFixture(); 
    const a = "a"; 
    const s = toHex("s", { size: 32 }); 
    const c = makeCommitment(a, s, alice.account.address, 1n); 
    await judge.write.submitCommitment([1n, c], { account: alice.account }); 
    await increaseTime(connection, 1001n); 
    await assert.rejects(judge.write.revealAnswer([1n, a, s], { account: bob.account })); 
  });

  it("finalizes winner", async () => { 
    const { connection, judge, owner, alice } = await deployFixture(); 
    const a = "winner"; 
    const s = toHex("s", { size: 32 }); 
    const c = makeCommitment(a, s, alice.account.address, 1n); 
    await judge.write.submitCommitment([1n, c], { account: alice.account }); 
    await increaseTime(connection, 1001n); 
    await judge.write.revealAnswer([1n, a, s], { account: alice.account }); 
    await judge.write.forceJudged([1n, toHex("ok")], { account: owner.account }); 
    await judge.write.finalizeWinner([1n, 0n], { account: owner.account }); 
    assert.ok(true); 
  });

  it("builds batch prompt with valid submissions", async () => { 
    const { connection, judge, alice } = await deployFixture(); 
    const a = "good answer"; 
    const s = toHex("s", { size: 32 }); 
    const c = makeCommitment(a, s, alice.account.address, 1n); 
    await judge.write.submitCommitment([1n, c], { account: alice.account }); 
    await increaseTime(connection, 1001n); 
    await judge.write.revealAnswer([1n, a, s], { account: alice.account }); 
    const prompt = await judge.read.getBatchJudgingPrompt([1n]); 
    assert.ok(prompt.includes("good answer")); 
  });
});
