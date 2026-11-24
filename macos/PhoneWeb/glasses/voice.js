// Speech from the glasses' microphones to the Mac: raw sound (16 kHz, one channel, signed
// 16-bit) gathered into binary messages between "listen" and "heard?". The Mac turns it
// into text and sends that back; nothing is done with it until you confirm on the glasses.

export const BYTES_PER_SECOND = 32_000;
/// A tenth of a second at least per message, half a second at most.
export const FRAME = 3200;
export const MAX_FRAME = 16_000;
/// The longest one utterance may be: a minute.
export const MAX_UTTERANCE = 60 * BYTES_PER_SECOND;

/// The sound as bytes, however the Even app handed it over: bytes, numbers or base64.
export function toBytes(pcm) {
  if (pcm instanceof Uint8Array) return pcm;
  if (pcm instanceof ArrayBuffer) return new Uint8Array(pcm);
  if (Array.isArray(pcm)) return Uint8Array.from(pcm);
  if (typeof pcm === "string") {
    try { return Uint8Array.from(atob(pcm), (char) => char.charCodeAt(0)); } catch { return new Uint8Array(0); }
  }
  return new Uint8Array(0);
}

/// Gathers pieces of sound into messages of whole samples, `frame` bytes or more each.
export function createFramer(frame = FRAME, max = MAX_FRAME) {
  let held = new Uint8Array(0);
  const take = (count) => {
    const out = held.slice(0, count);
    held = held.slice(count);
    return out;
  };
  return {
    /// Adds a piece; returns the messages that are ready.
    push(piece) {
      const joined = new Uint8Array(held.length + piece.length);
      joined.set(held);
      joined.set(piece, held.length);
      held = joined;
      const ready = [];
      while (held.length >= max) ready.push(take(max));
      if (held.length >= frame) ready.push(take(held.length - (held.length % 2)));
      return ready;
    },
    /// What's left, as whole samples; null when nothing is.
    flush() {
      const count = held.length - (held.length % 2);
      const out = count > 0 ? held.slice(0, count) : null;
      held = new Uint8Array(0);
      return out;
    },
    get held() { return held.length; },
  };
}

/// One utterance at a time. `send` takes a message, `sendAudio` bytes, `mic` turns the
/// glasses' microphones on or off; each may fail without breaking anything here.
export function createVoice({ send, sendAudio, mic }) {
  let framer = null;
  let sent = 0;
  const quiet = (work) => { try { const result = work(); if (result?.catch) result.catch(() => {}); } catch { /* the glasses or the link are gone */ } };

  function close(message) {
    if (!framer) return;
    const rest = framer.flush();
    framer = null;
    quiet(() => mic(false));
    if (message.t === "heard?" && rest && sent + rest.length <= MAX_UTTERANCE) quiet(() => sendAudio(rest));
    quiet(() => send(message));
  }

  return {
    get listening() { return framer != null; },
    /// Starts an utterance, dropping one still going.
    begin() {
      if (framer) close({ t: "unlisten" });
      framer = createFramer();
      sent = 0;
      quiet(() => send({ t: "listen" }));
      quiet(() => mic(true));
    },
    /// Sound from the glasses. Past a minute the utterance ends by itself; returns false then.
    audio(pcm) {
      if (!framer) return false;
      for (const message of framer.push(toBytes(pcm))) {
        if (sent + message.length > MAX_UTTERANCE) { close({ t: "heard?" }); return false; }
        sent += message.length;
        quiet(() => sendAudio(message));
      }
      return true;
    },
    /// Done talking: the Mac answers with what it heard.
    end() { close({ t: "heard?" }); },
    /// Never mind: nothing comes back.
    cancel() { close({ t: "unlisten" }); },
  };
}
