import assert from "node:assert/strict";
import { test } from "node:test";
import { FRAME, MAX_FRAME, MAX_UTTERANCE, createFramer, createVoice, toBytes } from "../voice.js";

test("sound is gathered into messages of whole samples", () => {
  const framer = createFramer();
  assert.deepEqual(framer.push(new Uint8Array(1000)), []);
  assert.deepEqual(framer.push(new Uint8Array(1000)), []);
  const ready = framer.push(new Uint8Array(1201));
  assert.equal(ready.length, 1);
  assert.equal(ready[0].length, FRAME);
  assert.equal(framer.held, 1, "the odd byte waits for its other half");
  assert.equal(framer.push(new Uint8Array(3199))[0].length, 3200);
  assert.equal(framer.flush(), null);
});

test("a big piece is split, and the rest comes out at the end", () => {
  const framer = createFramer();
  const ready = framer.push(new Uint8Array(MAX_FRAME * 2 + 500));
  assert.deepEqual(ready.map((message) => message.length), [MAX_FRAME, MAX_FRAME]);
  assert.equal(framer.flush().length, 500);
  assert.equal(framer.flush(), null);
});

test("bytes keep their order and values", () => {
  const framer = createFramer(4, 8);
  const ready = [...framer.push(Uint8Array.from([1, 2, 3])), ...framer.push(Uint8Array.from([4, 5, 6, 7, 8, 9, 10, 11]))];
  const all = ready.flatMap((message) => [...message]).concat([...(framer.flush() ?? [])]);
  assert.deepEqual(all, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
});

test("sound is taken as bytes, numbers or base64", () => {
  assert.deepEqual([...toBytes(Uint8Array.from([1, 2]))], [1, 2]);
  assert.deepEqual([...toBytes([3, 4])], [3, 4]);
  assert.deepEqual([...toBytes("AQID")], [1, 2, 3]);
  assert.equal(toBytes(undefined).length, 0);
  assert.equal(toBytes("***").length, 0);
});

function recorder() {
  const log = [];
  const voice = createVoice({
    send: (message) => log.push(message.t),
    sendAudio: (bytes) => log.push(bytes.length),
    mic: (on) => log.push(on ? "mic on" : "mic off"),
  });
  return { log, voice };
}

test("an utterance is bracketed by listen and heard?", () => {
  const { log, voice } = recorder();
  assert.equal(voice.audio(new Uint8Array(3200)), false, "nothing before listen");
  voice.begin();
  voice.audio(new Uint8Array(3200));
  voice.audio(new Uint8Array(1000));
  voice.end();
  assert.deepEqual(log, ["listen", "mic on", 3200, "mic off", 1000, "heard?"]);
  assert.equal(voice.listening, false);
  voice.end();
  assert.equal(log.length, 6, "ending twice does nothing");
});

test("cancelling sends no more sound", () => {
  const { log, voice } = recorder();
  voice.begin();
  voice.audio(new Uint8Array(1000));
  voice.cancel();
  assert.deepEqual(log, ["listen", "mic on", "mic off", "unlisten"]);
});

test("an utterance ends by itself at a minute", () => {
  const { log, voice } = recorder();
  voice.begin();
  let going = true;
  let pieces = 0;
  while (going && pieces < 500) { going = voice.audio(new Uint8Array(MAX_FRAME)); pieces += 1; }
  assert.equal(going, false);
  const sound = log.filter((entry) => typeof entry === "number").reduce((sum, n) => sum + n, 0);
  assert.ok(sound <= MAX_UTTERANCE);
  assert.equal(log.at(-1), "heard?");
});

test("a microphone or link that fails doesn't break the utterance", () => {
  const voice = createVoice({
    send: () => { throw new Error("no link"); },
    sendAudio: () => { throw new Error("no link"); },
    mic: () => Promise.reject(new Error("no glasses")),
  });
  voice.begin();
  voice.audio(new Uint8Array(4000));
  voice.end();
  assert.equal(voice.listening, false);
});
