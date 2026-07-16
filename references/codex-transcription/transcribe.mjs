#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { extname, join } from "node:path";

const endpoint = "https://chatgpt.com/backend-api/transcribe";
const userAgent = "Codex Desktop/26.707.72221 (Mac OS; arm64)";
const contentType = "audio/webm;codecs=opus";

function validateAudioFile(file) {
  if (extname(file).toLowerCase() !== ".webm") {
    throw new Error("Codex Desktop uploads WebM/Opus audio; use a .webm file");
  }
}

function authHeaders(auth) {
  const token = auth.tokens?.access_token;
  const accountId = auth.tokens?.account_id;

  if (auth.auth_mode !== "chatgpt" || !token || !accountId) {
    throw new Error("Codex must be logged in with a ChatGPT account");
  }

  return {
    Authorization: `Bearer ${token}`,
    "ChatGPT-Account-Id": accountId,
    originator: "Codex Desktop",
    "User-Agent": userAgent,
  };
}

async function transcribe(file) {
  validateAudioFile(file);
  const auth = JSON.parse(
    await readFile(join(homedir(), ".codex", "auth.json"), "utf8"),
  );
  const form = new FormData();
  form.append(
    "file",
    new Blob([await readFile(file)], { type: contentType }),
    "codex.webm",
  );

  const response = await fetch(endpoint, {
    method: "POST",
    headers: authHeaders(auth),
    body: form,
  });

  if (!response.ok) {
    const detail = (await response.text()).slice(0, 300);
    throw new Error(
      `Transcription failed: HTTP ${response.status}${detail ? ` — ${detail}` : ""}`,
    );
  }

  const result = await response.json();
  if (typeof result.text !== "string") {
    throw new Error("Transcription response did not contain text");
  }

  console.log(result.text);
}

if (process.argv[2] === "--self-check") {
  assert.doesNotThrow(() => validateAudioFile("sample.WEBM"));
  assert.throws(() => validateAudioFile("sample.wav"), /WebM\/Opus/);
  assert.throws(() => authHeaders({}), /ChatGPT account/);
  assert.ok(!("OPENAI_API_KEY" in authHeaders({
    auth_mode: "chatgpt",
    tokens: { access_token: "token", account_id: "account" },
  })));
  console.log("self-check passed");
} else if (!process.argv[2]) {
  console.error("Usage: node transcribe.mjs <audio-file>");
  process.exitCode = 2;
} else {
  await transcribe(process.argv[2]);
}
