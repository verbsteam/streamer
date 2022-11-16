import { assert, describe, test, clearStore, afterEach } from "matchstick-as/assembly/index";
import { Address, BigInt, Bytes } from "@graphprotocol/graph-ts";
import { handleStreamCreated } from "../src/StreamFactory";
import { createStreamCreatedEvent } from "./utils";
import { Stream } from "../generated/schema";

describe("StreamFactory", () => {
  afterEach(() => {
    clearStore();
  });

  test("Creates a new Stream", () => {
    const payer = Address.fromString("0x0000000000000000000000000000000000000001");
    const recipient = Address.fromString("0x0000000000000000000000000000000000000002");
    const tokenAmount = BigInt.fromI32(1234);
    const tokenAddress = Address.fromString("0x0000000000000000000000000000000000000003");
    const startTime = BigInt.fromI32(1000);
    const stopTime = BigInt.fromI32(2000);
    const streamAddress = Address.fromString("0x0000000000000000000000000000000000000004");

    handleStreamCreated(
      createStreamCreatedEvent(payer, recipient, tokenAmount, tokenAddress, startTime, stopTime, streamAddress),
    );

    const s = Stream.load(Bytes.fromHexString(streamAddress.toHex()));

    assert.stringEquals(s!.payer.toHex(), payer.toHex());
    assert.stringEquals(s!.recipient.toHex(), recipient.toHex());
    assert.bigIntEquals(s!.tokenAmount, tokenAmount);
    assert.stringEquals(s!.tokenAddress.toHex(), tokenAddress.toHex());
    assert.bigIntEquals(s!.startTime, startTime);
    assert.bigIntEquals(s!.stopTime, stopTime);
    assert.booleanEquals(s!.cancelled, false);
    assert.assertTrue(s!.cancelledAt === null);
  });
});
