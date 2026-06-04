import { WORKFLOW_DESERIALIZE, WORKFLOW_SERIALIZE } from "@workflow/serde";
import { processCardCallbackUrls } from "./callback-url";
import { requireOutboundCapability } from "./capabilities";
import { cardToFallbackText } from "./cards";
import { normalizeBullXStream } from "./stream";
import { type ChatElement, isJSX, toCardElement } from "./jsx-runtime";
import {
  paragraph,
  parseMarkdown,
  rawPayloadToText,
  root,
  text as textNode,
  toPlainText,
} from "./markdown";
import { Message } from "./message";
import { isPostableObject, postPostableObject } from "./postable-object";
import { chatGatewayProjectionSink } from "./projection";
import type { ThreadHistoryCache } from "./thread-history";
import type {
  Adapter,
  AdapterPostableMessage,
  Author,
  Channel,
  ChannelInfo,
  ChannelVisibility,
  EphemeralMessage,
  PostableMessage,
  PostableObject,
  PostEphemeralOptions,
  ScheduledMessage,
  SentMessage,
  StateAdapter,
  ThreadSummary,
} from "./types";
import { NotImplementedError, THREAD_STATE_TTL_MS } from "./types";

/** State key prefix for channel state */
const CHANNEL_STATE_KEY_PREFIX = "channel-state:";

/**
 * Serialized channel data for passing to external systems (e.g., workflow engines).
 */
export interface SerializedChannel {
  _type: "chat:Channel";
  adapterName: string;
  channelVisibility?: ChannelVisibility;
  id: string;
  isDM: boolean;
}

/**
 * Config for creating a ChannelImpl with explicit adapter/state instances.
 */
interface ChannelImplConfigWithAdapter {
  adapter: Adapter;
  channelVisibility?: ChannelVisibility;
  id: string;
  isDM?: boolean;
  stateAdapter: StateAdapter;
  threadHistory?: ThreadHistoryCache;
}

type ChannelImplConfig = ChannelImplConfigWithAdapter;

/** Check if a value is a BullX chat output stream. */
function isAsyncIterable(value: unknown): value is AsyncIterable<string> {
  return (
    value !== null && typeof value === "object" && Symbol.asyncIterator in value
  );
}

