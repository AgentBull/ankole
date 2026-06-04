/**
 * JSON reviver for BullX Chat Gateway objects.
 *
 * Restores serialized Thread, Channel, and Message instances during
 * JSON.parse(). Live Thread and Channel handles require an explicit Chat
 * instance so adapter resolution never depends on process-global singleton
 * state.
 */

import { ChannelImpl, type SerializedChannel } from "./channel";
import { Message, type SerializedMessage } from "./message";
import { type SerializedThread, ThreadImpl } from "./thread";
import type { Adapter, StateAdapter } from "./types";

interface ReviverRuntime {
  getAdapter(name: string): Adapter | undefined;
  getState(): StateAdapter;
}

export function createReviver(runtime: ReviverRuntime): (key: string, value: unknown) => unknown {
  return (_key: string, value: unknown): unknown => {
    if (value && typeof value === "object" && "_type" in value) {
      const typed = value as { _type: string };
      if (typed._type === "chat:Thread") {
        const json = value as SerializedThread;
        const adapter = requireAdapter(runtime, json.adapterName);
        return ThreadImpl.fromJSON(json, adapter, runtime.getState());
      }
      if (typed._type === "chat:Channel") {
        const json = value as SerializedChannel;
        const adapter = requireAdapter(runtime, json.adapterName);
        return ChannelImpl.fromJSON(json, adapter, runtime.getState());
      }
      if (typed._type === "chat:Message") {
        return Message.fromJSON(value as SerializedMessage);
      }
    }
    return value;
  };
}

/**
 * Message-only standalone reviver.
 *
 * Serialized Thread and Channel handles need adapter/state context, so callers
 * that need live handles must use `chat.reviver()` instead.
 */
export function reviver(_key: string, value: unknown): unknown {
  if (value && typeof value === "object" && "_type" in value) {
    const typed = value as { _type: string };
    if (typed._type === "chat:Thread" || typed._type === "chat:Channel") {
      throw new Error(`Cannot deserialize ${typed._type} without Chat Gateway runtime context`);
    }
    if (typed._type === "chat:Message") return Message.fromJSON(value as SerializedMessage);
  }
  return value;
}

function requireAdapter(runtime: ReviverRuntime, adapterName: string): Adapter {
  const adapter = runtime.getAdapter(adapterName);
  if (!adapter) throw new Error(`Adapter "${adapterName}" is not available in this Chat instance`);
  return adapter;
}
