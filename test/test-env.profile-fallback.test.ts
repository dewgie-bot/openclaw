import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

const ORIGINAL_ENV = { ...process.env };
const tempDirs = new Set<string>();
const cleanupFns: Array<() => void> = [];

function restoreProcessEnv(): void {
  for (const key of Object.keys(process.env)) {
    if (!(key in ORIGINAL_ENV)) {
      delete process.env[key];
    }
  }
  for (const [key, value] of Object.entries(ORIGINAL_ENV)) {
    if (value === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = value;
    }
  }
}

function writeFile(targetPath: string, content: string): void {
  fs.mkdirSync(path.dirname(targetPath), { recursive: true });
  fs.writeFileSync(targetPath, content, "utf8");
}

function createTempHome(): string {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "openclaw-test-env-fallback-home-"));
  tempDirs.add(tempDir);
  return tempDir;
}

afterEach(() => {
  while (cleanupFns.length > 0) {
    cleanupFns.pop()?.();
  }
  restoreProcessEnv();
  vi.resetModules();
  vi.doUnmock("node:child_process");
  for (const tempDir of tempDirs) {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
  tempDirs.clear();
});

describe("installTestEnv profile fallback", () => {
  it("loads simple exported vars when shell-based profile sourcing fails", async () => {
    vi.doMock("node:child_process", () => ({
      execFileSync: vi.fn(() => {
        throw new Error("bash unavailable");
      }),
    }));

    const { installTestEnv } = await import("./test-env.js");

    const realHome = createTempHome();
    writeFile(path.join(realHome, ".profile"), "export TEST_PROFILE_ONLY=from-profile\n");

    process.env.HOME = realHome;
    process.env.USERPROFILE = realHome;
    process.env.OPENCLAW_LIVE_TEST = "1";
    process.env.OPENCLAW_LIVE_TEST_QUIET = "1";

    const testEnv = installTestEnv();
    cleanupFns.push(testEnv.cleanup);

    expect(process.env.TEST_PROFILE_ONLY).toBe("from-profile");
  });
});