export class ChannelImpl<TState = Record<string, unknown>>
  implements Channel<TState>
{
  readonly id: string;
  readonly isDM: boolean;
  readonly channelVisibility: ChannelVisibility;

  private _adapter?: Adapter;
  private _stateAdapterInstance?: StateAdapter;
  private _name: string | null = null;
  private readonly _threadHistory?: ThreadHistoryCache;

  constructor(config: ChannelImplConfig) {
    this.id = config.id;
    this.isDM = config.isDM ?? false;
    this.channelVisibility = config.channelVisibility ?? "unknown";

    this._adapter = config.adapter;
    this._stateAdapterInstance = config.stateAdapter;
    this._threadHistory = config.threadHistory;
  }

  get adapter(): Adapter {
    if (this._adapter) {
      return this._adapter;
    }

    throw new Error("Channel has no adapter configured");
  }

  private get _stateAdapter(): StateAdapter {
    if (this._stateAdapterInstance) {
      return this._stateAdapterInstance;
    }

    throw new Error("Channel has no state store configured");
  }

  get name(): string | null {
    return this._name;
  }

  get state(): Promise<TState | null> {
    return this._stateAdapter.get<TState>(
      `${CHANNEL_STATE_KEY_PREFIX}${this.id}`
    );
  }

  async setState(
    newState: Partial<TState>,
    options?: { replace?: boolean }
  ): Promise<void> {
    const key = `${CHANNEL_STATE_KEY_PREFIX}${this.id}`;

    if (options?.replace) {
      await this._stateAdapter.set(key, newState, THREAD_STATE_TTL_MS);
    } else {
      const existing = await this._stateAdapter.get<TState>(key);
      const merged = { ...existing, ...newState };
      await this._stateAdapter.set(key, merged, THREAD_STATE_TTL_MS);
    }
  }

  /**
   * Iterate messages newest first (backward from most recent).
   * Uses adapter.fetchChannelMessages if available, otherwise falls back
   * to adapter.fetchMessages with the channel ID.
   */
  get messages(): AsyncIterable<Message> {
    const adapter = this.adapter;
    const channelId = this.id;
    const threadHistory = this._threadHistory;

    return {
      async *[Symbol.asyncIterator]() {
        let cursor: string | undefined;
        let yieldedAny = false;

        while (adapter.fetchChannelMessages || adapter.fetchMessages) {
          const fetchOptions = { cursor, direction: "backward" as const };
          const result = adapter.fetchChannelMessages
            ? await adapter.fetchChannelMessages(channelId, fetchOptions)
            : await adapter.fetchMessages!(channelId, fetchOptions);

          // Messages within a page are chronological (oldest first),
          // but we want newest first, so reverse the page
          const reversed = [...result.messages].reverse();
          for (const message of reversed) {
            yieldedAny = true;
            yield message;
          }

          if (!result.nextCursor || result.messages.length === 0) {
            break;
          }

          cursor = result.nextCursor;
        }

        // Fall back to cached history if adapter returned nothing
        if (!yieldedAny && threadHistory) {
          const cached = await threadHistory.getMessages(channelId);
          // Yield newest first
          for (let i = cached.length - 1; i >= 0; i--) {
            yield cached[i];
          }
        }
      },
    };
  }

  /**
   * Iterate threads in this channel, most recently active first.
   */
  threads(): AsyncIterable<ThreadSummary> {
    const adapter = this.adapter;
    const channelId = this.id;

    return {
      async *[Symbol.asyncIterator]() {
        if (!adapter.listThreads) {
          // Platform doesn't support threading — return empty
          return;
        }

        let cursor: string | undefined;

        while (true) {
          const result = await adapter.listThreads(channelId, {
            cursor,
          });

          for (const thread of result.threads) {
            yield thread;
          }

          if (!result.nextCursor || result.threads.length === 0) {
            break;
          }

          cursor = result.nextCursor;
        }
      },
    };
  }

  async fetchMetadata(): Promise<ChannelInfo> {
    if (this.adapter.fetchChannelInfo) {
      const info = await this.adapter.fetchChannelInfo(this.id);
      this._name = info.name ?? null;
      return info;
    }

    // Fallback: return basic info
    return {
      id: this.id,
      isDM: this.isDM,
      metadata: {},
    };
  }

  async post<T extends PostableObject>(message: T): Promise<T>;
  async post(
    message:
      | string
      | AdapterPostableMessage
      | AsyncIterable<string>
      | ChatElement
  ): Promise<SentMessage>;
  async post(
    message: string | PostableMessage | ChatElement
  ): Promise<SentMessage | PostableObject> {
    if (isPostableObject(message)) {
      await this.handlePostableObject(message);
      return message;
    }

    // Handle AsyncIterable (streaming) — accumulate and post as single message
    if (isAsyncIterable(message)) {
      let accumulated = "";
      for await (const chunk of normalizeBullXStream(message)) {
        if (typeof chunk === "string") {
          accumulated += chunk;
        } else if (chunk.type === "markdown_text") {
          accumulated += chunk.text;
        }
      }
      return this.postSingleMessage({ markdown: accumulated });
    }

    // Auto-convert JSX elements to CardElement
    let postable: string | AdapterPostableMessage = message as
      | string
      | AdapterPostableMessage;
    if (isJSX(message)) {
      const card = toCardElement(message);
      if (!card) {
        throw new Error("Invalid JSX element: must be a Card element");
      }
      postable = card;
    }

    postable = await this.processCallbackUrls(postable);

    return this.postSingleMessage(postable);
  }

  private async handlePostableObject(obj: PostableObject): Promise<void> {
    await postPostableObject(obj, this.adapter, this.id, (threadId, message) => {
      requireOutboundCapability(
        this.adapter,
        "post_message",
        (this.adapter.postChannelMessage ?? this.adapter.postMessage)?.bind(this.adapter)
      );
      if (this.adapter.postChannelMessage) {
        return this.adapter.postChannelMessage(threadId, message);
      }

      return requireOutboundCapability(
        this.adapter,
        "post_message",
        this.adapter.postMessage?.bind(this.adapter)
      )(threadId, message);
    });
  }

  private async postSingleMessage(
    postable: AdapterPostableMessage
  ): Promise<SentMessage> {
    const postMessage = requireOutboundCapability(
      this.adapter,
      "post_message",
      (this.adapter.postChannelMessage ?? this.adapter.postMessage)?.bind(this.adapter)
    );
    const rawMessage = await postMessage(this.id, postable);

    const sent = this.createSentMessage(
      rawMessage.id,
      postable,
      rawMessage.threadId,
      rawMessage.raw
    );
    await this.projectSentMessage(sent);

    if (this._threadHistory) {
      await this._threadHistory.append(this.id, new Message(sent));
    }

    return sent;
  }

  async postEphemeral(
    user: string | Author,
    message: AdapterPostableMessage | ChatElement,
    options: PostEphemeralOptions
  ): Promise<EphemeralMessage | null> {
    const { fallbackToDM } = options;
    const userId = typeof user === "string" ? user : user.userId;

    let postable: AdapterPostableMessage;
    if (isJSX(message)) {
      const card = toCardElement(message);
      if (!card) {
        throw new Error("Invalid JSX element: must be a Card element");
      }
      postable = card;
    } else {
      postable = message as AdapterPostableMessage;
    }

    postable = await this.processCallbackUrls(postable);

    if (this.adapter.capabilities?.outbound?.includes("ephemeral") && this.adapter.postEphemeral) {
      return this.adapter.postEphemeral(this.id, userId, postable);
    }

    if (!fallbackToDM) {
      return null;
    }

    if (this.adapter.openDM && this.adapter.capabilities?.outbound?.includes("post_message")) {
      const dmThreadId = await this.adapter.openDM(userId);
      const result = await requireOutboundCapability(
        this.adapter,
        "post_message",
        this.adapter.postMessage?.bind(this.adapter)
      )(dmThreadId, postable);
      return {
        id: result.id,
        threadId: dmThreadId,
        usedFallback: true,
        raw: result.raw,
      };
    }

    return null;
  }

  async schedule(
    message: AdapterPostableMessage | ChatElement,
    options: { postAt: Date }
  ): Promise<ScheduledMessage> {
    let postable: AdapterPostableMessage;
    if (isJSX(message)) {
      const card = toCardElement(message);
      if (!card) {
        throw new Error("Invalid JSX element: must be a Card element");
      }
      postable = card;
    } else {
      postable = message as AdapterPostableMessage;
    }

    postable = await this.processCallbackUrls(postable);

    if (!this.adapter.scheduleMessage) {
      throw new NotImplementedError(
        "Scheduled messages are not supported by this adapter",
        "scheduling"
      );
    }

    return this.adapter.scheduleMessage(this.id, postable, options);
  }

  private async processCallbackUrls(
    postable: string | AdapterPostableMessage
  ): Promise<string | AdapterPostableMessage> {
    if (typeof postable === "string") {
      return postable;
    }

    if ("type" in postable && postable.type === "card") {
      return processCardCallbackUrls(postable, this._stateAdapter);
    }

    if ("card" in postable && postable.card?.type === "card") {
      const processed = await processCardCallbackUrls(
        postable.card,
        this._stateAdapter
      );
      if (processed !== postable.card) {
        return { ...postable, card: processed };
      }
    }

    return postable;
  }

  async startTyping(status?: string): Promise<void> {
    if (!this.adapter.startTyping) return;
    await this.adapter.startTyping(this.id, status);
  }

  mentionUser(userId: string): string {
    return `<@${userId}>`;
  }

  toJSON(): SerializedChannel {
    return {
      _type: "chat:Channel",
      id: this.id,
      adapterName: this.adapter.name,
      channelVisibility: this.channelVisibility,
      isDM: this.isDM,
    };
  }

  static fromJSON<TState = Record<string, unknown>>(
    json: SerializedChannel,
    adapter: Adapter,
    stateAdapter: StateAdapter
  ): ChannelImpl<TState> {
    return new ChannelImpl<TState>({
      id: json.id,
      adapter,
      stateAdapter,
      channelVisibility: json.channelVisibility,
      isDM: json.isDM,
    });
  }

  static [WORKFLOW_SERIALIZE](instance: ChannelImpl): SerializedChannel {
    return instance.toJSON();
  }

  static [WORKFLOW_DESERIALIZE](data: SerializedChannel): ChannelImpl {
    throw new Error(
      `Cannot deserialize ChannelImpl "${data.id}" without explicit Chat Gateway runtime context`
    );
  }

  private createSentMessage(
    messageId: string,
    postable: AdapterPostableMessage,
    threadIdOverride?: string,
    raw?: unknown
  ): SentMessage {
    const adapter = this.adapter;
    const threadId = threadIdOverride || this.id;
    const self = this;

    const { plainText, formatted, attachments } =
      extractMessageContent(postable);

    const sentMessage: SentMessage = {
      id: messageId,
      threadId,
      text: plainText,
      formatted,
      raw: raw ?? null,
      author: {
        userId: "self",
        userName: adapter.userName,
        fullName: adapter.userName,
        isBot: true,
        isMe: true,
      },
      metadata: {
        dateSent: new Date(),
        edited: false,
      },
      attachments,
      links: [],

      toJSON() {
        return new Message(this).toJSON();
      },

      async edit(
        newContent: string | PostableMessage | ChatElement
      ): Promise<SentMessage> {
        let editPostable: string | AdapterPostableMessage = newContent as
          | string
          | AdapterPostableMessage;
        if (isJSX(newContent)) {
          const card = toCardElement(newContent);
          if (!card) {
            throw new Error("Invalid JSX element: must be a Card element");
          }
          editPostable = card;
        }
        editPostable = await self.processCallbackUrls(editPostable);
        const rawMessage = await requireOutboundCapability(
          adapter,
          "edit_message",
          adapter.editMessage?.bind(adapter)
        )(threadId, messageId, editPostable);
        const edited = self.createSentMessage(messageId, editPostable, rawMessage.threadId || threadId, rawMessage.raw);
        edited.metadata.edited = true;
        edited.metadata.editedAt = new Date();
        await self.projectSentMessage(edited);
        return edited;
      },

      async delete(): Promise<void> {
        await requireOutboundCapability(
          adapter,
          "delete_message",
          adapter.deleteMessage?.bind(adapter)
        )(threadId, messageId);
        await self.projectSentDelete(threadId, messageId);
      },

      async addReaction(emoji: string): Promise<void> {
        await requireOutboundCapability(
          adapter,
          "add_reaction",
          adapter.addReaction?.bind(adapter)
        )(threadId, messageId, emoji);
      },

      async removeReaction(emoji: string): Promise<void> {
        await requireOutboundCapability(
          adapter,
          "remove_reaction",
          adapter.removeReaction?.bind(adapter)
        )(threadId, messageId, emoji);
      },
    };

    return sentMessage;
  }

  private async projectSentMessage(message: Omit<Message, "subject">): Promise<void> {
    await chatGatewayProjectionSink.projectMessage({
      thread: {
        id: message.threadId,
        channelId: this.id,
        channel: this,
      },
      message,
    });
  }

  private async projectSentDelete(threadId: string, messageId: string): Promise<void> {
    await chatGatewayProjectionSink.projectDelete({
      thread: {
        id: threadId,
        channelId: this.id,
        channel: this,
      },
      messageId,
    });
  }
}

