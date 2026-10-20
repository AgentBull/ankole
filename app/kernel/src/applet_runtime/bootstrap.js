// Capture the only native capabilities before removing Deno from the realm.
(() => {
  const { op_applet_call: hostCall, op_applet_console: hostConsole, op_applet_inspect_guard: inspectGuard } = Deno.core.ops;
  const stringify = JSON.stringify;
  const parse = JSON.parse;
  const ownKeys = Reflect.ownKeys;
  const createObject = Object.create;
  const isArray = Array.isArray;
  const defineProperty = Object.defineProperty;
  const freeze = Object.freeze;
  const NativeError = Error;
  const isInteger = Number.isInteger;
  const NativeUint8Array = Uint8Array;
  const errors = new WeakSet();
  const markError = WeakSet.prototype.add.bind(errors);
  const isHttpError = WeakSet.prototype.has.bind(errors);
  const trustedError = Symbol();
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  class HttpError extends NativeError {
    constructor(status, code, message, details, authority) {
      if (!isInteger(status) || status < 400 || status > (authority === trustedError ? 599 : 499) || typeof code !== 'string') {
        throw new TypeError('HttpError requires status 400..499 and a string code');
      }
      super(message === undefined ? code : String(message));
      defineProperty(this, 'status', {value: status, enumerable: true});
      defineProperty(this, 'code', {value: code, enumerable: true});
      if (details !== undefined) this.details = details;
      markError(this);
    }
  }
  function hostError(value) {
    return new HttpError(value.status, value.code, value.message, value.details, trustedError);
  }
  function encodeBytes(value) {
    if (!(value instanceof NativeUint8Array)) throw new TypeError('file.write bytes must be Uint8Array');
    let result = '';
    for (let i = 0; i < value.length; i += 3) {
      const bits = (value[i] << 16) | ((value[i + 1] || 0) << 8) | (value[i + 2] || 0);
      result += alphabet[(bits >>> 18) & 63] + alphabet[(bits >>> 12) & 63]
        + (i + 1 < value.length ? alphabet[(bits >>> 6) & 63] : '=')
        + (i + 2 < value.length ? alphabet[bits & 63] : '=');
    }
    return { __ankole_bytes: result };
  }
  function decodeBytes(value) {
    const input = value.__ankole_bytes;
    const length = input.length / 4 * 3 - (input.endsWith('==') ? 2 : input.endsWith('=') ? 1 : 0);
    const bytes = new NativeUint8Array(length);
    let offset = 0;
    for (let i = 0; i < input.length; i += 4) {
      const bits = (alphabet.indexOf(input[i]) << 18) | (alphabet.indexOf(input[i + 1]) << 12)
        | ((alphabet.indexOf(input[i + 2]) & 63) << 6) | (alphabet.indexOf(input[i + 3]) & 63);
      if (offset < length) bytes[offset++] = bits >>> 16;
      if (offset < length) bytes[offset++] = bits >>> 8;
      if (offset < length) bytes[offset++] = bits;
    }
    return bytes;
  }
  function guardInspection() {
    if (inspectGuard()) throw hostError({ status: 500, code: 'inspect_only', message: 'Capabilities are unavailable during module inspection' });
  }
  async function call(operation, args) {
    guardInspection();
    const reply = await hostCall(operation, stringify(args));
    if (reply.error) throw hostError(reply.error);
    if (operation === 'file.read' && reply.value && reply.value.bytes) {
      reply.value.bytes = decodeBytes(reply.value.bytes);
    }
    return reply.value;
  }
  const runtime = {
    HttpError,
    db: freeze({
      schema: tableId => call('db.schema', [tableId]),
      query: (tableId, query = {}) => call('db.query', [tableId, query]),
      aggregate: (tableId, query) => call('db.aggregate', [tableId, query]),
      write: (tableId, changes) => call('db.write', [tableId, changes]),
    }),
    file: freeze({
      list: pageId => call('file.list', [pageId]),
      read: path => call('file.read', [path]),
      write: (pageId, file) => { guardInspection(); return call('file.write', [pageId, { ...file, bytes: encodeBytes(file.bytes) }]); },
    }),
    ai: freeze({ generateText: options => call('ai.generateText', [options]) }),
  };
  defineProperty(globalThis, 'AnkoleRuntime', { value: freeze(runtime), enumerable: true });
  defineProperty(globalThis, 'console', { value: freeze(Object.fromEntries(
    ['log', 'info', 'warn', 'error', 'debug'].map(level => [level, (...args) => {
      let message;
      try { message = args.map(value => typeof value === 'string' ? value : stringify(value)).join(' '); }
      catch { message = '[unserializable console value]'; }
      hostConsole(level, message);
    }])
  )), configurable: false });

  // The module namespace stays in native state, never on globalThis. The
  // returned functions close over built-ins that applet code cannot replace.
  let handlers;
  const validate = routes => {
    if (routes === null || typeof routes !== 'object' || isArray(routes)) {
      throw new TypeError('default export must be a route object');
    }
    const keys = ownKeys(routes);
    const captured = createObject(null);
    let encodedKeys = '[';
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      if (typeof key !== 'string') throw new TypeError('route keys must be strings');
      const handler = routes[key];
      if (typeof handler !== 'function') throw new TypeError(`route must be a function: ${key}`);
      captured[key] = handler;
      encodedKeys += (i === 0 ? '' : ',') + stringify(key);
    }
    handlers = captured;
    return `${encodedKeys}]`;
  };
  const invoke = async (routes, key, input) => {
    try {
      const result = await handlers[key](parse(input));
      if (result === undefined) return '{"status":204}';
      const encoded = stringify(result);
      if (encoded === undefined) throw new TypeError('handler result is not JSON serializable');
      return `{"status":200,"body":${encoded}}`;
    } catch (error) {
      if (isHttpError(error)) {
        const details = error.details === undefined ? '' : `,"details":${stringify(error.details)}`;
        return `{"status":${error.status},"body":{"error":{"code":${stringify(error.code)},"message":${stringify(error.message)}${details}}}}`;
      }
      let message = 'Handler failed';
      let stack = '';
      try { message = String(error && error.message || error); stack = String(error && error.stack || ''); }
      catch { /* The fixed browser response still applies to hostile exceptions. */ }
      return `{"status":500,"body":{"error":{"code":"handler_error","message":"Applet handler failed"}},"debug":{"message":${stringify(message.slice(0, 16384))},"stack":${stringify(stack.slice(0, 16384))}}}`;
    }
  };
  for (const name of ['Deno', 'WebAssembly']) {
    delete globalThis[name];
  }
  return { validate, invoke };
})()