/**
 * Derive the channel ID from a thread ID.
 */
export function deriveChannelId(adapter: Adapter, threadId: string): string {
  return adapter.channelIdFromThreadId(threadId);
}

/**
 * Extract plain text, AST, and attachments from a message.
 */
function extractMessageContent(message: AdapterPostableMessage): {
  plainText: string;
  formatted: import("mdast").Root;
  attachments: import("./types").Attachment[];
} {
  if (typeof message === "string") {
    return {
      plainText: message,
      formatted: root([paragraph([textNode(message)])]),
      attachments: [],
    };
  }

  if ("raw" in message) {
    const rawText = rawPayloadToText(message.raw);
    return {
      plainText: rawText,
      formatted: root([paragraph([textNode(rawText)])]),
      attachments: message.attachments || [],
    };
  }

  if ("markdown" in message) {
    const ast = parseMarkdown(message.markdown);
    return {
      plainText: toPlainText(ast),
      formatted: ast,
      attachments: message.attachments || [],
    };
  }

  if ("ast" in message) {
    return {
      plainText: toPlainText(message.ast),
      formatted: message.ast,
      attachments: message.attachments || [],
    };
  }

  if ("card" in message) {
    const fallbackText =
      message.fallbackText || cardToFallbackText(message.card);
    return {
      plainText: fallbackText,
      formatted: root([paragraph([textNode(fallbackText)])]),
      attachments: [],
    };
  }

  if ("type" in message && message.type === "card") {
    const fallbackText = cardToFallbackText(message);
    return {
      plainText: fallbackText,
      formatted: root([paragraph([textNode(fallbackText)])]),
      attachments: [],
    };
  }

  throw new Error("Invalid PostableMessage format");
}
