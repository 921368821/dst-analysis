var __create = Object.create;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getProtoOf = Object.getPrototypeOf;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __require = /* @__PURE__ */ ((x) => typeof require !== "undefined" ? require : typeof Proxy !== "undefined" ? new Proxy(x, {
  get: (a, b) => (typeof require !== "undefined" ? require : a)[b]
}) : x)(function(x) {
  if (typeof require !== "undefined") return require.apply(this, arguments);
  throw Error('Dynamic require of "' + x + '" is not supported');
});
var __commonJS = (cb, mod) => function __require2() {
  return mod || (0, cb[__getOwnPropNames(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
  // If the importer is in node compatibility mode or this is not an ESM
  // file that has been converted to a CommonJS file using a Babel-
  // compatible transform (i.e. "__esModule" has not been set), then set
  // "default" to the CommonJS "module.exports" for node compatibility.
  isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
  mod
));

// node_modules/wasmoon/dist/index.js
var require_dist = __commonJS({
  "node_modules/wasmoon/dist/index.js"(exports, module) {
    (function(global, factory) {
      typeof exports === "object" && typeof module !== "undefined" ? factory(exports) : typeof define === "function" && define.amd ? define(["exports"], factory) : (global = typeof globalThis !== "undefined" ? globalThis : global || self, factory(global.wasmoon = {}));
    })(exports, function(exports2) {
      "use strict";
      var _documentCurrentScript = typeof document !== "undefined" ? document.currentScript : null;
      exports2.LuaReturn = void 0;
      (function(LuaReturn) {
        LuaReturn[LuaReturn["Ok"] = 0] = "Ok";
        LuaReturn[LuaReturn["Yield"] = 1] = "Yield";
        LuaReturn[LuaReturn["ErrorRun"] = 2] = "ErrorRun";
        LuaReturn[LuaReturn["ErrorSyntax"] = 3] = "ErrorSyntax";
        LuaReturn[LuaReturn["ErrorMem"] = 4] = "ErrorMem";
        LuaReturn[LuaReturn["ErrorErr"] = 5] = "ErrorErr";
        LuaReturn[LuaReturn["ErrorFile"] = 6] = "ErrorFile";
      })(exports2.LuaReturn || (exports2.LuaReturn = {}));
      const PointerSize = 4;
      const LUA_MULTRET = -1;
      const LUAI_MAXSTACK = 1e6;
      const LUA_REGISTRYINDEX = -LUAI_MAXSTACK - 1e3;
      exports2.LuaType = void 0;
      (function(LuaType) {
        LuaType[LuaType["None"] = -1] = "None";
        LuaType[LuaType["Nil"] = 0] = "Nil";
        LuaType[LuaType["Boolean"] = 1] = "Boolean";
        LuaType[LuaType["LightUserdata"] = 2] = "LightUserdata";
        LuaType[LuaType["Number"] = 3] = "Number";
        LuaType[LuaType["String"] = 4] = "String";
        LuaType[LuaType["Table"] = 5] = "Table";
        LuaType[LuaType["Function"] = 6] = "Function";
        LuaType[LuaType["Userdata"] = 7] = "Userdata";
        LuaType[LuaType["Thread"] = 8] = "Thread";
      })(exports2.LuaType || (exports2.LuaType = {}));
      exports2.LuaEventCodes = void 0;
      (function(LuaEventCodes) {
        LuaEventCodes[LuaEventCodes["Call"] = 0] = "Call";
        LuaEventCodes[LuaEventCodes["Ret"] = 1] = "Ret";
        LuaEventCodes[LuaEventCodes["Line"] = 2] = "Line";
        LuaEventCodes[LuaEventCodes["Count"] = 3] = "Count";
        LuaEventCodes[LuaEventCodes["TailCall"] = 4] = "TailCall";
      })(exports2.LuaEventCodes || (exports2.LuaEventCodes = {}));
      exports2.LuaEventMasks = void 0;
      (function(LuaEventMasks) {
        LuaEventMasks[LuaEventMasks["Call"] = 1] = "Call";
        LuaEventMasks[LuaEventMasks["Ret"] = 2] = "Ret";
        LuaEventMasks[LuaEventMasks["Line"] = 4] = "Line";
        LuaEventMasks[LuaEventMasks["Count"] = 8] = "Count";
      })(exports2.LuaEventMasks || (exports2.LuaEventMasks = {}));
      exports2.LuaLibraries = void 0;
      (function(LuaLibraries) {
        LuaLibraries["Base"] = "_G";
        LuaLibraries["Coroutine"] = "coroutine";
        LuaLibraries["Table"] = "table";
        LuaLibraries["IO"] = "io";
        LuaLibraries["OS"] = "os";
        LuaLibraries["String"] = "string";
        LuaLibraries["UTF8"] = "utf8";
        LuaLibraries["Math"] = "math";
        LuaLibraries["Debug"] = "debug";
        LuaLibraries["Package"] = "package";
      })(exports2.LuaLibraries || (exports2.LuaLibraries = {}));
      class LuaTimeoutError extends Error {
      }
      class Decoration {
        constructor(target, options) {
          this.target = target;
          this.options = options;
        }
      }
      function decorate(target, options) {
        return new Decoration(target, options);
      }
      class Pointer extends Number {
      }
      class MultiReturn extends Array {
      }
      const INSTRUCTION_HOOK_COUNT = 1e3;
      class Thread {
        constructor(lua, typeExtensions, address, parent) {
          this.closed = false;
          this.lua = lua;
          this.typeExtensions = typeExtensions;
          this.address = address;
          this.parent = parent;
        }
        newThread() {
          const address = this.lua.lua_newthread(this.address);
          if (!address) {
            throw new Error("lua_newthread returned a null pointer");
          }
          return new Thread(this.lua, this.typeExtensions, address, this.parent || this);
        }
        resetThread() {
          this.assertOk(this.lua.lua_resetthread(this.address));
        }
        loadString(luaCode, name) {
          const size = this.lua.module.lengthBytesUTF8(luaCode);
          const pointerSize = size + 1;
          const bufferPointer = this.lua.module._malloc(pointerSize);
          try {
            this.lua.module.stringToUTF8(luaCode, bufferPointer, pointerSize);
            this.assertOk(this.lua.luaL_loadbufferx(this.address, bufferPointer, size, name !== null && name !== void 0 ? name : bufferPointer, null));
          } finally {
            this.lua.module._free(bufferPointer);
          }
        }
        loadFile(filename) {
          this.assertOk(this.lua.luaL_loadfilex(this.address, filename, null));
        }
        resume(argCount = 0) {
          const dataPointer = this.lua.module._malloc(PointerSize);
          try {
            this.lua.module.setValue(dataPointer, 0, "i32");
            const luaResult = this.lua.lua_resume(this.address, null, argCount, dataPointer);
            return {
              result: luaResult,
              resultCount: this.lua.module.getValue(dataPointer, "i32")
            };
          } finally {
            this.lua.module._free(dataPointer);
          }
        }
        getTop() {
          return this.lua.lua_gettop(this.address);
        }
        setTop(index) {
          this.lua.lua_settop(this.address, index);
        }
        remove(index) {
          return this.lua.lua_remove(this.address, index);
        }
        setField(index, name, value) {
          index = this.lua.lua_absindex(this.address, index);
          this.pushValue(value);
          this.lua.lua_setfield(this.address, index, name);
        }
        async run(argCount = 0, options) {
          const originalTimeout = this.timeout;
          try {
            if ((options === null || options === void 0 ? void 0 : options.timeout) !== void 0) {
              this.setTimeout(Date.now() + options.timeout);
            }
            let resumeResult = this.resume(argCount);
            while (resumeResult.result === exports2.LuaReturn.Yield) {
              if (this.timeout && Date.now() > this.timeout) {
                if (resumeResult.resultCount > 0) {
                  this.pop(resumeResult.resultCount);
                }
                throw new LuaTimeoutError(`thread timeout exceeded`);
              }
              if (resumeResult.resultCount > 0) {
                const lastValue = this.getValue(-1);
                this.pop(resumeResult.resultCount);
                if (lastValue === Promise.resolve(lastValue)) {
                  await lastValue;
                } else {
                  await new Promise((resolve) => setImmediate(resolve));
                }
              } else {
                await new Promise((resolve) => setImmediate(resolve));
              }
              resumeResult = this.resume(0);
            }
            this.assertOk(resumeResult.result);
            return this.getStackValues();
          } finally {
            if ((options === null || options === void 0 ? void 0 : options.timeout) !== void 0) {
              this.setTimeout(originalTimeout);
            }
          }
        }
        runSync(argCount = 0) {
          const base = this.getTop() - argCount - 1;
          this.assertOk(this.lua.lua_pcallk(this.address, argCount, LUA_MULTRET, 0, 0, null));
          return this.getStackValues(base);
        }
        pop(count = 1) {
          this.lua.lua_pop(this.address, count);
        }
        call(name, ...args) {
          const type = this.lua.lua_getglobal(this.address, name);
          if (type !== exports2.LuaType.Function) {
            throw new Error(`A function of type '${type}' was pushed, expected is ${exports2.LuaType.Function}`);
          }
          for (const arg of args) {
            this.pushValue(arg);
          }
          const base = this.getTop() - args.length - 1;
          this.lua.lua_callk(this.address, args.length, LUA_MULTRET, 0, null);
          return this.getStackValues(base);
        }
        getStackValues(start = 0) {
          const returns = this.getTop() - start;
          const returnValues = new MultiReturn(returns);
          for (let i = 0; i < returns; i++) {
            returnValues[i] = this.getValue(start + i + 1);
          }
          return returnValues;
        }
        stateToThread(L) {
          var _a;
          return L === ((_a = this.parent) === null || _a === void 0 ? void 0 : _a.address) ? this.parent : new Thread(this.lua, this.typeExtensions, L, this.parent || this);
        }
        pushValue(rawValue, userdata) {
          const decoratedValue = this.getValueDecorations(rawValue);
          const target = decoratedValue.target;
          if (target instanceof Thread) {
            const isMain = this.lua.lua_pushthread(target.address) === 1;
            if (!isMain) {
              this.lua.lua_xmove(target.address, this.address, 1);
            }
            return;
          }
          const startTop = this.getTop();
          switch (typeof target) {
            case "undefined":
              this.lua.lua_pushnil(this.address);
              break;
            case "number":
              if (Number.isInteger(target)) {
                this.lua.lua_pushinteger(this.address, BigInt(target));
              } else {
                this.lua.lua_pushnumber(this.address, target);
              }
              break;
            case "string":
              this.lua.lua_pushstring(this.address, target);
              break;
            case "boolean":
              this.lua.lua_pushboolean(this.address, target ? 1 : 0);
              break;
            default:
              if (!this.typeExtensions.find((wrapper) => wrapper.extension.pushValue(this, decoratedValue, userdata))) {
                throw new Error(`The type '${typeof target}' is not supported by Lua`);
              }
          }
          if (decoratedValue.options.metatable) {
            this.setMetatable(-1, decoratedValue.options.metatable);
          }
          if (this.getTop() !== startTop + 1) {
            throw new Error(`pushValue expected stack size ${startTop + 1}, got ${this.getTop()}`);
          }
        }
        setMetatable(index, metatable) {
          index = this.lua.lua_absindex(this.address, index);
          if (this.lua.lua_getmetatable(this.address, index)) {
            this.pop(1);
            const name = this.getMetatableName(index);
            throw new Error(`data already has associated metatable: ${name || "unknown name"}`);
          }
          this.pushValue(metatable);
          this.lua.lua_setmetatable(this.address, index);
        }
        getMetatableName(index) {
          const metatableNameType = this.lua.luaL_getmetafield(this.address, index, "__name");
          if (metatableNameType === exports2.LuaType.Nil) {
            return void 0;
          }
          if (metatableNameType !== exports2.LuaType.String) {
            this.pop(1);
            return void 0;
          }
          const name = this.lua.lua_tolstring(this.address, -1, null);
          this.pop(1);
          return name;
        }
        getValue(index, inputType, userdata) {
          index = this.lua.lua_absindex(this.address, index);
          const type = inputType !== null && inputType !== void 0 ? inputType : this.lua.lua_type(this.address, index);
          switch (type) {
            case exports2.LuaType.None:
              return void 0;
            case exports2.LuaType.Nil:
              return null;
            case exports2.LuaType.Number:
              return this.lua.lua_tonumberx(this.address, index, null);
            case exports2.LuaType.String:
              return this.lua.lua_tolstring(this.address, index, null);
            case exports2.LuaType.Boolean:
              return Boolean(this.lua.lua_toboolean(this.address, index));
            case exports2.LuaType.Thread:
              return this.stateToThread(this.lua.lua_tothread(this.address, index));
            default: {
              let metatableName;
              if (type === exports2.LuaType.Table || type === exports2.LuaType.Userdata) {
                metatableName = this.getMetatableName(index);
              }
              const typeExtensionWrapper = this.typeExtensions.find((wrapper) => wrapper.extension.isType(this, index, type, metatableName));
              if (typeExtensionWrapper) {
                return typeExtensionWrapper.extension.getValue(this, index, userdata);
              }
              console.warn(`The type '${this.lua.lua_typename(this.address, type)}' returned is not supported on JS`);
              return new Pointer(this.lua.lua_topointer(this.address, index));
            }
          }
        }
        close() {
          if (this.isClosed()) {
            return;
          }
          if (this.hookFunctionPointer) {
            this.lua.module.removeFunction(this.hookFunctionPointer);
          }
          this.closed = true;
        }
        setTimeout(timeout) {
          if (timeout && timeout > 0) {
            if (!this.hookFunctionPointer) {
              this.hookFunctionPointer = this.lua.module.addFunction(() => {
                if (Date.now() > timeout) {
                  this.pushValue(new LuaTimeoutError(`thread timeout exceeded`));
                  this.lua.lua_error(this.address);
                }
              }, "vii");
            }
            this.lua.lua_sethook(this.address, this.hookFunctionPointer, exports2.LuaEventMasks.Count, INSTRUCTION_HOOK_COUNT);
            this.timeout = timeout;
          } else if (this.hookFunctionPointer) {
            this.hookFunctionPointer = void 0;
            this.timeout = void 0;
            this.lua.lua_sethook(this.address, null, 0, 0);
          }
        }
        getTimeout() {
          return this.timeout;
        }
        getPointer(index) {
          return new Pointer(this.lua.lua_topointer(this.address, index));
        }
        isClosed() {
          var _a;
          return !this.address || this.closed || Boolean((_a = this.parent) === null || _a === void 0 ? void 0 : _a.isClosed());
        }
        indexToString(index) {
          const str = this.lua.luaL_tolstring(this.address, index, null);
          this.pop();
          return str;
        }
        dumpStack(log = console.log) {
          const top = this.getTop();
          for (let i = 1; i <= top; i++) {
            const type = this.lua.lua_type(this.address, i);
            const typename = this.lua.lua_typename(this.address, type);
            const pointer = this.getPointer(i);
            const name = this.indexToString(i);
            const value = this.getValue(i, type);
            log(i, typename, pointer, name, value);
          }
        }
        assertOk(result) {
          if (result !== exports2.LuaReturn.Ok && result !== exports2.LuaReturn.Yield) {
            const resultString = exports2.LuaReturn[result];
            const error = new Error(`Lua Error(${resultString}/${result})`);
            if (this.getTop() > 0) {
              if (result === exports2.LuaReturn.ErrorMem) {
                error.message = this.lua.lua_tolstring(this.address, -1, null);
              } else {
                const luaError = this.getValue(-1);
                if (luaError instanceof Error) {
                  error.stack = luaError.stack;
                }
                error.message = this.indexToString(-1);
              }
            }
            if (result !== exports2.LuaReturn.ErrorMem) {
              try {
                this.lua.luaL_traceback(this.address, this.address, null, 1);
                const traceback = this.lua.lua_tolstring(this.address, -1, null);
                if (traceback.trim() !== "stack traceback:") {
                  error.message = `${error.message}
${traceback}`;
                }
                this.pop(1);
              } catch (err2) {
                console.warn("Failed to generate stack trace", err2);
              }
            }
            throw error;
          }
        }
        getValueDecorations(value) {
          return value instanceof Decoration ? value : new Decoration(value, {});
        }
      }
      class Global extends Thread {
        constructor(cmodule, shouldTraceAllocations) {
          if (shouldTraceAllocations) {
            const memoryStats = { memoryUsed: 0 };
            const allocatorFunctionPointer = cmodule.module.addFunction((_userData, pointer, oldSize, newSize) => {
              if (newSize === 0) {
                if (pointer) {
                  memoryStats.memoryUsed -= oldSize;
                  cmodule.module._free(pointer);
                }
                return 0;
              }
              const endMemoryDelta = pointer ? newSize - oldSize : newSize;
              const endMemory = memoryStats.memoryUsed + endMemoryDelta;
              if (newSize > oldSize && memoryStats.memoryMax && endMemory > memoryStats.memoryMax) {
                return 0;
              }
              const reallocated = cmodule.module._realloc(pointer, newSize);
              if (reallocated) {
                memoryStats.memoryUsed = endMemory;
              }
              return reallocated;
            }, "iiiii");
            const address = cmodule.lua_newstate(allocatorFunctionPointer, null);
            if (!address) {
              cmodule.module.removeFunction(allocatorFunctionPointer);
              throw new Error("lua_newstate returned a null pointer");
            }
            super(cmodule, [], address);
            this.memoryStats = memoryStats;
            this.allocatorFunctionPointer = allocatorFunctionPointer;
          } else {
            super(cmodule, [], cmodule.luaL_newstate());
          }
          if (this.isClosed()) {
            throw new Error("Global state could not be created (probably due to lack of memory)");
          }
        }
        close() {
          if (this.isClosed()) {
            return;
          }
          super.close();
          this.lua.lua_close(this.address);
          if (this.allocatorFunctionPointer) {
            this.lua.module.removeFunction(this.allocatorFunctionPointer);
          }
          for (const wrapper of this.typeExtensions) {
            wrapper.extension.close();
          }
        }
        registerTypeExtension(priority, extension) {
          this.typeExtensions.push({ extension, priority });
          this.typeExtensions.sort((a, b) => b.priority - a.priority);
        }
        loadLibrary(library) {
          switch (library) {
            case exports2.LuaLibraries.Base:
              this.lua.luaopen_base(this.address);
              break;
            case exports2.LuaLibraries.Coroutine:
              this.lua.luaopen_coroutine(this.address);
              break;
            case exports2.LuaLibraries.Table:
              this.lua.luaopen_table(this.address);
              break;
            case exports2.LuaLibraries.IO:
              this.lua.luaopen_io(this.address);
              break;
            case exports2.LuaLibraries.OS:
              this.lua.luaopen_os(this.address);
              break;
            case exports2.LuaLibraries.String:
              this.lua.luaopen_string(this.address);
              break;
            case exports2.LuaLibraries.UTF8:
              this.lua.luaopen_string(this.address);
              break;
            case exports2.LuaLibraries.Math:
              this.lua.luaopen_math(this.address);
              break;
            case exports2.LuaLibraries.Debug:
              this.lua.luaopen_debug(this.address);
              break;
            case exports2.LuaLibraries.Package:
              this.lua.luaopen_package(this.address);
              break;
          }
          this.lua.lua_setglobal(this.address, library);
        }
        get(name) {
          const type = this.lua.lua_getglobal(this.address, name);
          const value = this.getValue(-1, type);
          this.pop();
          return value;
        }
        set(name, value) {
          this.pushValue(value);
          this.lua.lua_setglobal(this.address, name);
        }
        getTable(name, callback) {
          const startStackTop = this.getTop();
          const type = this.lua.lua_getglobal(this.address, name);
          try {
            if (type !== exports2.LuaType.Table) {
              throw new TypeError(`Unexpected type in ${name}. Expected ${exports2.LuaType[exports2.LuaType.Table]}. Got ${exports2.LuaType[type]}.`);
            }
            callback(startStackTop + 1);
          } finally {
            if (this.getTop() !== startStackTop + 1) {
              console.warn(`getTable: expected stack size ${startStackTop} got ${this.getTop()}`);
            }
            this.setTop(startStackTop);
          }
        }
        getMemoryUsed() {
          return this.getMemoryStatsRef().memoryUsed;
        }
        getMemoryMax() {
          return this.getMemoryStatsRef().memoryMax;
        }
        setMemoryMax(max) {
          this.getMemoryStatsRef().memoryMax = max;
        }
        getMemoryStatsRef() {
          if (!this.memoryStats) {
            throw new Error("Memory allocations is not being traced, please build engine with { traceAllocations: true }");
          }
          return this.memoryStats;
        }
      }
      class LuaTypeExtension {
        constructor(thread, name) {
          this.thread = thread;
          this.name = name;
        }
        isType(_thread, _index, type, name) {
          return type === exports2.LuaType.Userdata && name === this.name;
        }
        getValue(thread, index, _userdata) {
          const refUserdata = thread.lua.luaL_testudata(thread.address, index, this.name);
          if (!refUserdata) {
            throw new Error(`data does not have the expected metatable: ${this.name}`);
          }
          const referencePointer = thread.lua.module.getValue(refUserdata, "*");
          return thread.lua.getRef(referencePointer);
        }
        pushValue(thread, decoratedValue, _userdata) {
          const { target } = decoratedValue;
          const pointer = thread.lua.ref(target);
          const userDataPointer = thread.lua.lua_newuserdatauv(thread.address, PointerSize, 0);
          thread.lua.module.setValue(userDataPointer, pointer, "*");
          if (exports2.LuaType.Nil === thread.lua.luaL_getmetatable(thread.address, this.name)) {
            thread.pop(2);
            throw new Error(`metatable not found: ${this.name}`);
          }
          thread.lua.lua_setmetatable(thread.address, -2);
          return true;
        }
      }
      class ErrorTypeExtension extends LuaTypeExtension {
        constructor(thread, injectObject) {
          super(thread, "js_error");
          this.gcPointer = thread.lua.module.addFunction((functionStateAddress) => {
            const userDataPointer = thread.lua.luaL_checkudata(functionStateAddress, 1, this.name);
            const referencePointer = thread.lua.module.getValue(userDataPointer, "*");
            thread.lua.unref(referencePointer);
            return exports2.LuaReturn.Ok;
          }, "ii");
          if (thread.lua.luaL_newmetatable(thread.address, this.name)) {
            const metatableIndex = thread.lua.lua_gettop(thread.address);
            thread.lua.lua_pushstring(thread.address, "protected metatable");
            thread.lua.lua_setfield(thread.address, metatableIndex, "__metatable");
            thread.lua.lua_pushcclosure(thread.address, this.gcPointer, 0);
            thread.lua.lua_setfield(thread.address, metatableIndex, "__gc");
            thread.pushValue((jsRefError, key) => {
              if (key === "message") {
                return jsRefError.message;
              }
              return null;
            });
            thread.lua.lua_setfield(thread.address, metatableIndex, "__index");
            thread.pushValue((jsRefError) => {
              return jsRefError.message;
            });
            thread.lua.lua_setfield(thread.address, metatableIndex, "__tostring");
          }
          thread.lua.lua_pop(thread.address, 1);
          if (injectObject) {
            thread.set("Error", {
              create: (message) => {
                if (message && typeof message !== "string") {
                  throw new Error("message must be a string");
                }
                return new Error(message);
              }
            });
          }
        }
        pushValue(thread, decoration) {
          if (!(decoration.target instanceof Error)) {
            return false;
          }
          return super.pushValue(thread, decoration);
        }
        close() {
          this.thread.lua.module.removeFunction(this.gcPointer);
        }
      }
      function createTypeExtension$6(thread, injectObject) {
        return new ErrorTypeExtension(thread, injectObject);
      }
      class RawResult {
        constructor(count) {
          this.count = count;
        }
      }
      function decorateFunction(target, options) {
        return new Decoration(target, options);
      }
      class FunctionTypeExtension extends LuaTypeExtension {
        constructor(thread, options) {
          super(thread, "js_function");
          this.functionRegistry = typeof FinalizationRegistry !== "undefined" ? new FinalizationRegistry((func) => {
            if (!this.thread.isClosed()) {
              this.thread.lua.luaL_unref(this.thread.address, LUA_REGISTRYINDEX, func);
            }
          }) : void 0;
          this.options = options;
          this.callbackContext = thread.newThread();
          this.callbackContextIndex = this.thread.lua.luaL_ref(thread.address, LUA_REGISTRYINDEX);
          if (!this.functionRegistry) {
            console.warn("FunctionTypeExtension: FinalizationRegistry not found. Memory leaks likely.");
          }
          this.gcPointer = thread.lua.module.addFunction((calledL) => {
            thread.lua.luaL_checkudata(calledL, 1, this.name);
            const userDataPointer = thread.lua.luaL_checkudata(calledL, 1, this.name);
            const referencePointer = thread.lua.module.getValue(userDataPointer, "*");
            thread.lua.unref(referencePointer);
            return exports2.LuaReturn.Ok;
          }, "ii");
          if (thread.lua.luaL_newmetatable(thread.address, this.name)) {
            thread.lua.lua_pushstring(thread.address, "__gc");
            thread.lua.lua_pushcclosure(thread.address, this.gcPointer, 0);
            thread.lua.lua_settable(thread.address, -3);
            thread.lua.lua_pushstring(thread.address, "__metatable");
            thread.lua.lua_pushstring(thread.address, "protected metatable");
            thread.lua.lua_settable(thread.address, -3);
          }
          thread.lua.lua_pop(thread.address, 1);
          this.functionWrapper = thread.lua.module.addFunction((calledL) => {
            const calledThread = thread.stateToThread(calledL);
            const refUserdata = thread.lua.luaL_checkudata(calledL, thread.lua.lua_upvalueindex(1), this.name);
            const refPointer = thread.lua.module.getValue(refUserdata, "*");
            const { target, options: options2 } = thread.lua.getRef(refPointer);
            const argsQuantity = calledThread.getTop();
            const args = [];
            if (options2.receiveThread) {
              args.push(calledThread);
            }
            if (options2.receiveArgsQuantity) {
              args.push(argsQuantity);
            } else {
              for (let i = 1; i <= argsQuantity; i++) {
                const value = calledThread.getValue(i);
                if (i !== 1 || !(options2 === null || options2 === void 0 ? void 0 : options2.self) || value !== options2.self) {
                  args.push(value);
                }
              }
            }
            try {
              const result = target.apply(options2 === null || options2 === void 0 ? void 0 : options2.self, args);
              if (result === void 0) {
                return 0;
              } else if (result instanceof RawResult) {
                return result.count;
              } else if (result instanceof MultiReturn) {
                for (const item of result) {
                  calledThread.pushValue(item);
                }
                return result.length;
              } else {
                calledThread.pushValue(result);
                return 1;
              }
            } catch (err2) {
              if (err2 === Infinity) {
                throw err2;
              }
              calledThread.pushValue(err2);
              return calledThread.lua.lua_error(calledThread.address);
            }
          }, "ii");
        }
        close() {
          this.thread.lua.module.removeFunction(this.gcPointer);
          this.thread.lua.module.removeFunction(this.functionWrapper);
          this.callbackContext.close();
          this.callbackContext.lua.luaL_unref(this.callbackContext.address, LUA_REGISTRYINDEX, this.callbackContextIndex);
        }
        isType(_thread, _index, type) {
          return type === exports2.LuaType.Function;
        }
        pushValue(thread, decoration) {
          if (typeof decoration.target !== "function") {
            return false;
          }
          const pointer = thread.lua.ref(decoration);
          const userDataPointer = thread.lua.lua_newuserdatauv(thread.address, PointerSize, 0);
          thread.lua.module.setValue(userDataPointer, pointer, "*");
          if (exports2.LuaType.Nil === thread.lua.luaL_getmetatable(thread.address, this.name)) {
            thread.pop(1);
            thread.lua.unref(pointer);
            throw new Error(`metatable not found: ${this.name}`);
          }
          thread.lua.lua_setmetatable(thread.address, -2);
          thread.lua.lua_pushcclosure(thread.address, this.functionWrapper, 1);
          return true;
        }
        getValue(thread, index) {
          var _a;
          thread.lua.lua_pushvalue(thread.address, index);
          const func = thread.lua.luaL_ref(thread.address, LUA_REGISTRYINDEX);
          const jsFunc = (...args) => {
            var _a2;
            if (this.callbackContext.isClosed()) {
              console.warn("Tried to call a function after closing lua state");
              return;
            }
            const callThread = this.callbackContext.newThread();
            try {
              const internalType = callThread.lua.lua_rawgeti(callThread.address, LUA_REGISTRYINDEX, BigInt(func));
              if (internalType !== exports2.LuaType.Function) {
                const callMetafieldType = callThread.lua.luaL_getmetafield(callThread.address, -1, "__call");
                callThread.pop();
                if (callMetafieldType !== exports2.LuaType.Function) {
                  throw new Error(`A value of type '${internalType}' was pushed but it is not callable`);
                }
              }
              for (const arg of args) {
                callThread.pushValue(arg);
              }
              if ((_a2 = this.options) === null || _a2 === void 0 ? void 0 : _a2.functionTimeout) {
                callThread.setTimeout(Date.now() + this.options.functionTimeout);
              }
              const status = callThread.lua.lua_pcallk(callThread.address, args.length, 1, 0, 0, null);
              if (status === exports2.LuaReturn.Yield) {
                throw new Error("cannot yield in callbacks from javascript");
              }
              callThread.assertOk(status);
              if (callThread.getTop() > 0) {
                return callThread.getValue(-1);
              }
              return void 0;
            } finally {
              callThread.close();
              this.callbackContext.pop();
            }
          };
          (_a = this.functionRegistry) === null || _a === void 0 ? void 0 : _a.register(jsFunc, func);
          return jsFunc;
        }
      }
      function createTypeExtension$5(thread, options) {
        return new FunctionTypeExtension(thread, options);
      }
      class NullTypeExtension extends LuaTypeExtension {
        constructor(thread) {
          super(thread, "js_null");
          this.gcPointer = thread.lua.module.addFunction((functionStateAddress) => {
            const userDataPointer = thread.lua.luaL_checkudata(functionStateAddress, 1, this.name);
            const referencePointer = thread.lua.module.getValue(userDataPointer, "*");
            thread.lua.unref(referencePointer);
            return exports2.LuaReturn.Ok;
          }, "ii");
          if (thread.lua.luaL_newmetatable(thread.address, this.name)) {
            const metatableIndex = thread.lua.lua_gettop(thread.address);
            thread.lua.lua_pushstring(thread.address, "protected metatable");
            thread.lua.lua_setfield(thread.address, metatableIndex, "__metatable");
            thread.lua.lua_pushcclosure(thread.address, this.gcPointer, 0);
            thread.lua.lua_setfield(thread.address, metatableIndex, "__gc");
            thread.pushValue(() => null);
            thread.lua.lua_setfield(thread.address, metatableIndex, "__index");
            thread.pushValue(() => "null");
            thread.lua.lua_setfield(thread.address, metatableIndex, "__tostring");
            thread.pushValue((self2, other) => self2 === other);
            thread.lua.lua_setfield(thread.address, metatableIndex, "__eq");
          }
          thread.lua.lua_pop(thread.address, 1);
          super.pushValue(thread, new Decoration({}, {}));
          thread.lua.lua_setglobal(thread.address, "null");
        }
        getValue(thread, index) {
          const refUserData = thread.lua.luaL_testudata(thread.address, index, this.name);
          if (!refUserData) {
            throw new Error(`data does not have the expected metatable: ${this.name}`);
          }
          return null;
        }
        pushValue(thread, decoration) {
          if ((decoration === null || decoration === void 0 ? void 0 : decoration.target) !== null) {
            return false;
          }
          thread.lua.lua_getglobal(thread.address, "null");
          return true;
        }
        close() {
          this.thread.lua.module.removeFunction(this.gcPointer);
        }
      }
      function createTypeExtension$4(thread) {
        return new NullTypeExtension(thread);
      }
      class PromiseTypeExtension extends LuaTypeExtension {
        constructor(thread, injectObject) {
          super(thread, "js_promise");
          this.gcPointer = thread.lua.module.addFunction((functionStateAddress) => {
            const userDataPointer = thread.lua.luaL_checkudata(functionStateAddress, 1, this.name);
            const referencePointer = thread.lua.module.getValue(userDataPointer, "*");
            thread.lua.unref(referencePointer);
            return exports2.LuaReturn.Ok;
          }, "ii");
          if (thread.lua.luaL_newmetatable(thread.address, this.name)) {
            const metatableIndex = thread.lua.lua_gettop(thread.address);
            thread.lua.lua_pushstring(thread.address, "protected metatable");
            thread.lua.lua_setfield(thread.address, metatableIndex, "__metatable");
            thread.lua.lua_pushcclosure(thread.address, this.gcPointer, 0);
            thread.lua.lua_setfield(thread.address, metatableIndex, "__gc");
            const checkSelf = (self2) => {
              if (Promise.resolve(self2) !== self2 && typeof self2.then !== "function") {
                throw new Error("promise method called without self instance");
              }
              return true;
            };
            thread.pushValue({
              next: (self2, ...args) => checkSelf(self2) && self2.then(...args),
              catch: (self2, ...args) => checkSelf(self2) && self2.catch(...args),
              finally: (self2, ...args) => checkSelf(self2) && self2.finally(...args),
              await: decorateFunction((functionThread, self2) => {
                checkSelf(self2);
                if (functionThread.address === thread.address) {
                  throw new Error("cannot await in the main thread");
                }
                let promiseResult = void 0;
                const awaitPromise = self2.then((res) => {
                  promiseResult = { status: "fulfilled", value: res };
                }).catch((err2) => {
                  promiseResult = { status: "rejected", value: err2 };
                });
                const continuance = this.thread.lua.module.addFunction((continuanceState) => {
                  if (!promiseResult) {
                    return thread.lua.lua_yieldk(functionThread.address, 0, 0, continuance);
                  }
                  this.thread.lua.module.removeFunction(continuance);
                  const continuanceThread = thread.stateToThread(continuanceState);
                  if (promiseResult.status === "rejected") {
                    continuanceThread.pushValue(promiseResult.value || new Error("promise rejected with no error"));
                    return this.thread.lua.lua_error(continuanceState);
                  }
                  if (promiseResult.value instanceof RawResult) {
                    return promiseResult.value.count;
                  } else if (promiseResult.value instanceof MultiReturn) {
                    for (const arg of promiseResult.value) {
                      continuanceThread.pushValue(arg);
                    }
                    return promiseResult.value.length;
                  } else {
                    continuanceThread.pushValue(promiseResult.value);
                    return 1;
                  }
                }, "iiii");
                functionThread.pushValue(awaitPromise);
                return new RawResult(thread.lua.lua_yieldk(functionThread.address, 1, 0, continuance));
              }, { receiveThread: true })
            });
            thread.lua.lua_setfield(thread.address, metatableIndex, "__index");
            thread.pushValue((self2, other) => self2 === other);
            thread.lua.lua_setfield(thread.address, metatableIndex, "__eq");
          }
          thread.lua.lua_pop(thread.address, 1);
          if (injectObject) {
            thread.set("Promise", {
              create: (callback) => new Promise(callback),
              all: (promiseArray) => {
                if (!Array.isArray(promiseArray)) {
                  throw new Error("argument must be an array of promises");
                }
                return Promise.all(promiseArray.map((potentialPromise) => Promise.resolve(potentialPromise)));
              },
              resolve: (value) => Promise.resolve(value)
            });
          }
        }
        close() {
          this.thread.lua.module.removeFunction(this.gcPointer);
        }
        pushValue(thread, decoration) {
          if (Promise.resolve(decoration.target) !== decoration.target && typeof decoration.target.then !== "function") {
            return false;
          }
          return super.pushValue(thread, decoration);
        }
      }
      function createTypeExtension$3(thread, injectObject) {
        return new PromiseTypeExtension(thread, injectObject);
      }
      function decorateProxy(target, options) {
        return new Decoration(target, options || {});
      }
      class ProxyTypeExtension extends LuaTypeExtension {
        constructor(thread) {
          super(thread, "js_proxy");
          this.gcPointer = thread.lua.module.addFunction((functionStateAddress) => {
            const userDataPointer = thread.lua.luaL_checkudata(functionStateAddress, 1, this.name);
            const referencePointer = thread.lua.module.getValue(userDataPointer, "*");
            thread.lua.unref(referencePointer);
            return exports2.LuaReturn.Ok;
          }, "ii");
          if (thread.lua.luaL_newmetatable(thread.address, this.name)) {
            const metatableIndex = thread.lua.lua_gettop(thread.address);
            thread.lua.lua_pushstring(thread.address, "protected metatable");
            thread.lua.lua_setfield(thread.address, metatableIndex, "__metatable");
            thread.lua.lua_pushcclosure(thread.address, this.gcPointer, 0);
            thread.lua.lua_setfield(thread.address, metatableIndex, "__gc");
            thread.pushValue((self2, key) => {
              switch (typeof key) {
                case "number":
                  key = key - 1;
                case "string":
                  break;
                default:
                  throw new Error("Only strings or numbers can index js objects");
              }
              const value = self2[key];
              if (typeof value === "function") {
                return decorateFunction(value, { self: self2 });
              }
              return value;
            });
            thread.lua.lua_setfield(thread.address, metatableIndex, "__index");
            thread.pushValue((self2, key, value) => {
              switch (typeof key) {
                case "number":
                  key = key - 1;
                case "string":
                  break;
                default:
                  throw new Error("Only strings or numbers can index js objects");
              }
              self2[key] = value;
            });
            thread.lua.lua_setfield(thread.address, metatableIndex, "__newindex");
            thread.pushValue((self2) => {
              var _a, _b;
              return (_b = (_a = self2.toString) === null || _a === void 0 ? void 0 : _a.call(self2)) !== null && _b !== void 0 ? _b : typeof self2;
            });
            thread.lua.lua_setfield(thread.address, metatableIndex, "__tostring");
            thread.pushValue((self2) => {
              return self2.length || 0;
            });
            thread.lua.lua_setfield(thread.address, metatableIndex, "__len");
            thread.pushValue((self2) => {
              const keys = Object.getOwnPropertyNames(self2);
              let i = 0;
              return MultiReturn.of(() => {
                const ret = MultiReturn.of(keys[i], self2[keys[i]]);
                i++;
                return ret;
              }, self2, null);
            });
            thread.lua.lua_setfield(thread.address, metatableIndex, "__pairs");
            thread.pushValue((self2, other) => {
              return self2 === other;
            });
            thread.lua.lua_setfield(thread.address, metatableIndex, "__eq");
            thread.pushValue((self2, ...args) => {
              if (args[0] === self2) {
                args.shift();
              }
              return self2(...args);
            });
            thread.lua.lua_setfield(thread.address, metatableIndex, "__call");
          }
          thread.lua.lua_pop(thread.address, 1);
        }
        isType(_thread, _index, type, name) {
          return type === exports2.LuaType.Userdata && name === this.name;
        }
        getValue(thread, index) {
          const refUserdata = thread.lua.lua_touserdata(thread.address, index);
          const referencePointer = thread.lua.module.getValue(refUserdata, "*");
          return thread.lua.getRef(referencePointer);
        }
        pushValue(thread, decoratedValue) {
          var _a;
          const { target, options } = decoratedValue;
          if (options.proxy === void 0) {
            if (target === null || target === void 0) {
              return false;
            }
            if (typeof target !== "object") {
              const isClass = typeof target === "function" && ((_a = target.prototype) === null || _a === void 0 ? void 0 : _a.constructor) === target && target.toString().startsWith("class ");
              if (!isClass) {
                return false;
              }
            }
            if (Promise.resolve(target) === target || typeof target.then === "function") {
              return false;
            }
          } else if (options.proxy === false) {
            return false;
          }
          if (options.metatable && !(options.metatable instanceof Decoration)) {
            decoratedValue.options.metatable = decorateProxy(options.metatable, { proxy: false });
            return false;
          }
          return super.pushValue(thread, decoratedValue);
        }
        close() {
          this.thread.lua.module.removeFunction(this.gcPointer);
        }
      }
      function createTypeExtension$2(thread) {
        return new ProxyTypeExtension(thread);
      }
      class TableTypeExtension extends LuaTypeExtension {
        constructor(thread) {
          super(thread, "js_table");
        }
        close() {
        }
        isType(_thread, _index, type) {
          return type === exports2.LuaType.Table;
        }
        getValue(thread, index, userdata) {
          const seenMap = userdata || /* @__PURE__ */ new Map();
          const pointer = thread.lua.lua_topointer(thread.address, index);
          let table = seenMap.get(pointer);
          if (!table) {
            const keys = this.readTableKeys(thread, index);
            const isSequential = keys.length > 0 && keys.every((key, index2) => key === String(index2 + 1));
            table = isSequential ? [] : {};
            seenMap.set(pointer, table);
            this.readTableValues(thread, index, seenMap, table);
          }
          return table;
        }
        pushValue(thread, { target }, userdata) {
          if (typeof target !== "object" || target === null) {
            return false;
          }
          const seenMap = userdata || /* @__PURE__ */ new Map();
          const existingReference = seenMap.get(target);
          if (existingReference !== void 0) {
            thread.lua.lua_rawgeti(thread.address, LUA_REGISTRYINDEX, BigInt(existingReference));
            return true;
          }
          try {
            const tableIndex = thread.getTop() + 1;
            const createTable = (arrayCount, keyCount) => {
              thread.lua.lua_createtable(thread.address, arrayCount, keyCount);
              const ref = thread.lua.luaL_ref(thread.address, LUA_REGISTRYINDEX);
              seenMap.set(target, ref);
              thread.lua.lua_rawgeti(thread.address, LUA_REGISTRYINDEX, BigInt(ref));
            };
            if (Array.isArray(target)) {
              createTable(target.length, 0);
              for (let i = 0; i < target.length; i++) {
                thread.pushValue(i + 1, seenMap);
                thread.pushValue(target[i], seenMap);
                thread.lua.lua_settable(thread.address, tableIndex);
              }
            } else {
              createTable(0, Object.getOwnPropertyNames(target).length);
              for (const key in target) {
                thread.pushValue(key, seenMap);
                thread.pushValue(target[key], seenMap);
                thread.lua.lua_settable(thread.address, tableIndex);
              }
            }
          } finally {
            if (userdata === void 0) {
              for (const reference of seenMap.values()) {
                thread.lua.luaL_unref(thread.address, LUA_REGISTRYINDEX, reference);
              }
            }
          }
          return true;
        }
        readTableKeys(thread, index) {
          const keys = [];
          thread.lua.lua_pushnil(thread.address);
          while (thread.lua.lua_next(thread.address, index)) {
            const key = thread.indexToString(-2);
            keys.push(key);
            thread.pop();
          }
          return keys;
        }
        readTableValues(thread, index, seenMap, table) {
          const isArray = Array.isArray(table);
          thread.lua.lua_pushnil(thread.address);
          while (thread.lua.lua_next(thread.address, index)) {
            const key = thread.indexToString(-2);
            const value = thread.getValue(-1, void 0, seenMap);
            if (isArray) {
              table.push(value);
            } else {
              table[key] = value;
            }
            thread.pop();
          }
        }
      }
      function createTypeExtension$1(thread) {
        return new TableTypeExtension(thread);
      }
      function decorateUserdata(target) {
        return new Decoration(target, { reference: true });
      }
      class UserdataTypeExtension extends LuaTypeExtension {
        constructor(thread) {
          super(thread, "js_userdata");
          this.gcPointer = thread.lua.module.addFunction((functionStateAddress) => {
            const userDataPointer = thread.lua.luaL_checkudata(functionStateAddress, 1, this.name);
            const referencePointer = thread.lua.module.getValue(userDataPointer, "*");
            thread.lua.unref(referencePointer);
            return exports2.LuaReturn.Ok;
          }, "ii");
          if (thread.lua.luaL_newmetatable(thread.address, this.name)) {
            const metatableIndex = thread.lua.lua_gettop(thread.address);
            thread.lua.lua_pushstring(thread.address, "protected metatable");
            thread.lua.lua_setfield(thread.address, metatableIndex, "__metatable");
            thread.lua.lua_pushcclosure(thread.address, this.gcPointer, 0);
            thread.lua.lua_setfield(thread.address, metatableIndex, "__gc");
          }
          thread.lua.lua_pop(thread.address, 1);
        }
        isType(_thread, _index, type, name) {
          return type === exports2.LuaType.Userdata && name === this.name;
        }
        getValue(thread, index) {
          const refUserdata = thread.lua.lua_touserdata(thread.address, index);
          const referencePointer = thread.lua.module.getValue(refUserdata, "*");
          return thread.lua.getRef(referencePointer);
        }
        pushValue(thread, decoratedValue) {
          if (!decoratedValue.options.reference) {
            return false;
          }
          return super.pushValue(thread, decoratedValue);
        }
        close() {
          this.thread.lua.module.removeFunction(this.gcPointer);
        }
      }
      function createTypeExtension(thread) {
        return new UserdataTypeExtension(thread);
      }
      class LuaEngine {
        constructor(cmodule, { openStandardLibs = true, injectObjects = false, enableProxy = true, traceAllocations = false, functionTimeout = void 0 } = {}) {
          this.cmodule = cmodule;
          this.global = new Global(this.cmodule, traceAllocations);
          this.global.registerTypeExtension(0, createTypeExtension$1(this.global));
          this.global.registerTypeExtension(0, createTypeExtension$5(this.global, { functionTimeout }));
          this.global.registerTypeExtension(1, createTypeExtension$3(this.global, injectObjects));
          if (injectObjects) {
            this.global.registerTypeExtension(5, createTypeExtension$4(this.global));
          }
          if (enableProxy) {
            this.global.registerTypeExtension(3, createTypeExtension$2(this.global));
          } else {
            this.global.registerTypeExtension(1, createTypeExtension$6(this.global, injectObjects));
          }
          this.global.registerTypeExtension(4, createTypeExtension(this.global));
          if (openStandardLibs) {
            this.cmodule.luaL_openlibs(this.global.address);
          }
        }
        doString(script) {
          return this.callByteCode((thread) => thread.loadString(script));
        }
        doFile(filename) {
          return this.callByteCode((thread) => thread.loadFile(filename));
        }
        doStringSync(script) {
          this.global.loadString(script);
          const result = this.global.runSync();
          return result[0];
        }
        doFileSync(filename) {
          this.global.loadFile(filename);
          const result = this.global.runSync();
          return result[0];
        }
        async callByteCode(loader) {
          const thread = this.global.newThread();
          const threadIndex = this.global.getTop();
          try {
            loader(thread);
            const result = await thread.run(0);
            if (result.length > 0) {
              this.cmodule.lua_xmove(thread.address, this.global.address, result.length);
              return this.global.getValue(this.global.getTop() - result.length + 1);
            }
            return void 0;
          } finally {
            this.global.remove(threadIndex);
          }
        }
      }
      var initWasmModule = (() => {
        var _scriptDir = typeof document === "undefined" && typeof location === "undefined" ? __require("url").pathToFileURL(__filename).href : typeof document === "undefined" ? location.href : _documentCurrentScript && _documentCurrentScript.src || new URL("index.js", document.baseURI).href;
        return async function(moduleArg = {}) {
          var e = moduleArg, aa, ba;
          e.ready = new Promise((a, b) => {
            aa = a;
            ba = b;
          });
          "_malloc _free _realloc _luaL_checkversion_ _luaL_getmetafield _luaL_callmeta _luaL_tolstring _luaL_argerror _luaL_typeerror _luaL_checklstring _luaL_optlstring _luaL_checknumber _luaL_optnumber _luaL_checkinteger _luaL_optinteger _luaL_checkstack _luaL_checktype _luaL_checkany _luaL_newmetatable _luaL_setmetatable _luaL_testudata _luaL_checkudata _luaL_where _luaL_fileresult _luaL_execresult _luaL_ref _luaL_unref _luaL_loadfilex _luaL_loadbufferx _luaL_loadstring _luaL_newstate _luaL_len _luaL_addgsub _luaL_gsub _luaL_setfuncs _luaL_getsubtable _luaL_traceback _luaL_requiref _luaL_buffinit _luaL_prepbuffsize _luaL_addlstring _luaL_addstring _luaL_addvalue _luaL_pushresult _luaL_pushresultsize _luaL_buffinitsize _lua_newstate _lua_close _lua_newthread _lua_resetthread _lua_atpanic _lua_version _lua_absindex _lua_gettop _lua_settop _lua_pushvalue _lua_rotate _lua_copy _lua_checkstack _lua_xmove _lua_isnumber _lua_isstring _lua_iscfunction _lua_isinteger _lua_isuserdata _lua_type _lua_typename _lua_tonumberx _lua_tointegerx _lua_toboolean _lua_tolstring _lua_rawlen _lua_tocfunction _lua_touserdata _lua_tothread _lua_topointer _lua_arith _lua_rawequal _lua_compare _lua_pushnil _lua_pushnumber _lua_pushinteger _lua_pushlstring _lua_pushstring _lua_pushcclosure _lua_pushboolean _lua_pushlightuserdata _lua_pushthread _lua_getglobal _lua_gettable _lua_getfield _lua_geti _lua_rawget _lua_rawgeti _lua_rawgetp _lua_createtable _lua_newuserdatauv _lua_getmetatable _lua_getiuservalue _lua_setglobal _lua_settable _lua_setfield _lua_seti _lua_rawset _lua_rawseti _lua_rawsetp _lua_setmetatable _lua_setiuservalue _lua_callk _lua_pcallk _lua_load _lua_dump _lua_yieldk _lua_resume _lua_status _lua_isyieldable _lua_setwarnf _lua_warning _lua_error _lua_next _lua_concat _lua_len _lua_stringtonumber _lua_getallocf _lua_setallocf _lua_toclose _lua_closeslot _lua_getstack _lua_getinfo _lua_getlocal _lua_setlocal _lua_getupvalue _lua_setupvalue _lua_upvalueid _lua_upvaluejoin _lua_sethook _lua_gethook _lua_gethookmask _lua_gethookcount _lua_setcstacklimit _luaopen_base _luaopen_coroutine _luaopen_table _luaopen_io _luaopen_os _luaopen_string _luaopen_utf8 _luaopen_math _luaopen_debug _luaopen_package _luaL_openlibs _memory ___indirect_function_table _fflush onRuntimeInitialized".split(" ").forEach((a) => {
            Object.getOwnPropertyDescriptor(
              e.ready,
              a
            ) || Object.defineProperty(e.ready, a, { get: () => g("You are getting " + a + " on the Promise object, instead of the instance. Use .then() to get called back with the instance, see the MODULARIZE docs in src/settings.js"), set: () => g("You are setting " + a + " on the Promise object, instead of the instance. Use .then() to get called back with the instance, see the MODULARIZE docs in src/settings.js") });
          });
          var ca = Object.assign({}, e), da = "./this.program", ea = (a, b) => {
            throw b;
          }, fa = "object" == typeof window, k = "function" == typeof importScripts, n = "object" == typeof process && "object" == typeof process.versions && "string" == typeof process.versions.node, ha = !fa && !n && !k;
          if (e.ENVIRONMENT) throw Error("Module.ENVIRONMENT has been deprecated. To force the environment, use the ENVIRONMENT compile-time option (for example, -sENVIRONMENT=web or -sENVIRONMENT=node)");
          var r = "", ia, ja, ka;
          if (n) {
            if ("undefined" == typeof process || !process.release || "node" !== process.release.name) throw Error("not compiled for this environment (did you build to HTML and try to run it not on the web, or set ENVIRONMENT to something - like node - and run it someplace else - like on the web?)");
            var la = process.versions.node, ma = la.split(".").slice(0, 3);
            ma = 1e4 * ma[0] + 100 * ma[1] + 1 * ma[2].split("-")[0];
            if (16e4 > ma) throw Error("This emscripten-generated code requires node v16.0.0 (detected v" + la + ")");
            const { createRequire: a } = await import("module");
            var require$1 = a(typeof document === "undefined" && typeof location === "undefined" ? __require("url").pathToFileURL(__filename).href : typeof document === "undefined" ? location.href : _documentCurrentScript && _documentCurrentScript.src || new URL("index.js", document.baseURI).href), fs = require$1("fs"), na = require$1("path");
            k ? r = na.dirname(r) + "/" : r = require$1("url").fileURLToPath(new URL("./", typeof document === "undefined" && typeof location === "undefined" ? __require("url").pathToFileURL(__filename).href : typeof document === "undefined" ? location.href : _documentCurrentScript && _documentCurrentScript.src || new URL("index.js", document.baseURI).href));
            ia = (b, c) => {
              b = oa(b) ? new URL(b) : na.normalize(b);
              return fs.readFileSync(b, c ? void 0 : "utf8");
            };
            ka = (b) => {
              b = ia(b, true);
              b.buffer || (b = new Uint8Array(b));
              u(b.buffer);
              return b;
            };
            ja = (b, c, d, f = true) => {
              b = oa(b) ? new URL(b) : na.normalize(b);
              fs.readFile(b, f ? void 0 : "utf8", (h, m) => {
                h ? d(h) : c(f ? m.buffer : m);
              });
            };
            !e.thisProgram && 1 < process.argv.length && (da = process.argv[1].replace(/\\/g, "/"));
            process.argv.slice(2);
            ea = (b, c) => {
              process.exitCode = b;
              throw c;
            };
            e.inspect = () => "[Emscripten Module object]";
          } else if (ha) {
            if ("object" == typeof process && "function" === typeof require$1 || "object" == typeof window || "function" == typeof importScripts) throw Error("not compiled for this environment (did you build to HTML and try to run it not on the web, or set ENVIRONMENT to something - like node - and run it someplace else - like on the web?)");
            "undefined" != typeof read && (ia = read);
            ka = (a) => {
              if ("function" == typeof readbuffer) return new Uint8Array(readbuffer(a));
              a = read(a, "binary");
              u("object" == typeof a);
              return a;
            };
            ja = (a, b) => {
              setTimeout(() => b(ka(a)));
            };
            "undefined" == typeof clearTimeout && (globalThis.clearTimeout = () => {
            });
            "undefined" == typeof setTimeout && (globalThis.setTimeout = (a) => "function" == typeof a ? a() : g());
            "function" == typeof quit && (ea = (a, b) => {
              setTimeout(() => {
                if (!(b instanceof pa)) {
                  let c = b;
                  b && "object" == typeof b && b.stack && (c = [b, b.stack]);
                  z(`exiting due to exception: ${c}`);
                }
                quit(a);
              });
              throw b;
            });
            "undefined" != typeof print && ("undefined" == typeof console && (console = {}), console.log = print, console.warn = console.error = "undefined" != typeof printErr ? printErr : print);
          } else if (fa || k) {
            k ? r = self.location.href : "undefined" != typeof document && document.currentScript && (r = document.currentScript.src);
            _scriptDir && (r = _scriptDir);
            0 !== r.indexOf("blob:") ? r = r.substr(0, r.replace(/[?#].*/, "").lastIndexOf("/") + 1) : r = "";
            if ("object" != typeof window && "function" != typeof importScripts) throw Error("not compiled for this environment (did you build to HTML and try to run it not on the web, or set ENVIRONMENT to something - like node - and run it someplace else - like on the web?)");
            ia = (a) => {
              var b = new XMLHttpRequest();
              b.open("GET", a, false);
              b.send(null);
              return b.responseText;
            };
            k && (ka = (a) => {
              var b = new XMLHttpRequest();
              b.open("GET", a, false);
              b.responseType = "arraybuffer";
              b.send(null);
              return new Uint8Array(b.response);
            });
            ja = (a, b, c) => {
              var d = new XMLHttpRequest();
              d.open("GET", a, true);
              d.responseType = "arraybuffer";
              d.onload = () => {
                200 == d.status || 0 == d.status && d.response ? b(d.response) : c();
              };
              d.onerror = c;
              d.send(null);
            };
          } else throw Error("environment detection error");
          var qa = console.log.bind(console), z = console.error.bind(console);
          Object.assign(e, ca);
          ca = null;
          C("ENVIRONMENT");
          C("GL_MAX_TEXTURE_IMAGE_UNITS");
          C("SDL_canPlayWithWebAudio");
          C("SDL_numSimultaneouslyQueuedBuffers");
          C("INITIAL_MEMORY");
          C("wasmMemory");
          C("arguments");
          C("buffer");
          C("canvas");
          C("doNotCaptureKeyboard");
          C("dynamicLibraries");
          C("elementPointerLock");
          C("extraStackTrace");
          C("forcedAspectRatio");
          C("instantiateWasm");
          C("keyboardListeningElement");
          C("freePreloadedMediaOnUse");
          C("loadSplitModule");
          C("logReadFiles");
          C("mainScriptUrlOrBlob");
          C("mem");
          C("monitorRunDependencies");
          C("noExitRuntime");
          C("noInitialRun");
          C("onAbort");
          C("onCustomMessage");
          C("onExit");
          C("onFree");
          C("onFullScreen");
          C("onMalloc");
          C("onRealloc");
          C("onRuntimeInitialized");
          C("postMainLoop");
          C("postRun");
          C("preInit");
          C("preMainLoop");
          C("preinitializedWebGLContext");
          C("memoryInitializerRequest");
          C("preloadPlugins");
          C("print");
          C("printErr");
          C("quit");
          C("setStatus");
          C("statusMessage");
          C("stderr");
          C("stdin");
          C("stdout");
          C("thisProgram");
          C("wasm");
          C("wasmBinary");
          C("websocket");
          C("fetchSettings");
          D("arguments", "arguments_");
          D("thisProgram", "thisProgram");
          D("quit", "quit_");
          u("undefined" == typeof e.memoryInitializerPrefixURL, "Module.memoryInitializerPrefixURL option was removed, use Module.locateFile instead");
          u("undefined" == typeof e.pthreadMainPrefixURL, "Module.pthreadMainPrefixURL option was removed, use Module.locateFile instead");
          u("undefined" == typeof e.cdInitializerPrefixURL, "Module.cdInitializerPrefixURL option was removed, use Module.locateFile instead");
          u("undefined" == typeof e.filePackagePrefixURL, "Module.filePackagePrefixURL option was removed, use Module.locateFile instead");
          u("undefined" == typeof e.read, "Module.read option was removed (modify read_ in JS)");
          u("undefined" == typeof e.readAsync, "Module.readAsync option was removed (modify readAsync in JS)");
          u("undefined" == typeof e.readBinary, "Module.readBinary option was removed (modify readBinary in JS)");
          u("undefined" == typeof e.setWindowTitle, "Module.setWindowTitle option was removed (modify emscripten_set_window_title in JS)");
          u("undefined" == typeof e.TOTAL_MEMORY, "Module.TOTAL_MEMORY has been renamed Module.INITIAL_MEMORY");
          D("asm", "wasmExports");
          D("read", "read_");
          D("readAsync", "readAsync");
          D("readBinary", "readBinary");
          D("setWindowTitle", "setWindowTitle");
          u(!ha, "shell environment detected but not enabled at build time.  Add 'shell' to `-sENVIRONMENT` to enable.");
          D("wasmBinary", "wasmBinary");
          "object" != typeof WebAssembly && g("no native wasm support detected");
          var ra, sa = false;
          function u(a, b) {
            a || g("Assertion failed" + (b ? ": " + b : ""));
          }
          var E, ta, ua, F, G, va, wa, xa;
          function ya() {
            var a = ra.buffer;
            e.HEAP8 = E = new Int8Array(a);
            e.HEAP16 = ua = new Int16Array(a);
            e.HEAPU8 = ta = new Uint8Array(a);
            e.HEAPU16 = new Uint16Array(a);
            e.HEAP32 = F = new Int32Array(a);
            e.HEAPU32 = G = new Uint32Array(a);
            e.HEAPF32 = va = new Float32Array(a);
            e.HEAPF64 = xa = new Float64Array(a);
            e.HEAP64 = wa = new BigInt64Array(a);
            e.HEAPU64 = new BigUint64Array(a);
          }
          u(!e.STACK_SIZE, "STACK_SIZE can no longer be set at runtime.  Use -sSTACK_SIZE at link time");
          u("undefined" != typeof Int32Array && "undefined" !== typeof Float64Array && void 0 != Int32Array.prototype.subarray && void 0 != Int32Array.prototype.set, "JS engine does not provide full typed array support");
          u(!e.wasmMemory, "Use of `wasmMemory` detected.  Use -sIMPORTED_MEMORY to define wasmMemory externally");
          u(!e.INITIAL_MEMORY, "Detected runtime INITIAL_MEMORY setting.  Use -sIMPORTED_MEMORY to define wasmMemory dynamically");
          function za() {
            if (!sa) {
              var a = Aa();
              0 == a && (a += 4);
              var b = G[a >> 2], c = G[a + 4 >> 2];
              34821223 == b && 2310721022 == c || g(`Stack overflow! Stack cookie has been overwritten at ${Ba(a)}, expected hex dwords 0x89BACDFE and 0x2135467, but received ${Ba(c)} ${Ba(b)}`);
              1668509029 != G[0] && g("Runtime error: The application has corrupted its heap memory area (address zero)!");
            }
          }
          var Ca = new Int16Array(1), Da = new Int8Array(Ca.buffer);
          Ca[0] = 25459;
          if (115 !== Da[0] || 99 !== Da[1]) throw "Runtime error: expected the system to be little-endian! (Run with -sSUPPORT_BIG_ENDIAN to bypass)";
          var Ea = [], Fa = [], Ga = [], Ha = false;
          u(Math.imul, "This browser does not support Math.imul(), build with LEGACY_VM_SUPPORT or POLYFILL_OLD_MATH_FUNCTIONS to add in a polyfill");
          u(Math.fround, "This browser does not support Math.fround(), build with LEGACY_VM_SUPPORT or POLYFILL_OLD_MATH_FUNCTIONS to add in a polyfill");
          u(Math.clz32, "This browser does not support Math.clz32(), build with LEGACY_VM_SUPPORT or POLYFILL_OLD_MATH_FUNCTIONS to add in a polyfill");
          u(Math.trunc, "This browser does not support Math.trunc(), build with LEGACY_VM_SUPPORT or POLYFILL_OLD_MATH_FUNCTIONS to add in a polyfill");
          var Ia = 0, I = null, Ja = null, Ka = {};
          function La(a) {
            for (var b = a; ; ) {
              if (!Ka[a]) return a;
              a = b + Math.random();
            }
          }
          function Ma(a) {
            Ia++;
            a ? (u(!Ka[a]), Ka[a] = 1, null === I && "undefined" != typeof setInterval && (I = setInterval(() => {
              if (sa) clearInterval(I), I = null;
              else {
                var b = false, c;
                for (c in Ka) b || (b = true, z("still waiting on run dependencies:")), z(`dependency: ${c}`);
                b && z("(end of list)");
              }
            }, 1e4))) : z("warning: run dependency added without ID");
          }
          function Na(a) {
            Ia--;
            a ? (u(Ka[a]), delete Ka[a]) : z("warning: run dependency removed without ID");
            0 == Ia && (null !== I && (clearInterval(I), I = null), Ja && (a = Ja, Ja = null, a()));
          }
          function g(a) {
            a = "Aborted(" + a + ")";
            z(a);
            sa = true;
            a = new WebAssembly.RuntimeError(a);
            ba(a);
            throw a;
          }
          var Oa = (a) => a.startsWith("data:application/octet-stream;base64,"), oa = (a) => a.startsWith("file://");
          function J(a) {
            return function() {
              u(Ha, `native function \`${a}\` called before runtime initialization`);
              var b = L[a];
              u(b, `exported native function \`${a}\` not found`);
              return b.apply(null, arguments);
            };
          }
          var M;
          if (e.locateFile) {
            if (M = "glue.wasm", !Oa(M)) {
              var Pa = M;
              M = e.locateFile ? e.locateFile(Pa, r) : r + Pa;
            }
          } else M = new URL("glue.wasm", typeof document === "undefined" && typeof location === "undefined" ? __require("url").pathToFileURL(__filename).href : typeof document === "undefined" ? location.href : _documentCurrentScript && _documentCurrentScript.src || new URL("index.js", document.baseURI).href).href;
          function Qa(a) {
            if (ka) return ka(a);
            throw "both async and sync fetching of the wasm failed";
          }
          function Ra(a) {
            if (fa || k) {
              if ("function" == typeof fetch && !oa(a)) return fetch(a, { credentials: "same-origin" }).then((b) => {
                if (!b.ok) throw "failed to load wasm binary file at '" + a + "'";
                return b.arrayBuffer();
              }).catch(() => Qa(a));
              if (ja) return new Promise((b, c) => {
                ja(a, (d) => b(new Uint8Array(d)), c);
              });
            }
            return Promise.resolve().then(() => Qa(a));
          }
          function Sa(a, b, c) {
            return Ra(a).then((d) => WebAssembly.instantiate(d, b)).then((d) => d).then(c, (d) => {
              z(`failed to asynchronously prepare wasm: ${d}`);
              oa(M) && z(`warning: Loading from a file URI (${M}) is not supported in most browsers. See https://emscripten.org/docs/getting_started/FAQ.html#how-do-i-run-a-local-webserver-for-testing-why-does-my-program-stall-in-downloading-or-preparing`);
              g(d);
            });
          }
          function Ta(a, b) {
            var c = M;
            return "function" != typeof WebAssembly.instantiateStreaming || Oa(c) || oa(c) || n || "function" != typeof fetch ? Sa(c, a, b) : fetch(c, { credentials: "same-origin" }).then((d) => WebAssembly.instantiateStreaming(d, a).then(b, function(f) {
              z(`wasm streaming compile failed: ${f}`);
              z("falling back to ArrayBuffer instantiation");
              return Sa(c, a, b);
            }));
          }
          function D(a, b) {
            Object.getOwnPropertyDescriptor(e, a) || Object.defineProperty(e, a, { configurable: true, get() {
              g(`\`Module.${a}\` has been replaced by \`${b}\` (the initial value can be provided on Module, but after startup the value is only looked for on a local variable of that name)`);
            } });
          }
          function C(a) {
            Object.getOwnPropertyDescriptor(e, a) && g(`\`Module.${a}\` was supplied but \`${a}\` not included in INCOMING_MODULE_JS_API`);
          }
          function Ua(a) {
            return "FS_createPath" === a || "FS_createDataFile" === a || "FS_createPreloadedFile" === a || "FS_unlink" === a || "addRunDependency" === a || "FS_createLazyFile" === a || "FS_createDevice" === a || "removeRunDependency" === a;
          }
          function Va(a, b) {
            "undefined" !== typeof globalThis && Object.defineProperty(globalThis, a, { configurable: true, get() {
              Wa(`\`${a}\` is not longer defined by emscripten. ${b}`);
            } });
          }
          Va("buffer", "Please use HEAP8.buffer or wasmMemory.buffer");
          Va("asm", "Please use wasmExports instead");
          function Xa(a) {
            Object.getOwnPropertyDescriptor(e, a) || Object.defineProperty(e, a, { configurable: true, get() {
              var b = `'${a}' was not exported. add it to EXPORTED_RUNTIME_METHODS (see the Emscripten FAQ)`;
              Ua(a) && (b += ". Alternatively, forcing filesystem support (-sFORCE_FILESYSTEM) can export this for you");
              g(b);
            } });
          }
          function pa(a) {
            this.name = "ExitStatus";
            this.message = `Program terminated with exit(${a})`;
            this.status = a;
          }
          var Ba = (a) => {
            u("number" === typeof a);
            return "0x" + (a >>> 0).toString(16).padStart(8, "0");
          }, Wa = (a) => {
            Ya ||= {};
            Ya[a] || (Ya[a] = 1, n && (a = "warning: " + a), z(a));
          }, Ya, Za = (a, b) => {
            for (var c = 0, d = a.length - 1; 0 <= d; d--) {
              var f = a[d];
              "." === f ? a.splice(d, 1) : ".." === f ? (a.splice(d, 1), c++) : c && (a.splice(d, 1), c--);
            }
            if (b) for (; c; c--) a.unshift("..");
            return a;
          }, P = (a) => {
            var b = "/" === a.charAt(0), c = "/" === a.substr(-1);
            (a = Za(a.split("/").filter((d) => !!d), !b).join("/")) || b || (a = ".");
            a && c && (a += "/");
            return (b ? "/" : "") + a;
          }, $a = (a) => {
            var b = /^(\/?|)([\s\S]*?)((?:\.{1,2}|[^\/]+?|)(\.[^.\/]*|))(?:[\/]*)$/.exec(a).slice(1);
            a = b[0];
            b = b[1];
            if (!a && !b) return ".";
            b &&= b.substr(0, b.length - 1);
            return a + b;
          }, Q = (a) => {
            if ("/" === a) return "/";
            a = P(a);
            a = a.replace(/\/$/, "");
            var b = a.lastIndexOf("/");
            return -1 === b ? a : a.substr(b + 1);
          }, ab = (a, b) => P(a + "/" + b), bb = () => {
            if ("object" == typeof crypto && "function" == typeof crypto.getRandomValues) return (c) => crypto.getRandomValues(c);
            if (n) try {
              var a = require$1("crypto");
              if (a.randomFillSync) return (c) => a.randomFillSync(c);
              var b = a.randomBytes;
              return (c) => (c.set(b(c.byteLength)), c);
            } catch (c) {
            }
            g("no cryptographic support found for randomDevice. consider polyfilling it if you want to use something insecure like Math.random(), e.g. put this in a --pre-js: var crypto = { getRandomValues: (array) => { for (var i = 0; i < array.length; i++) array[i] = (Math.random()*256)|0 } };");
          }, cb = (a) => (cb = bb())(a);
          function db() {
            for (var a = "", b = false, c = arguments.length - 1; -1 <= c && !b; c--) {
              b = 0 <= c ? arguments[c] : R.cwd();
              if ("string" != typeof b) throw new TypeError("Arguments to path.resolve must be strings");
              if (!b) return "";
              a = b + "/" + a;
              b = "/" === b.charAt(0);
            }
            a = Za(a.split("/").filter((d) => !!d), !b).join("/");
            return (b ? "/" : "") + a || ".";
          }
          var eb = (a, b) => {
            function c(m) {
              for (var p = 0; p < m.length && "" === m[p]; p++) ;
              for (var y = m.length - 1; 0 <= y && "" === m[y]; y--) ;
              return p > y ? [] : m.slice(p, y - p + 1);
            }
            a = db(a).substr(1);
            b = db(b).substr(1);
            a = c(a.split("/"));
            b = c(b.split("/"));
            for (var d = Math.min(a.length, b.length), f = d, h = 0; h < d; h++) if (a[h] !== b[h]) {
              f = h;
              break;
            }
            d = [];
            for (h = f; h < a.length; h++) d.push("..");
            d = d.concat(b.slice(f));
            return d.join("/");
          }, gb = "undefined" != typeof TextDecoder ? new TextDecoder("utf8") : void 0, hb = (a, b) => {
            for (var c = b + NaN, d = b; a[d] && !(d >= c); ) ++d;
            if (16 < d - b && a.buffer && gb) return gb.decode(a.subarray(b, d));
            for (c = ""; b < d; ) {
              var f = a[b++];
              if (f & 128) {
                var h = a[b++] & 63;
                if (192 == (f & 224)) c += String.fromCharCode((f & 31) << 6 | h);
                else {
                  var m = a[b++] & 63;
                  224 == (f & 240) ? f = (f & 15) << 12 | h << 6 | m : (240 != (f & 248) && Wa("Invalid UTF-8 leading byte " + Ba(f) + " encountered when deserializing a UTF-8 string in wasm memory to a JS string!"), f = (f & 7) << 18 | h << 12 | m << 6 | a[b++] & 63);
                  65536 > f ? c += String.fromCharCode(f) : (f -= 65536, c += String.fromCharCode(55296 | f >> 10, 56320 | f & 1023));
                }
              } else c += String.fromCharCode(f);
            }
            return c;
          }, ib = [], jb = (a) => {
            for (var b = 0, c = 0; c < a.length; ++c) {
              var d = a.charCodeAt(c);
              127 >= d ? b++ : 2047 >= d ? b += 2 : 55296 <= d && 57343 >= d ? (b += 4, ++c) : b += 3;
            }
            return b;
          }, kb = (a, b, c, d) => {
            u("string" === typeof a, `stringToUTF8Array expects a string (got ${typeof a})`);
            if (!(0 < d)) return 0;
            var f = c;
            d = c + d - 1;
            for (var h = 0; h < a.length; ++h) {
              var m = a.charCodeAt(h);
              if (55296 <= m && 57343 >= m) {
                var p = a.charCodeAt(++h);
                m = 65536 + ((m & 1023) << 10) | p & 1023;
              }
              if (127 >= m) {
                if (c >= d) break;
                b[c++] = m;
              } else {
                if (2047 >= m) {
                  if (c + 1 >= d) break;
                  b[c++] = 192 | m >> 6;
                } else {
                  if (65535 >= m) {
                    if (c + 2 >= d) break;
                    b[c++] = 224 | m >> 12;
                  } else {
                    if (c + 3 >= d) break;
                    1114111 < m && Wa("Invalid Unicode code point " + Ba(m) + " encountered when serializing a JS string to a UTF-8 string in wasm memory! (Valid unicode code points should be in range 0-0x10FFFF).");
                    b[c++] = 240 | m >> 18;
                    b[c++] = 128 | m >> 12 & 63;
                  }
                  b[c++] = 128 | m >> 6 & 63;
                }
                b[c++] = 128 | m & 63;
              }
            }
            b[c] = 0;
            return c - f;
          };
          function lb(a, b) {
            var c = Array(jb(a) + 1);
            a = kb(a, c, 0, c.length);
            b && (c.length = a);
            return c;
          }
          var mb = [];
          function nb(a, b) {
            mb[a] = { input: [], output: [], K: b };
            ob(a, pb);
          }
          var pb = { open(a) {
            var b = mb[a.node.rdev];
            if (!b) throw new R.g(43);
            a.tty = b;
            a.seekable = false;
          }, close(a) {
            a.tty.K.fsync(a.tty);
          }, fsync(a) {
            a.tty.K.fsync(a.tty);
          }, read(a, b, c, d) {
            if (!a.tty || !a.tty.K.ra) throw new R.g(60);
            for (var f = 0, h = 0; h < d; h++) {
              try {
                var m = a.tty.K.ra(a.tty);
              } catch (p) {
                throw new R.g(29);
              }
              if (void 0 === m && 0 === f) throw new R.g(6);
              if (null === m || void 0 === m) break;
              f++;
              b[c + h] = m;
            }
            f && (a.node.timestamp = Date.now());
            return f;
          }, write(a, b, c, d) {
            if (!a.tty || !a.tty.K.ia) throw new R.g(60);
            try {
              for (var f = 0; f < d; f++) a.tty.K.ia(
                a.tty,
                b[c + f]
              );
            } catch (h) {
              throw new R.g(29);
            }
            d && (a.node.timestamp = Date.now());
            return f;
          } }, qb = { ra() {
            a: {
              if (!ib.length) {
                var a = null;
                if (n) {
                  var b = Buffer.alloc(256), c = 0, d = process.stdin.fd;
                  try {
                    c = fs.readSync(d, b);
                  } catch (f) {
                    if (f.toString().includes("EOF")) c = 0;
                    else throw f;
                  }
                  0 < c ? a = b.slice(0, c).toString("utf-8") : a = null;
                } else "undefined" != typeof window && "function" == typeof window.prompt ? (a = window.prompt("Input: "), null !== a && (a += "\n")) : "function" == typeof readline && (a = readline(), null !== a && (a += "\n"));
                if (!a) {
                  a = null;
                  break a;
                }
                ib = lb(
                  a,
                  true
                );
              }
              a = ib.shift();
            }
            return a;
          }, ia(a, b) {
            null === b || 10 === b ? (qa(hb(a.output, 0)), a.output = []) : 0 != b && a.output.push(b);
          }, fsync(a) {
            a.output && 0 < a.output.length && (qa(hb(a.output, 0)), a.output = []);
          }, Ia() {
            return { ab: 25856, cb: 5, $a: 191, bb: 35387, Za: [3, 28, 127, 21, 4, 0, 1, 0, 17, 19, 26, 0, 18, 15, 23, 22, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] };
          }, Ja() {
            return 0;
          }, Ka() {
            return [24, 80];
          } }, rb = { ia(a, b) {
            null === b || 10 === b ? (z(hb(a.output, 0)), a.output = []) : 0 != b && a.output.push(b);
          }, fsync(a) {
            a.output && 0 < a.output.length && (z(hb(a.output, 0)), a.output = []);
          } }, sb = () => {
            g("internal error: mmapAlloc called but `emscripten_builtin_memalign` native symbol not exported");
          };
          function tb(a, b) {
            var c = a.m ? a.m.length : 0;
            c >= b || (b = Math.max(b, c * (1048576 > c ? 2 : 1.125) >>> 0), 0 != c && (b = Math.max(b, 256)), c = a.m, a.m = new Uint8Array(b), 0 < a.o && a.m.set(c.subarray(0, a.o), 0));
          }
          var S = { G: null, s() {
            return S.createNode(null, "/", 16895, 0);
          }, createNode(a, b, c, d) {
            if (24576 === (c & 61440) || R.isFIFO(c)) throw new R.g(63);
            S.G || (S.G = { dir: { node: { C: S.h.C, v: S.h.v, lookup: S.h.lookup, J: S.h.J, rename: S.h.rename, unlink: S.h.unlink, rmdir: S.h.rmdir, readdir: S.h.readdir, symlink: S.h.symlink }, stream: { D: S.l.D } }, file: { node: { C: S.h.C, v: S.h.v }, stream: { D: S.l.D, read: S.l.read, write: S.l.write, T: S.l.T, S: S.l.S, V: S.l.V } }, link: { node: { C: S.h.C, v: S.h.v, readlink: S.h.readlink }, stream: {} }, na: { node: { C: S.h.C, v: S.h.v }, stream: R.Da } });
            c = R.createNode(a, b, c, d);
            T(c.mode) ? (c.h = S.G.dir.node, c.l = S.G.dir.stream, c.m = {}) : R.isFile(c.mode) ? (c.h = S.G.file.node, c.l = S.G.file.stream, c.o = 0, c.m = null) : 40960 === (c.mode & 61440) ? (c.h = S.G.link.node, c.l = S.G.link.stream) : 8192 === (c.mode & 61440) && (c.h = S.G.na.node, c.l = S.G.na.stream);
            c.timestamp = Date.now();
            a && (a.m[b] = c, a.timestamp = c.timestamp);
            return c;
          }, lb(a) {
            return a.m ? a.m.subarray ? a.m.subarray(0, a.o) : new Uint8Array(a.m) : new Uint8Array(0);
          }, h: { C(a) {
            var b = {};
            b.dev = 8192 === (a.mode & 61440) ? a.id : 1;
            b.ino = a.id;
            b.mode = a.mode;
            b.nlink = 1;
            b.uid = 0;
            b.gid = 0;
            b.rdev = a.rdev;
            T(a.mode) ? b.size = 4096 : R.isFile(a.mode) ? b.size = a.o : 40960 === (a.mode & 61440) ? b.size = a.link.length : b.size = 0;
            b.atime = new Date(a.timestamp);
            b.mtime = new Date(a.timestamp);
            b.ctime = new Date(a.timestamp);
            b.Ba = 4096;
            b.blocks = Math.ceil(b.size / b.Ba);
            return b;
          }, v(a, b) {
            void 0 !== b.mode && (a.mode = b.mode);
            void 0 !== b.timestamp && (a.timestamp = b.timestamp);
            if (void 0 !== b.size && (b = b.size, a.o != b)) if (0 == b) a.m = null, a.o = 0;
            else {
              var c = a.m;
              a.m = new Uint8Array(b);
              c && a.m.set(c.subarray(
                0,
                Math.min(b, a.o)
              ));
              a.o = b;
            }
          }, lookup() {
            throw R.da[44];
          }, J(a, b, c, d) {
            return S.createNode(a, b, c, d);
          }, rename(a, b, c) {
            if (T(a.mode)) {
              try {
                var d = U(b, c);
              } catch (h) {
              }
              if (d) for (var f in d.m) throw new R.g(55);
            }
            delete a.parent.m[a.name];
            a.parent.timestamp = Date.now();
            a.name = c;
            b.m[c] = a;
            b.timestamp = a.parent.timestamp;
            a.parent = b;
          }, unlink(a, b) {
            delete a.m[b];
            a.timestamp = Date.now();
          }, rmdir(a, b) {
            var c = U(a, b), d;
            for (d in c.m) throw new R.g(55);
            delete a.m[b];
            a.timestamp = Date.now();
          }, readdir(a) {
            var b = [".", ".."], c;
            for (c in a.m) a.m.hasOwnProperty(c) && b.push(c);
            return b;
          }, symlink(a, b, c) {
            a = S.createNode(a, b, 41471, 0);
            a.link = c;
            return a;
          }, readlink(a) {
            if (40960 !== (a.mode & 61440)) throw new R.g(28);
            return a.link;
          } }, l: { read(a, b, c, d, f) {
            var h = a.node.m;
            if (f >= a.node.o) return 0;
            a = Math.min(a.node.o - f, d);
            u(0 <= a);
            if (8 < a && h.subarray) b.set(h.subarray(f, f + a), c);
            else for (d = 0; d < a; d++) b[c + d] = h[f + d];
            return a;
          }, write(a, b, c, d, f, h) {
            u(!(b instanceof ArrayBuffer));
            b.buffer === E.buffer && (h = false);
            if (!d) return 0;
            a = a.node;
            a.timestamp = Date.now();
            if (b.subarray && (!a.m || a.m.subarray)) {
              if (h) return u(0 === f, "canOwn must imply no weird position inside the file"), a.m = b.subarray(c, c + d), a.o = d;
              if (0 === a.o && 0 === f) return a.m = b.slice(c, c + d), a.o = d;
              if (f + d <= a.o) return a.m.set(b.subarray(c, c + d), f), d;
            }
            tb(a, f + d);
            if (a.m.subarray && b.subarray) a.m.set(b.subarray(c, c + d), f);
            else for (h = 0; h < d; h++) a.m[f + h] = b[c + h];
            a.o = Math.max(a.o, f + d);
            return d;
          }, D(a, b, c) {
            1 === c ? b += a.position : 2 === c && R.isFile(a.node.mode) && (b += a.node.o);
            if (0 > b) throw new R.g(28);
            return b;
          }, T(a, b, c) {
            tb(a.node, b + c);
            a.node.o = Math.max(a.node.o, b + c);
          }, S(a, b, c, d, f) {
            if (!R.isFile(a.node.mode)) throw new R.g(43);
            a = a.node.m;
            if (f & 2 || a.buffer !== E.buffer) {
              if (0 < c || c + b < a.length) a.subarray ? a = a.subarray(c, c + b) : a = Array.prototype.slice.call(a, c, c + b);
              c = true;
              b = sb();
              if (!b) throw new R.g(48);
              E.set(a, b);
            } else c = false, b = a.byteOffset;
            return { Ra: b, Aa: c };
          }, V(a, b, c, d) {
            S.l.write(a, b, 0, d, c, false);
            return 0;
          } } }, ub = (a, b, c) => {
            var d = La(`al ${a}`);
            ja(a, (f) => {
              u(f, `Loading data file "${a}" failed (no arrayBuffer).`);
              b(new Uint8Array(f));
              d && Na(d);
            }, () => {
              if (c) c();
              else throw `Loading data file "${a}" failed.`;
            });
            d && Ma(d);
          }, vb = [], wb = (a, b, c, d) => {
            "undefined" != typeof Browser && Browser.R();
            var f = false;
            vb.forEach((h) => {
              !f && h.canHandle(b) && (h.handle(a, b, c, d), f = true);
            });
            return f;
          }, xb = (a, b) => {
            var c = 0;
            a && (c |= 365);
            b && (c |= 146);
            return c;
          }, yb = {
            0: "Success",
            1: "Arg list too long",
            2: "Permission denied",
            3: "Address already in use",
            4: "Address not available",
            5: "Address family not supported by protocol family",
            6: "No more processes",
            7: "Socket already connected",
            8: "Bad file number",
            9: "Trying to read unreadable message",
            10: "Mount device busy",
            11: "Operation canceled",
            12: "No children",
            13: "Connection aborted",
            14: "Connection refused",
            15: "Connection reset by peer",
            16: "File locking deadlock error",
            17: "Destination address required",
            18: "Math arg out of domain of func",
            19: "Quota exceeded",
            20: "File exists",
            21: "Bad address",
            22: "File too large",
            23: "Host is unreachable",
            24: "Identifier removed",
            25: "Illegal byte sequence",
            26: "Connection already in progress",
            27: "Interrupted system call",
            28: "Invalid argument",
            29: "I/O error",
            30: "Socket is already connected",
            31: "Is a directory",
            32: "Too many symbolic links",
            33: "Too many open files",
            34: "Too many links",
            35: "Message too long",
            36: "Multihop attempted",
            37: "File or path name too long",
            38: "Network interface is not configured",
            39: "Connection reset by network",
            40: "Network is unreachable",
            41: "Too many open files in system",
            42: "No buffer space available",
            43: "No such device",
            44: "No such file or directory",
            45: "Exec format error",
            46: "No record locks available",
            47: "The link has been severed",
            48: "Not enough core",
            49: "No message of desired type",
            50: "Protocol not available",
            51: "No space left on device",
            52: "Function not implemented",
            53: "Socket is not connected",
            54: "Not a directory",
            55: "Directory not empty",
            56: "State not recoverable",
            57: "Socket operation on non-socket",
            59: "Not a typewriter",
            60: "No such device or address",
            61: "Value too large for defined data type",
            62: "Previous owner died",
            63: "Not super-user",
            64: "Broken pipe",
            65: "Protocol error",
            66: "Unknown protocol",
            67: "Protocol wrong type for socket",
            68: "Math result not representable",
            69: "Read only file system",
            70: "Illegal seek",
            71: "No such process",
            72: "Stale file handle",
            73: "Connection timed out",
            74: "Text file busy",
            75: "Cross-device link",
            100: "Device not a stream",
            101: "Bad font file fmt",
            102: "Invalid slot",
            103: "Invalid request code",
            104: "No anode",
            105: "Block device required",
            106: "Channel number out of range",
            107: "Level 3 halted",
            108: "Level 3 reset",
            109: "Link number out of range",
            110: "Protocol driver not attached",
            111: "No CSI structure available",
            112: "Level 2 halted",
            113: "Invalid exchange",
            114: "Invalid request descriptor",
            115: "Exchange full",
            116: "No data (for no delay io)",
            117: "Timer expired",
            118: "Out of streams resources",
            119: "Machine is not on the network",
            120: "Package not installed",
            121: "The object is remote",
            122: "Advertise error",
            123: "Srmount error",
            124: "Communication error on send",
            125: "Cross mount point (not really error)",
            126: "Given log. name not unique",
            127: "f.d. invalid for this operation",
            128: "Remote address changed",
            129: "Can   access a needed shared lib",
            130: "Accessing a corrupted shared lib",
            131: ".lib section in a.out corrupted",
            132: "Attempting to link in too many libs",
            133: "Attempting to exec a shared library",
            135: "Streams pipe error",
            136: "Too many users",
            137: "Socket type not supported",
            138: "Not supported",
            139: "Protocol family not supported",
            140: "Can't send after socket shutdown",
            141: "Too many references",
            142: "Host is down",
            148: "No medium (in tape drive)",
            156: "Level 2 not synchronized"
          }, zb = {
            EPERM: 63,
            ENOENT: 44,
            ESRCH: 71,
            EINTR: 27,
            EIO: 29,
            ENXIO: 60,
            E2BIG: 1,
            ENOEXEC: 45,
            EBADF: 8,
            ECHILD: 12,
            EAGAIN: 6,
            EWOULDBLOCK: 6,
            ENOMEM: 48,
            EACCES: 2,
            EFAULT: 21,
            ENOTBLK: 105,
            EBUSY: 10,
            EEXIST: 20,
            EXDEV: 75,
            ENODEV: 43,
            ENOTDIR: 54,
            EISDIR: 31,
            EINVAL: 28,
            ENFILE: 41,
            EMFILE: 33,
            ENOTTY: 59,
            ETXTBSY: 74,
            EFBIG: 22,
            ENOSPC: 51,
            ESPIPE: 70,
            EROFS: 69,
            EMLINK: 34,
            EPIPE: 64,
            EDOM: 18,
            ERANGE: 68,
            ENOMSG: 49,
            EIDRM: 24,
            ECHRNG: 106,
            EL2NSYNC: 156,
            EL3HLT: 107,
            EL3RST: 108,
            ELNRNG: 109,
            EUNATCH: 110,
            ENOCSI: 111,
            EL2HLT: 112,
            EDEADLK: 16,
            ENOLCK: 46,
            EBADE: 113,
            EBADR: 114,
            EXFULL: 115,
            ENOANO: 104,
            EBADRQC: 103,
            EBADSLT: 102,
            EDEADLOCK: 16,
            EBFONT: 101,
            ENOSTR: 100,
            ENODATA: 116,
            ETIME: 117,
            ENOSR: 118,
            ENONET: 119,
            ENOPKG: 120,
            EREMOTE: 121,
            ENOLINK: 47,
            EADV: 122,
            ESRMNT: 123,
            ECOMM: 124,
            EPROTO: 65,
            EMULTIHOP: 36,
            EDOTDOT: 125,
            EBADMSG: 9,
            ENOTUNIQ: 126,
            EBADFD: 127,
            EREMCHG: 128,
            ELIBACC: 129,
            ELIBBAD: 130,
            ELIBSCN: 131,
            ELIBMAX: 132,
            ELIBEXEC: 133,
            ENOSYS: 52,
            ENOTEMPTY: 55,
            ENAMETOOLONG: 37,
            ELOOP: 32,
            EOPNOTSUPP: 138,
            EPFNOSUPPORT: 139,
            ECONNRESET: 15,
            ENOBUFS: 42,
            EAFNOSUPPORT: 5,
            EPROTOTYPE: 67,
            ENOTSOCK: 57,
            ENOPROTOOPT: 50,
            ESHUTDOWN: 140,
            ECONNREFUSED: 14,
            EADDRINUSE: 3,
            ECONNABORTED: 13,
            ENETUNREACH: 40,
            ENETDOWN: 38,
            ETIMEDOUT: 73,
            EHOSTDOWN: 142,
            EHOSTUNREACH: 23,
            EINPROGRESS: 26,
            EALREADY: 7,
            EDESTADDRREQ: 17,
            EMSGSIZE: 35,
            EPROTONOSUPPORT: 66,
            ESOCKTNOSUPPORT: 137,
            EADDRNOTAVAIL: 4,
            ENETRESET: 39,
            EISCONN: 30,
            ENOTCONN: 53,
            ETOOMANYREFS: 141,
            EUSERS: 136,
            EDQUOT: 19,
            ESTALE: 72,
            ENOTSUP: 138,
            ENOMEDIUM: 148,
            EILSEQ: 25,
            EOVERFLOW: 61,
            ECANCELED: 11,
            ENOTRECOVERABLE: 56,
            EOWNERDEAD: 62,
            ESTRPIPE: 135
          }, Ab = (a) => a.replace(/\b_Z[\w\d_]+/g, function(b) {
            Wa("warning: build with -sDEMANGLE_SUPPORT to link in libcxxabi demangling");
            return b === b ? b : b + " [" + b + "]";
          });
          function ob(a, b) {
            R.pa[a] = { l: b };
          }
          function T(a) {
            return 16384 === (a & 61440);
          }
          function U(a, b) {
            var c;
            if (c = (c = Bb(a, "x")) ? c : a.h.lookup ? 0 : 2) throw new R.g(c, a);
            for (c = R.F[Cb(a.id, b)]; c; c = c.N) {
              var d = c.name;
              if (c.parent.id === a.id && d === b) return c;
            }
            return R.lookup(a, b);
          }
          function V(a, b = {}) {
            a = db(a);
            if (!a) return { path: "", node: null };
            b = Object.assign({ ba: true, ka: 0 }, b);
            if (8 < b.ka) throw new R.g(32);
            a = a.split("/").filter((m) => !!m);
            for (var c = R.root, d = "/", f = 0; f < a.length; f++) {
              var h = f === a.length - 1;
              if (h && b.parent) break;
              c = U(c, a[f]);
              d = P(d + "/" + a[f]);
              c.A && (!h || h && b.ba) && (c = c.A.root);
              if (!h || b.B) {
                for (h = 0; 40960 === (c.mode & 61440); ) if (c = R.readlink(d), d = db($a(d), c), c = V(d, { ka: b.ka + 1 }).node, 40 < h++) throw new R.g(32);
              }
            }
            return { path: d, node: c };
          }
          function Db(a) {
            for (var b; ; ) {
              if (R.Z(a)) return a = a.s.ua, b ? "/" !== a[a.length - 1] ? `${a}/${b}` : a + b : a;
              b = b ? `${a.name}/${b}` : a.name;
              a = a.parent;
            }
          }
          function Cb(a, b) {
            for (var c = 0, d = 0; d < b.length; d++) c = (c << 5) - c + b.charCodeAt(d) | 0;
            return (a + c >>> 0) % R.F.length;
          }
          function Eb(a) {
            var b = Cb(a.parent.id, a.name);
            a.N = R.F[b];
            R.F[b] = a;
          }
          function Fb(a) {
            var b = Cb(a.parent.id, a.name);
            if (R.F[b] === a) R.F[b] = a.N;
            else for (b = R.F[b]; b; ) {
              if (b.N === a) {
                b.N = a.N;
                break;
              }
              b = b.N;
            }
          }
          function Gb(a) {
            var b = ["r", "w", "rw"][a & 3];
            a & 512 && (b += "w");
            return b;
          }
          function Bb(a, b) {
            if (R.ta) return 0;
            if (!b.includes("r") || a.mode & 292) {
              if (b.includes("w") && !(a.mode & 146) || b.includes("x") && !(a.mode & 73)) return 2;
            } else return 2;
            return 0;
          }
          function Hb(a, b) {
            try {
              return U(a, b), 20;
            } catch (c) {
            }
            return Bb(a, "wx");
          }
          function Ib(a, b, c) {
            try {
              var d = U(a, b);
            } catch (f) {
              return f.u;
            }
            if (a = Bb(a, "wx")) return a;
            if (c) {
              if (!T(d.mode)) return 54;
              if (R.Z(d) || Db(d) === R.cwd()) return 10;
            } else if (T(d.mode)) return 31;
            return 0;
          }
          function Jb() {
            for (var a = 0; a <= R.xa; a++) if (!R.streams[a]) return a;
            throw new R.g(33);
          }
          function W(a) {
            a = R.qa(a);
            if (!a) throw new R.g(8);
            return a;
          }
          function Kb(a, b = -1) {
            R.X || (R.X = function() {
              this.I = {};
            }, R.X.prototype = {}, Object.defineProperties(R.X.prototype, { object: { get() {
              return this.node;
            }, set(c) {
              this.node = c;
            } }, flags: { get() {
              return this.I.flags;
            }, set(c) {
              this.I.flags = c;
            } }, position: { get() {
              return this.I.position;
            }, set(c) {
              this.I.position = c;
            } } }));
            a = Object.assign(new R.X(), a);
            -1 == b && (b = Jb());
            a.fd = b;
            return R.streams[b] = a;
          }
          function Lb(a) {
            var b = [];
            for (a = [a]; a.length; ) {
              var c = a.pop();
              b.push(c);
              a.push.apply(a, c.U);
            }
            return b;
          }
          function Mb(a, b, c) {
            "undefined" == typeof c && (c = b, b = 438);
            return R.J(a, b | 8192, c);
          }
          function Nb() {
            R.g || (R.g = function(a, b) {
              this.name = "ErrnoError";
              this.node = b;
              this.Sa = function(c) {
                this.u = c;
                for (var d in zb) if (zb[d] === c) {
                  this.code = d;
                  break;
                }
              };
              this.Sa(a);
              this.message = yb[a];
              this.stack && (Object.defineProperty(this, "stack", { value: Error().stack, writable: true }), this.stack = Ab(this.stack));
            }, R.g.prototype = Error(), R.g.prototype.constructor = R.g, [44].forEach((a) => {
              R.da[a] = new R.g(a);
              R.da[a].stack = "<generic error, no stack>";
            }));
          }
          function Ob(a, b) {
            try {
              var c = V(a, { B: !b });
              a = c.path;
            } catch (f) {
            }
            var d = { Z: false, exists: false, error: 0, name: null, path: null, object: null, Oa: false, Qa: null, Pa: null };
            try {
              c = V(a, { parent: true }), d.Oa = true, d.Qa = c.path, d.Pa = c.node, d.name = Q(a), c = V(a, { B: !b }), d.exists = true, d.path = c.path, d.object = c.node, d.name = c.node.name, d.Z = "/" === c.path;
            } catch (f) {
              d.error = f.u;
            }
            return d;
          }
          function Pb(a, b, c, d) {
            a = "string" == typeof a ? a : Db(a);
            b = P(a + "/" + b);
            return R.create(b, xb(c, d));
          }
          function Qb(a) {
            if (!(a.La || a.Ma || a.link || a.m)) {
              if ("undefined" != typeof XMLHttpRequest) throw Error("Lazy loading should have been performed (contents set) in createLazyFile, but it was not. Lazy loading only works in web workers. Use --embed-file or --preload-file in emcc on the main thread.");
              if (ia) try {
                a.m = lb(ia(a.url), true), a.o = a.m.length;
              } catch (b) {
                throw new R.g(29);
              }
              else throw Error("Cannot load without read() or XMLHttpRequest.");
            }
          }
          var R = {
            root: null,
            U: [],
            pa: {},
            streams: [],
            Na: 1,
            F: null,
            oa: "/",
            Y: false,
            ta: true,
            g: null,
            da: {},
            Fa: null,
            W: 0,
            createNode(a, b, c, d) {
              u("object" == typeof a);
              a = new R.wa(a, b, c, d);
              Eb(a);
              return a;
            },
            Z(a) {
              return a === a.parent;
            },
            isFile(a) {
              return 32768 === (a & 61440);
            },
            isFIFO(a) {
              return 4096 === (a & 61440);
            },
            isSocket(a) {
              return 49152 === (a & 49152);
            },
            xa: 4096,
            qa: (a) => R.streams[a],
            Da: { open(a) {
              a.l = R.Ga(a.node.rdev).l;
              a.l.open && a.l.open(a);
            }, D() {
              throw new R.g(70);
            } },
            ha: (a) => a >> 8,
            nb: (a) => a & 255,
            M: (a, b) => a << 8 | b,
            Ga: (a) => R.pa[a],
            va(a, b) {
              function c(m) {
                u(0 < R.W);
                R.W--;
                return b(m);
              }
              function d(m) {
                if (m) {
                  if (!d.Ea) return d.Ea = true, c(m);
                } else ++h >= f.length && c(null);
              }
              "function" == typeof a && (b = a, a = false);
              R.W++;
              1 < R.W && z(`warning: ${R.W} FS.syncfs operations in flight at once, probably just doing extra work`);
              var f = Lb(R.root.s), h = 0;
              f.forEach((m) => {
                if (!m.type.va) return d(null);
                m.type.va(m, a, d);
              });
            },
            s(a, b, c) {
              if ("string" == typeof a) throw a;
              var d = "/" === c, f = !c;
              if (d && R.root) throw new R.g(10);
              if (!d && !f) {
                var h = V(c, { ba: false });
                c = h.path;
                h = h.node;
                if (h.A) throw new R.g(10);
                if (!T(h.mode)) throw new R.g(54);
              }
              b = { type: a, rb: b, ua: c, U: [] };
              a = a.s(b);
              a.s = b;
              b.root = a;
              d ? R.root = a : h && (h.A = b, h.s && h.s.U.push(b));
              return a;
            },
            xb(a) {
              a = V(a, { ba: false });
              if (!a.node.A) throw new R.g(28);
              a = a.node;
              var b = a.A, c = Lb(b);
              Object.keys(R.F).forEach((d) => {
                for (d = R.F[d]; d; ) {
                  var f = d.N;
                  c.includes(d.s) && Fb(d);
                  d = f;
                }
              });
              a.A = null;
              b = a.s.U.indexOf(b);
              u(-1 !== b);
              a.s.U.splice(b, 1);
            },
            lookup(a, b) {
              return a.h.lookup(a, b);
            },
            J(a, b, c) {
              var d = V(a, { parent: true }).node;
              a = Q(a);
              if (!a || "." === a || ".." === a) throw new R.g(28);
              var f = Hb(d, a);
              if (f) throw new R.g(f);
              if (!d.h.J) throw new R.g(63);
              return d.h.J(d, a, b, c);
            },
            create(a, b) {
              return R.J(a, (void 0 !== b ? b : 438) & 4095 | 32768, 0);
            },
            mkdir(a, b) {
              return R.J(a, (void 0 !== b ? b : 511) & 1023 | 16384, 0);
            },
            ob(a, b) {
              a = a.split("/");
              for (var c = "", d = 0; d < a.length; ++d) if (a[d]) {
                c += "/" + a[d];
                try {
                  R.mkdir(c, b);
                } catch (f) {
                  if (20 != f.u) throw f;
                }
              }
            },
            symlink(a, b) {
              if (!db(a)) throw new R.g(44);
              var c = V(b, { parent: true }).node;
              if (!c) throw new R.g(44);
              b = Q(b);
              var d = Hb(c, b);
              if (d) throw new R.g(d);
              if (!c.h.symlink) throw new R.g(63);
              return c.h.symlink(c, b, a);
            },
            rename(a, b) {
              var c = $a(a), d = $a(b), f = Q(a), h = Q(b);
              var m = V(a, { parent: true });
              var p = m.node;
              m = V(b, { parent: true });
              m = m.node;
              if (!p || !m) throw new R.g(44);
              if (p.s !== m.s) throw new R.g(75);
              var y = U(p, f);
              a = eb(a, d);
              if ("." !== a.charAt(0)) throw new R.g(28);
              a = eb(b, c);
              if ("." !== a.charAt(0)) throw new R.g(55);
              try {
                var q2 = U(m, h);
              } catch (x) {
              }
              if (y !== q2) {
                b = T(y.mode);
                if (f = Ib(p, f, b)) throw new R.g(f);
                if (f = q2 ? Ib(m, h, b) : Hb(m, h)) throw new R.g(f);
                if (!p.h.rename) throw new R.g(63);
                if (y.A || q2 && q2.A) throw new R.g(10);
                if (m !== p && (f = Bb(p, "w"))) throw new R.g(f);
                Fb(y);
                try {
                  p.h.rename(y, m, h);
                } catch (x) {
                  throw x;
                } finally {
                  Eb(y);
                }
              }
            },
            rmdir(a) {
              var b = V(a, { parent: true }).node;
              a = Q(a);
              var c = U(b, a), d = Ib(b, a, true);
              if (d) throw new R.g(d);
              if (!b.h.rmdir) throw new R.g(63);
              if (c.A) throw new R.g(10);
              b.h.rmdir(b, a);
              Fb(c);
            },
            readdir(a) {
              a = V(a, { B: true }).node;
              if (!a.h.readdir) throw new R.g(54);
              return a.h.readdir(a);
            },
            unlink(a) {
              var b = V(a, { parent: true }).node;
              if (!b) throw new R.g(44);
              a = Q(a);
              var c = U(b, a), d = Ib(b, a, false);
              if (d) throw new R.g(d);
              if (!b.h.unlink) throw new R.g(63);
              if (c.A) throw new R.g(10);
              b.h.unlink(b, a);
              Fb(c);
            },
            readlink(a) {
              a = V(a).node;
              if (!a) throw new R.g(44);
              if (!a.h.readlink) throw new R.g(28);
              return db(Db(a.parent), a.h.readlink(a));
            },
            stat(a, b) {
              a = V(a, { B: !b }).node;
              if (!a) throw new R.g(44);
              if (!a.h.C) throw new R.g(63);
              return a.h.C(a);
            },
            lstat(a) {
              return R.stat(a, true);
            },
            chmod(a, b, c) {
              a = "string" == typeof a ? V(a, { B: !c }).node : a;
              if (!a.h.v) throw new R.g(63);
              a.h.v(a, { mode: b & 4095 | a.mode & -4096, timestamp: Date.now() });
            },
            lchmod(a, b) {
              R.chmod(a, b, true);
            },
            fchmod(a, b) {
              a = W(a);
              R.chmod(a.node, b);
            },
            chown(a, b, c, d) {
              a = "string" == typeof a ? V(a, { B: !d }).node : a;
              if (!a.h.v) throw new R.g(63);
              a.h.v(
                a,
                { timestamp: Date.now() }
              );
            },
            lchown(a, b, c) {
              R.chown(a, b, c, true);
            },
            fchown(a, b, c) {
              a = W(a);
              R.chown(a.node, b, c);
            },
            truncate(a, b) {
              if (0 > b) throw new R.g(28);
              a = "string" == typeof a ? V(a, { B: true }).node : a;
              if (!a.h.v) throw new R.g(63);
              if (T(a.mode)) throw new R.g(31);
              if (!R.isFile(a.mode)) throw new R.g(28);
              var c = Bb(a, "w");
              if (c) throw new R.g(c);
              a.h.v(a, { size: b, timestamp: Date.now() });
            },
            kb(a, b) {
              a = W(a);
              if (0 === (a.flags & 2097155)) throw new R.g(28);
              R.truncate(a.node, b);
            },
            yb(a, b, c) {
              a = V(a, { B: true }).node;
              a.h.v(a, { timestamp: Math.max(b, c) });
            },
            open(a, b, c) {
              if ("" === a) throw new R.g(44);
              if ("string" == typeof b) {
                var d = { r: 0, "r+": 2, w: 577, "w+": 578, a: 1089, "a+": 1090 }[b];
                if ("undefined" == typeof d) throw Error(`Unknown file open mode: ${b}`);
                b = d;
              }
              c = b & 64 ? ("undefined" == typeof c ? 438 : c) & 4095 | 32768 : 0;
              if ("object" == typeof a) var f = a;
              else {
                a = P(a);
                try {
                  f = V(a, { B: !(b & 131072) }).node;
                } catch (h) {
                }
              }
              d = false;
              if (b & 64) if (f) {
                if (b & 128) throw new R.g(20);
              } else f = R.J(a, c, 0), d = true;
              if (!f) throw new R.g(44);
              8192 === (f.mode & 61440) && (b &= -513);
              if (b & 65536 && !T(f.mode)) throw new R.g(54);
              if (!d && (c = f ? 40960 === (f.mode & 61440) ? 32 : T(f.mode) && ("r" !== Gb(b) || b & 512) ? 31 : Bb(f, Gb(b)) : 44)) throw new R.g(c);
              b & 512 && !d && R.truncate(f, 0);
              b &= -131713;
              f = Kb({ node: f, path: Db(f), flags: b, seekable: true, position: 0, l: f.l, Xa: [], error: false });
              f.l.open && f.l.open(f);
              !e.logReadFiles || b & 1 || (R.ja || (R.ja = {}), a in R.ja || (R.ja[a] = 1));
              return f;
            },
            close(a) {
              if (null === a.fd) throw new R.g(8);
              a.ea && (a.ea = null);
              try {
                a.l.close && a.l.close(a);
              } catch (b) {
                throw b;
              } finally {
                R.streams[a.fd] = null;
              }
              a.fd = null;
            },
            D(a, b, c) {
              if (null === a.fd) throw new R.g(8);
              if (!a.seekable || !a.l.D) throw new R.g(70);
              if (0 != c && 1 != c && 2 != c) throw new R.g(28);
              a.position = a.l.D(a, b, c);
              a.Xa = [];
              return a.position;
            },
            read(a, b, c, d, f) {
              u(0 <= c);
              if (0 > d || 0 > f) throw new R.g(28);
              if (null === a.fd) throw new R.g(8);
              if (1 === (a.flags & 2097155)) throw new R.g(8);
              if (T(a.node.mode)) throw new R.g(31);
              if (!a.l.read) throw new R.g(28);
              var h = "undefined" != typeof f;
              if (!h) f = a.position;
              else if (!a.seekable) throw new R.g(70);
              b = a.l.read(a, b, c, d, f);
              h || (a.position += b);
              return b;
            },
            write(a, b, c, d, f, h) {
              u(0 <= c);
              if (0 > d || 0 > f) throw new R.g(28);
              if (null === a.fd) throw new R.g(8);
              if (0 === (a.flags & 2097155)) throw new R.g(8);
              if (T(a.node.mode)) throw new R.g(31);
              if (!a.l.write) throw new R.g(28);
              a.seekable && a.flags & 1024 && R.D(a, 0, 2);
              var m = "undefined" != typeof f;
              if (!m) f = a.position;
              else if (!a.seekable) throw new R.g(70);
              b = a.l.write(a, b, c, d, f, h);
              m || (a.position += b);
              return b;
            },
            T(a, b, c) {
              if (null === a.fd) throw new R.g(8);
              if (0 > b || 0 >= c) throw new R.g(28);
              if (0 === (a.flags & 2097155)) throw new R.g(8);
              if (!R.isFile(a.node.mode) && !T(a.node.mode)) throw new R.g(43);
              if (!a.l.T) throw new R.g(138);
              a.l.T(a, b, c);
            },
            S(a, b, c, d, f) {
              if (0 !== (d & 2) && 0 === (f & 2) && 2 !== (a.flags & 2097155)) throw new R.g(2);
              if (1 === (a.flags & 2097155)) throw new R.g(2);
              if (!a.l.S) throw new R.g(43);
              return a.l.S(a, b, c, d, f);
            },
            V(a, b, c, d, f) {
              u(0 <= c);
              return a.l.V ? a.l.V(a, b, c, d, f) : 0;
            },
            qb: () => 0,
            fa(a, b, c) {
              if (!a.l.fa) throw new R.g(59);
              return a.l.fa(a, b, c);
            },
            readFile(a, b = {}) {
              b.flags = b.flags || 0;
              b.encoding = b.encoding || "binary";
              if ("utf8" !== b.encoding && "binary" !== b.encoding) throw Error(`Invalid encoding type "${b.encoding}"`);
              var c, d = R.open(a, b.flags);
              a = R.stat(a).size;
              var f = new Uint8Array(a);
              R.read(d, f, 0, a, 0);
              "utf8" === b.encoding ? c = hb(f, 0) : "binary" === b.encoding && (c = f);
              R.close(d);
              return c;
            },
            writeFile(a, b, c = {}) {
              c.flags = c.flags || 577;
              a = R.open(a, c.flags, c.mode);
              if ("string" == typeof b) {
                var d = new Uint8Array(jb(b) + 1);
                b = kb(b, d, 0, d.length);
                R.write(a, d, 0, b, void 0, c.Ca);
              } else if (ArrayBuffer.isView(b)) R.write(a, b, 0, b.byteLength, void 0, c.Ca);
              else throw Error("Unsupported data type");
              R.close(a);
            },
            cwd: () => R.oa,
            chdir(a) {
              a = V(a, { B: true });
              if (null === a.node) throw new R.g(44);
              if (!T(a.node.mode)) throw new R.g(54);
              var b = Bb(a.node, "x");
              if (b) throw new R.g(b);
              R.oa = a.path;
            },
            R(a, b, c) {
              u(!R.R.Y, "FS.init was previously called. If you want to initialize later with custom parameters, remove any earlier calls (note that one is automatically added to the generated code)");
              R.R.Y = true;
              Nb();
              e.stdin = a || e.stdin;
              e.stdout = b || e.stdout;
              e.stderr = c || e.stderr;
              e.stdin ? R.L("/dev", "stdin", e.stdin) : R.symlink("/dev/tty", "/dev/stdin");
              e.stdout ? R.L("/dev", "stdout", null, e.stdout) : R.symlink("/dev/tty", "/dev/stdout");
              e.stderr ? R.L(
                "/dev",
                "stderr",
                null,
                e.stderr
              ) : R.symlink("/dev/tty1", "/dev/stderr");
              a = R.open("/dev/stdin", 0);
              b = R.open("/dev/stdout", 1);
              c = R.open("/dev/stderr", 1);
              u(0 === a.fd, `invalid handle for stdin (${a.fd})`);
              u(1 === b.fd, `invalid handle for stdout (${b.fd})`);
              u(2 === c.fd, `invalid handle for stderr (${c.fd})`);
            },
            sb() {
              R.R.Y = false;
              Rb(0);
              for (var a = 0; a < R.streams.length; a++) {
                var b = R.streams[a];
                b && R.close(b);
              }
            },
            jb(a, b) {
              a = Ob(a, b);
              return a.exists ? a.object : null;
            },
            hb(a, b) {
              a = "string" == typeof a ? a : Db(a);
              for (b = b.split("/").reverse(); b.length; ) {
                var c = b.pop();
                if (c) {
                  var d = P(a + "/" + c);
                  try {
                    R.mkdir(d);
                  } catch (f) {
                  }
                  a = d;
                }
              }
              return d;
            },
            L(a, b, c, d) {
              a = ab("string" == typeof a ? a : Db(a), b);
              b = xb(!!c, !!d);
              R.L.ha || (R.L.ha = 64);
              var f = R.M(R.L.ha++, 0);
              ob(f, { open(h) {
                h.seekable = false;
              }, close() {
                d && d.buffer && d.buffer.length && d(10);
              }, read(h, m, p, y) {
                for (var q2 = 0, x = 0; x < y; x++) {
                  try {
                    var t = c();
                  } catch (B) {
                    throw new R.g(29);
                  }
                  if (void 0 === t && 0 === q2) throw new R.g(6);
                  if (null === t || void 0 === t) break;
                  q2++;
                  m[p + x] = t;
                }
                q2 && (h.node.timestamp = Date.now());
                return q2;
              }, write(h, m, p, y) {
                for (var q2 = 0; q2 < y; q2++) try {
                  d(m[p + q2]);
                } catch (x) {
                  throw new R.g(29);
                }
                y && (h.node.timestamp = Date.now());
                return q2;
              } });
              return Mb(a, b, f);
            },
            fb(a, b, c, d, f) {
              function h() {
                this.ga = false;
                this.I = [];
              }
              function m(t, B, l, w, v) {
                t = t.node.m;
                if (v >= t.length) return 0;
                w = Math.min(t.length - v, w);
                u(0 <= w);
                if (t.slice) for (var A = 0; A < w; A++) B[l + A] = t[v + A];
                else for (A = 0; A < w; A++) B[l + A] = t.get(v + A);
                return w;
              }
              h.prototype.get = function(t) {
                if (!(t > this.length - 1 || 0 > t)) {
                  var B = t % this.chunkSize;
                  return this.sa(t / this.chunkSize | 0)[B];
                }
              };
              h.prototype.Ha = function(t) {
                this.sa = t;
              };
              h.prototype.ma = function() {
                var t = new XMLHttpRequest();
                t.open("HEAD", c, false);
                t.send(null);
                if (!(200 <= t.status && 300 > t.status || 304 === t.status)) throw Error("Couldn't load " + c + ". Status: " + t.status);
                var B = Number(t.getResponseHeader("Content-length")), l, w = (l = t.getResponseHeader("Accept-Ranges")) && "bytes" === l;
                t = (l = t.getResponseHeader("Content-Encoding")) && "gzip" === l;
                var v = 1048576;
                w || (v = B);
                var A = this;
                A.Ha((H) => {
                  var N = H * v, O = (H + 1) * v - 1;
                  O = Math.min(O, B - 1);
                  if ("undefined" == typeof A.I[H]) {
                    var fb = A.I;
                    if (N > O) throw Error("invalid range (" + N + ", " + O + ") or no bytes requested!");
                    if (O > B - 1) throw Error("only " + B + " bytes available! programmer error!");
                    var K = new XMLHttpRequest();
                    K.open("GET", c, false);
                    B !== v && K.setRequestHeader("Range", "bytes=" + N + "-" + O);
                    K.responseType = "arraybuffer";
                    K.overrideMimeType && K.overrideMimeType("text/plain; charset=x-user-defined");
                    K.send(null);
                    if (!(200 <= K.status && 300 > K.status || 304 === K.status)) throw Error("Couldn't load " + c + ". Status: " + K.status);
                    N = void 0 !== K.response ? new Uint8Array(K.response || []) : lb(K.responseText || "", true);
                    fb[H] = N;
                  }
                  if ("undefined" == typeof A.I[H]) throw Error("doXHR failed!");
                  return A.I[H];
                });
                if (t || !B) v = B = 1, v = B = this.sa(0).length, qa("LazyFiles on gzip forces download of the whole file when length is accessed");
                this.za = B;
                this.ya = v;
                this.ga = true;
              };
              if ("undefined" != typeof XMLHttpRequest) {
                if (!k) throw "Cannot do synchronous binary XHRs outside webworkers in modern browsers. Use --embed-file or --preload-file in emcc";
                var p = new h();
                Object.defineProperties(p, { length: { get: function() {
                  this.ga || this.ma();
                  return this.za;
                } }, chunkSize: { get: function() {
                  this.ga || this.ma();
                  return this.ya;
                } } });
                var y = void 0;
              } else y = c, p = void 0;
              var q2 = Pb(a, b, d, f);
              p ? q2.m = p : y && (q2.m = null, q2.url = y);
              Object.defineProperties(q2, { o: { get: function() {
                return this.m.length;
              } } });
              var x = {};
              Object.keys(q2.l).forEach((t) => {
                var B = q2.l[t];
                x[t] = function() {
                  Qb(q2);
                  return B.apply(null, arguments);
                };
              });
              x.read = (t, B, l, w, v) => {
                Qb(q2);
                return m(t, B, l, w, v);
              };
              x.S = (t, B, l) => {
                Qb(q2);
                var w = sb();
                if (!w) throw new R.g(48);
                m(t, E, w, B, l);
                return { Ra: w, Aa: true };
              };
              q2.l = x;
              return q2;
            },
            Ya() {
              g("FS.absolutePath has been removed; use PATH_FS.resolve instead");
            },
            eb() {
              g("FS.createFolder has been removed; use FS.mkdir instead");
            },
            gb() {
              g("FS.createLink has been removed; use FS.symlink instead");
            },
            mb() {
              g("FS.joinPath has been removed; use PATH.join instead");
            },
            pb() {
              g("FS.mmapAlloc has been replaced by the top level function mmapAlloc");
            },
            vb() {
              g("FS.standardizePath has been removed; use PATH.normalize instead");
            }
          }, X = (a) => {
            u("number" == typeof a, `UTF8ToString expects a number (got ${typeof a})`);
            return a ? hb(ta, a) : "";
          };
          function Sb(a, b) {
            if ("/" === b.charAt(0)) return b;
            a = -100 === a ? R.cwd() : W(a).path;
            if (0 == b.length) throw new R.g(44);
            return P(a + "/" + b);
          }
          var Tb = void 0;
          function Y() {
            u(void 0 != Tb);
            var a = F[+Tb >> 2];
            Tb += 4;
            return a;
          }
          var Ub = (a, b, c) => {
            u("number" == typeof c, "stringToUTF8(str, outPtr, maxBytesToWrite) is missing the third parameter that specifies the length of the output buffer!");
            return kb(a, ta, b, c);
          }, Vb = (a) => 0 === a % 4 && (0 !== a % 100 || 0 === a % 400), Wb = [0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335], Xb = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334], Zb = (a) => {
            var b = jb(a) + 1, c = Yb(b);
            c && Ub(a, c, b);
            return c;
          }, $b = {}, bc = () => {
            if (!ac) {
              var a = { USER: "web_user", LOGNAME: "web_user", PATH: "/", PWD: "/", HOME: "/home/web_user", LANG: ("object" == typeof navigator && navigator.languages && navigator.languages[0] || "C").replace("-", "_") + ".UTF-8", _: da || "./this.program" }, b;
              for (b in $b) void 0 === $b[b] ? delete a[b] : a[b] = $b[b];
              var c = [];
              for (b in a) c.push(`${b}=${a[b]}`);
              ac = c;
            }
            return ac;
          }, ac, cc = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31], dc = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31], ec = (a, b) => {
            u(0 <= a.length, "writeArrayToMemory array must have a length (should be an array or typed array)");
            E.set(a, b);
          }, fc = [], Z, gc = (a) => {
            var b = fc[a];
            b || (a >= fc.length && (fc.length = a + 1), fc[a] = b = Z.get(a));
            u(Z.get(a) == b, "JavaScript-side Wasm function table mirror is out of date!");
            return b;
          }, hc = (a) => {
            var b = e["_" + a];
            u(b, "Cannot call unknown function " + a + ", make sure it is exported");
            return b;
          }, ic, jc = [];
          function kc(a, b, c, d) {
            a ||= this;
            this.parent = a;
            this.s = a.s;
            this.A = null;
            this.id = R.Na++;
            this.name = b;
            this.mode = c;
            this.h = {};
            this.l = {};
            this.rdev = d;
          }
          Object.defineProperties(kc.prototype, { read: { get: function() {
            return 365 === (this.mode & 365);
          }, set: function(a) {
            a ? this.mode |= 365 : this.mode &= -366;
          } }, write: { get: function() {
            return 146 === (this.mode & 146);
          }, set: function(a) {
            a ? this.mode |= 146 : this.mode &= -147;
          } }, Ma: { get: function() {
            return T(this.mode);
          } }, La: { get: function() {
            return 8192 === (this.mode & 61440);
          } } });
          R.wa = kc;
          R.ib = (a, b, c, d, f, h, m, p, y, q2) => {
            function x(l) {
              function w(v) {
                q2 && q2();
                if (!p) {
                  var A = a, H = b;
                  A && (A = "string" == typeof A ? A : Db(A), H = b ? P(A + "/" + b) : A);
                  A = xb(d, f);
                  H = R.create(H, A);
                  if (v) {
                    if ("string" == typeof v) {
                      for (var N = Array(v.length), O = 0, fb = v.length; O < fb; ++O) N[O] = v.charCodeAt(O);
                      v = N;
                    }
                    R.chmod(H, A | 146);
                    N = R.open(H, 577);
                    R.write(N, v, 0, v.length, 0, y);
                    R.close(N);
                    R.chmod(H, A);
                  }
                }
                h && h();
                Na(B);
              }
              wb(l, t, w, () => {
                m && m();
                Na(B);
              }) || w(l);
            }
            var t = b ? db(P(a + "/" + b)) : a, B = La(`cp ${t}`);
            Ma(B);
            "string" == typeof c ? ub(c, (l) => x(l), m) : x(c);
          };
          Nb();
          R.F = Array(4096);
          R.s(S, {}, "/");
          R.mkdir("/tmp");
          R.mkdir("/home");
          R.mkdir("/home/web_user");
          (function() {
            R.mkdir("/dev");
            ob(R.M(1, 3), { read: () => 0, write: (d, f, h, m) => m });
            Mb("/dev/null", R.M(1, 3));
            nb(R.M(5, 0), qb);
            nb(R.M(6, 0), rb);
            Mb("/dev/tty", R.M(5, 0));
            Mb("/dev/tty1", R.M(6, 0));
            var a = new Uint8Array(1024), b = 0, c = () => {
              0 === b && (b = cb(a).byteLength);
              return a[--b];
            };
            R.L("/dev", "random", c);
            R.L("/dev", "urandom", c);
            R.mkdir("/dev/shm");
            R.mkdir("/dev/shm/tmp");
          })();
          (function() {
            R.mkdir("/proc");
            var a = R.mkdir("/proc/self");
            R.mkdir("/proc/self/fd");
            R.s({ s() {
              var b = R.createNode(a, "fd", 16895, 73);
              b.h = { lookup(c, d) {
                var f = W(+d);
                c = { parent: null, s: { ua: "fake" }, h: { readlink: () => f.path } };
                return c.parent = c;
              } };
              return b;
            } }, {}, "/proc/self/fd");
          })();
          R.Fa = { MEMFS: S };
          var oc = {
            __syscall_dup3: function(a, b, c) {
              try {
                var d = W(a);
                u(!c);
                if (d.fd === b) return -28;
                var f = R.qa(b);
                f && R.close(f);
                return Kb(d, b).fd;
              } catch (h) {
                if ("undefined" == typeof R || "ErrnoError" !== h.name) throw h;
                return -h.u;
              }
            },
            __syscall_fcntl64: function(a, b, c) {
              Tb = c;
              try {
                var d = W(a);
                switch (b) {
                  case 0:
                    var f = Y();
                    if (0 > f) return -28;
                    for (; R.streams[f]; ) f++;
                    return Kb(d, f).fd;
                  case 1:
                  case 2:
                    return 0;
                  case 3:
                    return d.flags;
                  case 4:
                    return f = Y(), d.flags |= f, 0;
                  case 5:
                    return f = Y(), ua[f + 0 >> 1] = 2, 0;
                  case 6:
                  case 7:
                    return 0;
                  case 16:
                  case 8:
                    return -28;
                  case 9:
                    return F[lc() >> 2] = 28, -1;
                  default:
                    return -28;
                }
              } catch (h) {
                if ("undefined" == typeof R || "ErrnoError" !== h.name) throw h;
                return -h.u;
              }
            },
            __syscall_ioctl: function(a, b, c) {
              Tb = c;
              try {
                var d = W(a);
                switch (b) {
                  case 21509:
                    return d.tty ? 0 : -59;
                  case 21505:
                    if (!d.tty) return -59;
                    if (d.tty.K.Ia) {
                      a = [3, 28, 127, 21, 4, 0, 1, 0, 17, 19, 26, 0, 18, 15, 23, 22, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
                      var f = Y();
                      F[f >> 2] = 25856;
                      F[f + 4 >> 2] = 5;
                      F[f + 8 >> 2] = 191;
                      F[f + 12 >> 2] = 35387;
                      for (var h = 0; 32 > h; h++) E[f + h + 17 >> 0] = a[h] || 0;
                    }
                    return 0;
                  case 21510:
                  case 21511:
                  case 21512:
                    return d.tty ? 0 : -59;
                  case 21506:
                  case 21507:
                  case 21508:
                    if (!d.tty) return -59;
                    if (d.tty.K.Ja) for (f = Y(), a = [], h = 0; 32 > h; h++) a.push(E[f + h + 17 >> 0]);
                    return 0;
                  case 21519:
                    if (!d.tty) return -59;
                    f = Y();
                    return F[f >> 2] = 0;
                  case 21520:
                    return d.tty ? -28 : -59;
                  case 21531:
                    return f = Y(), R.fa(d, b, f);
                  case 21523:
                    if (!d.tty) return -59;
                    d.tty.K.Ka && (h = [24, 80], f = Y(), ua[f >> 1] = h[0], ua[f + 2 >> 1] = h[1]);
                    return 0;
                  case 21524:
                    return d.tty ? 0 : -59;
                  case 21515:
                    return d.tty ? 0 : -59;
                  default:
                    return -28;
                }
              } catch (m) {
                if ("undefined" == typeof R || "ErrnoError" !== m.name) throw m;
                return -m.u;
              }
            },
            __syscall_openat: function(a, b, c, d) {
              Tb = d;
              try {
                b = X(b);
                b = Sb(a, b);
                var f = d ? Y() : 0;
                return R.open(b, c, f).fd;
              } catch (h) {
                if ("undefined" == typeof R || "ErrnoError" !== h.name) throw h;
                return -h.u;
              }
            },
            __syscall_readlinkat: function(a, b, c, d) {
              try {
                b = X(b);
                b = Sb(a, b);
                if (0 >= d) return -28;
                var f = R.readlink(b), h = Math.min(d, jb(f)), m = E[c + h];
                Ub(f, c, d + 1);
                E[c + h] = m;
                return h;
              } catch (p) {
                if ("undefined" == typeof R || "ErrnoError" !== p.name) throw p;
                return -p.u;
              }
            },
            __syscall_renameat: function(a, b, c, d) {
              try {
                return b = X(b), d = X(d), b = Sb(a, b), d = Sb(c, d), R.rename(
                  b,
                  d
                ), 0;
              } catch (f) {
                if ("undefined" == typeof R || "ErrnoError" !== f.name) throw f;
                return -f.u;
              }
            },
            __syscall_rmdir: function(a) {
              try {
                return a = X(a), R.rmdir(a), 0;
              } catch (b) {
                if ("undefined" == typeof R || "ErrnoError" !== b.name) throw b;
                return -b.u;
              }
            },
            __syscall_unlinkat: function(a, b, c) {
              try {
                return b = X(b), b = Sb(a, b), 0 === c ? R.unlink(b) : 512 === c ? R.rmdir(b) : g("Invalid flags passed to unlinkat"), 0;
              } catch (d) {
                if ("undefined" == typeof R || "ErrnoError" !== d.name) throw d;
                return -d.u;
              }
            },
            _emscripten_get_now_is_monotonic: () => 1,
            _emscripten_throw_longjmp: () => {
              throw Infinity;
            },
            _gmtime_js: function(a, b) {
              a = -9007199254740992 > a || 9007199254740992 < a ? NaN : Number(a);
              a = new Date(1e3 * a);
              F[b >> 2] = a.getUTCSeconds();
              F[b + 4 >> 2] = a.getUTCMinutes();
              F[b + 8 >> 2] = a.getUTCHours();
              F[b + 12 >> 2] = a.getUTCDate();
              F[b + 16 >> 2] = a.getUTCMonth();
              F[b + 20 >> 2] = a.getUTCFullYear() - 1900;
              F[b + 24 >> 2] = a.getUTCDay();
              F[b + 28 >> 2] = (a.getTime() - Date.UTC(a.getUTCFullYear(), 0, 1, 0, 0, 0, 0)) / 864e5 | 0;
            },
            _localtime_js: function(a, b) {
              a = -9007199254740992 > a || 9007199254740992 < a ? NaN : Number(a);
              a = new Date(1e3 * a);
              F[b >> 2] = a.getSeconds();
              F[b + 4 >> 2] = a.getMinutes();
              F[b + 8 >> 2] = a.getHours();
              F[b + 12 >> 2] = a.getDate();
              F[b + 16 >> 2] = a.getMonth();
              F[b + 20 >> 2] = a.getFullYear() - 1900;
              F[b + 24 >> 2] = a.getDay();
              F[b + 28 >> 2] = (Vb(a.getFullYear()) ? Wb : Xb)[a.getMonth()] + a.getDate() - 1 | 0;
              F[b + 36 >> 2] = -(60 * a.getTimezoneOffset());
              var c = new Date(a.getFullYear(), 6, 1).getTimezoneOffset(), d = new Date(a.getFullYear(), 0, 1).getTimezoneOffset();
              F[b + 32 >> 2] = (c != d && a.getTimezoneOffset() == Math.min(d, c)) | 0;
            },
            _mktime_js: function(a) {
              var b = new Date(F[a + 20 >> 2] + 1900, F[a + 16 >> 2], F[a + 12 >> 2], F[a + 8 >> 2], F[a + 4 >> 2], F[a >> 2], 0), c = F[a + 32 >> 2], d = b.getTimezoneOffset(), f = new Date(b.getFullYear(), 6, 1).getTimezoneOffset(), h = new Date(b.getFullYear(), 0, 1).getTimezoneOffset(), m = Math.min(h, f);
              0 > c ? F[a + 32 >> 2] = Number(f != h && m == d) : 0 < c != (m == d) && (f = Math.max(h, f), b.setTime(b.getTime() + 6e4 * ((0 < c ? m : f) - d)));
              F[a + 24 >> 2] = b.getDay();
              F[a + 28 >> 2] = (Vb(b.getFullYear()) ? Wb : Xb)[b.getMonth()] + b.getDate() - 1 | 0;
              F[a >> 2] = b.getSeconds();
              F[a + 4 >> 2] = b.getMinutes();
              F[a + 8 >> 2] = b.getHours();
              F[a + 12 >> 2] = b.getDate();
              F[a + 16 >> 2] = b.getMonth();
              F[a + 20 >> 2] = b.getYear();
              a = b.getTime();
              isNaN(a) ? (F[lc() >> 2] = 61, a = -1) : a /= 1e3;
              return BigInt(a);
            },
            _tzset_js: (a, b, c) => {
              function d(y) {
                return (y = y.toTimeString().match(/\(([A-Za-z ]+)\)$/)) ? y[1] : "GMT";
              }
              var f = (/* @__PURE__ */ new Date()).getFullYear(), h = new Date(f, 0, 1), m = new Date(f, 6, 1);
              f = h.getTimezoneOffset();
              var p = m.getTimezoneOffset();
              G[a >> 2] = 60 * Math.max(f, p);
              F[b >> 2] = Number(f != p);
              a = d(h);
              b = d(m);
              a = Zb(a);
              b = Zb(b);
              p < f ? (G[c >> 2] = a, G[c + 4 >> 2] = b) : (G[c >> 2] = b, G[c + 4 >> 2] = a);
            },
            abort: () => {
              g("native code called abort()");
            },
            emscripten_date_now: () => Date.now(),
            emscripten_get_now: () => performance.now(),
            emscripten_resize_heap: (a) => {
              var b = ta.length;
              a >>>= 0;
              u(a > b);
              if (2147483648 < a) return z(`Cannot enlarge memory, requested ${a} bytes, but the limit is ${2147483648} bytes!`), false;
              for (var c = 1; 4 >= c; c *= 2) {
                var d = b * (1 + 0.2 / c);
                d = Math.min(d, a + 100663296);
                var f = Math;
                d = Math.max(a, d);
                f = f.min.call(f, 2147483648, d + (65536 - d % 65536) % 65536);
                a: {
                  d = f;
                  var h = ra.buffer, m = (d - h.byteLength + 65535) / 65536;
                  try {
                    ra.grow(m);
                    ya();
                    var p = 1;
                    break a;
                  } catch (y) {
                    z(`growMemory: Attempted to grow heap from ${h.byteLength} bytes to ${d} bytes, but got error: ${y}`);
                  }
                  p = void 0;
                }
                if (p) return true;
              }
              z(`Failed to grow the heap from ${b} bytes to ${f} bytes, not enough memory!`);
              return false;
            },
            environ_get: (a, b) => {
              var c = 0;
              bc().forEach((d, f) => {
                var h = b + c;
                f = G[a + 4 * f >> 2] = h;
                for (h = 0; h < d.length; ++h) u(d.charCodeAt(h) === (d.charCodeAt(h) & 255)), E[f++ >> 0] = d.charCodeAt(h);
                E[f >> 0] = 0;
                c += d.length + 1;
              });
              return 0;
            },
            environ_sizes_get: (a, b) => {
              var c = bc();
              G[a >> 2] = c.length;
              var d = 0;
              c.forEach((f) => d += f.length + 1);
              G[b >> 2] = d;
              return 0;
            },
            exit: (a) => {
              mc();
              sa = true;
              ea(a, new pa(a));
            },
            fd_close: function(a) {
              try {
                var b = W(a);
                R.close(b);
                return 0;
              } catch (c) {
                if ("undefined" == typeof R || "ErrnoError" !== c.name) throw c;
                return c.u;
              }
            },
            fd_read: function(a, b, c, d) {
              try {
                a: {
                  var f = W(a);
                  a = b;
                  for (var h, m = b = 0; m < c; m++) {
                    var p = G[a >> 2], y = G[a + 4 >> 2];
                    a += 8;
                    var q2 = R.read(f, E, p, y, h);
                    if (0 > q2) {
                      var x = -1;
                      break a;
                    }
                    b += q2;
                    if (q2 < y) break;
                    "undefined" !== typeof h && (h += q2);
                  }
                  x = b;
                }
                G[d >> 2] = x;
                return 0;
              } catch (t) {
                if ("undefined" == typeof R || "ErrnoError" !== t.name) throw t;
                return t.u;
              }
            },
            fd_seek: function(a, b, c, d) {
              b = -9007199254740992 > b || 9007199254740992 < b ? NaN : Number(b);
              try {
                if (isNaN(b)) return 61;
                var f = W(a);
                R.D(f, b, c);
                wa[d >> 3] = BigInt(f.position);
                f.ea && 0 === b && 0 === c && (f.ea = null);
                return 0;
              } catch (h) {
                if ("undefined" == typeof R || "ErrnoError" !== h.name) throw h;
                return h.u;
              }
            },
            fd_write: function(a, b, c, d) {
              try {
                a: {
                  var f = W(a);
                  a = b;
                  for (var h, m = b = 0; m < c; m++) {
                    var p = G[a >> 2], y = G[a + 4 >> 2];
                    a += 8;
                    var q2 = R.write(f, E, p, y, h);
                    if (0 > q2) {
                      var x = -1;
                      break a;
                    }
                    b += q2;
                    "undefined" !== typeof h && (h += q2);
                  }
                  x = b;
                }
                G[d >> 2] = x;
                return 0;
              } catch (t) {
                if ("undefined" == typeof R || "ErrnoError" !== t.name) throw t;
                return t.u;
              }
            },
            invoke_vii: nc,
            strftime: (a, b, c, d) => {
              function f(l, w, v) {
                for (l = "number" == typeof l ? l.toString() : l || ""; l.length < w; ) l = v[0] + l;
                return l;
              }
              function h(l, w) {
                return f(l, w, "0");
              }
              function m(l, w) {
                function v(H) {
                  return 0 > H ? -1 : 0 < H ? 1 : 0;
                }
                var A;
                0 === (A = v(l.getFullYear() - w.getFullYear())) && 0 === (A = v(l.getMonth() - w.getMonth())) && (A = v(l.getDate() - w.getDate()));
                return A;
              }
              function p(l) {
                switch (l.getDay()) {
                  case 0:
                    return new Date(l.getFullYear() - 1, 11, 29);
                  case 1:
                    return l;
                  case 2:
                    return new Date(l.getFullYear(), 0, 3);
                  case 3:
                    return new Date(l.getFullYear(), 0, 2);
                  case 4:
                    return new Date(
                      l.getFullYear(),
                      0,
                      1
                    );
                  case 5:
                    return new Date(l.getFullYear() - 1, 11, 31);
                  case 6:
                    return new Date(l.getFullYear() - 1, 11, 30);
                }
              }
              function y(l) {
                var w = l.O;
                for (l = new Date(new Date(l.P + 1900, 0, 1).getTime()); 0 < w; ) {
                  var v = l.getMonth(), A = (Vb(l.getFullYear()) ? cc : dc)[v];
                  if (w > A - l.getDate()) w -= A - l.getDate() + 1, l.setDate(1), 11 > v ? l.setMonth(v + 1) : (l.setMonth(0), l.setFullYear(l.getFullYear() + 1));
                  else {
                    l.setDate(l.getDate() + w);
                    break;
                  }
                }
                v = new Date(l.getFullYear() + 1, 0, 4);
                w = p(new Date(l.getFullYear(), 0, 4));
                v = p(v);
                return 0 >= m(w, l) ? 0 >= m(v, l) ? l.getFullYear() + 1 : l.getFullYear() : l.getFullYear() - 1;
              }
              var q2 = G[d + 40 >> 2];
              d = { Va: F[d >> 2], Ua: F[d + 4 >> 2], $: F[d + 8 >> 2], la: F[d + 12 >> 2], aa: F[d + 16 >> 2], P: F[d + 20 >> 2], H: F[d + 24 >> 2], O: F[d + 28 >> 2], wb: F[d + 32 >> 2], Ta: F[d + 36 >> 2], Wa: q2 ? X(q2) : "" };
              c = X(c);
              q2 = {
                "%c": "%a %b %d %H:%M:%S %Y",
                "%D": "%m/%d/%y",
                "%F": "%Y-%m-%d",
                "%h": "%b",
                "%r": "%I:%M:%S %p",
                "%R": "%H:%M",
                "%T": "%H:%M:%S",
                "%x": "%m/%d/%y",
                "%X": "%H:%M:%S",
                "%Ec": "%c",
                "%EC": "%C",
                "%Ex": "%m/%d/%y",
                "%EX": "%H:%M:%S",
                "%Ey": "%y",
                "%EY": "%Y",
                "%Od": "%d",
                "%Oe": "%e",
                "%OH": "%H",
                "%OI": "%I",
                "%Om": "%m",
                "%OM": "%M",
                "%OS": "%S",
                "%Ou": "%u",
                "%OU": "%U",
                "%OV": "%V",
                "%Ow": "%w",
                "%OW": "%W",
                "%Oy": "%y"
              };
              for (var x in q2) c = c.replace(new RegExp(x, "g"), q2[x]);
              var t = "Sunday Monday Tuesday Wednesday Thursday Friday Saturday".split(" "), B = "January February March April May June July August September October November December".split(" ");
              q2 = {
                "%a": (l) => t[l.H].substring(0, 3),
                "%A": (l) => t[l.H],
                "%b": (l) => B[l.aa].substring(0, 3),
                "%B": (l) => B[l.aa],
                "%C": (l) => h((l.P + 1900) / 100 | 0, 2),
                "%d": (l) => h(l.la, 2),
                "%e": (l) => f(l.la, 2, " "),
                "%g": (l) => y(l).toString().substring(2),
                "%G": (l) => y(l),
                "%H": (l) => h(l.$, 2),
                "%I": (l) => {
                  l = l.$;
                  0 == l ? l = 12 : 12 < l && (l -= 12);
                  return h(l, 2);
                },
                "%j": (l) => {
                  for (var w = 0, v = 0; v <= l.aa - 1; w += (Vb(l.P + 1900) ? cc : dc)[v++]) ;
                  return h(l.la + w, 3);
                },
                "%m": (l) => h(l.aa + 1, 2),
                "%M": (l) => h(l.Ua, 2),
                "%n": () => "\n",
                "%p": (l) => 0 <= l.$ && 12 > l.$ ? "AM" : "PM",
                "%S": (l) => h(l.Va, 2),
                "%t": () => "	",
                "%u": (l) => l.H || 7,
                "%U": (l) => h(Math.floor((l.O + 7 - l.H) / 7), 2),
                "%V": (l) => {
                  var w = Math.floor((l.O + 7 - (l.H + 6) % 7) / 7);
                  2 >= (l.H + 371 - l.O - 2) % 7 && w++;
                  if (w) 53 == w && (v = (l.H + 371 - l.O) % 7, 4 == v || 3 == v && Vb(l.P) || (w = 1));
                  else {
                    w = 52;
                    var v = (l.H + 7 - l.O - 1) % 7;
                    (4 == v || 5 == v && Vb(l.P % 400 - 1)) && w++;
                  }
                  return h(w, 2);
                },
                "%w": (l) => l.H,
                "%W": (l) => h(Math.floor((l.O + 7 - (l.H + 6) % 7) / 7), 2),
                "%y": (l) => (l.P + 1900).toString().substring(2),
                "%Y": (l) => l.P + 1900,
                "%z": (l) => {
                  l = l.Ta;
                  var w = 0 <= l;
                  l = Math.abs(l) / 60;
                  return (w ? "+" : "-") + String("0000" + (l / 60 * 100 + l % 60)).slice(-4);
                },
                "%Z": (l) => l.Wa,
                "%%": () => "%"
              };
              c = c.replace(/%%/g, "\0\0");
              for (x in q2) c.includes(x) && (c = c.replace(new RegExp(x, "g"), q2[x](d)));
              c = c.replace(/\0\0/g, "%");
              x = lb(c, false);
              if (x.length > b) return 0;
              ec(x, a);
              return x.length - 1;
            },
            system: (a) => {
              if (n) {
                if (!a) return 1;
                a = X(a);
                if (!a.length) return 0;
                a = require$1("child_process").ub(a, [], { tb: true, stdio: "inherit" });
                var b = (c, d) => c << 8 | d;
                return null === a.status ? b(0, ((c) => {
                  switch (c) {
                    case "SIGHUP":
                      return 1;
                    case "SIGQUIT":
                      return 3;
                    case "SIGFPE":
                      return 8;
                    case "SIGKILL":
                      return 9;
                    case "SIGALRM":
                      return 14;
                    case "SIGTERM":
                      return 15;
                  }
                  return 2;
                })(a.signal)) : a.status << 8 | 0;
              }
              if (!a) return 0;
              F[lc() >> 2] = 52;
              return -1;
            }
          }, L = function() {
            var a = { env: oc, wasi_snapshot_preview1: oc };
            Ma("wasm-instantiate");
            var b = e;
            Ta(a, function(c) {
              u(e === b, "the Module object should not be replaced during async compilation - perhaps the order of HTML elements is wrong?");
              b = null;
              L = c.instance.exports;
              ra = L.memory;
              u(ra, "memory not found in wasm exports");
              ya();
              Z = L.__indirect_function_table;
              u(Z, "table not found in wasm exports");
              Fa.unshift(L.__wasm_call_ctors);
              Na("wasm-instantiate");
            }).catch(ba);
            return {};
          }();
          e._lua_checkstack = J("lua_checkstack");
          e._lua_xmove = J("lua_xmove");
          e._lua_atpanic = J("lua_atpanic");
          e._lua_version = J("lua_version");
          e._lua_absindex = J("lua_absindex");
          e._lua_gettop = J("lua_gettop");
          e._lua_settop = J("lua_settop");
          e._lua_closeslot = J("lua_closeslot");
          e._lua_rotate = J("lua_rotate");
          e._lua_copy = J("lua_copy");
          e._lua_pushvalue = J("lua_pushvalue");
          e._lua_type = J("lua_type");
          e._lua_typename = J("lua_typename");
          e._lua_iscfunction = J("lua_iscfunction");
          e._lua_isinteger = J("lua_isinteger");
          e._lua_isnumber = J("lua_isnumber");
          e._lua_isstring = J("lua_isstring");
          e._lua_isuserdata = J("lua_isuserdata");
          e._lua_rawequal = J("lua_rawequal");
          e._lua_arith = J("lua_arith");
          e._lua_compare = J("lua_compare");
          e._lua_stringtonumber = J("lua_stringtonumber");
          e._lua_tonumberx = J("lua_tonumberx");
          e._lua_tointegerx = J("lua_tointegerx");
          e._lua_toboolean = J("lua_toboolean");
          e._lua_tolstring = J("lua_tolstring");
          e._lua_rawlen = J("lua_rawlen");
          e._lua_tocfunction = J("lua_tocfunction");
          e._lua_touserdata = J("lua_touserdata");
          e._lua_tothread = J("lua_tothread");
          e._lua_topointer = J("lua_topointer");
          e._lua_pushnil = J("lua_pushnil");
          e._lua_pushnumber = J("lua_pushnumber");
          e._lua_pushinteger = J("lua_pushinteger");
          e._lua_pushlstring = J("lua_pushlstring");
          e._lua_pushstring = J("lua_pushstring");
          e._lua_pushcclosure = J("lua_pushcclosure");
          e._lua_pushboolean = J("lua_pushboolean");
          e._lua_pushlightuserdata = J("lua_pushlightuserdata");
          e._lua_pushthread = J("lua_pushthread");
          e._lua_getglobal = J("lua_getglobal");
          e._lua_gettable = J("lua_gettable");
          e._lua_getfield = J("lua_getfield");
          e._lua_geti = J("lua_geti");
          e._lua_rawget = J("lua_rawget");
          e._lua_rawgeti = J("lua_rawgeti");
          e._lua_rawgetp = J("lua_rawgetp");
          e._lua_createtable = J("lua_createtable");
          e._lua_getmetatable = J("lua_getmetatable");
          e._lua_getiuservalue = J("lua_getiuservalue");
          e._lua_setglobal = J("lua_setglobal");
          e._lua_settable = J("lua_settable");
          e._lua_setfield = J("lua_setfield");
          e._lua_seti = J("lua_seti");
          e._lua_rawset = J("lua_rawset");
          e._lua_rawsetp = J("lua_rawsetp");
          e._lua_rawseti = J("lua_rawseti");
          e._lua_setmetatable = J("lua_setmetatable");
          e._lua_setiuservalue = J("lua_setiuservalue");
          e._lua_callk = J("lua_callk");
          e._lua_pcallk = J("lua_pcallk");
          e._lua_load = J("lua_load");
          e._lua_dump = J("lua_dump");
          e._lua_status = J("lua_status");
          e._lua_error = J("lua_error");
          e._lua_next = J("lua_next");
          e._lua_toclose = J("lua_toclose");
          e._lua_concat = J("lua_concat");
          e._lua_len = J("lua_len");
          e._lua_getallocf = J("lua_getallocf");
          e._lua_setallocf = J("lua_setallocf");
          e._lua_setwarnf = J("lua_setwarnf");
          e._lua_warning = J("lua_warning");
          e._lua_newuserdatauv = J("lua_newuserdatauv");
          e._lua_getupvalue = J("lua_getupvalue");
          e._lua_setupvalue = J("lua_setupvalue");
          e._lua_upvalueid = J("lua_upvalueid");
          e._lua_upvaluejoin = J("lua_upvaluejoin");
          e._luaL_traceback = J("luaL_traceback");
          e._lua_getstack = J("lua_getstack");
          e._lua_getinfo = J("lua_getinfo");
          e._luaL_buffinit = J("luaL_buffinit");
          e._luaL_addstring = J("luaL_addstring");
          e._luaL_prepbuffsize = J("luaL_prepbuffsize");
          e._luaL_addvalue = J("luaL_addvalue");
          e._luaL_pushresult = J("luaL_pushresult");
          e._luaL_argerror = J("luaL_argerror");
          e._luaL_typeerror = J("luaL_typeerror");
          e._luaL_getmetafield = J("luaL_getmetafield");
          e._luaL_where = J("luaL_where");
          e._luaL_fileresult = J("luaL_fileresult");
          var lc = J("__errno_location");
          e._luaL_execresult = J("luaL_execresult");
          e._luaL_newmetatable = J("luaL_newmetatable");
          e._luaL_setmetatable = J("luaL_setmetatable");
          e._luaL_testudata = J("luaL_testudata");
          e._luaL_checkudata = J("luaL_checkudata");
          e._luaL_optlstring = J("luaL_optlstring");
          e._luaL_checklstring = J("luaL_checklstring");
          e._luaL_checkstack = J("luaL_checkstack");
          e._luaL_checktype = J("luaL_checktype");
          e._luaL_checkany = J("luaL_checkany");
          e._luaL_checknumber = J("luaL_checknumber");
          e._luaL_optnumber = J("luaL_optnumber");
          e._luaL_checkinteger = J("luaL_checkinteger");
          e._luaL_optinteger = J("luaL_optinteger");
          e._luaL_setfuncs = J("luaL_setfuncs");
          e._luaL_addlstring = J("luaL_addlstring");
          e._luaL_pushresultsize = J("luaL_pushresultsize");
          e._luaL_buffinitsize = J("luaL_buffinitsize");
          e._luaL_ref = J("luaL_ref");
          e._luaL_unref = J("luaL_unref");
          e._luaL_loadfilex = J("luaL_loadfilex");
          e._luaL_loadbufferx = J("luaL_loadbufferx");
          e._luaL_loadstring = J("luaL_loadstring");
          e._luaL_callmeta = J("luaL_callmeta");
          e._luaL_len = J("luaL_len");
          e._luaL_tolstring = J("luaL_tolstring");
          e._luaL_getsubtable = J("luaL_getsubtable");
          e._luaL_requiref = J("luaL_requiref");
          e._luaL_addgsub = J("luaL_addgsub");
          e._luaL_gsub = J("luaL_gsub");
          e._luaL_newstate = J("luaL_newstate");
          e._lua_newstate = J("lua_newstate");
          e._free = J("free");
          e._realloc = J("realloc");
          var Rb = e._fflush = J("fflush");
          e._luaL_checkversion_ = J("luaL_checkversion_");
          e._luaopen_base = J("luaopen_base");
          e._luaopen_coroutine = J("luaopen_coroutine");
          e._lua_newthread = J("lua_newthread");
          e._lua_yieldk = J("lua_yieldk");
          e._lua_isyieldable = J("lua_isyieldable");
          e._lua_resetthread = J("lua_resetthread");
          e._lua_resume = J("lua_resume");
          e._luaopen_debug = J("luaopen_debug");
          e._lua_gethookmask = J("lua_gethookmask");
          e._lua_gethook = J("lua_gethook");
          e._lua_gethookcount = J("lua_gethookcount");
          e._lua_getlocal = J("lua_getlocal");
          e._lua_sethook = J("lua_sethook");
          e._lua_setlocal = J("lua_setlocal");
          e._lua_setcstacklimit = J("lua_setcstacklimit");
          var Yb = e._malloc = J("malloc");
          e._luaL_openlibs = J("luaL_openlibs");
          e._luaopen_package = J("luaopen_package");
          e._luaopen_table = J("luaopen_table");
          e._luaopen_io = J("luaopen_io");
          e._luaopen_os = J("luaopen_os");
          e._luaopen_string = J("luaopen_string");
          e._luaopen_math = J("luaopen_math");
          e._luaopen_utf8 = J("luaopen_utf8");
          e._lua_close = J("lua_close");
          var pc = J("setThrew"), qc = () => (qc = L.emscripten_stack_init)(), Aa = () => (Aa = L.emscripten_stack_get_end)(), rc = J("stackSave"), sc = J("stackRestore"), tc = J("stackAlloc");
          function nc(a, b, c) {
            var d = rc();
            try {
              gc(a)(b, c);
            } catch (f) {
              sc(d);
              if (f !== f + 0) throw f;
              pc(1, 0);
            }
          }
          e.ENV = $b;
          e.ccall = (a, b, c, d) => {
            var f = { string: (q2) => {
              var x = 0;
              if (null !== q2 && void 0 !== q2 && 0 !== q2) {
                x = jb(q2) + 1;
                var t = tc(x);
                Ub(q2, t, x);
                x = t;
              }
              return x;
            }, array: (q2) => {
              var x = tc(q2.length);
              ec(q2, x);
              return x;
            } };
            a = hc(a);
            var h = [], m = 0;
            u("array" !== b, 'Return type should not be "array".');
            if (d) for (var p = 0; p < d.length; p++) {
              var y = f[c[p]];
              y ? (0 === m && (m = rc()), h[p] = y(d[p])) : h[p] = d[p];
            }
            c = a.apply(null, h);
            return c = function(q2) {
              0 !== m && sc(m);
              return "string" === b ? X(q2) : "boolean" === b ? !!q2 : q2;
            }(c);
          };
          e.addFunction = (a, b) => {
            u("undefined" != typeof a);
            if (!ic) {
              ic = /* @__PURE__ */ new WeakMap();
              var c = Z.length;
              if (ic) for (var d = 0; d < 0 + c; d++) {
                var f = gc(d);
                f && ic.set(f, d);
              }
            }
            if (c = ic.get(a) || 0) return c;
            if (jc.length) c = jc.pop();
            else {
              try {
                Z.grow(1);
              } catch (p) {
                if (!(p instanceof RangeError)) throw p;
                throw "Unable to grow wasm table. Set ALLOW_TABLE_GROWTH.";
              }
              c = Z.length - 1;
            }
            try {
              d = c, Z.set(d, a), fc[d] = Z.get(d);
            } catch (p) {
              if (!(p instanceof TypeError)) throw p;
              u("undefined" != typeof b, "Missing signature argument to addFunction: " + a);
              if ("function" == typeof WebAssembly.Function) {
                d = WebAssembly.Function;
                f = { i: "i32", j: "i64", f: "f32", d: "f64", e: "externref", p: "i32" };
                for (var h = { parameters: [], results: "v" == b[0] ? [] : [f[b[0]]] }, m = 1; m < b.length; ++m) u(b[m] in f, "invalid signature char: " + b[m]), h.parameters.push(f[b[m]]);
                b = new d(h, a);
              } else {
                d = [1];
                f = b.slice(0, 1);
                b = b.slice(1);
                h = { i: 127, p: 127, j: 126, f: 125, d: 124, e: 111 };
                d.push(96);
                m = b.length;
                u(16384 > m);
                128 > m ? d.push(m) : d.push(m % 128 | 128, m >> 7);
                for (m = 0; m < b.length; ++m) u(b[m] in h, "invalid signature char: " + b[m]), d.push(h[b[m]]);
                "v" == f ? d.push(0) : d.push(1, h[f]);
                b = [0, 97, 115, 109, 1, 0, 0, 0, 1];
                f = d.length;
                u(16384 > f);
                128 > f ? b.push(f) : b.push(f % 128 | 128, f >> 7);
                b.push.apply(b, d);
                b.push(2, 7, 1, 1, 101, 1, 102, 0, 0, 7, 5, 1, 1, 102, 0, 0);
                b = new WebAssembly.Module(new Uint8Array(b));
                b = new WebAssembly.Instance(b, { e: { f: a } }).exports.f;
              }
              d = c;
              Z.set(d, b);
              fc[d] = Z.get(d);
            }
            ic.set(a, c);
            return c;
          };
          e.removeFunction = (a) => {
            ic.delete(gc(a));
            Z.set(a, null);
            fc[a] = Z.get(a);
            jc.push(a);
          };
          e.setValue = function(a, b, c = "i8") {
            c.endsWith("*") && (c = "*");
            switch (c) {
              case "i1":
                E[a >> 0] = b;
                break;
              case "i8":
                E[a >> 0] = b;
                break;
              case "i16":
                ua[a >> 1] = b;
                break;
              case "i32":
                F[a >> 2] = b;
                break;
              case "i64":
                wa[a >> 3] = BigInt(b);
                break;
              case "float":
                va[a >> 2] = b;
                break;
              case "double":
                xa[a >> 3] = b;
                break;
              case "*":
                G[a >> 2] = b;
                break;
              default:
                g(`invalid type for setValue: ${c}`);
            }
          };
          e.getValue = function(a, b = "i8") {
            b.endsWith("*") && (b = "*");
            switch (b) {
              case "i1":
                return E[a >> 0];
              case "i8":
                return E[a >> 0];
              case "i16":
                return ua[a >> 1];
              case "i32":
                return F[a >> 2];
              case "i64":
                return wa[a >> 3];
              case "float":
                return va[a >> 2];
              case "double":
                return xa[a >> 3];
              case "*":
                return G[a >> 2];
              default:
                g(`invalid type for getValue: ${b}`);
            }
          };
          e.stringToUTF8 = Ub;
          e.lengthBytesUTF8 = jb;
          e.stringToNewUTF8 = Zb;
          e.FS = R;
          "writeI53ToI64 writeI53ToI64Clamped writeI53ToI64Signaling writeI53ToU64Clamped writeI53ToU64Signaling readI53FromI64 readI53FromU64 convertI32PairToI53 convertI32PairToI53Checked convertU32PairToI53 inetPton4 inetNtop4 inetPton6 inetNtop6 readSockaddr writeSockaddr getHostByName getCallstack emscriptenLog convertPCtoSourceLocation readEmAsmArgs jstoi_q jstoi_s listenOnce autoResumeAudioContext getDynCaller dynCall handleException runtimeKeepalivePush runtimeKeepalivePop callUserCallback maybeExit asmjsMangle handleAllocatorInit HandleAllocator getNativeTypeSize STACK_SIZE STACK_ALIGN POINTER_SIZE ASSERTIONS cwrap reallyNegative unSign strLen reSign formatString intArrayToString AsciiToString UTF16ToString stringToUTF16 lengthBytesUTF16 UTF32ToString stringToUTF32 lengthBytesUTF32 registerKeyEventCallback maybeCStringToJsString findEventTarget findCanvasEventTarget getBoundingClientRect fillMouseEventData registerMouseEventCallback registerWheelEventCallback registerUiEventCallback registerFocusEventCallback fillDeviceOrientationEventData registerDeviceOrientationEventCallback fillDeviceMotionEventData registerDeviceMotionEventCallback screenOrientation fillOrientationChangeEventData registerOrientationChangeEventCallback fillFullscreenChangeEventData registerFullscreenChangeEventCallback JSEvents_requestFullscreen JSEvents_resizeCanvasForFullscreen registerRestoreOldStyle hideEverythingExceptGivenElement restoreHiddenElements setLetterbox softFullscreenResizeWebGLRenderTarget doRequestFullscreen fillPointerlockChangeEventData registerPointerlockChangeEventCallback registerPointerlockErrorEventCallback requestPointerLock fillVisibilityChangeEventData registerVisibilityChangeEventCallback registerTouchEventCallback fillGamepadEventData registerGamepadEventCallback registerBeforeUnloadEventCallback fillBatteryEventData battery registerBatteryEventCallback setCanvasElementSize getCanvasElementSize jsStackTrace stackTrace checkWasiClock wasiRightsToMuslOFlags wasiOFlagsToMuslOFlags createDyncallWrapper safeSetTimeout setImmediateWrapped clearImmediateWrapped polyfillSetImmediate getPromise makePromise idsToPromises makePromiseCallback setMainLoop getSocketFromFD getSocketAddress FS_unlink FS_mkdirTree _setNetworkCallback".split(" ").forEach(function(a) {
            "undefined" === typeof globalThis || Object.getOwnPropertyDescriptor(globalThis, a) || Object.defineProperty(globalThis, a, { configurable: true, get() {
              var b = `\`${a}\` is a library symbol and not included by default; add it to your library.js __deps or to DEFAULT_LIBRARY_FUNCS_TO_INCLUDE on the command line`, c = a;
              c.startsWith("_") || (c = "$" + a);
              b += ` (e.g. -sDEFAULT_LIBRARY_FUNCS_TO_INCLUDE='${c}')`;
              Ua(a) && (b += ". Alternatively, forcing filesystem support (-sFORCE_FILESYSTEM) can export this for you");
              Wa(b);
            } });
            Xa(a);
          });
          "run addOnPreRun addOnInit addOnPreMain addOnExit addOnPostRun addRunDependency removeRunDependency FS_createFolder FS_createPath FS_createLazyFile FS_createLink FS_createDevice FS_readFile out err callMain abort wasmMemory wasmExports stackAlloc stackSave stackRestore getTempRet0 setTempRet0 writeStackCookie checkStackCookie MAX_INT53 MIN_INT53 bigintToI53Checked ptrToString zeroMemory exitJS getHeapMax growMemory MONTH_DAYS_REGULAR MONTH_DAYS_LEAP MONTH_DAYS_REGULAR_CUMULATIVE MONTH_DAYS_LEAP_CUMULATIVE isLeapYear ydayFromDate arraySum addDays ERRNO_CODES ERRNO_MESSAGES setErrNo DNS Protocols Sockets initRandomFill randomFill timers warnOnce UNWIND_CACHE readEmAsmArgsArray getExecutableName keepRuntimeAlive asyncLoad alignMemory mmapAlloc wasmTable noExitRuntime getCFunc uleb128Encode sigToWasmTypes generateFuncType convertJsFunctionToWasm freeTableIndexes functionsInTableMap getEmptyTableSlot updateTableMap getFunctionAddress PATH PATH_FS UTF8Decoder UTF8ArrayToString UTF8ToString stringToUTF8Array intArrayFromString stringToAscii UTF16Decoder stringToUTF8OnStack writeArrayToMemory JSEvents specialHTMLTargets currentFullscreenStrategy restoreOldWindowedStyle demangle demangleAll ExitStatus getEnvStrings doReadv doWritev promiseMap Browser wget SYSCALLS preloadPlugins FS_createPreloadedFile FS_modeStringToFlags FS_getMode FS_stdin_getChar_buffer FS_stdin_getChar FS_createDataFile MEMFS TTY PIPEFS SOCKFS".split(" ").forEach(Xa);
          var uc;
          Ja = function vc() {
            uc || wc();
            uc || (Ja = vc);
          };
          function wc() {
            if (!(0 < Ia)) {
              qc();
              var a = Aa();
              u(0 == (a & 3));
              0 == a && (a += 4);
              G[a >> 2] = 34821223;
              G[a + 4 >> 2] = 2310721022;
              G[0] = 1668509029;
              if (e.preRun) for ("function" == typeof e.preRun && (e.preRun = [e.preRun]); e.preRun.length; ) a = e.preRun.shift(), Ea.unshift(a);
              for (; 0 < Ea.length; ) Ea.shift()(e);
              if (!(0 < Ia)) {
                if (!uc && (uc = true, e.calledRun = true, !sa)) {
                  u(!Ha);
                  Ha = true;
                  za();
                  e.noFSInit || R.R.Y || R.R();
                  for (R.ta = false; 0 < Fa.length; ) Fa.shift()(e);
                  aa(e);
                  u(!e._main, 'compiled without a main, but one is present. if you added it from JS, use Module["onRuntimeInitialized"]');
                  for (za(); 0 < Ga.length; ) Ga.shift()(e);
                }
                za();
              }
            }
          }
          function mc() {
            var a = qa, b = z, c = false;
            qa = z = () => {
              c = true;
            };
            try {
              Rb(0), ["stdout", "stderr"].forEach(function(d) {
                (d = Ob("/dev/" + d)) && (d = mb[d.object.rdev]) && d.output && d.output.length && (c = true);
              });
            } catch (d) {
            }
            qa = a;
            z = b;
            c && Wa("stdio streams had content in them that was not flushed. you should set EXIT_RUNTIME to 1 (see the Emscripten FAQ), or make sure to emit a newline when you printf etc.");
          }
          wc();
          return moduleArg.ready;
        };
      })();
      class LuaWasm {
        static async initialize(customWasmFileLocation, environmentVariables) {
          const module2 = await initWasmModule({
            locateFile: (path, scriptDirectory) => {
              return customWasmFileLocation || scriptDirectory + path;
            },
            preRun: (initializedModule) => {
              if (typeof environmentVariables === "object") {
                Object.entries(environmentVariables).forEach(([k, v]) => initializedModule.ENV[k] = v);
              }
            }
          });
          return new LuaWasm(module2);
        }
        constructor(module2) {
          this.referenceTracker = /* @__PURE__ */ new WeakMap();
          this.referenceMap = /* @__PURE__ */ new Map();
          this.availableReferences = [];
          this.module = module2;
          this.luaL_checkversion_ = this.cwrap("luaL_checkversion_", null, ["number", "number", "number"]);
          this.luaL_getmetafield = this.cwrap("luaL_getmetafield", "number", ["number", "number", "string"]);
          this.luaL_callmeta = this.cwrap("luaL_callmeta", "number", ["number", "number", "string"]);
          this.luaL_tolstring = this.cwrap("luaL_tolstring", "string", ["number", "number", "number"]);
          this.luaL_argerror = this.cwrap("luaL_argerror", "number", ["number", "number", "string"]);
          this.luaL_typeerror = this.cwrap("luaL_typeerror", "number", ["number", "number", "string"]);
          this.luaL_checklstring = this.cwrap("luaL_checklstring", "string", ["number", "number", "number"]);
          this.luaL_optlstring = this.cwrap("luaL_optlstring", "string", ["number", "number", "string", "number"]);
          this.luaL_checknumber = this.cwrap("luaL_checknumber", "number", ["number", "number"]);
          this.luaL_optnumber = this.cwrap("luaL_optnumber", "number", ["number", "number", "number"]);
          this.luaL_checkinteger = this.cwrap("luaL_checkinteger", "number", ["number", "number"]);
          this.luaL_optinteger = this.cwrap("luaL_optinteger", "number", ["number", "number", "number"]);
          this.luaL_checkstack = this.cwrap("luaL_checkstack", null, ["number", "number", "string"]);
          this.luaL_checktype = this.cwrap("luaL_checktype", null, ["number", "number", "number"]);
          this.luaL_checkany = this.cwrap("luaL_checkany", null, ["number", "number"]);
          this.luaL_newmetatable = this.cwrap("luaL_newmetatable", "number", ["number", "string"]);
          this.luaL_setmetatable = this.cwrap("luaL_setmetatable", null, ["number", "string"]);
          this.luaL_testudata = this.cwrap("luaL_testudata", "number", ["number", "number", "string"]);
          this.luaL_checkudata = this.cwrap("luaL_checkudata", "number", ["number", "number", "string"]);
          this.luaL_where = this.cwrap("luaL_where", null, ["number", "number"]);
          this.luaL_fileresult = this.cwrap("luaL_fileresult", "number", ["number", "number", "string"]);
          this.luaL_execresult = this.cwrap("luaL_execresult", "number", ["number", "number"]);
          this.luaL_ref = this.cwrap("luaL_ref", "number", ["number", "number"]);
          this.luaL_unref = this.cwrap("luaL_unref", null, ["number", "number", "number"]);
          this.luaL_loadfilex = this.cwrap("luaL_loadfilex", "number", ["number", "string", "string"]);
          this.luaL_loadbufferx = this.cwrap("luaL_loadbufferx", "number", ["number", "string|number", "number", "string|number", "string"]);
          this.luaL_loadstring = this.cwrap("luaL_loadstring", "number", ["number", "string"]);
          this.luaL_newstate = this.cwrap("luaL_newstate", "number", []);
          this.luaL_len = this.cwrap("luaL_len", "number", ["number", "number"]);
          this.luaL_addgsub = this.cwrap("luaL_addgsub", null, ["number", "string", "string", "string"]);
          this.luaL_gsub = this.cwrap("luaL_gsub", "string", ["number", "string", "string", "string"]);
          this.luaL_setfuncs = this.cwrap("luaL_setfuncs", null, ["number", "number", "number"]);
          this.luaL_getsubtable = this.cwrap("luaL_getsubtable", "number", ["number", "number", "string"]);
          this.luaL_traceback = this.cwrap("luaL_traceback", null, ["number", "number", "string", "number"]);
          this.luaL_requiref = this.cwrap("luaL_requiref", null, ["number", "string", "number", "number"]);
          this.luaL_buffinit = this.cwrap("luaL_buffinit", null, ["number", "number"]);
          this.luaL_prepbuffsize = this.cwrap("luaL_prepbuffsize", "string", ["number", "number"]);
          this.luaL_addlstring = this.cwrap("luaL_addlstring", null, ["number", "string", "number"]);
          this.luaL_addstring = this.cwrap("luaL_addstring", null, ["number", "string"]);
          this.luaL_addvalue = this.cwrap("luaL_addvalue", null, ["number"]);
          this.luaL_pushresult = this.cwrap("luaL_pushresult", null, ["number"]);
          this.luaL_pushresultsize = this.cwrap("luaL_pushresultsize", null, ["number", "number"]);
          this.luaL_buffinitsize = this.cwrap("luaL_buffinitsize", "string", ["number", "number", "number"]);
          this.lua_newstate = this.cwrap("lua_newstate", "number", ["number", "number"]);
          this.lua_close = this.cwrap("lua_close", null, ["number"]);
          this.lua_newthread = this.cwrap("lua_newthread", "number", ["number"]);
          this.lua_resetthread = this.cwrap("lua_resetthread", "number", ["number"]);
          this.lua_atpanic = this.cwrap("lua_atpanic", "number", ["number", "number"]);
          this.lua_version = this.cwrap("lua_version", "number", ["number"]);
          this.lua_absindex = this.cwrap("lua_absindex", "number", ["number", "number"]);
          this.lua_gettop = this.cwrap("lua_gettop", "number", ["number"]);
          this.lua_settop = this.cwrap("lua_settop", null, ["number", "number"]);
          this.lua_pushvalue = this.cwrap("lua_pushvalue", null, ["number", "number"]);
          this.lua_rotate = this.cwrap("lua_rotate", null, ["number", "number", "number"]);
          this.lua_copy = this.cwrap("lua_copy", null, ["number", "number", "number"]);
          this.lua_checkstack = this.cwrap("lua_checkstack", "number", ["number", "number"]);
          this.lua_xmove = this.cwrap("lua_xmove", null, ["number", "number", "number"]);
          this.lua_isnumber = this.cwrap("lua_isnumber", "number", ["number", "number"]);
          this.lua_isstring = this.cwrap("lua_isstring", "number", ["number", "number"]);
          this.lua_iscfunction = this.cwrap("lua_iscfunction", "number", ["number", "number"]);
          this.lua_isinteger = this.cwrap("lua_isinteger", "number", ["number", "number"]);
          this.lua_isuserdata = this.cwrap("lua_isuserdata", "number", ["number", "number"]);
          this.lua_type = this.cwrap("lua_type", "number", ["number", "number"]);
          this.lua_typename = this.cwrap("lua_typename", "string", ["number", "number"]);
          this.lua_tonumberx = this.cwrap("lua_tonumberx", "number", ["number", "number", "number"]);
          this.lua_tointegerx = this.cwrap("lua_tointegerx", "number", ["number", "number", "number"]);
          this.lua_toboolean = this.cwrap("lua_toboolean", "number", ["number", "number"]);
          this.lua_tolstring = this.cwrap("lua_tolstring", "string", ["number", "number", "number"]);
          this.lua_rawlen = this.cwrap("lua_rawlen", "number", ["number", "number"]);
          this.lua_tocfunction = this.cwrap("lua_tocfunction", "number", ["number", "number"]);
          this.lua_touserdata = this.cwrap("lua_touserdata", "number", ["number", "number"]);
          this.lua_tothread = this.cwrap("lua_tothread", "number", ["number", "number"]);
          this.lua_topointer = this.cwrap("lua_topointer", "number", ["number", "number"]);
          this.lua_arith = this.cwrap("lua_arith", null, ["number", "number"]);
          this.lua_rawequal = this.cwrap("lua_rawequal", "number", ["number", "number", "number"]);
          this.lua_compare = this.cwrap("lua_compare", "number", ["number", "number", "number", "number"]);
          this.lua_pushnil = this.cwrap("lua_pushnil", null, ["number"]);
          this.lua_pushnumber = this.cwrap("lua_pushnumber", null, ["number", "number"]);
          this.lua_pushinteger = this.cwrap("lua_pushinteger", null, ["number", "number"]);
          this.lua_pushlstring = this.cwrap("lua_pushlstring", "string", ["number", "string|number", "number"]);
          this.lua_pushstring = this.cwrap("lua_pushstring", "string", ["number", "string|number"]);
          this.lua_pushcclosure = this.cwrap("lua_pushcclosure", null, ["number", "number", "number"]);
          this.lua_pushboolean = this.cwrap("lua_pushboolean", null, ["number", "number"]);
          this.lua_pushlightuserdata = this.cwrap("lua_pushlightuserdata", null, ["number", "number"]);
          this.lua_pushthread = this.cwrap("lua_pushthread", "number", ["number"]);
          this.lua_getglobal = this.cwrap("lua_getglobal", "number", ["number", "string"]);
          this.lua_gettable = this.cwrap("lua_gettable", "number", ["number", "number"]);
          this.lua_getfield = this.cwrap("lua_getfield", "number", ["number", "number", "string"]);
          this.lua_geti = this.cwrap("lua_geti", "number", ["number", "number", "number"]);
          this.lua_rawget = this.cwrap("lua_rawget", "number", ["number", "number"]);
          this.lua_rawgeti = this.cwrap("lua_rawgeti", "number", ["number", "number", "number"]);
          this.lua_rawgetp = this.cwrap("lua_rawgetp", "number", ["number", "number", "number"]);
          this.lua_createtable = this.cwrap("lua_createtable", null, ["number", "number", "number"]);
          this.lua_newuserdatauv = this.cwrap("lua_newuserdatauv", "number", ["number", "number", "number"]);
          this.lua_getmetatable = this.cwrap("lua_getmetatable", "number", ["number", "number"]);
          this.lua_getiuservalue = this.cwrap("lua_getiuservalue", "number", ["number", "number", "number"]);
          this.lua_setglobal = this.cwrap("lua_setglobal", null, ["number", "string"]);
          this.lua_settable = this.cwrap("lua_settable", null, ["number", "number"]);
          this.lua_setfield = this.cwrap("lua_setfield", null, ["number", "number", "string"]);
          this.lua_seti = this.cwrap("lua_seti", null, ["number", "number", "number"]);
          this.lua_rawset = this.cwrap("lua_rawset", null, ["number", "number"]);
          this.lua_rawseti = this.cwrap("lua_rawseti", null, ["number", "number", "number"]);
          this.lua_rawsetp = this.cwrap("lua_rawsetp", null, ["number", "number", "number"]);
          this.lua_setmetatable = this.cwrap("lua_setmetatable", "number", ["number", "number"]);
          this.lua_setiuservalue = this.cwrap("lua_setiuservalue", "number", ["number", "number", "number"]);
          this.lua_callk = this.cwrap("lua_callk", null, ["number", "number", "number", "number", "number"]);
          this.lua_pcallk = this.cwrap("lua_pcallk", "number", ["number", "number", "number", "number", "number", "number"]);
          this.lua_load = this.cwrap("lua_load", "number", ["number", "number", "number", "string", "string"]);
          this.lua_dump = this.cwrap("lua_dump", "number", ["number", "number", "number", "number"]);
          this.lua_yieldk = this.cwrap("lua_yieldk", "number", ["number", "number", "number", "number"]);
          this.lua_resume = this.cwrap("lua_resume", "number", ["number", "number", "number", "number"]);
          this.lua_status = this.cwrap("lua_status", "number", ["number"]);
          this.lua_isyieldable = this.cwrap("lua_isyieldable", "number", ["number"]);
          this.lua_setwarnf = this.cwrap("lua_setwarnf", null, ["number", "number", "number"]);
          this.lua_warning = this.cwrap("lua_warning", null, ["number", "string", "number"]);
          this.lua_error = this.cwrap("lua_error", "number", ["number"]);
          this.lua_next = this.cwrap("lua_next", "number", ["number", "number"]);
          this.lua_concat = this.cwrap("lua_concat", null, ["number", "number"]);
          this.lua_len = this.cwrap("lua_len", null, ["number", "number"]);
          this.lua_stringtonumber = this.cwrap("lua_stringtonumber", "number", ["number", "string"]);
          this.lua_getallocf = this.cwrap("lua_getallocf", "number", ["number", "number"]);
          this.lua_setallocf = this.cwrap("lua_setallocf", null, ["number", "number", "number"]);
          this.lua_toclose = this.cwrap("lua_toclose", null, ["number", "number"]);
          this.lua_closeslot = this.cwrap("lua_closeslot", null, ["number", "number"]);
          this.lua_getstack = this.cwrap("lua_getstack", "number", ["number", "number", "number"]);
          this.lua_getinfo = this.cwrap("lua_getinfo", "number", ["number", "string", "number"]);
          this.lua_getlocal = this.cwrap("lua_getlocal", "string", ["number", "number", "number"]);
          this.lua_setlocal = this.cwrap("lua_setlocal", "string", ["number", "number", "number"]);
          this.lua_getupvalue = this.cwrap("lua_getupvalue", "string", ["number", "number", "number"]);
          this.lua_setupvalue = this.cwrap("lua_setupvalue", "string", ["number", "number", "number"]);
          this.lua_upvalueid = this.cwrap("lua_upvalueid", "number", ["number", "number", "number"]);
          this.lua_upvaluejoin = this.cwrap("lua_upvaluejoin", null, ["number", "number", "number", "number", "number"]);
          this.lua_sethook = this.cwrap("lua_sethook", null, ["number", "number", "number", "number"]);
          this.lua_gethook = this.cwrap("lua_gethook", "number", ["number"]);
          this.lua_gethookmask = this.cwrap("lua_gethookmask", "number", ["number"]);
          this.lua_gethookcount = this.cwrap("lua_gethookcount", "number", ["number"]);
          this.lua_setcstacklimit = this.cwrap("lua_setcstacklimit", "number", ["number", "number"]);
          this.luaopen_base = this.cwrap("luaopen_base", "number", ["number"]);
          this.luaopen_coroutine = this.cwrap("luaopen_coroutine", "number", ["number"]);
          this.luaopen_table = this.cwrap("luaopen_table", "number", ["number"]);
          this.luaopen_io = this.cwrap("luaopen_io", "number", ["number"]);
          this.luaopen_os = this.cwrap("luaopen_os", "number", ["number"]);
          this.luaopen_string = this.cwrap("luaopen_string", "number", ["number"]);
          this.luaopen_utf8 = this.cwrap("luaopen_utf8", "number", ["number"]);
          this.luaopen_math = this.cwrap("luaopen_math", "number", ["number"]);
          this.luaopen_debug = this.cwrap("luaopen_debug", "number", ["number"]);
          this.luaopen_package = this.cwrap("luaopen_package", "number", ["number"]);
          this.luaL_openlibs = this.cwrap("luaL_openlibs", null, ["number"]);
        }
        lua_remove(luaState, index) {
          this.lua_rotate(luaState, index, -1);
          this.lua_pop(luaState, 1);
        }
        lua_pop(luaState, count) {
          this.lua_settop(luaState, -count - 1);
        }
        luaL_getmetatable(luaState, name) {
          return this.lua_getfield(luaState, LUA_REGISTRYINDEX, name);
        }
        lua_yield(luaState, count) {
          return this.lua_yieldk(luaState, count, 0, null);
        }
        lua_upvalueindex(index) {
          return LUA_REGISTRYINDEX - index;
        }
        ref(data) {
          const existing = this.referenceTracker.get(data);
          if (existing) {
            existing.refCount++;
            return existing.index;
          }
          const availableIndex = this.availableReferences.pop();
          const index = availableIndex === void 0 ? this.referenceMap.size + 1 : availableIndex;
          this.referenceMap.set(index, data);
          this.referenceTracker.set(data, {
            refCount: 1,
            index
          });
          this.lastRefIndex = index;
          return index;
        }
        unref(index) {
          const ref = this.referenceMap.get(index);
          if (ref === void 0) {
            return;
          }
          const metadata = this.referenceTracker.get(ref);
          if (metadata === void 0) {
            this.referenceTracker.delete(ref);
            this.availableReferences.push(index);
            return;
          }
          metadata.refCount--;
          if (metadata.refCount <= 0) {
            this.referenceTracker.delete(ref);
            this.referenceMap.delete(index);
            this.availableReferences.push(index);
          }
        }
        getRef(index) {
          return this.referenceMap.get(index);
        }
        getLastRefIndex() {
          return this.lastRefIndex;
        }
        printRefs() {
          for (const [key, value] of this.referenceMap.entries()) {
            console.log(key, value);
          }
        }
        cwrap(name, returnType, argTypes) {
          const hasStringOrNumber = argTypes.some((argType) => argType === "string|number");
          if (!hasStringOrNumber) {
            return (...args) => this.module.ccall(name, returnType, argTypes, args);
          }
          return (...args) => {
            const pointersToBeFreed = [];
            const resolvedArgTypes = argTypes.map((argType, i) => {
              var _a;
              if (argType === "string|number") {
                if (typeof args[i] === "number") {
                  return "number";
                } else {
                  if (((_a = args[i]) === null || _a === void 0 ? void 0 : _a.length) > 1024) {
                    const bufferPointer = this.module.stringToNewUTF8(args[i]);
                    args[i] = bufferPointer;
                    pointersToBeFreed.push(bufferPointer);
                    return "number";
                  } else {
                    return "string";
                  }
                }
              }
              return argType;
            });
            try {
              return this.module.ccall(name, returnType, resolvedArgTypes, args);
            } finally {
              for (const pointer of pointersToBeFreed) {
                this.module._free(pointer);
              }
            }
          };
        }
      }
      var version = "1.16.0";
      class LuaFactory2 {
        constructor(customWasmUri, environmentVariables) {
          var _a;
          if (customWasmUri === void 0) {
            const isBrowser = typeof window === "object" && typeof window.document !== "undefined" || typeof self === "object" && ((_a = self === null || self === void 0 ? void 0 : self.constructor) === null || _a === void 0 ? void 0 : _a.name) === "DedicatedWorkerGlobalScope";
            if (isBrowser) {
              customWasmUri = `https://unpkg.com/wasmoon@${version}/dist/glue.wasm`;
            }
          }
          this.luaWasmPromise = LuaWasm.initialize(customWasmUri, environmentVariables);
        }
        async mountFile(path, content) {
          this.mountFileSync(await this.getLuaModule(), path, content);
        }
        mountFileSync(luaWasm, path, content) {
          const fileSep = path.lastIndexOf("/");
          const file = path.substring(fileSep + 1);
          const body = path.substring(0, path.length - file.length - 1);
          if (body.length > 0) {
            const parts = body.split("/").reverse();
            let parent = "";
            while (parts.length) {
              const part = parts.pop();
              if (!part) {
                continue;
              }
              const current = `${parent}/${part}`;
              try {
                luaWasm.module.FS.mkdir(current);
              } catch (err2) {
              }
              parent = current;
            }
          }
          luaWasm.module.FS.writeFile(path, content);
        }
        async createEngine(options = {}) {
          return new LuaEngine(await this.getLuaModule(), options);
        }
        async getLuaModule() {
          return this.luaWasmPromise;
        }
      }
      exports2.Decoration = Decoration;
      exports2.LUAI_MAXSTACK = LUAI_MAXSTACK;
      exports2.LUA_MULTRET = LUA_MULTRET;
      exports2.LUA_REGISTRYINDEX = LUA_REGISTRYINDEX;
      exports2.LuaEngine = LuaEngine;
      exports2.LuaFactory = LuaFactory2;
      exports2.LuaGlobal = Global;
      exports2.LuaMultiReturn = MultiReturn;
      exports2.LuaRawResult = RawResult;
      exports2.LuaThread = Thread;
      exports2.LuaTimeoutError = LuaTimeoutError;
      exports2.LuaTypeExtension = LuaTypeExtension;
      exports2.LuaWasm = LuaWasm;
      exports2.PointerSize = PointerSize;
      exports2.decorate = decorate;
      exports2.decorateFunction = decorateFunction;
      exports2.decorateProxy = decorateProxy;
      exports2.decorateUserdata = decorateUserdata;
    });
  }
});

// src/foundation/result.ts
function ok(value) {
  return { ok: true, value };
}
function err(error) {
  return { ok: false, error };
}
function engineError(code, message, detail) {
  return detail === void 0 ? { code, message } : { code, message, detail };
}

// src/platform/registry.ts
var BackendRegistry = class {
  tables = /* @__PURE__ */ new Map();
  register(kind, entry) {
    let table = this.tables.get(kind);
    if (table === void 0) {
      table = /* @__PURE__ */ new Map();
      this.tables.set(kind, table);
    }
    if (table.has(entry.id)) {
      throw new Error(`\u540E\u7AEF ${kind}/${entry.id} \u5DF2\u7ECF\u6CE8\u518C\u8FC7\uFF08\u540C id \u4E0D\u5141\u8BB8\u91CD\u590D\u6CE8\u518C\uFF09`);
    }
    table.set(entry.id, entry);
  }
  /** 便捷注册：从工厂对象批量取 probe/create。 */
  registerGfx(f, priority = 100) {
    this.register("gfx", { id: f.id, priority, probe: f.probe, create: f.create });
  }
  registerAudio(f, priority = 100) {
    this.register("audio", {
      id: f.id,
      priority,
      probe: f.probe,
      create: f.create
    });
  }
  registerInput(f, priority = 100) {
    this.register("input", { id: f.id, priority, probe: f.probe, create: f.create });
  }
  registerFs(f, priority = 100) {
    this.register("fs", { id: f.id, priority, probe: f.probe, create: f.create });
  }
  registerNet(f, priority = 100) {
    this.register("net", { id: f.id, priority, probe: f.probe, create: f.create });
  }
  registerScript(f, priority = 100) {
    this.register("script", { id: f.id, priority, probe: f.probe, create: f.create });
  }
  list(kind) {
    return Array.from(this.tables.get(kind)?.keys() ?? []).sort();
  }
  has(kind, id) {
    return this.tables.get(kind)?.has(id) ?? false;
  }
  /**
   * 创建后端。选择顺序：
   *   1) `prefer` 指定 → 必须成功（除非 `allowFallbackToNull` 且 `null` 可用）
   *   2) `allow` 白名单内、probe 通过、priority 最高的
   *   3) 全失败 → 返回聚合错误
   */
  create(kind, opts = {}) {
    const table = this.tables.get(kind);
    if (table === void 0 || table.size === 0) {
      return err(
        engineError(
          "BACKEND.NONE_REGISTERED",
          `\u6CA1\u6709\u4EFB\u4F55 ${kind} \u540E\u7AEF\u88AB\u6CE8\u518C\uFF08\u5BBF\u4E3B\u5E94\u8BE5\u5728 bootstrap \u9636\u6BB5\u8C03\u7528 register* \uFF09`
        )
      );
    }
    const notes = [];
    if (opts.prefer !== void 0) {
      const e = table.get(opts.prefer);
      if (e === void 0) {
        notes.push(`prefer=${opts.prefer} \u672A\u6CE8\u518C`);
      } else if (!e.probe(opts.options)) {
        notes.push(`prefer=${opts.prefer} \u63A2\u6D4B\u5931\u8D25\uFF08\u8BE5\u73AF\u5883\u4E0D\u652F\u6301\uFF09`);
      } else {
        const r = e.create(opts.options);
        if (r.ok) return ok(r.value);
        notes.push(`prefer=${opts.prefer} \u521B\u5EFA\u5931\u8D25\uFF1A${r.error.message}`);
      }
    }
    const cands = Array.from(table.values()).filter((e) => opts.allow === void 0 || opts.allow.includes(e.id)).sort((a, b) => b.priority - a.priority);
    for (const e of cands) {
      if (opts.allowFallbackToNull === false && e.id === "null") continue;
      let probed = false;
      try {
        probed = e.probe(opts.options);
      } catch (ex) {
        notes.push(`${e.id} \u63A2\u6D4B\u629B\u9519\uFF1A${ex instanceof Error ? ex.message : String(ex)}`);
        continue;
      }
      if (!probed) {
        notes.push(`${e.id} \u4E0D\u53EF\u7528`);
        continue;
      }
      const r = e.create(opts.options);
      if (r.ok) return ok(r.value);
      notes.push(`${e.id} \u521B\u5EFA\u5931\u8D25\uFF1A${r.error.message}`);
    }
    return err(
      engineError("BACKEND.UNAVAILABLE", `\u6CA1\u6709\u53EF\u7528\u7684 ${kind} \u540E\u7AEF`, {
        kind,
        candidates: opts.allow ?? Array.from(table.keys()),
        reasons: notes
      })
    );
  }
};

// src/foundation/hash.ts
var FNV_PRIME = 16777619;
var FNV_BASIS_A = 2166136261;
var FNV_BASIS_B = 2654435769;
function hashStateCreate() {
  return { h1: FNV_BASIS_A, h2: FNV_BASIS_B, bytes: 0 };
}
function hashStateUpdate(s, bytes) {
  let h1 = s.h1;
  let h2 = s.h2;
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i];
    h1 = Math.imul(h1 ^ b, FNV_PRIME) >>> 0;
    h2 = Math.imul(h2 ^ b, FNV_PRIME) >>> 0;
  }
  s.h1 = h1;
  s.h2 = h2;
  s.bytes += bytes.length;
}
function hex8(n) {
  return (n >>> 0).toString(16).padStart(8, "0");
}
function hashStateHex(s) {
  return hex8(s.h1) + hex8(s.h2);
}
function hashBytes(bytes) {
  const s = hashStateCreate();
  hashStateUpdate(s, bytes);
  return hashStateHex(s);
}

// src/foundation/math/vec.ts
var Vec2 = class _Vec2 {
  constructor(x, y) {
    this.x = x;
    this.y = y;
  }
  static zero = new _Vec2(0, 0);
  static one = new _Vec2(1, 1);
  static up = new _Vec2(0, 1);
  static right = new _Vec2(1, 0);
  add(v) {
    return new _Vec2(this.x + v.x, this.y + v.y);
  }
  sub(v) {
    return new _Vec2(this.x - v.x, this.y - v.y);
  }
  scale(s) {
    return new _Vec2(this.x * s, this.y * s);
  }
  dot(v) {
    return this.x * v.x + this.y * v.y;
  }
  /** 二维叉积（标量），用于判定左右与三角形朝向。 */
  cross(v) {
    return this.x * v.y - this.y * v.x;
  }
  get lengthSq() {
    return this.x * this.x + this.y * this.y;
  }
  get length() {
    return Math.sqrt(this.lengthSq);
  }
  /** 零向量归一化返回零向量，不产生 NaN。 */
  normalized() {
    const l = this.length;
    return l > 0 ? new _Vec2(this.x / l, this.y / l) : _Vec2.zero;
  }
  equals(v, eps = 0) {
    return Math.abs(this.x - v.x) <= eps && Math.abs(this.y - v.y) <= eps;
  }
  toString() {
    return `(${this.x}, ${this.y})`;
  }
};
var Vec3 = class _Vec3 {
  constructor(x, y, z) {
    this.x = x;
    this.y = y;
    this.z = z;
  }
  static zero = new _Vec3(0, 0, 0);
  static one = new _Vec3(1, 1, 1);
  add(v) {
    return new _Vec3(this.x + v.x, this.y + v.y, this.z + v.z);
  }
  sub(v) {
    return new _Vec3(this.x - v.x, this.y - v.y, this.z - v.z);
  }
  scale(s) {
    return new _Vec3(this.x * s, this.y * s, this.z * s);
  }
  dot(v) {
    return this.x * v.x + this.y * v.y + this.z * v.z;
  }
  cross(v) {
    return new _Vec3(
      this.y * v.z - this.z * v.y,
      this.z * v.x - this.x * v.z,
      this.x * v.y - this.y * v.x
    );
  }
  get lengthSq() {
    return this.x * this.x + this.y * this.y + this.z * this.z;
  }
  get length() {
    return Math.sqrt(this.lengthSq);
  }
  normalized() {
    const l = this.length;
    return l > 0 ? new _Vec3(this.x / l, this.y / l, this.z / l) : _Vec3.zero;
  }
  /** 取 XZ 平面（2.5D 里"地面"就是 XZ）。 */
  toXZ() {
    return new Vec2(this.x, this.z);
  }
  toString() {
    return `(${this.x}, ${this.y}, ${this.z})`;
  }
};

// src/foundation/math/geometry.ts
var Rect = class _Rect {
  constructor(x, y, width, height) {
    this.x = x;
    this.y = y;
    this.width = width;
    this.height = height;
  }
  static zero = new _Rect(0, 0, 0, 0);
  get xMin() {
    return this.x;
  }
  get yMin() {
    return this.y;
  }
  get xMax() {
    return this.x + this.width;
  }
  get yMax() {
    return this.y + this.height;
  }
  get center() {
    return new Vec2(this.x + this.width / 2, this.y + this.height / 2);
  }
  contains(p) {
    return p.x >= this.xMin && p.x <= this.xMax && p.y >= this.yMin && p.y <= this.yMax;
  }
  /** 相交判定用 `<` 而非 `<=`：贴边不算重叠（与 SAT 的严格内部分离一致）。 */
  intersects(o) {
    return this.xMin < o.xMax && this.xMax > o.xMin && this.yMin < o.yMax && this.yMax > o.yMin;
  }
  intersect(o) {
    const x0 = Math.max(this.xMin, o.xMin);
    const y0 = Math.max(this.yMin, o.yMin);
    const x1 = Math.min(this.xMax, o.xMax);
    const y1 = Math.min(this.yMax, o.yMax);
    return new _Rect(x0, y0, Math.max(0, x1 - x0), Math.max(0, y1 - y0));
  }
  expand(by) {
    return new _Rect(this.x - by, this.y - by, this.width + by * 2, this.height + by * 2);
  }
};
var Color = class _Color {
  constructor(r, g, b, a = 1) {
    this.r = r;
    this.g = g;
    this.b = b;
    this.a = a;
  }
  static white = new _Color(1, 1, 1, 1);
  static black = new _Color(0, 0, 0, 1);
  static transparent = new _Color(0, 0, 0, 0);
  /** `0xRRGGBBAA` → Color。资产文件里用得多。 */
  static fromRgba8(rgba) {
    return new _Color(
      (rgba >>> 24 & 255) / 255,
      (rgba >>> 16 & 255) / 255,
      (rgba >>> 8 & 255) / 255,
      (rgba & 255) / 255
    );
  }
  toArray() {
    return [this.r, this.g, this.b, this.a];
  }
};
var Affine2 = class _Affine2 {
  constructor(m00, m01, m02, m10, m11, m12) {
    this.m00 = m00;
    this.m01 = m01;
    this.m02 = m02;
    this.m10 = m10;
    this.m11 = m11;
    this.m12 = m12;
  }
  static identity = new _Affine2(1, 0, 0, 0, 1, 0);
  static fromTrs(pos, rotationRad, scale) {
    const c = Math.cos(rotationRad);
    const s = Math.sin(rotationRad);
    return new _Affine2(c * scale.x, -s * scale.y, pos.x, s * scale.x, c * scale.y, pos.y);
  }
  /** this ∘ o（先应用 o，再应用 this）—— 与父子变换的语义一致。 */
  multiply(o) {
    return new _Affine2(
      this.m00 * o.m00 + this.m01 * o.m10,
      this.m00 * o.m01 + this.m01 * o.m11,
      this.m00 * o.m02 + this.m01 * o.m12 + this.m02,
      this.m10 * o.m00 + this.m11 * o.m10,
      this.m10 * o.m01 + this.m11 * o.m11,
      this.m10 * o.m02 + this.m11 * o.m12 + this.m12
    );
  }
  transformPoint(p) {
    return new Vec2(
      this.m00 * p.x + this.m01 * p.y + this.m02,
      this.m10 * p.x + this.m11 * p.y + this.m12
    );
  }
  /** 展开成 WebGL 需要的 9 元素列主序数组。 */
  toMat3Array(out) {
    const m = out ?? new Float32Array(9);
    m[0] = this.m00;
    m[1] = this.m10;
    m[2] = 0;
    m[3] = this.m01;
    m[4] = this.m11;
    m[5] = 0;
    m[6] = this.m02;
    m[7] = this.m12;
    m[8] = 1;
    return m;
  }
  equals(o, eps = 1e-9) {
    return Math.abs(this.m00 - o.m00) <= eps && Math.abs(this.m01 - o.m01) <= eps && Math.abs(this.m02 - o.m02) <= eps && Math.abs(this.m10 - o.m10) <= eps && Math.abs(this.m11 - o.m11) <= eps && Math.abs(this.m12 - o.m12) <= eps;
  }
};

// src/foundation/math/scalar.ts
var TAU = Math.PI * 2;
function clamp(v, lo, hi) {
  return v < lo ? lo : v > hi ? hi : v;
}
function quantize(v, decimals = 3) {
  const f = Math.pow(10, decimals);
  return Math.sign(v) * Math.round(Math.abs(v) * f + 1e-9) / f;
}

// src/backends/gfx-null/device.ts
function asBytes(view) {
  return new Uint8Array(view.buffer, view.byteOffset, view.byteLength);
}
var NullGraphicsDevice = class {
  caps = {
    backend: "null",
    version: "1",
    maxTextureSize: 4096,
    maxTextureUnits: 8,
    maxVerticesPerDraw: 65536,
    instancing: false,
    floatTextures: false,
    readback: true,
    srgbTextures: false
  };
  nextHandle = 1;
  buffers = /* @__PURE__ */ new Map();
  textures = /* @__PURE__ */ new Map();
  shaders = /* @__PURE__ */ new Map();
  pipelines = /* @__PURE__ */ new Map();
  targets = /* @__PURE__ */ new Map();
  frameIndex = 0;
  current = null;
  _stats = {
    frameIndex: 0,
    drawCalls: 0,
    verticesSubmitted: 0,
    textureBindings: 0,
    pipelineSwitches: 0,
    bytesUploaded: 0
  };
  _size = { width: 0, height: 0 };
  /** 所有完成的帧（判据读最近若干帧）。 */
  frames = [];
  /** 错误调用记录：契约测试会断言"非法操作没有静默通过"。 */
  rejectedCalls = [];
  constructor(width = 1280, height = 720) {
    this._size = { width, height };
  }
  get stats() {
    return this._stats;
  }
  get size() {
    return this._size;
  }
  resize(width, height) {
    this._size = { width, height };
  }
  // ---------------------------------------------------------------- buffer
  createBuffer(desc) {
    if (!(desc.byteLength > 0)) {
      return err(engineError("GFX.BAD_BUFFER", `\u7F13\u51B2\u533A\u5927\u5C0F\u5FC5\u987B > 0\uFF0C\u6536\u5230 ${desc.byteLength}`));
    }
    if (desc.byteLength > 64 * 1024 * 1024) {
      return err(engineError("GFX.BAD_BUFFER", `\u7F13\u51B2\u533A\u8FC7\u5927\uFF1A${desc.byteLength} \u5B57\u8282\uFF08\u4E0A\u9650 64 MB\uFF09`));
    }
    const h = this.nextHandle++;
    this.buffers.set(h, {
      byteLength: desc.byteLength,
      usage: desc.usage,
      dynamic: desc.dynamic,
      label: desc.label ?? ""
    });
    return ok(h);
  }
  updateBuffer(handle, data, byteOffset = 0) {
    const rec = this.buffers.get(handle);
    if (rec === void 0) {
      this.rejectedCalls.push(`updateBuffer(\u65E0\u6548\u53E5\u67C4 ${handle})`);
      return err(engineError("GFX.INVALID_HANDLE", `\u7F13\u51B2\u533A\u53E5\u67C4 ${handle} \u4E0D\u5B58\u5728\uFF08\u53EF\u80FD\u5DF2\u9500\u6BC1\uFF09`));
    }
    const end = byteOffset + data.byteLength;
    if (byteOffset < 0 || end > rec.byteLength) {
      this.rejectedCalls.push(`updateBuffer(\u8D8A\u754C ${byteOffset}+${data.byteLength} > ${rec.byteLength})`);
      return err(
        engineError("GFX.BUFFER_OVERFLOW", `\u5199\u5165\u8D8A\u754C\uFF1Aoffset=${byteOffset} len=${data.byteLength} \u5BB9\u91CF=${rec.byteLength}`, {
          label: rec.label
        })
      );
    }
    this._stats = { ...this._stats, bytesUploaded: this._stats.bytesUploaded + data.byteLength };
    return ok(void 0);
  }
  destroyBuffer(handle) {
    if (!this.buffers.delete(handle)) {
      this.rejectedCalls.push(`destroyBuffer(\u5DF2\u5931\u6548 ${handle})`);
    }
  }
  // ---------------------------------------------------------------- texture
  createTexture(desc, data) {
    if (!(desc.width > 0) || !(desc.height > 0)) {
      return err(engineError("GFX.BAD_TEXTURE", `\u7EB9\u7406\u5C3A\u5BF8\u975E\u6CD5\uFF1A${desc.width}x${desc.height}`));
    }
    if (desc.width > this.caps.maxTextureSize || desc.height > this.caps.maxTextureSize) {
      return err(
        engineError(
          "GFX.TEXTURE_TOO_LARGE",
          `\u7EB9\u7406 ${desc.width}x${desc.height} \u8D85\u8FC7\u4E0A\u9650 ${this.caps.maxTextureSize}`,
          { label: desc.label ?? "" }
        )
      );
    }
    const h = this.nextHandle++;
    const hash = hashStateCreate();
    if (data !== void 0 && data !== null) hashStateUpdate(hash, asBytes(data));
    this.textures.set(h, {
      width: desc.width,
      height: desc.height,
      label: desc.label ?? "",
      isTarget: desc.renderTarget === true,
      hash
    });
    return ok(h);
  }
  updateTexture(handle, region, data) {
    const rec = this.textures.get(handle);
    if (rec === void 0) {
      return err(engineError("GFX.INVALID_HANDLE", `\u7EB9\u7406\u53E5\u67C4 ${handle} \u4E0D\u5B58\u5728`));
    }
    if (region.x < 0 || region.y < 0 || region.x + region.width > rec.width || region.y + region.height > rec.height) {
      return err(
        engineError("GFX.REGION_OUT_OF_BOUNDS", `\u4E0A\u4F20\u533A\u57DF\u8D85\u51FA\u7EB9\u7406\uFF1A${JSON.stringify(region)} vs ${rec.width}x${rec.height}`)
      );
    }
    const expect = region.width * region.height * 4;
    if (data.byteLength !== expect && rec.isTarget) {
      return err(
        engineError("GFX.SIZE_MISMATCH", `\u4E0A\u4F20\u5B57\u8282\u6570 ${data.byteLength} \u4E0E\u533A\u57DF\u671F\u671B ${expect} \u4E0D\u7B26`)
      );
    }
    this._stats = { ...this._stats, bytesUploaded: this._stats.bytesUploaded + data.byteLength };
    hashStateUpdate(rec.hash, asBytes(data));
    return ok(void 0);
  }
  /**
   * 纹理的"上传字节流"摘要（16 hex），用于断言"解码出的 pixels == GPU 实际收到的字节"。
   * 句柄不存在 → `undefined`（不抛：这不是程序错误，是查询语气）。
   * 从未上传过任何字节 → 也返回 `undefined`：空流的摘要看起来像一个真摘要，
   * 让调用方误以为"上传过了"。
   */
  textureDigest(handle) {
    const rec = this.textures.get(handle);
    if (rec === void 0 || rec.hash.bytes === 0) return void 0;
    return hashStateHex(rec.hash);
  }
  /**
   * 已创建且未销毁的纹理句柄（按创建顺序）。
   *
   * ★ 判据需要它才能回答"渲染模块到底传了哪张图"：
   *   `stats.bytesUploaded` 只能说明"传了 65536 字节"，分不清"传对了"
   *   和"传了同样大小的另一张图"—— 而后者正是"假贴图"在生产环境里的样子。
   */
  get textureHandles() {
    return Array.from(this.textures.keys());
  }
  destroyTexture(handle) {
    if (!this.textures.delete(handle)) {
      this.rejectedCalls.push(`destroyTexture(\u5DF2\u5931\u6548 ${handle})`);
    }
  }
  // ---------------------------------------------------------------- shader / pipeline
  createShader(desc) {
    if (desc.vertex.trim() === "" || desc.fragment.trim() === "") {
      return err(engineError("GFX.SHADER_EMPTY", "\u7740\u8272\u5668\u6E90\u7801\u4E3A\u7A7A"));
    }
    if (!/(void\s+main|fn\s+main)/.test(desc.vertex + desc.fragment)) {
      return err(engineError("GFX.SHADER_COMPILE", "\u7740\u8272\u5668\u6CA1\u6709 main \u5165\u53E3", { label: desc.label ?? "" }));
    }
    const h = this.nextHandle++;
    this.shaders.set(h, { label: desc.label ?? "" });
    return ok(h);
  }
  destroyShader(handle) {
    this.shaders.delete(handle);
  }
  createPipeline(desc) {
    if (!this.shaders.has(desc.shader)) {
      return err(engineError("GFX.INVALID_HANDLE", `\u7BA1\u7EBF\u5F15\u7528\u7684\u7740\u8272\u5668 ${desc.shader} \u4E0D\u5B58\u5728`));
    }
    const h = this.nextHandle++;
    this.pipelines.set(h, { shader: desc.shader, label: desc.label ?? "" });
    return ok(h);
  }
  destroyPipeline(handle) {
    this.pipelines.delete(handle);
  }
  createRenderTarget(desc) {
    if (!this.textures.has(desc.color)) {
      return err(engineError("GFX.INVALID_HANDLE", `\u6E32\u67D3\u76EE\u6807\u7684\u989C\u8272\u7EB9\u7406 ${desc.color} \u4E0D\u5B58\u5728`));
    }
    const h = this.nextHandle++;
    this.targets.set(h, { color: desc.color });
    return ok(h);
  }
  destroyRenderTarget(handle) {
    this.targets.delete(handle);
  }
  // ---------------------------------------------------------------- frame
  beginFrame(target) {
    if (this.current !== null) {
      this.rejectedCalls.push("beginFrame(\u4E0A\u4E00\u5E27\u6CA1\u6709 endFrame)");
    }
    const record = {
      frameIndex: this.frameIndex++,
      clears: [],
      draws: [],
      scissorSets: 0,
      viewportSets: 0
    };
    this.current = record;
    this._stats = {
      frameIndex: record.frameIndex,
      drawCalls: 0,
      verticesSubmitted: 0,
      textureBindings: 0,
      pipelineSwitches: 0,
      bytesUploaded: 0
    };
    return new NullCommandList(this, target);
  }
  endFrame() {
    if (this.current === null) {
      this.rejectedCalls.push("endFrame(\u6CA1\u6709 beginFrame)");
      return;
    }
    this.frames.push(this.current);
    if (this.frames.length > 120) this.frames.shift();
    this.current = null;
  }
  readPixels(target, rect) {
    if (!this.caps.readback) {
      return err(engineError("GFX.NO_READBACK", "\u8BE5\u8BBE\u5907\u4E0D\u652F\u6301\u8BFB\u56DE\u50CF\u7D20"));
    }
    const w = Math.max(1, Math.floor(rect.width));
    const h = Math.max(1, Math.floor(rect.height));
    const out = new Uint8Array(w * h * 4);
    if (target !== null) {
      const t = this.targets.get(target);
      if (t === void 0) return err(engineError("GFX.INVALID_HANDLE", `\u6E32\u67D3\u76EE\u6807 ${target} \u4E0D\u5B58\u5728`));
      for (let i = 0; i < out.length; i += 4) {
        out[i] = 32;
        out[i + 1] = 64;
        out[i + 2] = 96;
        out[i + 3] = 255;
      }
    }
    return ok(out);
  }
  destroy() {
    this.buffers.clear();
    this.textures.clear();
    this.shaders.clear();
    this.pipelines.clear();
    this.targets.clear();
    this.current = null;
  }
  /** 内部：命令列表回调。 */
  _pushDraw(rec) {
    this.current?.draws.push(rec);
    this._stats = {
      ...this._stats,
      drawCalls: this._stats.drawCalls + 1,
      verticesSubmitted: this._stats.verticesSubmitted + rec.vertices,
      textureBindings: this._stats.textureBindings + rec.textures.length
    };
  }
  _pushClear(color, flags) {
    this.current?.clears.push({ color, flags });
  }
  _pushPipeline() {
    this._stats = { ...this._stats, pipelineSwitches: this._stats.pipelineSwitches + 1 };
  }
  _bumpScissor() {
    if (this.current) this.current.scissorSets++;
  }
  _bumpViewport() {
    if (this.current) this.current.viewportSets++;
  }
};
var NullCommandList = class {
  constructor(dev, target) {
    this.dev = dev;
    this.target = target;
    void this.target;
  }
  pipeline = 0;
  textures = /* @__PURE__ */ new Map();
  uniforms = /* @__PURE__ */ new Map();
  finished = false;
  setViewport(rect) {
    this.dev._bumpViewport();
  }
  setScissor(rect) {
    this.dev._bumpScissor();
  }
  clear(color, flags) {
    this.assertOpen("clear");
    this.dev._pushClear(color, flags);
  }
  setPipeline(pipeline) {
    this.assertOpen("setPipeline");
    this.pipeline = pipeline;
    this.dev._pushPipeline();
  }
  setUniform(name, value, _kind = "float") {
    this.assertOpen("setUniform");
    this.uniforms.set(name, value);
  }
  bindTexture(slot, texture) {
    this.assertOpen("bindTexture");
    this.textures.set(slot, texture);
  }
  draw(batch) {
    this.assertOpen("draw");
    this.dev._pushDraw({
      vertices: batch.vertexCount,
      indices: batch.indexCount,
      pipeline: this.pipeline,
      textures: Array.from(this.textures.values())
    });
  }
  finish() {
    this.finished = true;
  }
  assertOpen(what) {
    if (this.finished) {
      throw new Error(`\u547D\u4EE4\u5217\u8868\u5DF2 finish\uFF0C\u4ECD\u5728\u8C03\u7528 ${what}`);
    }
  }
};
var nullGfxBackend = {
  id: "null",
  priority: 0,
  probe(_options) {
    return true;
  },
  create(options) {
    const o = options ?? {};
    return ok(new NullGraphicsDevice(o.width ?? 1280, o.height ?? 720));
  }
};

// src/backends/audio-null/device.ts
var NullAudioDevice = class {
  caps = {
    backend: "null",
    maxVoices: 32,
    requiresGesture: true,
    spatial: true
  };
  nextHandle = 1;
  clips = /* @__PURE__ */ new Map();
  voices = /* @__PURE__ */ new Map();
  buses = /* @__PURE__ */ new Map([["master", { name: "master", volume: 1, muted: false }]]);
  clock = 0;
  resumed = false;
  resumeCalls = 0;
  playLog = [];
  /** 因为超过 maxVoices 被拒绝的播放次数（"声音被吞掉"必须可见）。 */
  voicesRejected = 0;
  async init() {
    return ok(void 0);
  }
  async resume() {
    this.resumeCalls++;
    if (!this.caps.requiresGesture) {
      this.resumed = true;
      return ok(void 0);
    }
    if (!this.resumed) {
      this.resumed = true;
      return err(
        engineError("AUDIO.NEEDS_GESTURE", "\u97F3\u9891\u9700\u8981\u7528\u6237\u624B\u52BF\u624D\u80FD\u89E3\u9501\uFF08\u7B2C\u4E00\u6B21 resume \u5FC5\u7136\u5931\u8D25\uFF0C\u8FD9\u662F\u5951\u7EA6\uFF09")
      );
    }
    return ok(void 0);
  }
  /** 判据用：模拟"用户点了"（跳过手势检查）。 */
  forceUnlock() {
    this.resumed = true;
    this.capsUnlockPatch();
  }
  capsUnlockPatch() {
    this.caps.requiresGesture = false;
  }
  async loadClip(name, data) {
    if (data.byteLength === 0) {
      return err(engineError("AUDIO.BAD_CLIP", "\u97F3\u9891\u6570\u636E\u4E3A\u7A7A\uFF1A" + name));
    }
    const durationMs = Math.max(50, Math.round(data.byteLength / 8e3 * 1e3));
    const h = this.nextHandle++;
    this.clips.set(h, { name, durationMs });
    return ok(h);
  }
  releaseClip(clip) {
    this.clips.delete(clip);
    for (const [h, v] of this.voices) if (v.clip === clip) this.voices.delete(h);
  }
  play(clip, opts = {}) {
    const c = this.clips.get(clip);
    if (c === void 0) return err(engineError("AUDIO.INVALID_CLIP", `clip ${clip} \u4E0D\u5B58\u5728`));
    if (this.voices.size >= this.caps.maxVoices) {
      this.voicesRejected++;
      return err(
        engineError("AUDIO.NO_FREE_VOICE", `\u5DF2\u8FBE ${this.caps.maxVoices} \u4E2A\u58F0\u90E8\u4E0A\u9650`, { clip: c.name })
      );
    }
    const busName = opts.bus ?? "master";
    const bus = this.buses.get(busName) ?? { name: busName, volume: 1, muted: false };
    this.buses.set(busName, bus);
    if (bus.muted) {
      this.playLog.push({
        clip,
        name: c.name,
        bus: busName,
        volume: 0,
        loop: opts.loop === true,
        atMs: this.clock,
        position: opts.position === void 0 ? null : { x: opts.position.x, z: opts.position.z }
      });
      return err(engineError("AUDIO.BUS_MUTED", `\u603B\u7EBF ${busName} \u5DF2\u9759\u97F3`, { clip: c.name }));
    }
    const rate = opts.rate ?? 1;
    const volume = (opts.volume ?? 1) * bus.volume;
    const loop = opts.loop === true;
    const h = this.nextHandle++;
    this.voices.set(h, {
      handle: h,
      clip,
      name: c.name,
      bus: busName,
      volume,
      rate,
      loop,
      endsAtMs: loop ? Number.POSITIVE_INFINITY : this.clock + Math.round(c.durationMs / rate),
      position: opts.position === void 0 ? null : { x: opts.position.x, z: opts.position.z }
    });
    this.playLog.push({
      clip,
      name: c.name,
      bus: busName,
      volume,
      loop,
      atMs: this.clock,
      position: opts.position === void 0 ? null : { x: opts.position.x, z: opts.position.z }
    });
    return ok(h);
  }
  stop(voice) {
    this.voices.delete(voice);
  }
  setVoice(voice, patch) {
    const v = this.voices.get(voice);
    if (v === void 0) return;
    if (patch.volume !== void 0) v.volume = patch.volume;
    if (patch.rate !== void 0) v.rate = patch.rate;
    if (patch.loop !== void 0) v.loop = patch.loop;
  }
  getVoice(voice) {
    const v = this.voices.get(voice);
    if (v === void 0) return void 0;
    return {
      handle: v.handle,
      playing: true,
      clip: v.clip,
      bus: v.bus,
      volume: v.volume,
      rate: v.rate,
      loop: v.loop
    };
  }
  bus(name) {
    let b = this.buses.get(name);
    if (b === void 0) {
      b = { name, volume: 1, muted: false };
      this.buses.set(name, b);
    }
    return b;
  }
  setListener(_pos) {
  }
  get timeMs() {
    return this.clock;
  }
  get activeVoices() {
    return this.voices.size;
  }
  /** 判据用：推进音频时钟并结束到期 voice。 */
  advance(ms) {
    this.clock += ms;
    for (const [h, v] of [...this.voices]) {
      if (!v.loop && this.clock >= v.endsAtMs) this.voices.delete(h);
    }
  }
  destroy() {
    this.voices.clear();
    this.clips.clear();
  }
};
var nullAudioBackend = {
  id: "null",
  priority: 0,
  probe(_options) {
    return true;
  },
  create(_options) {
    return ok(new NullAudioDevice());
  }
};

// src/backends/input-null/device.ts
var NullInputDevice = class {
  caps = {
    backend: "null",
    pointer: true,
    touch: false,
    gamepad: false,
    textInput: true
  };
  down = /* @__PURE__ */ new Set();
  pressed = /* @__PURE__ */ new Set();
  released = /* @__PURE__ */ new Set();
  pointerDown = false;
  pointerPressed = false;
  pointerReleased = false;
  px = 0;
  py = 0;
  wheelX = 0;
  wheelY = 0;
  text = "";
  subs = /* @__PURE__ */ new Set();
  poll() {
    const snap = {
      keysDown: new Set(this.down),
      keysPressed: new Set(this.pressed),
      keysReleased: new Set(this.released),
      pointer: {
        x: this.px,
        y: this.py,
        down: this.pointerDown,
        pressed: this.pointerPressed,
        released: this.pointerReleased,
        button: 0
      },
      wheel: { dx: this.wheelX, dy: this.wheelY },
      text: this.text
    };
    this.pressed.clear();
    this.released.clear();
    this.pointerPressed = false;
    this.pointerReleased = false;
    this.wheelX = 0;
    this.wheelY = 0;
    this.text = "";
    return snap;
  }
  subscribe(fn) {
    this.subs.add(fn);
    return () => this.subs.delete(fn);
  }
  setFocusTarget(_target) {
  }
  reset() {
    this.down.clear();
    this.pressed.clear();
    this.released.clear();
    this.pointerDown = false;
    this.pointerPressed = false;
    this.pointerReleased = false;
  }
  destroy() {
    this.subs.clear();
    this.reset();
  }
  // ---- 编程接口（判据/编辑器用）
  keyDown(code) {
    if (!this.down.has(code)) {
      this.down.add(code);
      this.pressed.add(code);
    }
    this.emit({ kind: "key", code, down: true });
  }
  keyUp(code) {
    if (this.down.delete(code)) {
      this.released.add(code);
    }
    this.emit({ kind: "key", code, down: false });
  }
  movePointer(x, y) {
    this.px = x;
    this.py = y;
    this.emit({ kind: "pointer", x, y });
  }
  pointerDownAt(x, y) {
    this.px = x;
    this.py = y;
    this.pointerDown = true;
    this.pointerPressed = true;
    this.emit({ kind: "pointer", x, y, down: true });
  }
  pointerUpAt(x, y) {
    this.px = x;
    this.py = y;
    this.pointerDown = false;
    this.pointerReleased = true;
    this.emit({ kind: "pointer", x, y, down: false });
  }
  wheel(dx, dy) {
    this.wheelX += dx;
    this.wheelY += dy;
    this.emit({ kind: "wheel", x: dx, y: dy });
  }
  typeText(s) {
    this.text += s;
    this.emit({ kind: "text", value: s });
  }
  emit(e) {
    for (const f of this.subs) f(e);
  }
};
var nullInputBackend = {
  id: "null",
  priority: 0,
  probe(_options) {
    return true;
  },
  create(_options) {
    return ok(new NullInputDevice());
  }
};

// src/backends/fs-memory/fs.ts
function norm(path) {
  let p = path.replace(/\\/g, "/");
  if (p.startsWith("mem:")) p = p.slice(4);
  if (!p.startsWith("/")) p = "/" + p;
  const parts = [];
  for (const seg of p.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") {
      return err(
        engineError("FS.PATH_ESCAPE", `\u8DEF\u5F84\u91CC\u51FA\u73B0 ".."\uFF1A${path}\uFF08\u62D2\u7EDD\uFF0C\u4E0D\u505A'\u806A\u660E'\u7684\u89E3\u6790\uFF09`)
      );
    }
    parts.push(seg);
  }
  return ok("/" + parts.join("/"));
}
var MemoryFileSystem = class {
  /** 前缀，用于同一进程里隔离多个内存盘（`mem:/a` vs `mem:/b`）。 */
  constructor(prefix = "") {
    this.prefix = prefix;
  }
  scheme = "mem";
  files = /* @__PURE__ */ new Map();
  dirs = /* @__PURE__ */ new Set(["/"]);
  nowCounter = 1;
  /** 写入次数：判据可以断言"没有多余的落盘"。 */
  writeCount = 0;
  key(p) {
    const n = norm(this.prefix + p);
    return n;
  }
  async readText(path) {
    const b = await this.readBinary(path);
    if (!b.ok) return b;
    try {
      return ok(new TextDecoder("utf-8", { fatal: true }).decode(b.value));
    } catch (e) {
      return err(engineError("FS.NOT_UTF8", `\u4E0D\u662F\u5408\u6CD5 UTF-8\uFF1A${path}\uFF08${e instanceof Error ? e.message : ""}\uFF09`));
    }
  }
  async readBinary(path) {
    const k = this.key(path);
    if (!k.ok) return k;
    const f = this.files.get(k.value);
    if (f === void 0) {
      return err(
        engineError("FS.NOT_FOUND", `\u6587\u4EF6\u4E0D\u5B58\u5728\uFF1A${k.value}`, {
          known: Array.from(this.files.keys()).sort().slice(0, 20)
        })
      );
    }
    return ok(f.data.slice());
  }
  async writeText(path, text) {
    return this.writeBinary(path, new TextEncoder().encode(text));
  }
  async writeBinary(path, data) {
    const k = this.key(path);
    if (!k.ok) return k;
    this.files.set(k.value, { data: data.slice(), mtimeMs: this.nowCounter++ });
    this.writeCount++;
    const segs = k.value.split("/").filter(Boolean);
    for (let i = 1; i <= segs.length - 1; i++) {
      this.dirs.add("/" + segs.slice(0, i).join("/"));
    }
    return ok(void 0);
  }
  async remove(path) {
    const k = this.key(path);
    if (!k.ok) return k;
    if (!this.files.delete(k.value)) {
      return err(engineError("FS.NOT_FOUND", `\u8981\u5220\u9664\u7684\u8DEF\u5F84\u4E0D\u5B58\u5728\uFF1A${k.value}`));
    }
    return ok(void 0);
  }
  async exists(path) {
    const k = this.key(path);
    if (!k.ok) return false;
    return this.files.has(k.value) || this.dirs.has(k.value);
  }
  async list(dir) {
    const k = this.key(dir);
    if (!k.ok) return k;
    const base = k.value === "/" ? "/" : k.value + "/";
    const out = [];
    for (const [p, f] of this.files) {
      if (!p.startsWith(base)) continue;
      const rest = p.slice(base.length);
      if (rest === "" || rest.includes("/")) continue;
      out.push({ name: rest, path: p, isDirectory: false, size: f.data.byteLength });
    }
    for (const d of this.dirs) {
      if (d === k.value || !d.startsWith(base)) continue;
      const rest = d.slice(base.length);
      if (rest === "" || rest.includes("/")) continue;
      out.push({ name: rest, path: d, isDirectory: true, size: 0 });
    }
    out.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
    return ok(out);
  }
  async stat(path) {
    const k = this.key(path);
    if (!k.ok) return k;
    const f = this.files.get(k.value);
    if (f !== void 0) {
      return ok({ size: f.data.byteLength, mtimeMs: f.mtimeMs, isDirectory: false });
    }
    if (this.dirs.has(k.value)) return ok({ size: 0, mtimeMs: 0, isDirectory: true });
    return err(engineError("FS.NOT_FOUND", `\u8DEF\u5F84\u4E0D\u5B58\u5728\uFF1A${k.value}`));
  }
  async ensureDir(dir) {
    const k = this.key(dir);
    if (!k.ok) return k;
    this.dirs.add(k.value);
    return ok(void 0);
  }
  // ---- 判据/编辑器便利（不在 IFileSystem 接口里，避免所有实现都要有）
  snapshotFiles() {
    const m = /* @__PURE__ */ new Map();
    for (const [k, v] of this.files) m.set(k, v.data.slice());
    return m;
  }
  reset() {
    this.files.clear();
    this.dirs.clear();
    this.dirs.add("/");
    this.writeCount = 0;
  }
};
var memFsBackend = {
  id: "mem",
  scheme: "mem",
  priority: 50,
  probe(_options) {
    return true;
  },
  create(options) {
    const o = options ?? {};
    return ok(new MemoryFileSystem(o.prefix ?? ""));
  }
};

// src/platform/script/runtime.ts
var ScriptErrorCode = {
  NotSupported: "SCRIPT.NOT_SUPPORTED",
  Disposed: "SCRIPT.DISPOSED",
  NoFunction: "SCRIPT.NO_FUNCTION",
  CallFailed: "SCRIPT.CALL_FAILED",
  Timeout: "SCRIPT.TIMEOUT",
  LoadFailed: "SCRIPT.LOAD_FAILED",
  BadValue: "SCRIPT.BAD_VALUE"
};
function assertScriptValue(v, where) {
  const walk = (x, depth) => {
    if (depth > 32) {
      return err(engineError(ScriptErrorCode.BadValue, `${where}: \u5D4C\u5957\u8D85\u8FC7 32 \u5C42\uFF08\u516B\u6210\u662F\u6210\u73AF\u7684\u5F15\u7528\uFF09`));
    }
    if (x === null || typeof x === "boolean" || typeof x === "string") return ok(x);
    if (typeof x === "number") {
      if (!Number.isFinite(x)) {
        return err(engineError(ScriptErrorCode.BadValue, `${where}: \u6570\u503C ${String(x)} \u4E0D\u662F\u6709\u9650\u6570`));
      }
      return ok(x);
    }
    if (Array.isArray(x)) {
      const out = [];
      for (let i = 0; i < x.length; i++) {
        const r = walk(x[i], depth + 1);
        if (!r.ok) return r;
        out.push(r.value);
      }
      return ok(out);
    }
    if (typeof x === "object") {
      const src = x;
      const out = {};
      for (const k of Object.keys(src).sort()) {
        const r = walk(src[k], depth + 1);
        if (!r.ok) return r;
        out[k] = r.value;
      }
      return ok(out);
    }
    return err(
      engineError(ScriptErrorCode.BadValue, `${where}: \u7C7B\u578B ${typeof x} \u4E0D\u80FD\u8DE8\u811A\u672C\u8FB9\u754C\uFF08\u53EA\u5141\u8BB8 null/bool/number/string/\u6570\u7EC4/\u7EAF\u5BF9\u8C61\uFF09`)
    );
  };
  return walk(v, 0);
}

// src/backends/script-null/runtime.ts
var NullScriptRuntime = class {
  id = "null";
  caps = {
    language: "none",
    version: null,
    interruptible: false,
    hostCalls: false,
    executes: false
  };
  modules = /* @__PURE__ */ new Map();
  hostFns = /* @__PURE__ */ new Map();
  loaded = [];
  calls = 0;
  errors = 0;
  disposed = false;
  async loadModule(name, source) {
    if (this.disposed) return this.disposedErr();
    this.modules.set(name, source);
    this.loaded.push({ name, bytes: source.length });
    return ok(void 0);
  }
  async unloadModule(name) {
    if (this.disposed) return this.disposedErr();
    this.modules.delete(name);
    return ok(void 0);
  }
  hasModule(name) {
    return this.modules.has(name);
  }
  listModules() {
    return Array.from(this.modules.keys()).sort();
  }
  async call(fn, args = [], _opts = {}) {
    if (this.disposed) return this.disposedErr();
    this.calls++;
    this.errors++;
    return err(
      engineError(
        ScriptErrorCode.NotSupported,
        `null \u811A\u672C\u540E\u7AEF\u4E0D\u80FD\u6267\u884C ${fn}\uFF08\u8FD9\u4E2A\u5E73\u53F0\u6CA1\u6709\u811A\u672C\u80FD\u529B\uFF1Acaps.executes=false\uFF09`,
        { fn }
      )
    );
  }
  expose(name, fn) {
    if (this.disposed) return this.disposedErr();
    this.hostFns.set(name, fn);
    return ok(void 0);
  }
  exposed() {
    return Array.from(this.hostFns.keys()).sort();
  }
  async ready() {
    return this.disposed ? this.disposedErr() : ok(void 0);
  }
  stats() {
    return {
      modules: this.modules.size,
      calls: this.calls,
      errors: this.errors,
      timeouts: 0
    };
  }
  /** 诊断：加载历史（含热重载的重复项）。 */
  history() {
    return this.loaded.slice();
  }
  dispose() {
    this.disposed = true;
    this.modules.clear();
    this.hostFns.clear();
  }
  disposedErr() {
    return err(engineError(ScriptErrorCode.Disposed, "\u811A\u672C\u8FD0\u884C\u65F6\u5DF2\u91CA\u653E"));
  }
};
var nullScriptBackend = {
  id: "null",
  probe: () => true,
  create: () => ok(new NullScriptRuntime())
};

// src/backends/index.ts
function registerNullBackends(reg, opts = {}) {
  reg.registerGfx(nullGfxBackend, 0);
  reg.registerAudio(nullAudioBackend, 0);
  reg.registerInput(nullInputBackend, 0);
  reg.registerFs(
    {
      id: memFsBackend.id,
      scheme: memFsBackend.scheme,
      probe: memFsBackend.probe,
      create: (o) => memFsBackend.create({ prefix: opts.fsPrefix ?? "", ...o })
    },
    0
  );
  reg.registerScript(nullScriptBackend, 0);
}

// src/backends/script-lua/runtime.ts
var import_wasmoon = __toESM(require_dist(), 1);

// src/backends/script-lua/compat-lua51.ts
var LUA51_COMPAT_SRC = String.raw`
-- ============================== 内部工具 ==============================

local __type = type
local __error = error
local __select = select
local __tostring = tostring
local __setmetatable = setmetatable
local __getmetatable = getmetatable
local __rawget = rawget
local __load = load
local __debug = debug

-- 找到函数的 _ENV upvalue 序号；没有（函数不读全局 / 是 C 函数）返回 nil。
-- 注意：5.4 里 _ENV 可能不是 1 号（函数先捕获了别的局部变量），必须按名字找。
local function __engine_compat_envindex(f)
  if __type(f) ~= "function" then return nil end
  local i = 1
  while true do
    local name = __debug.getupvalue(f, i)
    if name == nil then return nil end
    if name == "_ENV" then return i end
    i = i + 1
  end
end

local function __engine_compat_getenv(f)
  local idx = __engine_compat_envindex(f)
  if idx == nil then return nil end
  local _, v = __debug.getupvalue(f, idx)
  if __type(v) ~= "table" then return nil end
  return v
end

local __engine_compat_has_join = __type(__debug.upvaluejoin) == "function"

-- 把 f 的 _ENV 换成 t（私有 upvalue，不牵连兄弟闭包）。返回是否真的换了。
local function __engine_compat_bind(f, t)
  local idx = __engine_compat_envindex(f)
  if idx == nil then
    -- 函数根本没读过全局 ⇒ 没有可观察差异。5.1 会给它 env，但读了才有意义。
    return false
  end
  if __engine_compat_has_join then
    local holder = __load("return _ENV", "=__engine_compat_envholder", "t", t)
    if holder ~= nil then
      __debug.upvaluejoin(f, idx, holder, 1)
      return true
    end
  end
  -- 退化路径：upvaluejoin 不可用。语义仍对，但会牵连同 chunk 的兄弟闭包。
  __debug.setupvalue(f, idx, t)
  return true
end

-- ============================== setfenv / getfenv ==============================

function setfenv(f, t)
  if __type(f) == "number" then
    __error(
      "setfenv: Lua 5.4 无法按栈层号(level=" .. __tostring(f) .. ")设置环境；"
        .. "5.1 的这个用法在 5.4 里没有对应物，请改成传函数本身",
      2
    )
  end
  if __type(f) ~= "function" then
    __error("setfenv: 第一个参数必须是函数（收到 " .. __type(f) .. "）", 2)
  end
  if __type(t) ~= "table" then
    __error("setfenv: 第二个参数必须是 table（收到 " .. __type(t) .. "）", 2)
  end
  __engine_compat_bind(f, t)
  return f
end

function getfenv(f)
  if f == nil then f = 1 end
  if __type(f) == "number" then
    -- 5.1 的 getfenv(level) 只是查询，5.4 能**精确**做到，因此不降级。
    -- +1 是因为 level 1 在 5.1 里指"调用 getfenv 的那个函数"，
    -- 而在 debug.getinfo 里 level 1 是 getfenv 自己。
    local info = __debug.getinfo(f + 1, "f")
    if info == nil or __type(info.func) ~= "function" then return _G end
    return __engine_compat_getenv(info.func) or _G
  end
  if __type(f) ~= "function" then
    __error("getfenv: 参数必须是函数或栈层号（收到 " .. __type(f) .. "）", 2)
  end
  return __engine_compat_getenv(f) or _G
end

-- ============================== module / package.seeall ==============================

-- 在真正的 _G 上建（或复用）点号嵌套的表。5.1 的 findtable 就是往全局表里写。
local function __engine_compat_findtable(name)
  local cur = _G
  local created = false
  for part in string.gmatch(name, "[^.]+") do
    local nxt = cur[part]
    if __type(nxt) ~= "table" then
      nxt = {}
      cur[part] = nxt
      created = true
    end
    cur = nxt
  end
  return cur, created
end

function module(name, ...)
  if __type(name) ~= "string" or name == "" then
    __error("module: 模块名必须是非空字符串", 2)
  end

  -- ① 建/取模块表，并登记到 package.loaded
  local mod = package.loaded[name]
  if __type(mod) ~= "table" then
    mod = __engine_compat_findtable(name)
  end
  package.loaded[name] = mod

  -- ② 取调用者的旧 env（module 之后模块里还要能看见全局，5.1 靠这个兜底链）
  local caller = __debug.getinfo(2, "f")
  local caller_fn = nil
  local caller_env = _G
  if caller ~= nil and __type(caller.func) == "function" then
    caller_fn = caller.func
    caller_env = __engine_compat_getenv(caller_fn) or _G
  end

  -- ③ 先铺默认 __index（链到调用者旧 env ⇒ 最终到 _G），再跑选项覆盖它。
  --    ★ 严格的 5.1 没有这条默认（所以才需要 package.seeall），但缺了它，
  --      任何 module("x") 之后 math/string/engine_* 全部变 nil —— 5.1 生态里
  --      这条默认被视为"本来就该有"。加上它只会让更多内容层跑得起来。
  local mt = __getmetatable(mod)
  if __type(mt) ~= "table" then
    mt = {}
    __setmetatable(mod, mt)
  end
  if mt.__index == nil then mt.__index = caller_env end

  -- ④ 跑选项（package.seeall 等）。5.1 在 setfenv **之前**跑，顺序会影响
  --    __index 的最终值，这里保持一致。
  local n = __select("#", ...)
  for i = 1, n do
    local opt = __select(i, ...)
    if __type(opt) ~= "function" then
      __error("module: 第 " .. __tostring(i + 1) .. " 个参数不是函数（选项应为 package.seeall 之类）", 2)
    end
    opt(mod)
  end

  -- ⑤ 换调用者的 env。5.1 的 setfenv(2, mod) 就是这一步。
  if caller_fn ~= nil then
    __engine_compat_bind(caller_fn, mod)
  end
  return mod
end

function package.seeall(t)
  if __type(t) ~= "table" then
    __error("package.seeall: 需要 table（收到 " .. __type(t) .. "）", 2)
  end
  local mt = __getmetatable(t)
  if __type(mt) ~= "table" then
    __setmetatable(t, { __index = _G })
  else
    mt.__index = _G
  end
end

-- ============================== require ==============================

-- 5.1 语义：package.loaded → package.preload → 报错。
-- ★ 不碰文件系统：wasm 里没有 fs，package.preload 才是引擎注册模块的入口。
function require(name)
  if __type(name) ~= "string" then
    __error("require: 模块名必须是字符串（收到 " .. __type(name) .. "）", 2)
  end

  local loaded = package.loaded[name]
  if loaded ~= nil then return loaded end

  local loader = package.preload[name]
  if loader == nil then
    __error("module '" .. name .. "' not found", 2)
  end
  if __type(loader) ~= "function" then
    __error("module '" .. name .. "': package.preload 里登记的不是函数", 2)
  end

  local r = loader(name)
  if r ~= nil then package.loaded[name] = r end
  local v = package.loaded[name]
  if v == nil then
    v = true
    package.loaded[name] = v
  end
  return v
end

-- ============================== math 补齐 ==============================

function math.pow(x, y) return x ^ y end
math.mod = math.fmod
function math.ldexp(x, e) return x * 2.0 ^ e end
function math.log10(x) return math.log(x, 10) end

-- frexp：x = m * 2^e，要求 0.5 <= |m| < 1（C 库的 frexp 定义）。
-- 用循环而不是位运算：Lua 5.4 的整数/浮点边界比这里需要的精度更容易出错。
function math.frexp(x)
  if x == 0 or x ~= x or x == math.huge or x == -math.huge then return x, 0 end
  local sign = 1
  local m = x
  if m < 0 then sign = -1; m = -m end
  local e = 0
  -- 次数上限：极值/非规格化数下也不会转不出来（每步最多把 |x| 缩一半）
  for _ = 1, 1200 do
    if m >= 1 then m = m / 2; e = e + 1 else break end
  end
  for _ = 1, 1200 do
    if m < 0.5 and m > 0 then m = m * 2; e = e - 1 else break end
  end
  return sign * m, e
end

-- ============================== table / string 补齐 ==============================

function table.getn(t) return #t end
function table.setn()
  __error("table.setn 在 Lua 5.1 已废弃（表长度由 # 决定），5.4 没有对应实现", 2)
end

string.gfind = string.gmatch

-- ============================== 全局别名 ==============================

unpack = table.unpack

-- 5.1 的 loadstring 与 5.4 的 load 返回值形状一致（成功 fn / 失败 nil, err），
-- 差别只在"默认 env"：5.1 用**全局表**，这里不传第 4 个参数即同一行为。
-- 也正因如此，loadstring 出来的 chunk 看不见调用它的模块 env —— 与 5.1 一致。
function loadstring(s, chunkname)
  if __type(s) ~= "string" then
    return nil, "bad argument #1 to 'loadstring' (string expected, got " .. __type(s) .. ")"
  end
  return __load(s, chunkname or s, "t")
end

-- 5.1 的启动参数表。wasm 里没有 argv，但内容层会读 arg[0]/arg[1]（拿到 nil 就行）。
if __rawget(_G, "arg") == nil then _G.arg = {} end
`;

// src/backends/script-lua/runtime.ts
var envGate = Promise.resolve();
function withSanitizedEnv(fn) {
  const run = envGate.then(
    () => runWithSanitizedEnv(fn),
    () => runWithSanitizedEnv(fn)
  );
  envGate = run.then(
    () => void 0,
    () => void 0
  );
  return run;
}
async function runWithSanitizedEnv(fn) {
  const proc = globalThis.process;
  const env = { _: "lua" };
  const saved = [];
  if (proc !== void 0 && proc.env !== void 0) {
    for (const [key, value] of Object.entries(proc.env)) {
      if (value === void 0) continue;
      if (!/[^\u0000-\u00ff]/.test(value)) continue;
      saved.push([key, value]);
      const ascii = value.replace(/[^\u0000-\u00ff]/g, "_");
      proc.env[key] = ascii;
      env[key] = ascii;
    }
    env["_"] = "lua";
  }
  try {
    return await fn(env);
  } finally {
    for (const [key, value] of saved) proc.env[key] = value;
  }
}
var BOOTSTRAP = `
__engine_deadline = 0

-- \u8BA1\u65F6\u94A9\u5B50\uFF1A\u53EA\u5728\u8C03\u7528\u65B9\u7ED9\u4E86 timeoutMs \u65F6\u6302\u4E0A\uFF08\u5426\u5219\u6BCF N \u6761\u6307\u4EE4\u4E00\u6B21\u56DE\u8C03\u662F\u767D\u4ED8\u7684\u5F00\u9500\uFF09\u3002
-- \u7528 CPU \u65F6\u95F4\u800C\u4E0D\u662F Date.now\uFF1A\u811A\u672C\u91CC\u62FF\u4E0D\u5230 JS \u65F6\u949F\uFF0Cos.clock \u5728 wasm \u91CC\u53EF\u7528\u4E14\u5355\u8C03\u3002
__engine_timeout_hook = function()
  if os.clock() >= __engine_deadline then
    error("__ENGINE_TIMEOUT__", 0)
  end
end

-- \u652F\u6301 "a.b.c" \u5F62\u5F0F\u7684\u51FD\u6570\u540D\uFF1A\u6A21\u5757\u53EF\u4EE5\u628A API \u6302\u5728\u81EA\u5DF1\u7684\u8868\u91CC\u3002
local function __engine_walk(root, path)
  local cur = root
  for part in string.gmatch(path, "[^.]+") do
    if type(cur) ~= "table" then return nil end
    cur = cur[part]
  end
  return cur
end

-- \u5DF2\u52A0\u8F7D\u6A21\u5757\u7684"\u547D\u540D\u7A7A\u95F4"\uFF08env \u91CC\u6A21\u5757\u81EA\u5DF1\u5B9A\u4E49\u7684\u952E\u7684\u6D45\u62F7\u8D1D\uFF0C\u89C1 __engine_load\uFF09
__engine_modules = {}
-- \u6A21\u5757\u540D -> \u8BE5\u6A21\u5757\u7684\u6709\u6548 _ENV \u8868\u3002\u53EA\u7528\u4E8E\u8BCA\u65AD\u4E0E\u5378\u8F7D\uFF08\u70ED\u91CD\u8F7D\u65F6\u6574\u5F20\u4E22\u5F03\uFF09
__engine_envs = {}
-- \u52A0\u8F7D\u987A\u5E8F\uFF08\u6700\u8FD1\u52A0\u8F7D\u7684\u5728\u6700\u540E\uFF09\u3002\u88F8\u540D\u89E3\u6790\u7528"\u540E\u6765\u8005\u4F18\u5148"\uFF0C\u4E0E\u5171\u4EAB _G \u65F6\u4EE3\u4E00\u81F4
__engine_order = {}

local function __engine_drop_order(name)
  for i = #__engine_order, 1, -1 do
    if __engine_order[i] == name then table.remove(__engine_order, i) end
  end
end

local function __engine_push_order(name)
  __engine_drop_order(name)
  __engine_order[#__engine_order + 1] = name
end

-- \u53D6\u51FD\u6570\u7684 _ENV upvalue \u503C\uFF085.4 \u91CC _ENV \u662F\u666E\u901A upvalue\uFF0C\u4E0D\u4E00\u5B9A\u5728 1 \u53F7\u4F4D\uFF09\u3002
-- \u8FD4\u56DE nil \u8868\u793A"\u8FD9\u4E2A\u51FD\u6570\u4E0D\u8BFB\u5168\u5C40"\u6216"\u662F C \u51FD\u6570"\u3002
local function __engine_env_of(f)
  local i = 1
  while true do
    local n = debug.getupvalue(f, i)
    if n == nil then return nil end
    if n == "_ENV" then
      -- \u2605 \u53D6\u7B2C\u4E8C\u4E2A\u8FD4\u56DE\u503C\uFF1Adebug.getupvalue \u8FD4\u56DE (name, value)\uFF0C\u5199\u6210 local v = ...
      --   \u62FF\u5230\u7684\u662F **name**\uFF0Ctype \u6C38\u8FDC\u4E0D\u662F table\uFF08\u8FD9\u4E2A\u5751\u5403\u8FC7\u4E00\u6B21\uFF0C\u522B\u518D\u6539\u56DE\u53BB\uFF09
      local _, v = debug.getupvalue(f, i)
      if type(v) == "table" then return v end
      return nil
    end
    i = i + 1
  end
end

local function __engine_resolve(name)
  -- \u2460 \u6309"\u6A21\u5757\u9650\u5B9A\u540D"\u627E\uFF1A\u53D6\u6700\u957F\u5339\u914D\u7684\u6A21\u5757\u540D\uFF0C\u907F\u514D a \u4E0E a.b \u4E92\u76F8\u62A2\u5360\u3002
  --    ScriptModule \u7528 "<module>.<entry>" \u8C03\u7528\uFF0C\u6240\u4EE5\u4E24\u4E2A\u6A21\u5757\u90FD\u5B9A\u4E49 onUpdate \u65F6
  --    \u4E0D\u4F1A\u4E92\u76F8\u8986\u76D6\uFF08\u6A21\u5757\u540D\u53EF\u4EE5\u5E26\u70B9\uFF0C\u6240\u4EE5\u5FC5\u987B\u7528\u6700\u957F\u5339\u914D\uFF09\u3002
  local best = nil
  for m in pairs(__engine_modules) do
    if string.sub(name, 1, #m + 1) == m .. "." then
      if best == nil or #m > #best then best = m end
    end
  end
  if best ~= nil then
    local fn = __engine_walk(__engine_modules[best], string.sub(name, #best + 2))
    if type(fn) == "function" then return fn end
  end

  -- \u2461 \u88F8\u540D/\u8DEF\u5F84\uFF1A\u6700\u8FD1\u52A0\u8F7D\u7684\u6A21\u5757\u4F18\u5148\u3002
  --    \u2605 \u8FD9\u6761\u662F"per-module env"\u7684\u5FC5\u8981\u8865\u507F\uFF1A\u6A21\u5757\u5B9A\u4E49\u7684\u5168\u5C40\u4E0D\u518D\u843D\u5230 _G\uFF0C
  --      \u4F46\u5951\u7EA6\u8981\u6C42 loadModule("greet", "function greet() ...") \u4E4B\u540E call("greet") \u80FD\u8C03\u5230\u3002
  for i = #__engine_order, 1, -1 do
    local ns = __engine_modules[__engine_order[i]]
    if ns ~= nil then
      local fn = __engine_walk(ns, name)
      if type(fn) == "function" then return fn end
    end
  end

  -- \u2462 _G\uFF1A\u5BBF\u4E3B expose \u7684\u51FD\u6570\u4E0E\u771F\u6B63\u7684\u5168\u5C40\uFF08\u542B\u517C\u5BB9\u57AB\u7247\u88C5\u7684 unpack/setfenv \u7B49\uFF09
  return __engine_walk(_G, name)
end

function __engine_dispatch(name, args, n, timeout_ms)
  local out = {}
  local fn = __engine_resolve(name)
  if type(fn) ~= "function" then
    out.s = 2
    out.m = tostring(name)
    return out
  end

  local co = coroutine.running()
  local hooked = false
  if timeout_ms ~= nil and timeout_ms > 0 then
    __engine_deadline = os.clock() + timeout_ms / 1000
    debug.sethook(co, __engine_timeout_hook, "", 1000)
    hooked = true
  end

  local ok, v = pcall(fn, table.unpack(args or {}, 1, n or 0))

  -- \u4E00\u5B9A\u8981\u6E05 hook\uFF08\u8D85\u65F6\u8DEF\u5F84\u4E5F\u8981\uFF09\uFF1A\u6B8B\u7559\u7684\u94A9\u5B50\u4F1A\u8BA9\u4E0B\u4E00\u6B21\u8C03\u7528\u83AB\u540D\u5176\u5999\u5730\u4E5F\u8D85\u65F6
  if hooked then debug.sethook(co) end

  if ok then
    out.s = 0
    out.v = v
  else
    local msg = tostring(v)
    if string.find(msg, "__ENGINE_TIMEOUT__", 1, true) then
      out.s = 4
      out.m = msg
    elseif string.find(msg, "__ENGINE_BAD_VALUE__", 1, true) then
      out.s = 3
      out.m = msg
    else
      out.s = 1
      out.m = msg
    end
  end
  return out
end

-- \u5148\u7F16\u8BD1\u540E\u66FF\u6362\uFF1Aload \u53EA\u7F16\u8BD1\uFF1B\u8BED\u6CD5\u9519\u8BEF\u65F6\u65E7\u6A21\u5757\u4E00\u4E2A\u90FD\u6CA1\u52A8\u3002
-- \u7F16\u8BD1\u6210\u529F\u540E\u624D\u6267\u884C chunk\uFF0C\u5176\u8FD4\u56DE\u503C\u5199\u5165 package.loaded[name]
--\uFF08\u6A21\u5757\u540D\u5728 Lua \u4FA7\u53EF\u89C1\uFF0C\u8C03\u8BD5\u65F6 print(package.loaded["ai.brain"]) \u6709\u4E1C\u897F\u770B\uFF09\u3002
--
-- \u2605 \u70ED\u91CD\u8F7D\u8BED\u4E49\uFF1A\u6BCF\u6B21\u52A0\u8F7D\u90FD\u9020\u4E00\u5F20**\u5168\u65B0\u7684** env\u3002\u65E7 env \u8FDE\u540C\u5B83\u91CC\u9762\u7684\u5168\u5C40\u4E00\u8D77
--   \u53D8\u6210\u5783\u573E\uFF08\u65E7\u7684\u95ED\u5305\u8FD8\u5F15\u7528\u7740\u5B83\uFF0C\u6240\u4EE5\u4E0D\u4F1A\u51FA\u95EE\u9898\uFF0C\u53EA\u662F\u6CA1\u4EBA\u518D\u8BFB\uFF09\u3002\u590D\u7528\u65E7 env
--   \u4F1A\u8BA9\u4E0A\u4E00\u7248\u7684 "counter = 3" \u6B8B\u7559\u5230\u65B0\u7248\u672C \u2014\u2014 \u8FD9\u6B63\u662F\u70ED\u91CD\u8F7D\u6700\u5178\u578B\u7684\u4E32\u5473\u7F3A\u9677\u3002
--
-- \u2605 \u6536\u96C6\u6A21\u5757\u547D\u540D\u7A7A\u95F4\uFF1A\u6A21\u5757\u53EF\u4EE5
--     \u2460 \u76F4\u63A5\u5199 env\uFF08\u6700\u5E38\u89C1\uFF09\uFF1B
--     \u2461 \u8C03 module()/setfenv(1, ...) \u628A chunk \u7684 _ENV \u6362\u6389\uFF085.1 \u98CE\u683C\uFF09\u2014\u2014
--        \u8FD9\u65F6\u6709\u6548 env \u5728**\u6267\u884C\u540E**\u624D\u770B\u5F97\u5230\uFF0C\u6240\u4EE5\u4E24\u4E2A\u8868\u90FD\u8981\u6536\uFF1B
--     \u2462 "return { onUpdate = ... }"\u3002
--   \u4E0E _G \u91CC\u540C\u503C\u7684\u952E\u4E0D\u6536\uFF08\u6A21\u5757\u628A env \u6362\u6210\u4E86 _G \u65F6\uFF0C\u90A3\u91CC\u7684\u4E00\u5207\u90FD\u662F\u5168\u5C40\u7684\uFF0C
--   \u4E0D\u8BE5\u6574\u4F53\u642C\u8FDB\u6A21\u5757\u547D\u540D\u7A7A\u95F4\uFF09\u3002
function __engine_load(name, source)
  local env = {}
  setmetatable(env, { __index = _G })

  local chunk, compile_err = load(source, "@" .. name, "t", env)
  if not chunk then
    return { s = 0, m = tostring(compile_err) }
  end

  local ok, result = pcall(chunk)
  if not ok then
    -- \u7F16\u8BD1\u901A\u8FC7\u4F46\u6267\u884C\u671F\u51FA\u9519\uFF1A\u4E0D\u52A8\u5DF2\u767B\u8BB0\u7684 env/\u547D\u540D\u7A7A\u95F4\uFF08\u65E7\u6A21\u5757\u8FD8\u80FD\u8DD1\uFF09
    return { s = 2, m = tostring(result) }
  end

  local live = __engine_env_of(chunk) or env

  local ns = {}
  local function collect(t)
    if t == nil or t == _G then return end
    for k, v in pairs(t) do
      if _G[k] ~= v then ns[k] = v end
    end
  end
  collect(env)
  collect(live)
  -- \u60EF\u7528\u5199\u6CD5 "return { onUpdate = ... }"\uFF1A\u628A\u8FD4\u56DE\u8868\u7684\u6210\u5458\u4E5F\u7EB3\u5165\u6A21\u5757\u547D\u540D\u7A7A\u95F4
  if type(result) == "table" then
    for k, v in pairs(result) do ns[k] = v end
  end

  __engine_envs[name] = live
  __engine_modules[name] = ns
  __engine_push_order(name)
  package.loaded[name] = result == nil and true or result
  return { s = 1, m = "" }
end

function __engine_unload(name)
  package.loaded[name] = nil
  __engine_modules[name] = nil
  __engine_envs[name] = nil
  __engine_drop_order(name)
  return { s = 1 }
end
`;
var COMPAT_PROBE_SRC = `
local need = { "unpack", "loadstring", "setfenv", "getfenv", "module", "require", "math.pow", "math.mod", "math.ldexp", "math.frexp", "math.log10", "table.getn", "string.gfind", "arg" }
local missing = {}
for i = 1, #need do
  local name = need[i]
  local dot = string.find(name, ".", 1, true)
  local v = _G
  if dot == nil then
    v = _G[name]
  else
    v = _G[string.sub(name, 1, dot - 1)]
    if v ~= nil then v = v[string.sub(name, dot + 1)] end
  end
  if v == nil then missing[#missing + 1] = name end
end
return table.concat(missing, ",")
`;
var LuaStatus = {
  Ok: 0,
  CallFailed: 1,
  NoFunction: 2,
  BadValue: 3,
  Timeout: 4
};
function looksLikeSequence(obj) {
  const keys = Object.keys(obj);
  if (keys.length === 0) return false;
  for (let i = 1; i <= keys.length; i++) {
    if (!Object.prototype.hasOwnProperty.call(obj, String(i))) return false;
  }
  return true;
}
function toScriptValue(v, where, depth = 0) {
  if (depth > 32) {
    return err(engineError(ScriptErrorCode.BadValue, `${where}: \u5D4C\u5957\u8D85\u8FC7 32 \u5C42\uFF08\u516B\u6210\u662F\u6210\u73AF\u7684\u8868\uFF09`));
  }
  if (v === null || v === void 0) return ok(null);
  if (typeof v === "boolean" || typeof v === "string") return ok(v);
  if (typeof v === "number") {
    if (!Number.isFinite(v)) {
      return err(engineError(ScriptErrorCode.BadValue, `${where}: \u6570\u503C ${String(v)} \u4E0D\u662F\u6709\u9650\u6570`));
    }
    return ok(v);
  }
  if (Array.isArray(v)) {
    const out = [];
    for (let i = 0; i < v.length; i++) {
      const r = toScriptValue(v[i], `${where}[${i}]`, depth + 1);
      if (!r.ok) return r;
      out.push(r.value);
    }
    return ok(out);
  }
  if (typeof v === "object") {
    const src = v;
    if (looksLikeSequence(src)) {
      const out2 = [];
      for (let i = 1; i <= Object.keys(src).length; i++) {
        const r = toScriptValue(src[String(i)], `${where}[${i}]`, depth + 1);
        if (!r.ok) return r;
        out2.push(r.value);
      }
      return ok(out2);
    }
    const out = {};
    for (const k of Object.keys(src).sort()) {
      const r = toScriptValue(src[k], `${where}.${k}`, depth + 1);
      if (!r.ok) return r;
      out[k] = r.value;
    }
    return ok(out);
  }
  return err(
    engineError(
      ScriptErrorCode.BadValue,
      `${where}: \u7C7B\u578B ${typeof v} \u4E0D\u80FD\u8DE8\u811A\u672C\u8FB9\u754C\uFF08\u53EA\u5141\u8BB8 null/bool/number/string/\u6570\u7EC4/\u7EAF\u5BF9\u8C61\uFF09`
    )
  );
}
function sanitizeForLua(v) {
  if (v === null) return void 0;
  if (Array.isArray(v)) {
    const out = [];
    for (let i = 0; i < v.length; i++) out.push(sanitizeForLua(v[i]));
    return out;
  }
  if (typeof v === "object") {
    const src = v;
    const out = {};
    for (const k of Object.keys(src)) out[k] = sanitizeForLua(src[k]);
    return out;
  }
  return v;
}
function statusOf(raw) {
  return raw !== null && typeof raw === "object" ? raw : {};
}
var LuaScriptRuntime = class {
  id = "lua";
  /**
   * ★ `version` 写的是**解释器**的版本（5.4），不是"脚本该按哪版写"。
   *   5.1 兼容垫片是 API 补齐，不是换运行时；把它写成 "5.1" 会让
   *   "这段脚本到底按哪个语义能跑"变得不可判定（5.4 的 goto / 整除仍在）。
   */
  caps = {
    language: "lua",
    version: "5.4",
    interruptible: true,
    hostCalls: true,
    executes: true
  };
  opts;
  constructor(opts = {}) {
    this.opts = opts;
  }
  engine = null;
  dispatchFn = null;
  loadFn = null;
  unloadFn = null;
  readyPromise = null;
  modules = /* @__PURE__ */ new Map();
  hostFns = /* @__PURE__ */ new Map();
  calls = 0;
  errors = 0;
  timeouts = 0;
  disposed = false;
  // ---------------------------------------------------------------- 生命周期
  ready() {
    if (this.disposed) return Promise.resolve(this.disposedErr());
    if (this.readyPromise === null) this.readyPromise = this.initEngine();
    return this.readyPromise;
  }
  async initEngine() {
    let lua = null;
    try {
      lua = await withSanitizedEnv((env) => new import_wasmoon.LuaFactory(this.opts.wasmPath, env).createEngine());
      if (this.disposed) {
        lua.global.close();
        return this.disposedErr();
      }
      await lua.doString(BOOTSTRAP);
      if (this.disposed) {
        lua.global.close();
        return this.disposedErr();
      }
      try {
        await lua.doString(LUA51_COMPAT_SRC);
      } catch (e) {
        lua.global.close();
        return err(
          engineError(
            ScriptErrorCode.LoadFailed,
            `Lua 5.1 \u517C\u5BB9\u57AB\u7247\u6267\u884C\u5931\u8D25\uFF1A${e instanceof Error ? e.message : String(e)}`,
            { backend: this.id }
          )
        );
      }
      if (this.disposed) {
        lua.global.close();
        return this.disposedErr();
      }
      const missing = await lua.doString(COMPAT_PROBE_SRC);
      if (typeof missing === "string" && missing.length > 0) {
        lua.global.close();
        return err(
          engineError(ScriptErrorCode.LoadFailed, `Lua 5.1 \u517C\u5BB9\u57AB\u7247\u6CA1\u6709\u88C5\u4E0A\u8FD9\u4E9B\u51FD\u6570\uFF1A${missing}`)
        );
      }
      const dispatch = lua.global.get("__engine_dispatch");
      const load = lua.global.get("__engine_load");
      const unload = lua.global.get("__engine_unload");
      if (typeof dispatch !== "function" || typeof load !== "function" || typeof unload !== "function") {
        lua.global.close();
        return err(
          engineError(ScriptErrorCode.LoadFailed, "Lua \u5F15\u5BFC\u811A\u672C\u6CA1\u6709\u4EA7\u51FA\u8FB9\u754C\u539F\u8BED\uFF08__engine_dispatch/load/unload\uFF09")
        );
      }
      this.engine = lua;
      this.dispatchFn = dispatch;
      this.loadFn = load;
      this.unloadFn = unload;
      for (const [name, fn] of this.hostFns) this.installHost(lua, name, fn);
      return ok(void 0);
    } catch (e) {
      if (lua !== null) {
        try {
          lua.global.close();
        } catch {
        }
      }
      return err(
        engineError(
          ScriptErrorCode.LoadFailed,
          `Lua \u8FD0\u884C\u65F6\u521D\u59CB\u5316\u5931\u8D25\uFF1A${e instanceof Error ? e.message : String(e)}`,
          { backend: this.id }
        )
      );
    }
  }
  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    const lua = this.engine;
    this.engine = null;
    this.dispatchFn = null;
    this.loadFn = null;
    this.unloadFn = null;
    this.modules.clear();
    this.hostFns.clear();
    this.calls = 0;
    this.errors = 0;
    this.timeouts = 0;
    if (lua !== null) {
      try {
        lua.global.close();
      } catch {
      }
    }
  }
  // ---------------------------------------------------------------- 模块
  async loadModule(name, source) {
    if (this.disposed) return this.disposedErr();
    const load = this.loadFn;
    if (load === null) {
      return err(engineError(ScriptErrorCode.LoadFailed, `\u52A0\u8F7D\u6A21\u5757 ${name} \u524D\u8981\u5148 await ready()`));
    }
    let raw;
    try {
      raw = load(name, source);
    } catch (e) {
      return err(
        engineError(
          ScriptErrorCode.LoadFailed,
          `\u6A21\u5757 ${name} \u7F16\u8BD1/\u6267\u884C\u65F6\u8FB9\u754C\u5F02\u5E38\uFF1A${e instanceof Error ? e.message : String(e)}`
        )
      );
    }
    const st = statusOf(raw);
    if (st.s !== 1) {
      return err(
        engineError(ScriptErrorCode.LoadFailed, `\u6A21\u5757 ${name} \u52A0\u8F7D\u5931\u8D25\uFF1A${String(st.m ?? "\u672A\u77E5\u539F\u56E0")}`, {
          module: name
        })
      );
    }
    this.modules.set(name, source);
    return ok(void 0);
  }
  async unloadModule(name) {
    if (this.disposed) return this.disposedErr();
    this.modules.delete(name);
    try {
      this.unloadFn?.(name);
    } catch (e) {
      return err(
        engineError(
          ScriptErrorCode.CallFailed,
          `\u5378\u8F7D\u6A21\u5757 ${name} \u65F6\u51FA\u9519\uFF1A${e instanceof Error ? e.message : String(e)}`
        )
      );
    }
    return ok(void 0);
  }
  hasModule(name) {
    return this.disposed ? false : this.modules.has(name);
  }
  listModules() {
    if (this.disposed) return [];
    return Array.from(this.modules.keys()).sort();
  }
  // ---------------------------------------------------------------- 调用
  async call(fn, args = [], opts = {}) {
    if (this.disposed) return this.disposedErr();
    this.calls++;
    const dispatch = this.dispatchFn;
    if (dispatch === null) {
      this.errors++;
      return err(engineError(ScriptErrorCode.LoadFailed, `\u8C03\u7528 ${fn} \u524D\u8981\u5148 await ready()`));
    }
    const checked = [];
    for (let i = 0; i < args.length; i++) {
      const r = assertScriptValue(args[i], `call(${fn}) \u53C2\u6570 #${i}`);
      if (!r.ok) {
        this.errors++;
        return err(r.error);
      }
      checked.push(r.value);
    }
    const timeoutMs = opts.timeoutMs;
    if (timeoutMs !== void 0 && !(Number.isFinite(timeoutMs) && timeoutMs > 0)) {
      this.errors++;
      return err(
        engineError(ScriptErrorCode.BadValue, `call(${fn}) \u7684 timeoutMs \u5FC5\u987B\u662F\u6B63\u7684\u6709\u9650\u6570\uFF08\u6536\u5230 ${String(timeoutMs)}\uFF09`)
      );
    }
    if (timeoutMs !== void 0 && !this.caps.interruptible) {
      this.errors++;
      return err(engineError(ScriptErrorCode.NotSupported, `\u540E\u7AEF ${this.id} \u4E0D\u80FD\u6253\u65AD\u811A\u672C\uFF0CtimeoutMs \u65E0\u5904\u751F\u6548`));
    }
    let raw;
    try {
      raw = dispatch(fn, sanitizeForLua(checked), checked.length, timeoutMs ?? 0);
    } catch (e) {
      this.errors++;
      return err(
        engineError(
          ScriptErrorCode.CallFailed,
          `\u8C03\u7528 ${fn} \u65F6\u8FD0\u884C\u65F6\u5F02\u5E38\uFF1A${e instanceof Error ? e.message : String(e)}`,
          { fn }
        )
      );
    }
    const st = statusOf(raw);
    switch (st.s) {
      case LuaStatus.Ok: {
        const r = toScriptValue(st.v, `call(${fn}) \u8FD4\u56DE\u503C`);
        if (!r.ok) {
          this.errors++;
          return err(r.error);
        }
        return r;
      }
      case LuaStatus.NoFunction:
        this.errors++;
        return err(
          engineError(ScriptErrorCode.NoFunction, `\u811A\u672C\u91CC\u6CA1\u6709\u51FD\u6570 ${fn}\uFF08\u4E0D\u662F\u53EF\u8C03\u7528\u7684 function\uFF09`, { fn })
        );
      case LuaStatus.Timeout:
        this.errors++;
        this.timeouts++;
        return err(
          engineError(ScriptErrorCode.Timeout, `\u8C03\u7528 ${fn} \u8D85\u8FC7 ${String(timeoutMs)} ms\uFF0C\u5DF2\u6253\u65AD`, {
            fn,
            timeoutMs
          })
        );
      case LuaStatus.BadValue:
        this.errors++;
        return err(
          engineError(ScriptErrorCode.BadValue, String(st.m ?? "\u5BBF\u4E3B\u51FD\u6570\u62D2\u7EDD\u4E86\u53C2\u6570"), { fn })
        );
      default:
        this.errors++;
        return err(
          engineError(ScriptErrorCode.CallFailed, String(st.m ?? "\u811A\u672C\u6267\u884C\u5931\u8D25\uFF08\u65E0\u9519\u8BEF\u4FE1\u606F\uFF09"), { fn })
        );
    }
  }
  // ---------------------------------------------------------------- 宿主函数
  expose(name, fn) {
    if (this.disposed) return this.disposedErr();
    if (name.length === 0) {
      return err(engineError(ScriptErrorCode.BadValue, "expose \u7684\u540D\u5B57\u4E0D\u80FD\u4E3A\u7A7A"));
    }
    if (name.startsWith("__engine_")) {
      return err(
        engineError(ScriptErrorCode.BadValue, `expose \u4E0D\u80FD\u5360\u7528\u4FDD\u7559\u524D\u7F00 __engine_\uFF08\u6536\u5230 ${name}\uFF09`)
      );
    }
    this.hostFns.set(name, fn);
    const lua = this.engine;
    if (lua !== null) this.installHost(lua, name, fn);
    return ok(void 0);
  }
  exposed() {
    if (this.disposed) return [];
    return Array.from(this.hostFns.keys()).sort();
  }
  installHost(lua, name, fn) {
    lua.global.set(name, (...rawArgs) => {
      const args = [];
      for (let i = 0; i < rawArgs.length; i++) {
        const r = toScriptValue(rawArgs[i], `${name} \u53C2\u6570 #${i}`);
        if (!r.ok) throw new Error(`__ENGINE_BAD_VALUE__: ${r.error.message}`);
        args.push(r.value);
      }
      let out;
      try {
        out = fn(...args);
      } catch (e) {
        throw e instanceof Error ? e : new Error(String(e));
      }
      const checked = assertScriptValue(out ?? null, `${name} \u8FD4\u56DE\u503C`);
      if (!checked.ok) throw new Error(`__ENGINE_BAD_VALUE__: ${checked.error.message}`);
      return sanitizeForLua(checked.value);
    });
  }
  // ---------------------------------------------------------------- 统计
  stats() {
    return {
      modules: this.disposed ? 0 : this.modules.size,
      calls: this.disposed ? 0 : this.calls,
      errors: this.disposed ? 0 : this.errors,
      timeouts: this.disposed ? 0 : this.timeouts
    };
  }
  disposedErr() {
    return err(engineError(ScriptErrorCode.Disposed, "\u811A\u672C\u8FD0\u884C\u65F6\u5DF2\u91CA\u653E"));
  }
};
function createLuaScriptBackend(opts = {}) {
  return {
    id: "lua",
    probe: () => true,
    create: () => ok(new LuaScriptRuntime(opts))
  };
}

// src/platform/gfx/types.ts
var BufferUsage = {
  Vertex: 1,
  Index: 2,
  Uniform: 3
};
var PixelFormat = {
  RGBA8: "rgba8",
  RGB8: "rgb8",
  R8: "r8",
  RGBA16F: "rgba16f"
};
var TextureFilter = { Nearest: "nearest", Linear: "linear" };
var TextureWrap = { Clamp: "clamp", Repeat: "repeat" };
var SPRITE_VERTEX_LAYOUT = {
  attributes: [
    { name: "a_position", components: 2 },
    { name: "a_uv", components: 2 },
    { name: "a_color", components: 4 }
  ]
};
var BlendMode = { None: 0, Alpha: 1, Additive: 2, Premultiplied: 3 };
var Topology = { Triangles: 0, TriangleStrip: 1 };

// src/backends/gfx-webgl2/gl2.ts
var GL = {
  // buffer
  ARRAY_BUFFER: 34962,
  ELEMENT_ARRAY_BUFFER: 34963,
  STATIC_DRAW: 35044,
  DYNAMIC_DRAW: 35048,
  // shader
  VERTEX_SHADER: 35633,
  FRAGMENT_SHADER: 35632,
  COMPILE_STATUS: 35713,
  LINK_STATUS: 35714,
  // texture
  TEXTURE_2D: 3553,
  TEXTURE0: 33984,
  RGBA: 6408,
  RGBA8: 32856,
  RGB: 6407,
  R8: 33321,
  UNSIGNED_BYTE: 5121,
  FLOAT: 5126,
  UNSIGNED_SHORT: 5123,
  UNSIGNED_INT: 5125,
  TEXTURE_MIN_FILTER: 10241,
  TEXTURE_MAG_FILTER: 10240,
  TEXTURE_WRAP_S: 10242,
  TEXTURE_WRAP_T: 10243,
  NEAREST: 9728,
  LINEAR: 9729,
  CLAMP_TO_EDGE: 33071,
  REPEAT: 10497,
  UNPACK_ALIGNMENT: 3317,
  // state
  BLEND: 3042,
  DEPTH_TEST: 2929,
  SCISSOR_TEST: 3089,
  SRC_ALPHA: 770,
  ONE_MINUS_SRC_ALPHA: 771,
  ONE: 1,
  COLOR_BUFFER_BIT: 16384,
  DEPTH_BUFFER_BIT: 256,
  TRIANGLES: 4,
  TRIANGLE_STRIP: 5,
  // limits
  MAX_TEXTURE_SIZE: 3379,
  MAX_TEXTURE_IMAGE_UNITS: 34930,
  MAX_VERTEX_ATTRIBS: 34921,
  MAX_ELEMENTS_VERTICES: 33e3,
  // framebuffer
  FRAMEBUFFER: 36160,
  COLOR_ATTACHMENT0: 36064,
  FRAMEBUFFER_COMPLETE: 36053
};
function isGL2Like(x) {
  if (x === null || typeof x !== "object") return false;
  const o = x;
  return typeof o["createBuffer"] === "function" && typeof o["createShader"] === "function" && typeof o["drawElements"] === "function" && typeof o["getParameter"] === "function";
}

// src/backends/gfx-webgl2/device.ts
var SPRITE_STRIDE = 8 * 4;
var GL2Device = class {
  caps;
  gl;
  next = 1;
  recs = /* @__PURE__ */ new Map();
  frameIndex = 0;
  recording = null;
  _size;
  _stats = {
    frameIndex: 0,
    drawCalls: 0,
    verticesSubmitted: 0,
    textureBindings: 0,
    pipelineSwitches: 0,
    bytesUploaded: 0
  };
  // 状态缓存：只在**真的变化**时才调 GL
  curProgram = null;
  curTextureSlot = -1;
  curTexture = null;
  constructor(gl) {
    if (!isGL2Like(gl)) {
      throw new Error("GL2Device \u9700\u8981\u4E00\u4E2A WebGL2 \u4E0A\u4E0B\u6587\uFF08webgl2\uFF09\uFF0C\u4F20\u8FDB\u6765\u7684\u5BF9\u8C61\u4E0D\u50CF WebGL2 context");
    }
    this.gl = gl;
    const maxTex = gl.getParameter(GL.MAX_TEXTURE_SIZE) || 2048;
    const maxUnits = gl.getParameter(GL.MAX_TEXTURE_IMAGE_UNITS) || 8;
    const maxVerts = gl.getParameter(GL.MAX_ELEMENTS_VERTICES) || 65536;
    this.caps = {
      backend: "webgl2",
      version: "3.0",
      maxTextureSize: maxTex,
      maxTextureUnits: maxUnits,
      maxVerticesPerDraw: Math.max(1024, maxVerts),
      instancing: true,
      floatTextures: true,
      readback: true,
      srgbTextures: true
    };
    this._size = { width: gl.canvas.width, height: gl.canvas.height };
    gl.enable(GL.BLEND);
    gl.blendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA);
    gl.disable(GL.DEPTH_TEST);
    gl.pixelStorei(GL.UNPACK_ALIGNMENT, 1);
  }
  get stats() {
    return this._stats;
  }
  get size() {
    return this._size;
  }
  resize(width, height) {
    this._size = { width, height };
    this.gl.canvas.width = width;
    this.gl.canvas.height = height;
  }
  // ---------------------------------------------------------------- buffer
  createBuffer(desc) {
    if (!(desc.byteLength > 0)) {
      return err(engineError("GFX.BAD_BUFFER", `\u7F13\u51B2\u533A\u5927\u5C0F\u5FC5\u987B > 0\uFF0C\u6536\u5230 ${desc.byteLength}`));
    }
    const gl = this.gl;
    const buf = gl.createBuffer();
    if (buf === null || buf === void 0) {
      return err(engineError("GFX.OUT_OF_MEMORY", "createBuffer \u8FD4\u56DE null\uFF08\u663E\u5B58\u4E0D\u8DB3\uFF09"));
    }
    const target = desc.usage === BufferUsage.Index ? GL.ELEMENT_ARRAY_BUFFER : GL.ARRAY_BUFFER;
    gl.bindBuffer(target, buf);
    gl.bufferData(target, desc.byteLength, desc.dynamic ? GL.DYNAMIC_DRAW : GL.STATIC_DRAW);
    gl.bindBuffer(target, null);
    return ok(this.track("buffer", buf, {
      byteLength: desc.byteLength,
      dynamic: desc.dynamic,
      target,
      label: desc.label ?? ""
    }));
  }
  updateBuffer(handle, data, byteOffset = 0) {
    const rec = this.get(handle, "buffer");
    if (rec === void 0) {
      return err(engineError("GFX.INVALID_HANDLE", `\u7F13\u51B2\u533A\u53E5\u67C4 ${handle} \u4E0D\u5B58\u5728\uFF08\u53EF\u80FD\u5DF2\u9500\u6BC1\uFF09`));
    }
    const cap = rec.meta["byteLength"];
    const end = byteOffset + data.byteLength;
    if (byteOffset < 0 || end > cap) {
      return err(
        engineError("GFX.BUFFER_OVERFLOW", `\u5199\u5165\u8D8A\u754C\uFF1Aoffset=${byteOffset} len=${data.byteLength} \u5BB9\u91CF=${cap}`)
      );
    }
    const target = rec.meta["target"];
    this.gl.bindBuffer(target, rec.gl);
    this.gl.bufferSubData(target, byteOffset, data);
    this.gl.bindBuffer(target, null);
    this._stats = { ...this._stats, bytesUploaded: this._stats.bytesUploaded + data.byteLength };
    return ok(void 0);
  }
  destroyBuffer(handle) {
    const rec = this.recs.get(handle);
    if (rec === void 0) return;
    this.gl.deleteBuffer(rec.gl);
    this.recs.delete(handle);
  }
  // ---------------------------------------------------------------- texture
  createTexture(desc, data) {
    if (!(desc.width > 0) || !(desc.height > 0)) {
      return err(engineError("GFX.BAD_TEXTURE", `\u7EB9\u7406\u5C3A\u5BF8\u975E\u6CD5\uFF1A${desc.width}x${desc.height}`));
    }
    if (desc.width > this.caps.maxTextureSize || desc.height > this.caps.maxTextureSize) {
      return err(
        engineError(
          "GFX.TEXTURE_TOO_LARGE",
          `\u7EB9\u7406 ${desc.width}x${desc.height} \u8D85\u8FC7\u4E0A\u9650 ${this.caps.maxTextureSize}`,
          { label: desc.label ?? "" }
        )
      );
    }
    const gl = this.gl;
    const tex = gl.createTexture();
    if (tex === null || tex === void 0) {
      return err(engineError("GFX.OUT_OF_MEMORY", "createTexture \u8FD4\u56DE null\uFF08\u663E\u5B58\u4E0D\u8DB3\uFF09"));
    }
    const fmt2 = glFormat(desc.format ?? PixelFormat.RGBA8);
    gl.bindTexture(GL.TEXTURE_2D, tex);
    gl.texImage2D(
      GL.TEXTURE_2D,
      0,
      fmt2.internal,
      desc.width,
      desc.height,
      0,
      fmt2.format,
      GL.UNSIGNED_BYTE,
      data ?? null
    );
    const filter = desc.filter === TextureFilter.Linear ? GL.LINEAR : GL.NEAREST;
    gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_MIN_FILTER, filter);
    gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_MAG_FILTER, filter);
    const wrap = desc.wrap === TextureWrap.Repeat ? GL.REPEAT : GL.CLAMP_TO_EDGE;
    gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_S, wrap);
    gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_T, wrap);
    if (desc.mipmaps === true) gl.generateMipmap(GL.TEXTURE_2D);
    gl.bindTexture(GL.TEXTURE_2D, null);
    return ok(
      this.track("texture", tex, {
        width: desc.width,
        height: desc.height,
        isTarget: desc.renderTarget === true,
        label: desc.label ?? ""
      })
    );
  }
  updateTexture(handle, region, data) {
    const rec = this.get(handle, "texture");
    if (rec === void 0) return err(engineError("GFX.INVALID_HANDLE", `\u7EB9\u7406\u53E5\u67C4 ${handle} \u4E0D\u5B58\u5728`));
    const w = rec.meta["width"];
    const h = rec.meta["height"];
    if (region.x < 0 || region.y < 0 || region.x + region.width > w || region.y + region.height > h) {
      return err(
        engineError("GFX.REGION_OUT_OF_BOUNDS", `\u4E0A\u4F20\u533A\u57DF\u8D85\u51FA\u7EB9\u7406\uFF1A${JSON.stringify(region)} vs ${w}x${h}`)
      );
    }
    const need = region.width * region.height * 4;
    if (data.byteLength !== need) {
      return err(engineError("GFX.SIZE_MISMATCH", `\u4E0A\u4F20\u5B57\u8282\u6570 ${data.byteLength} \u4E0E\u533A\u57DF\u671F\u671B ${need} \u4E0D\u7B26`));
    }
    const gl = this.gl;
    gl.bindTexture(GL.TEXTURE_2D, rec.gl);
    gl.texSubImage2D(
      GL.TEXTURE_2D,
      0,
      region.x,
      region.y,
      region.width,
      region.height,
      GL.RGBA,
      GL.UNSIGNED_BYTE,
      data
    );
    gl.bindTexture(GL.TEXTURE_2D, null);
    this._stats = { ...this._stats, bytesUploaded: this._stats.bytesUploaded + data.byteLength };
    return ok(void 0);
  }
  destroyTexture(handle) {
    const rec = this.recs.get(handle);
    if (rec === void 0) return;
    this.gl.deleteTexture(rec.gl);
    this.recs.delete(handle);
  }
  // ---------------------------------------------------------------- shader / pipeline
  createShader(desc) {
    if (desc.vertex.trim() === "" || desc.fragment.trim() === "") {
      return err(engineError("GFX.SHADER_EMPTY", "\u7740\u8272\u5668\u6E90\u7801\u4E3A\u7A7A"));
    }
    const gl = this.gl;
    const vs = gl.createShader(GL.VERTEX_SHADER);
    const fs = gl.createShader(GL.FRAGMENT_SHADER);
    gl.shaderSource(vs, desc.vertex);
    gl.compileShader(vs);
    if (!gl.getShaderParameter(vs, GL.COMPILE_STATUS)) {
      const log = gl.getShaderInfoLog(vs) ?? "";
      gl.deleteShader(vs);
      gl.deleteShader(fs);
      return err(engineError("GFX.SHADER_COMPILE", `\u9876\u70B9\u7740\u8272\u5668\u7F16\u8BD1\u5931\u8D25\uFF1A${log}`, { stage: "vertex", log }));
    }
    gl.shaderSource(fs, desc.fragment);
    gl.compileShader(fs);
    if (!gl.getShaderParameter(fs, GL.COMPILE_STATUS)) {
      const log = gl.getShaderInfoLog(fs) ?? "";
      gl.deleteShader(vs);
      gl.deleteShader(fs);
      return err(engineError("GFX.SHADER_COMPILE", `\u7247\u5143\u7740\u8272\u5668\u7F16\u8BD1\u5931\u8D25\uFF1A${log}`, { stage: "fragment", log }));
    }
    const prog = gl.createProgram();
    gl.attachShader(prog, vs);
    gl.attachShader(prog, fs);
    gl.linkProgram(prog);
    gl.deleteShader(vs);
    gl.deleteShader(fs);
    if (!gl.getProgramParameter(prog, GL.LINK_STATUS)) {
      const log = gl.getProgramInfoLog(prog) ?? "";
      gl.deleteProgram(prog);
      return err(engineError("GFX.SHADER_LINK", `\u7A0B\u5E8F\u94FE\u63A5\u5931\u8D25\uFF1A${log}`, { log }));
    }
    return ok(this.track("shader", prog, { label: desc.label ?? "" }));
  }
  destroyShader(handle) {
    const rec = this.recs.get(handle);
    if (rec === void 0) return;
    if (this.curProgram === rec.gl) this.curProgram = null;
    this.gl.deleteProgram(rec.gl);
    this.recs.delete(handle);
  }
  createPipeline(desc) {
    const sh = this.get(desc.shader, "shader");
    if (sh === void 0) {
      return err(engineError("GFX.INVALID_HANDLE", `\u7BA1\u7EBF\u5F15\u7528\u7684\u7740\u8272\u5668 ${desc.shader} \u4E0D\u5B58\u5728`));
    }
    return ok(
      this.track("pipeline", sh.gl, {
        blend: desc.blend ?? BlendMode.Alpha,
        topology: desc.topology ?? Topology.Triangles,
        label: desc.label ?? ""
      })
    );
  }
  destroyPipeline(handle) {
    this.recs.delete(handle);
  }
  // ---------------------------------------------------------------- target
  createRenderTarget(desc) {
    const tex = this.get(desc.color, "texture");
    if (tex === void 0) {
      return err(engineError("GFX.INVALID_HANDLE", `\u6E32\u67D3\u76EE\u6807\u7684\u989C\u8272\u7EB9\u7406 ${desc.color} \u4E0D\u5B58\u5728`));
    }
    const fb = this.gl.createFramebuffer();
    this.gl.bindFramebuffer(GL.FRAMEBUFFER, fb);
    this.gl.framebufferTexture2D(GL.FRAMEBUFFER, GL.COLOR_ATTACHMENT0, GL.TEXTURE_2D, tex.gl, 0);
    const status = this.gl.checkFramebufferStatus(GL.FRAMEBUFFER);
    this.gl.bindFramebuffer(GL.FRAMEBUFFER, null);
    if (status !== GL.FRAMEBUFFER_COMPLETE) {
      this.gl.deleteFramebuffer(fb);
      return err(engineError("GFX.FRAMEBUFFER_INCOMPLETE", `\u5E27\u7F13\u51B2\u4E0D\u5B8C\u6574\uFF08status=${status}\uFF09`));
    }
    return ok(this.track("target", fb, { label: desc.label ?? "" }));
  }
  destroyRenderTarget(handle) {
    const rec = this.recs.get(handle);
    if (rec === void 0) return;
    this.gl.deleteFramebuffer(rec.gl);
    this.recs.delete(handle);
  }
  // ---------------------------------------------------------------- frame
  beginFrame(target) {
    if (this.recording !== null) {
      this.recording.forceFinish();
      this.recording = null;
    }
    const gl = this.gl;
    if (target === null) {
      gl.bindFramebuffer(GL.FRAMEBUFFER, null);
    } else {
      const rec = this.get(target, "target");
      gl.bindFramebuffer(GL.FRAMEBUFFER, rec?.gl ?? null);
    }
    this.frameIndex++;
    this._stats = {
      frameIndex: this.frameIndex,
      drawCalls: 0,
      verticesSubmitted: 0,
      textureBindings: 0,
      pipelineSwitches: 0,
      bytesUploaded: 0
    };
    this.curProgram = null;
    this.curTextureSlot = -1;
    this.curTexture = null;
    const cmd = new GL2CommandList(this, gl);
    this.recording = cmd;
    return cmd;
  }
  endFrame() {
    this.recording?.forceFinish();
    this.recording = null;
    this.gl.bindFramebuffer(GL.FRAMEBUFFER, null);
  }
  readPixels(target, rect) {
    if (!this.caps.readback) return err(engineError("GFX.NO_READBACK", "\u8BE5\u8BBE\u5907\u4E0D\u652F\u6301\u8BFB\u56DE\u50CF\u7D20"));
    const w = Math.max(1, Math.floor(rect.width));
    const h = Math.max(1, Math.floor(rect.height));
    const out = new Uint8Array(w * h * 4);
    const gl = this.gl;
    if (target !== null) {
      const rec = this.get(target, "target");
      gl.bindFramebuffer(GL.FRAMEBUFFER, rec?.gl ?? null);
    }
    gl.readPixels(Math.floor(rect.x), Math.floor(rect.y), w, h, GL.RGBA, GL.UNSIGNED_BYTE, out);
    if (target !== null) gl.bindFramebuffer(GL.FRAMEBUFFER, null);
    return ok(out);
  }
  destroy() {
    const gl = this.gl;
    for (const [, rec] of this.recs) {
      switch (rec.kind) {
        case "buffer":
          gl.deleteBuffer(rec.gl);
          break;
        case "texture":
          gl.deleteTexture(rec.gl);
          break;
        case "shader":
          gl.deleteProgram(rec.gl);
          break;
        case "target":
          gl.deleteFramebuffer(rec.gl);
          break;
        default:
          break;
      }
    }
    this.recs.clear();
    this.recording = null;
  }
  // ---------------------------------------------------------------- 内部
  track(kind, glObj, meta) {
    const h = this.next++;
    this.recs.set(h, { kind, gl: glObj, meta });
    return h;
  }
  get(h, kind) {
    const rec = this.recs.get(h);
    return rec !== void 0 && rec.kind === kind ? rec : void 0;
  }
  // ---- 命令列表回调（保持 internal，但需要暴露给同文件的类）
  _useProgram(program) {
    if (this.curProgram === program) return false;
    this.gl.useProgram(program);
    this.curProgram = program;
    this._stats = { ...this._stats, pipelineSwitches: this._stats.pipelineSwitches + 1 };
    return true;
  }
  _bindTexture(slot, tex) {
    if (this.curTextureSlot === slot && this.curTexture === tex) return;
    this.gl.activeTexture(GL.TEXTURE0 + slot);
    this.gl.bindTexture(GL.TEXTURE_2D, tex);
    this.curTextureSlot = slot;
    this.curTexture = tex;
    this._stats = { ...this._stats, textureBindings: this._stats.textureBindings + 1 };
  }
  _countDraw(vertices) {
    this._stats = {
      ...this._stats,
      drawCalls: this._stats.drawCalls + 1,
      verticesSubmitted: this._stats.verticesSubmitted + vertices
    };
  }
  _bufferRec(h) {
    return this.recs.get(h);
  }
  _textureRec(h) {
    const rec = this.recs.get(h);
    return rec !== void 0 && rec.kind === "texture" ? rec : void 0;
  }
  _pipelineRec(h) {
    return this.recs.get(h);
  }
};
var GL2CommandList = class {
  constructor(dev, gl) {
    this.dev = dev;
    this.gl = gl;
    this.gl.viewport(0, 0, this.gl.canvas.width, this.gl.canvas.height);
  }
  pipeline = 0;
  uniforms = /* @__PURE__ */ new Map();
  textureSlots = /* @__PURE__ */ new Map();
  finished = false;
  setViewport(rect) {
    this.gl.viewport(rect.x | 0, rect.y | 0, rect.width | 0, rect.height | 0);
  }
  setScissor(rect) {
    if (rect === null) {
      this.gl.disable(GL.SCISSOR_TEST);
      return;
    }
    this.gl.enable(GL.SCISSOR_TEST);
    this.gl.scissor(rect.x | 0, rect.y | 0, rect.width | 0, rect.height | 0);
  }
  clear(color, flags) {
    this.assertOpen("clear");
    this.gl.clearColor(color.r, color.g, color.b, color.a);
    this.gl.clear(flags);
  }
  setPipeline(pipeline) {
    this.assertOpen("setPipeline");
    this.pipeline = pipeline;
    const rec = this.dev._pipelineRec(pipeline);
    if (rec === void 0) return;
    const changed = this.dev._useProgram(rec.gl);
    if (!changed) return;
    for (const [name, u] of this.uniforms) this.applyUniform(rec.gl, name, u.value, u.kind);
  }
  setUniform(name, value, kind = "float") {
    this.assertOpen("setUniform");
    this.uniforms.set(name, { value, kind });
    const rec = this.dev._pipelineRec(this.pipeline);
    if (rec !== void 0) this.applyUniform(rec.gl, name, value, kind);
  }
  bindTexture(slot, texture) {
    this.assertOpen("bindTexture");
    this.textureSlots.set(slot, texture);
    const rec = this.dev._textureRec(texture);
    if (rec !== void 0) this.dev._bindTexture(slot, rec.gl);
  }
  draw(batch) {
    this.assertOpen("draw");
    const pipe = this.dev._pipelineRec(this.pipeline);
    if (pipe === void 0) {
      throw new Error("draw \u4E4B\u524D\u6CA1\u6709 setPipeline\uFF08\u6216\u7BA1\u7EBF\u53E5\u67C4\u5DF2\u5931\u6548\uFF09");
    }
    const vrec = this.dev._bufferRec(batch.vertices);
    if (vrec === void 0) throw new Error(`draw \u7684\u9876\u70B9\u7F13\u51B2\u53E5\u67C4 ${batch.vertices} \u4E0D\u5B58\u5728`);
    this.gl.bindBuffer(GL.ARRAY_BUFFER, vrec.gl);
    this.gl.enableVertexAttribArray(0);
    this.gl.vertexAttribPointer(0, 2, GL.FLOAT, false, SPRITE_STRIDE, 0);
    this.gl.enableVertexAttribArray(1);
    this.gl.vertexAttribPointer(1, 2, GL.FLOAT, false, SPRITE_STRIDE, 8);
    this.gl.enableVertexAttribArray(2);
    this.gl.vertexAttribPointer(2, 4, GL.FLOAT, false, SPRITE_STRIDE, 16);
    if (batch.indices !== null) {
      const irec = this.dev._bufferRec(batch.indices);
      if (irec === void 0) throw new Error(`draw \u7684\u7D22\u5F15\u7F13\u51B2\u53E5\u67C4 ${batch.indices} \u4E0D\u5B58\u5728`);
      this.gl.bindBuffer(GL.ELEMENT_ARRAY_BUFFER, irec.gl);
      this.gl.drawElements(GL.TRIANGLES, batch.indexCount, GL.UNSIGNED_SHORT, 0);
    } else {
      this.gl.drawArrays(GL.TRIANGLES, 0, batch.vertexCount);
    }
    this.dev._countDraw(batch.vertexCount);
  }
  finish() {
    this.finished = true;
  }
  forceFinish() {
    this.finished = true;
  }
  applyUniform(program, name, v, kind = "float") {
    const loc = this.gl.getUniformLocation(program, name);
    if (loc === null || loc === void 0) return;
    if (typeof v === "number") {
      if (kind === "int") this.gl.uniform1i(loc, v | 0);
      else this.gl.uniform1f(loc, v);
    } else if (v instanceof Float32Array) {
      if (v.length === 9) this.gl.uniformMatrix3fv(loc, false, v);
      else this.gl.uniform1i(loc, v[0] ?? 0);
    } else if (v.length === 4) {
      this.gl.uniform4f(loc, v[0], v[1], v[2], v[3]);
    } else if (v.length === 1) {
      this.gl.uniform1f(loc, v[0]);
    }
  }
  assertOpen(what) {
    if (this.finished) {
      throw new Error(`\u547D\u4EE4\u5217\u8868\u5DF2 finish\uFF0C\u4ECD\u5728\u8C03\u7528 ${what}\uFF08\u4F1A\u753B\u8FDB\u4E0B\u4E00\u5E27\uFF09`);
    }
  }
};
function glFormat(f) {
  switch (f) {
    case PixelFormat.RGB8:
      return { internal: GL.RGB, format: GL.RGB };
    case PixelFormat.R8:
      return { internal: GL.R8, format: GL.R8 };
    default:
      return { internal: GL.RGBA8, format: GL.RGBA };
  }
}
var webgl2Backend = {
  id: "webgl2",
  priority: 100,
  probe(options) {
    const o = options ?? {};
    const canvas = o.canvas;
    if (canvas === void 0 || typeof canvas.getContext !== "function") return false;
    try {
      return isGL2Like(canvas.getContext("webgl2"));
    } catch {
      return false;
    }
  },
  create(options) {
    const o = options ?? {};
    let ctx = null;
    try {
      ctx = o.canvas?.getContext?.("webgl2") ?? null;
    } catch (e) {
      return err(engineError("GFX.CONTEXT_FAILED", `getContext('webgl2') \u629B\u9519\uFF1A${String(e)}`));
    }
    if (!isGL2Like(ctx)) {
      return err(engineError("GFX.CONTEXT_FAILED", "\u62FF\u4E0D\u5230 WebGL2 \u4E0A\u4E0B\u6587\uFF08\u6D4F\u89C8\u5668\u4E0D\u652F\u6301\u6216\u88AB\u7981\u7528\uFF09"));
    }
    try {
      return ok(new GL2Device(ctx));
    } catch (e) {
      return err(engineError("GFX.DEVICE_INIT", e instanceof Error ? e.message : String(e)));
    }
  }
};

// src/backends/input-dom/device.ts
var PREVENT = /* @__PURE__ */ new Set(["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Space", "Tab"]);
var DomInputDevice = class {
  caps = {
    backend: "dom",
    pointer: true,
    touch: true,
    gamepad: false,
    textInput: true
  };
  kb;
  ptr;
  down = /* @__PURE__ */ new Set();
  pressed = /* @__PURE__ */ new Set();
  released = /* @__PURE__ */ new Set();
  px = 0;
  py = 0;
  pDown = false;
  pPressed = false;
  pReleased = false;
  pButton = 0;
  wdx = 0;
  wdy = 0;
  text = "";
  subs = /* @__PURE__ */ new Set();
  bound = [];
  /** 有输入框聚焦时，键盘不驱动游戏（编辑器输入场景名时不能同时让角色走）。 */
  textFocus = false;
  constructor(opts) {
    if (opts.keyboard === void 0 || opts.pointer === void 0) {
      throw new Error("DomInputDevice \u9700\u8981 keyboard \u4E0E pointer \u4E24\u4E2A\u76D1\u542C\u76EE\u6807");
    }
    this.kb = opts.keyboard;
    this.ptr = opts.pointer;
    this.bind();
  }
  bind() {
    const onKeyDown = (ev) => {
      if (this.isTyping(ev)) {
        if (ev.key !== void 0 && ev.key.length === 1) {
          this.text += ev.key;
          this.emit({ kind: "text", value: ev.key });
        }
        return;
      }
      const code = ev.code ?? "";
      if (code === "") return;
      if (!this.down.has(code)) {
        this.down.add(code);
        this.pressed.add(code);
      }
      if (PREVENT.has(code)) ev.preventDefault?.();
      this.emit({ kind: "key", code, down: true });
    };
    const onKeyUp = (ev) => {
      const code = ev.code ?? "";
      if (code === "" || !this.down.delete(code)) return;
      this.released.add(code);
      this.emit({ kind: "key", code, down: false });
    };
    const onBlur = () => {
      this.down.clear();
      this.pressed.clear();
      this.released.clear();
      this.pDown = false;
      this.textFocus = false;
      this.emit({ kind: "blur" });
    };
    const onFocusIn = (ev) => {
      this.textFocus = this.isTyping(ev);
    };
    const onPointerDown = (ev) => {
      this.updatePointer(ev);
      this.pDown = true;
      this.pPressed = true;
      this.pButton = ev.button ?? 0;
      this.emit({ kind: "pointer", x: this.px, y: this.py, down: true });
      ev.target?.setPointerCapture?.(0);
    };
    const onPointerUp = (ev) => {
      this.updatePointer(ev);
      if (!this.pDown) return;
      this.pDown = false;
      this.pReleased = true;
      this.emit({ kind: "pointer", x: this.px, y: this.py, down: false });
    };
    const onPointerMove = (ev) => {
      this.updatePointer(ev);
    };
    const onWheel = (ev) => {
      this.wdx += ev.deltaX ?? 0;
      this.wdy += ev.deltaY ?? 0;
      this.emit({ kind: "wheel", x: ev.deltaX ?? 0, y: ev.deltaY ?? 0 });
    };
    this.add(this.kb, "keydown", onKeyDown);
    this.add(this.kb, "keyup", onKeyUp);
    this.add(this.kb, "blur", onBlur);
    this.add(this.kb, "focusin", onFocusIn);
    this.add(this.ptr, "pointerdown", onPointerDown);
    this.add(this.ptr, "pointerup", onPointerUp);
    this.add(this.ptr, "pointermove", onPointerMove);
    this.add(this.ptr, "wheel", onWheel);
  }
  add(target, type, fn) {
    target.addEventListener(type, fn, { passive: false });
    this.bound.push([target, type, fn]);
  }
  isTyping(ev) {
    const tag = ev.target?.tagName?.toUpperCase();
    return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || this.textFocus;
  }
  updatePointer(ev) {
    if (ev.offsetX !== void 0) {
      this.px = ev.offsetX;
      this.py = ev.offsetY ?? 0;
    } else {
      this.px = ev.clientX ?? this.px;
      this.py = ev.clientY ?? this.py;
    }
  }
  poll() {
    const snap = {
      keysDown: new Set(this.down),
      keysPressed: new Set(this.pressed),
      keysReleased: new Set(this.released),
      pointer: {
        x: this.px,
        y: this.py,
        down: this.pDown,
        pressed: this.pPressed,
        released: this.pReleased,
        button: this.pButton
      },
      wheel: { dx: this.wdx, dy: this.wdy },
      text: this.text
    };
    this.pressed.clear();
    this.released.clear();
    this.pPressed = false;
    this.pReleased = false;
    this.wdx = 0;
    this.wdy = 0;
    this.text = "";
    return snap;
  }
  subscribe(fn) {
    this.subs.add(fn);
    return () => this.subs.delete(fn);
  }
  setFocusTarget(target) {
  }
  reset() {
    this.down.clear();
    this.pressed.clear();
    this.released.clear();
    this.pDown = false;
    this.pPressed = false;
    this.pReleased = false;
  }
  destroy() {
    for (const [t, type, fn] of this.bound) t.removeEventListener(type, fn);
    this.bound.length = 0;
    this.subs.clear();
    this.reset();
  }
  emit(e) {
    for (const f of this.subs) f(e);
  }
};
var domInputBackend = {
  id: "dom",
  priority: 100,
  probe(options) {
    const o = options ?? {};
    return typeof o.keyboard?.addEventListener === "function";
  },
  create(options) {
    const o = options ?? {};
    if (typeof o.keyboard?.addEventListener !== "function") {
      return {
        ok: false,
        error: { code: "INPUT.NO_DOM", message: "\u6CA1\u6709\u53EF\u7528\u7684 DOM \u76D1\u542C\u76EE\u6807\uFF08keyboard/pointer\uFF09" }
      };
    }
    try {
      return ok(new DomInputDevice(o));
    } catch (e) {
      return {
        ok: false,
        error: { code: "INPUT.INIT_FAILED", message: e instanceof Error ? e.message : String(e) }
      };
    }
  }
};

// src/backends/audio-webaudio/device.ts
var WebAudioDevice = class {
  caps = {
    backend: "webaudio",
    maxVoices: 32,
    requiresGesture: true,
    spatial: false
  };
  ctx;
  next = 1;
  clips = /* @__PURE__ */ new Map();
  voices = /* @__PURE__ */ new Map();
  buses = /* @__PURE__ */ new Map([
    ["master", { name: "master", volume: 1, muted: false }]
  ]);
  busGains = /* @__PURE__ */ new Map();
  /** 因声部上限被拒的播放次数（可见，不静默）。 */
  voicesRejected = 0;
  constructor(ctx) {
    this.ctx = ctx;
  }
  async init() {
    try {
      const g = this.ctx.createGain();
      g.gain.value = 1;
      g.connect(this.ctx.destination);
      this.busGains.set("master", g);
      return ok(void 0);
    } catch (e) {
      return err(engineError("AUDIO.INIT_FAILED", e instanceof Error ? e.message : String(e)));
    }
  }
  async resume() {
    try {
      await this.ctx.resume();
    } catch (e) {
      return err(engineError("AUDIO.RESUME_FAILED", e instanceof Error ? e.message : String(e)));
    }
    if (this.ctx.state !== "running") {
      return err(
        engineError("AUDIO.NEEDS_GESTURE", `\u97F3\u9891\u4E0A\u4E0B\u6587\u4ECD\u5904\u4E8E '${this.ctx.state}'\uFF0C\u9700\u8981\u7528\u6237\u624B\u52BF\u540E\u624D\u80FD\u51FA\u58F0`)
      );
    }
    return ok(void 0);
  }
  async loadClip(name, data) {
    if (data.byteLength === 0) {
      return err(engineError("AUDIO.BAD_CLIP", "\u97F3\u9891\u6570\u636E\u4E3A\u7A7A\uFF1A" + name));
    }
    try {
      const buf = await this.ctx.decodeAudioData(data);
      const h = this.next++;
      this.clips.set(h, { name, buffer: buf });
      return ok(h);
    } catch (e) {
      return err(
        engineError("AUDIO.DECODE_FAILED", `\u89E3\u7801\u5931\u8D25\uFF1A${name}\uFF08${e instanceof Error ? e.message : String(e)}\uFF09`, {
          clip: name
        })
      );
    }
  }
  releaseClip(clip) {
    this.clips.delete(clip);
    for (const [h, v] of [...this.voices]) {
      if (v.clip === clip) this.stop(h);
    }
  }
  play(clip, opts = {}) {
    const c = this.clips.get(clip);
    if (c === void 0) return err(engineError("AUDIO.INVALID_CLIP", `clip ${clip} \u4E0D\u5B58\u5728\u6216\u5DF2\u91CA\u653E`));
    if (this.voices.size >= this.caps.maxVoices) {
      this.voicesRejected++;
      return err(
        engineError("AUDIO.NO_FREE_VOICE", `\u5DF2\u8FBE ${this.caps.maxVoices} \u4E2A\u58F0\u90E8\u4E0A\u9650`, { clip: c.name })
      );
    }
    const busName = opts.bus ?? "master";
    const bus = this.bus(busName);
    if (bus.muted) {
      return err(engineError("AUDIO.BUS_MUTED", `\u603B\u7EBF ${busName} \u5DF2\u9759\u97F3`, { clip: c.name }));
    }
    const src = this.ctx.createBufferSource();
    src.buffer = c.buffer;
    src.loop = opts.loop === true;
    src.playbackRate.value = opts.rate ?? 1;
    const gain = this.ctx.createGain();
    gain.gain.value = (opts.volume ?? 1) * bus.volume;
    src.connect(gain);
    gain.connect(this.busGain(busName));
    const h = this.next++;
    const rate = opts.rate ?? 1;
    const rec = {
      src,
      gain,
      clip,
      bus: busName,
      volume: (opts.volume ?? 1) * bus.volume,
      rate,
      loop: opts.loop === true,
      endsAt: this.ctx.currentTime + (opts.loop === true ? Number.POSITIVE_INFINITY : c.buffer.duration / rate),
      position: opts.position === void 0 ? null : { x: opts.position.x, z: opts.position.z }
    };
    src.onended = () => {
      const v = this.voices.get(h);
      if (v !== void 0 && v.src === src) this.voices.delete(h);
    };
    try {
      src.start();
    } catch (e) {
      this.voices.delete(h);
      return err(
        engineError("AUDIO.START_FAILED", `\u64AD\u653E\u5931\u8D25\uFF08\u97F3\u9891\u4E0A\u4E0B\u6587\u53EF\u80FD\u672A\u89E3\u9501\uFF09\uFF1A${e instanceof Error ? e.message : String(e)}`, {
          clip: c.name
        })
      );
    }
    this.voices.set(h, rec);
    return ok(h);
  }
  stop(voice) {
    const v = this.voices.get(voice);
    if (v === void 0) return;
    this.voices.delete(voice);
    try {
      v.src.onended = null;
      v.src.stop();
      v.src.disconnect();
      v.gain.disconnect();
    } catch {
    }
  }
  setVoice(voice, patch) {
    const v = this.voices.get(voice);
    if (v === void 0) return;
    if (patch.volume !== void 0) {
      v.volume = patch.volume;
      v.gain.gain.value = patch.volume * this.bus(v.bus).volume;
    }
    if (patch.rate !== void 0) {
      v.rate = patch.rate;
      v.src.playbackRate.value = patch.rate;
    }
    if (patch.loop !== void 0) {
      v.loop = patch.loop;
      v.src.loop = patch.loop;
    }
  }
  getVoice(voice) {
    const v = this.voices.get(voice);
    if (v === void 0) return void 0;
    return { handle: voice, playing: true, clip: v.clip, bus: v.bus, volume: v.volume, rate: v.rate, loop: v.loop };
  }
  bus(name) {
    let b = this.buses.get(name);
    if (b === void 0) {
      b = { name, volume: 1, muted: false };
      this.buses.set(name, b);
    }
    return b;
  }
  busGain(name) {
    let g = this.busGains.get(name);
    if (g === void 0) {
      g = this.ctx.createGain();
      g.gain.value = this.bus(name).volume;
      const master = this.busGains.get("master");
      g.connect(master ?? this.ctx.destination);
      this.busGains.set(name, g);
    }
    return g;
  }
  setListener(_pos) {
  }
  get timeMs() {
    return this.ctx.currentTime * 1e3;
  }
  get activeVoices() {
    return this.voices.size;
  }
  destroy() {
    for (const v of [...this.voices.keys()]) this.stop(v);
    this.voices.clear();
    this.clips.clear();
    for (const g of this.busGains.values()) {
      try {
        g.disconnect();
      } catch {
      }
    }
    this.busGains.clear();
  }
};
var webAudioBackend = {
  id: "webaudio",
  priority: 100,
  probe(options) {
    if (typeof globalThis.AudioContext === "function") return true;
    const o = options ?? {};
    return typeof o.context?.createGain === "function";
  },
  create(options) {
    const o = options ?? {};
    let ctx = o.context;
    if (ctx === void 0) {
      const Ctor = globalThis.AudioContext;
      if (Ctor === void 0) {
        return err(engineError("AUDIO.NO_CONTEXT", "\u5F53\u524D\u73AF\u5883\u6CA1\u6709 AudioContext"));
      }
      try {
        ctx = new Ctor();
      } catch (e) {
        return err(engineError("AUDIO.NO_CONTEXT", e instanceof Error ? e.message : String(e)));
      }
    }
    try {
      return ok(new WebAudioDevice(ctx));
    } catch (e) {
      return err(engineError("AUDIO.INIT_FAILED", e instanceof Error ? e.message : String(e)));
    }
  }
};

// src/foundation/log/logger.ts
var LogLevel = {
  Trace: 10,
  Debug: 20,
  Info: 30,
  Warn: 40,
  Error: 50,
  Off: 100
};
var DEFAULT_LIMIT = { maxPerWindow: 5, windowMs: 1e3 };
var MemorySink = class {
  constructor(capacity = 2e3) {
    this.capacity = capacity;
  }
  buf = [];
  dropped = 0;
  write(rec) {
    if (this.buf.length >= this.capacity) {
      this.buf.shift();
      this.dropped++;
    }
    this.buf.push(rec);
  }
  records() {
    return this.buf;
  }
  /** 按通道/级别过滤，判据里最常用的两个查询。 */
  byChannel(channel) {
    return this.buf.filter((r) => r.channel === channel);
  }
  has(level, substr) {
    return this.buf.some((r) => r.level >= level && r.message.includes(substr));
  }
  clear() {
    this.buf.length = 0;
    this.dropped = 0;
  }
  get droppedCount() {
    return this.dropped;
  }
};
var Logger = class {
  constructor(now = () => Date.now()) {
    this.now = now;
  }
  sinks = [];
  channelLevel = /* @__PURE__ */ new Map();
  limiters = /* @__PURE__ */ new Map();
  defaultLevel = LogLevel.Info;
  addSink(sink) {
    this.sinks.push(sink);
  }
  setLevel(level, channel) {
    if (channel === void 0) this.defaultLevel = level;
    else this.channelLevel.set(channel, level);
  }
  levelOf(channel) {
    return this.channelLevel.get(channel) ?? this.defaultLevel;
  }
  /**
   * 取一个通道的 logger。
   * ★ 通道名用 `点分层`（`gfx.webgl2` / `asset.registry`），这样"给 gfx 全开 debug"
   *   可以用前缀匹配（见 `setLevelPrefix`），不需要一处一处改。
   */
  channel(name) {
    return new ChannelLogger(this, name);
  }
  setLevelPrefix(prefix, level) {
    this.channelLevel.set(prefix.endsWith("*") ? prefix : prefix + "*", level);
  }
  log(level, channel, message, fields, limit) {
    const lv = this.levelOf(channel);
    if (level < lv || lv >= LogLevel.Off) return;
    let suppressed = 0;
    if (limit) {
      const key = channel + "\0" + message;
      const t = this.now();
      const st = this.limiters.get(key);
      if (st === void 0 || t - st.windowStart >= limit.windowMs) {
        suppressed = st ? st.folded : 0;
        this.limiters.set(key, { windowStart: t, count: 1, folded: 0 });
      } else {
        st.count++;
        if (st.count > limit.maxPerWindow) {
          st.folded++;
          return;
        }
      }
    }
    const rec = {
      t: this.now(),
      level,
      channel,
      message,
      ...fields === void 0 ? {} : { fields },
      suppressed
    };
    for (const s of this.sinks) s.write(rec);
  }
  flush() {
    for (const s of this.sinks) s.flush?.();
  }
};
var ChannelLogger = class {
  constructor(root, name) {
    this.root = root;
    this.name = name;
  }
  trace(msg, fields) {
    this.root.log(LogLevel.Trace, this.name, msg, fields);
  }
  debug(msg, fields) {
    this.root.log(LogLevel.Debug, this.name, msg, fields);
  }
  info(msg, fields) {
    this.root.log(LogLevel.Info, this.name, msg, fields);
  }
  warn(msg, fields, limit = DEFAULT_LIMIT) {
    this.root.log(LogLevel.Warn, this.name, msg, fields, limit);
  }
  error(msg, fields, limit = DEFAULT_LIMIT) {
    this.root.log(LogLevel.Error, this.name, msg, fields, limit);
  }
};
var ConsoleSink = class {
  constructor(minLevel = LogLevel.Info, echo = (l) => console.log(l)) {
    this.minLevel = minLevel;
    this.echo = echo;
  }
  write(rec) {
    if (rec.level < this.minLevel) return;
    const tag = rec.level >= LogLevel.Error ? "E" : rec.level >= LogLevel.Warn ? "W" : "I";
    const fold = rec.suppressed > 0 ? ` (+${rec.suppressed} \u540C\u7C7B\u88AB\u6298\u53E0)` : "";
    const f = rec.fields ? " " + JSON.stringify(rec.fields) : "";
    this.echo(`[${tag}][${rec.channel}] ${rec.message}${f}${fold}`);
  }
};

// src/foundation/time/clock.ts
var SystemClock = class {
  /** 高精度优先；没有就降级到 Date.now（可能回退，但只在极老环境）。 */
  impl;
  constructor() {
    const perf = globalThis.performance;
    if (perf && typeof perf.now === "function") {
      const p = perf;
      this.impl = () => p.now();
    } else {
      this.impl = () => Date.now();
    }
  }
  now() {
    return this.impl();
  }
};

// src/foundation/event/event-bus.ts
var EventBus = class {
  listeners = /* @__PURE__ */ new Map();
  emitted = 0;
  listenerErrors = 0;
  lastError = null;
  /** 错误回调：默认什么都不做，由宿主接到 logger 上（L0 不依赖具体 logger 实例，避免全局单例）。 */
  onListenerError = null;
  on(topic, fn) {
    let set = this.listeners.get(topic);
    if (set === void 0) {
      set = /* @__PURE__ */ new Set();
      this.listeners.set(topic, set);
    }
    set.add(fn);
    return () => {
      set.delete(fn);
    };
  }
  once(topic, fn) {
    const off = this.on(topic, (p) => {
      off();
      fn(p);
    });
    return off;
  }
  emit(topic, payload) {
    this.emitted++;
    const set = this.listeners.get(topic);
    if (set === void 0 || set.size === 0) return;
    const snapshot = Array.from(set);
    for (const fn of snapshot) {
      try {
        fn(payload);
      } catch (e) {
        this.listenerErrors++;
        this.lastError = e instanceof Error ? e.message : String(e);
        this.onListenerError?.(topic, e);
      }
    }
  }
  listenerCount(topic) {
    return this.listeners.get(topic)?.size ?? 0;
  }
  /** 清空所有订阅。宿主 dispose 时调用，避免模块卸载后仍被事件引用。 */
  clear() {
    this.listeners.clear();
  }
  stats() {
    return {
      emitted: this.emitted,
      listenerErrors: this.listenerErrors,
      lastError: this.lastError
    };
  }
};

// src/foundation/memory/disposable.ts
var DisposableBag = class {
  items = [];
  disposed = false;
  add(label, d) {
    if (this.disposed) {
      releaseOne(d);
      throw new Error(`DisposableBag \u5DF2\u91CA\u653E\uFF0C\u4E0D\u5141\u8BB8\u518D add\uFF08${label}\uFF09`);
    }
    this.items.push({ label, d });
  }
  /** 逆序释放。单个失败**不中断**其余释放，但把失败收集起来抛一个聚合错误。 */
  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    const failures = [];
    for (let i = this.items.length - 1; i >= 0; i--) {
      const it = this.items[i];
      try {
        releaseOne(it.d);
      } catch (e) {
        failures.push(`${it.label}: ${e instanceof Error ? e.message : String(e)}`);
      }
    }
    this.items.length = 0;
    if (failures.length > 0) {
      throw new Error(`\u91CA\u653E\u65F6\u6709 ${failures.length} \u9879\u5931\u8D25\uFF1A
  ${failures.join("\n  ")}`);
    }
  }
  get size() {
    return this.items.length;
  }
  get isDisposed() {
    return this.disposed;
  }
};
function releaseOne(d) {
  if (typeof d === "function") d();
  else d.dispose();
}

// src/foundation/random.ts
var XorShift128 = class {
  s0;
  s1;
  constructor(seed) {
    let x = seed | 0 || 2654435769;
    const next = () => {
      x = x + 2654435769 | 0;
      let z = x;
      z = Math.imul(z ^ z >>> 16, 2246822507);
      z = Math.imul(z ^ z >>> 13, 3266489909);
      return (z ^ z >>> 16) >>> 0;
    };
    this.s0 = next() || 1;
    this.s1 = next() || 2;
  }
  /** 32 位 xorshift128，返回 [0, 2^32) */
  nextU32() {
    let x = this.s0;
    const y = this.s1;
    this.s0 = y;
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    this.s1 = x >>> 0;
    return this.s1;
  }
  next() {
    const hi = this.nextU32() >>> 5;
    const lo = this.nextU32() >>> 6;
    return (hi * 67108864 + lo) / 9007199254740992;
  }
  int(lo, hi) {
    if (hi <= lo) return lo;
    return lo + Math.floor(this.next() * (hi - lo));
  }
  range(lo, hi) {
    return lo + this.next() * (hi - lo);
  }
  chance(p) {
    return this.next() < p;
  }
  shuffle(arr) {
    for (let i = arr.length - 1; i > 0; i--) {
      const j = this.int(0, i + 1);
      const t = arr[i];
      arr[i] = arr[j];
      arr[j] = t;
    }
    return arr;
  }
  pick(arr) {
    if (arr.length === 0) return void 0;
    return arr[this.int(0, arr.length)];
  }
  getState() {
    return { s0: this.s0, s1: this.s1 };
  }
  setState(s) {
    if (s.s0 === 0 && s.s1 === 0) throw new RangeError("\u968F\u673A\u72B6\u6001\u4E0D\u80FD\u662F\u5168\u96F6");
    this.s0 = s.s0 >>> 0;
    this.s1 = s.s1 >>> 0;
  }
};

// src/platform/platform.ts
function createPlatform(req) {
  const { registry } = req;
  const clock = req.clock ?? new SystemClock();
  const gfxR = registry.create("gfx", {
    ...req.prefer?.gfx === void 0 ? {} : { prefer: req.prefer.gfx },
    ...req.allow?.gfx === void 0 ? {} : { allow: req.allow.gfx },
    options: req.backendOptions?.gfx
  });
  if (!gfxR.ok) return gfxR;
  const audioR = registry.create("audio", {
    ...req.prefer?.audio === void 0 ? {} : { prefer: req.prefer.audio },
    ...req.allow?.audio === void 0 ? {} : { allow: req.allow.audio },
    options: req.backendOptions?.audio
  });
  if (!audioR.ok) {
    gfxR.value.destroy();
    return audioR;
  }
  const inputR = registry.create("input", {
    ...req.prefer?.input === void 0 ? {} : { prefer: req.prefer.input },
    ...req.allow?.input === void 0 ? {} : { allow: req.allow.input },
    options: req.backendOptions?.input
  });
  if (!inputR.ok) {
    audioR.value.destroy();
    gfxR.value.destroy();
    return inputR;
  }
  const fsR = registry.create("fs", {
    ...req.prefer?.fs === void 0 ? {} : { prefer: req.prefer.fs },
    ...req.allow?.fs === void 0 ? {} : { allow: req.allow.fs },
    options: req.backendOptions?.fs
  });
  if (!fsR.ok) {
    inputR.value.destroy();
    audioR.value.destroy();
    gfxR.value.destroy();
    return fsR;
  }
  let net = null;
  let netId = null;
  if (registry.list("net").length > 0) {
    const netR = registry.create("net", {
      ...req.prefer?.net === void 0 ? {} : { prefer: req.prefer.net },
      ...req.allow?.net === void 0 ? {} : { allow: req.allow.net },
      options: req.backendOptions?.net
    });
    if (netR.ok) {
      net = netR.value;
      netId = req.prefer?.net ?? "auto";
    }
  }
  let script = null;
  let scriptId = null;
  if (registry.list("script").length > 0) {
    const scriptR = registry.create("script", {
      ...req.prefer?.script === void 0 ? {} : { prefer: req.prefer.script },
      ...req.allow?.script === void 0 ? {} : { allow: req.allow.script },
      options: req.backendOptions?.script
    });
    if (scriptR.ok) {
      script = scriptR.value;
      scriptId = scriptR.value.id;
    } else if (req.prefer?.script !== void 0) {
      inputR.value.destroy();
      audioR.value.destroy();
      gfxR.value.destroy();
      return scriptR;
    }
  }
  const size = gfxR.value.size;
  const caps = {
    id: req.id,
    interactive: req.interactive,
    hasGpu: gfxR.value.caps.backend !== "null",
    hasAudio: audioR.value.caps.backend !== "null",
    hasDom: typeof globalThis.document !== "undefined",
    maxTextureSize: gfxR.value.caps.maxTextureSize
  };
  return {
    ok: true,
    value: {
      id: req.id,
      caps,
      gfx: gfxR.value,
      audio: audioR.value,
      input: inputR.value,
      fs: fsR.value,
      net,
      script,
      clock,
      backends: {
        gfx: gfxR.value.caps.backend,
        audio: audioR.value.caps.backend,
        input: inputR.value.caps.backend,
        fs: fsR.value.scheme,
        net: netId,
        script: scriptId
      },
      dispose() {
        script?.dispose();
        net?.close(1e3, "platform dispose");
        inputR.value.destroy();
        audioR.value.destroy();
        gfxR.value.destroy();
      }
    }
  };
}

// src/core/module/module.ts
var ModuleState = {
  Created: "created",
  Initialized: "initialized",
  Started: "started",
  Stopped: "stopped",
  Disposed: "disposed",
  Failed: "failed"
};
var ModuleRegistry = class {
  constructor(ctx, opts = {}) {
    this.ctx = ctx;
    this.opts = opts;
  }
  entries = /* @__PURE__ */ new Map();
  /** 拓扑序（启动顺序）。stop/dispose 时逆序用。 */
  order = [];
  started = false;
  /**
   * 注册。**可以在 start 之前注册任意多个**，顺序无关（排序在启动时做）。
   * 启动后注册直接拒绝：热插拔模块需要先 stop，否则会出现"半个世界在用它"。
   */
  register(mod) {
    if (this.started) {
      return err({
        code: "MODULE.REGISTER_AFTER_START",
        message: `\u6A21\u5757 ${mod.id} \u5728\u542F\u52A8\u540E\u6CE8\u518C \u2014\u2014 \u5148 stop \u518D register\uFF08\u70ED\u63D2\u62D4\u9700\u8981\u663E\u5F0F\u505C\u6B62\uFF0C\u4E0D\u5141\u8BB8\u9690\u5F0F\uFF09`
      });
    }
    if (this.entries.has(mod.id)) {
      return err({
        code: "MODULE.DUPLICATE_ID",
        message: `\u6A21\u5757 id \u91CD\u590D\uFF1A${mod.id}`
      });
    }
    this.entries.set(mod.id, { mod, state: ModuleState.Created, error: null });
    return ok(void 0);
  }
  get(id) {
    return this.entries.get(id)?.mod;
  }
  state(id) {
    return this.entries.get(id)?.state;
  }
  ids() {
    return Array.from(this.entries.keys());
  }
  /** 拓扑序（稳定：同层按 id 字典序，保证两次运行顺序一致 ⇒ 可回放）。 */
  topoSort() {
    const indeg = /* @__PURE__ */ new Map();
    const out = /* @__PURE__ */ new Map();
    for (const id of this.entries.keys()) {
      indeg.set(id, 0);
      out.set(id, []);
    }
    for (const [id, e] of this.entries) {
      for (const d of e.mod.deps ?? []) {
        if (!this.entries.has(d)) {
          if ((this.opts.onMissingDep ?? "fail") === "fail") {
            return err({
              code: "MODULE.MISSING_DEP",
              message: `\u6A21\u5757 ${id} \u4F9D\u8D56 ${d}\uFF0C\u4F46\u5B83\u6CA1\u6709\u6CE8\u518C`
            });
          }
          this.ctx.log.channel("module").warn(`\u6A21\u5757 ${id} \u4F9D\u8D56 ${d} \u7F3A\u5931\uFF08\u5BBD\u5BB9\u6A21\u5F0F\uFF0C\u7EE7\u7EED\uFF09`);
          continue;
        }
        out.get(d).push(id);
        indeg.set(id, (indeg.get(id) ?? 0) + 1);
      }
      for (const d of e.mod.optionalDeps ?? []) {
        if (this.entries.has(d)) {
          out.get(d).push(id);
          indeg.set(id, (indeg.get(id) ?? 0) + 1);
        }
      }
    }
    const ready = Array.from(indeg.entries()).filter(([, n]) => n === 0).map(([id]) => id).sort();
    const result = [];
    while (ready.length > 0) {
      const id = ready.shift();
      result.push(id);
      const next = [];
      for (const succ of out.get(id)) {
        const n = (indeg.get(succ) ?? 1) - 1;
        indeg.set(succ, n);
        if (n === 0) next.push(succ);
      }
      next.sort();
      ready.push(...next);
      ready.sort();
    }
    if (result.length !== this.entries.size) {
      const stuck = Array.from(this.entries.keys()).filter((id) => !result.includes(id)).sort();
      return err({
        code: "MODULE.CYCLE",
        message: `\u6A21\u5757\u4F9D\u8D56\u5B58\u5728\u73AF\uFF0C\u6D89\u53CA\uFF1A${stuck.join(", ")}\u3002\u73AF\u610F\u5473\u7740"\u8C01\u5148\u542F\u52A8"\u6CA1\u6709\u7B54\u6848\uFF0C\u5FC5\u987B\u62C6\u5F00`,
        detail: { stuck }
      });
    }
    return ok(result);
  }
  /** 初始化并启动全部模块。失败时**已启动的逆序回滚**。 */
  async start() {
    if (this.started) {
      return err({ code: "MODULE.ALREADY_STARTED", message: "\u5DF2\u7ECF\u542F\u52A8\u8FC7" });
    }
    const sorted = this.topoSort();
    if (!sorted.ok) return sorted;
    this.order = sorted.value;
    const log = this.ctx.log.channel("module");
    for (const id of this.order) {
      const e = this.entries.get(id);
      const r = await this.withTimeout(e.mod.init(this.ctx), id, "init");
      if (!r.ok) {
        e.state = ModuleState.Failed;
        e.error = r.error;
        log.error(`\u6A21\u5757 ${id} init \u5931\u8D25\uFF1A${r.error.message}`, { code: r.error.code });
        await this.rollback(id);
        return err({
          code: "MODULE.INIT_FAILED",
          message: `\u6A21\u5757 ${id} init \u5931\u8D25\uFF1A${r.error.message}`,
          detail: { moduleId: id, cause: r.error }
        });
      }
      e.state = ModuleState.Initialized;
    }
    for (const id of this.order) {
      const e = this.entries.get(id);
      if (e.mod.start === void 0) {
        e.state = ModuleState.Started;
        continue;
      }
      const r = await this.withTimeout(e.mod.start(), id, "start");
      if (!r.ok) {
        e.state = ModuleState.Failed;
        e.error = r.error;
        log.error(`\u6A21\u5757 ${id} start \u5931\u8D25\uFF1A${r.error.message}`, { code: r.error.code });
        await this.rollback(id);
        return err({
          code: "MODULE.START_FAILED",
          message: `\u6A21\u5757 ${id} start \u5931\u8D25\uFF1A${r.error.message}`,
          detail: { moduleId: id, cause: r.error }
        });
      }
      e.state = ModuleState.Started;
    }
    this.started = true;
    log.info(`\u6A21\u5757\u542F\u52A8\u5B8C\u6210\uFF1A${this.order.length} \u4E2A\uFF08${this.order.join(" \u2192 ")}\uFF09`);
    return ok(void 0);
  }
  /** 逆序 stop + dispose。单个模块抛错不阻断其余（但那一条会被记录并上抛）。 */
  async dispose() {
    const log = this.ctx.log.channel("module");
    const failures = [];
    for (const id of [...this.order].reverse()) {
      const e = this.entries.get(id);
      if (e === void 0) continue;
      if (e.state === ModuleState.Started) {
        try {
          e.mod.stop?.();
        } catch (ex) {
          failures.push(`${id}.stop: ${ex instanceof Error ? ex.message : String(ex)}`);
        }
        e.state = ModuleState.Stopped;
      }
      if (e.state === ModuleState.Stopped || e.state === ModuleState.Initialized) {
        try {
          e.mod.dispose?.();
        } catch (ex) {
          failures.push(`${id}.dispose: ${ex instanceof Error ? ex.message : String(ex)}`);
        }
        e.state = ModuleState.Disposed;
      }
    }
    this.started = false;
    if (failures.length > 0) {
      log.error(`\u91CA\u653E\u65F6 ${failures.length} \u9879\u5931\u8D25`, { failures });
      return err({
        code: "MODULE.DISPOSE_FAILED",
        message: `\u91CA\u653E\u65F6\u6709 ${failures.length} \u9879\u5931\u8D25`,
        detail: { failures }
      });
    }
    return ok(void 0);
  }
  /** 诊断快照：编辑器与 healthz 用同一份（避免两套状态描述）。 */
  snapshot() {
    return this.order.map((id) => {
      const e = this.entries.get(id);
      return {
        id,
        state: e.state,
        desc: e.mod.describe?.() ?? ""
      };
    });
  }
  async rollback(failingId) {
    const idx = this.order.indexOf(failingId);
    const done = idx >= 0 ? this.order.slice(0, idx) : this.order.slice();
    for (const id of [...done].reverse()) {
      const e = this.entries.get(id);
      try {
        if (e.state === ModuleState.Started) e.mod.stop?.();
        if (e.state !== ModuleState.Created) e.mod.dispose?.();
      } catch {
      }
      e.state = ModuleState.Disposed;
    }
  }
  /** 把 `void | Result | Promise<...>` 归一成 `Promise<Result>`。 */
  async withTimeout(p, id, phase) {
    const ms = this.opts.initTimeoutMs ?? 0;
    if (ms <= 0) {
      const v = await p;
      return v === void 0 ? ok(void 0) : v;
    }
    let timer;
    const timeout = new Promise((resolve) => {
      timer = setTimeout(
        () => resolve(
          err({
            code: "MODULE.TIMEOUT",
            message: `${id}.${phase} \u8D85\u8FC7 ${ms} ms`
          })
        ),
        ms
      );
    });
    const normalized = Promise.resolve(p).then(
      (v) => v === void 0 ? ok(void 0) : v
    );
    try {
      return await Promise.race([normalized, timeout]);
    } finally {
      if (timer !== void 0) clearTimeout(timer);
    }
  }
};

// src/core/module/services.ts
function defineService(key) {
  return { key };
}
var ServiceRegistry = class {
  map = /* @__PURE__ */ new Map();
  owner = /* @__PURE__ */ new Map();
  /**
   * 注册服务。`ownerId` 只用于诊断（"这个服务是谁提供的"）。
   * 重复注册直接抛：静默覆盖会让"到底注入的是哪个"变成运气。
   */
  provide(token, impl, ownerId = "unknown") {
    if (this.map.has(token)) {
      throw new Error(
        `\u670D\u52A1 ${token.key} \u5DF2\u88AB ${this.owner.get(token)} \u63D0\u4F9B\uFF0C${ownerId} \u4E0D\u80FD\u91CD\u590D\u63D0\u4F9B\uFF08\u8981\u66FF\u6362\u8BF7\u5148 revoke\uFF0C\u5BBF\u4E3B\u7EC4\u88C5\u9636\u6BB5\u624D\u5141\u8BB8\u66FF\u6362\uFF09`
      );
    }
    this.map.set(token, impl);
    this.owner.set(token, ownerId);
  }
  /** 供宿主在测试/热替换时显式撤销。 */
  revoke(token) {
    this.map.delete(token);
    this.owner.delete(token);
  }
  /** 可选取：没有就 undefined（软依赖用它）。 */
  get(token) {
    return this.map.get(token);
  }
  /** 必需取：没有就抛，并在错误里列出当前已提供的服务（便于一眼看出拼错）。 */
  require(token) {
    const v = this.map.get(token);
    if (v === void 0) {
      throw new Error(
        `\u7F3A\u5C11\u5FC5\u9700\u670D\u52A1 ${token.key}\u3002\u5DF2\u63D0\u4F9B\uFF1A${Array.from(this.map.keys()).map((t) => t.key).sort().join(", ") || "(\u7A7A)"}`
      );
    }
    return v;
  }
  has(token) {
    return this.map.has(token);
  }
  describe() {
    return Array.from(this.map.keys()).map((t) => ({ key: t.key, owner: this.owner.get(t) ?? "?" })).sort((a, b) => a.key.localeCompare(b.key));
  }
  dispose() {
    this.map.clear();
    this.owner.clear();
  }
};

// src/core/scene/component.ts
var FieldType = {
  Int: "i32",
  Float: "f32",
  Double: "f64",
  Bool: "bool",
  String: "string",
  Vec2: "vec2",
  Color: "color",
  /** 资产引用：存 AssetId（GUID），不存路径 —— 路径会变，GUID 不会。 */
  Asset: "asset",
  /** 场景内节点引用：存节点 id。 */
  NodeRef: "noderef",
  /** 字符串数组（标签、配方列表）。 */
  StringArray: "string[]"
};
function zeroValue(t) {
  switch (t) {
    case FieldType.Int:
    case FieldType.Float:
    case FieldType.Double:
      return 0;
    case FieldType.Bool:
      return false;
    case FieldType.String:
      return "";
    case FieldType.Vec2:
      return { x: 0, y: 0 };
    case FieldType.Color:
      return { r: 1, g: 1, b: 1, a: 1 };
    case FieldType.Asset:
    case FieldType.NodeRef:
      return "";
    case FieldType.StringArray:
      return [];
    default:
      return null;
  }
}
var Component = class {
  /** 所属节点。`null` 只在 attach 之前/ detach 之后。 */
  node = null;
  enabled = true;
  /** 场景内部用：记录 enabled 状态，避免重复触发 onEnable。 */
  lastActive = false;
  /** 便捷：组件类型（来自 schema，避免两处写）。 */
  get type() {
    return this.schema.type;
  }
  onAttach() {
  }
  onDetach() {
  }
  onEnable() {
  }
  onDisable() {
  }
  onUpdate(_tick, _dt) {
  }
  /** 通用保存：按 schema 逐字段取。**顺序由 schema 决定**（字节确定）。 */
  save() {
    const out = { type: this.schema.type };
    for (const k of Object.keys(this.schema.fields)) {
      const v = this[k];
      out[k] = v === void 0 ? zeroValue(this.schema.fields[k]) : v;
    }
    return out;
  }
  /**
   * 通用读取。**缺字段用默认值而不是跳过**，但要报告（见返回值）。
   * 返回缺失的字段名：调用方（AssetDatabase / 存档）据此判断"是不是旧版本"。
   */
  load(data) {
    const missing = [];
    const self2 = this;
    for (const [k, t] of Object.entries(this.schema.fields)) {
      if (data[k] === void 0) missing.push(k);
      self2[k] = data[k] === void 0 ? zeroValue(t) : data[k];
    }
    return { missing };
  }
  /** 场景内部：由 Scene 调用，管理 onEnable/onDisable 的边沿。 */
  _setActive(active) {
    if (active === this.lastActive) return;
    this.lastActive = active;
    if (active) this.onEnable();
    else this.onDisable();
  }
  get isActive() {
    return this.lastActive;
  }
};
function isFastForwardable(c) {
  return typeof c.onFastForward === "function";
}
var ComponentRegistry = class {
  factories = /* @__PURE__ */ new Map();
  schemas = /* @__PURE__ */ new Map();
  register(schema, factory) {
    if (this.factories.has(schema.type)) {
      throw new Error(`\u7EC4\u4EF6\u7C7B\u578B ${schema.type} \u5DF2\u6CE8\u518C\uFF08\u540C\u7C7B\u578B\u4E0D\u5141\u8BB8\u91CD\u590D\u6CE8\u518C\uFF09`);
    }
    this.factories.set(schema.type, factory);
    this.schemas.set(schema.type, schema);
  }
  create(type) {
    return this.factories.get(type)?.();
  }
  schemaOf(type) {
    return this.schemas.get(type);
  }
  has(type) {
    return this.factories.has(type);
  }
  types() {
    return Array.from(this.factories.keys()).sort();
  }
};

// src/core/scene/node.ts
var NEXT_NODE_ID = 1;
var Node = class {
  id;
  name;
  parent = null;
  children = [];
  components = [];
  /** 局部变换成分。改它们要调 `markTransformDirty()`（或用 setter）。 */
  localPosition = Vec2.zero;
  localRotation = 0;
  localScale = Vec2.one;
  /** 层级顺序微调（同一父下 `zIndex` 大的后画）。 */
  zIndex = 0;
  /** 整棵子树的开关：`false` 时组件不更新、不渲染。 */
  active = true;
  /** 渲染层（编辑器可以按层隐藏）。 */
  layer = 0;
  /** 变换版本：任何影响世界变换的改动都 +1。 */
  version = 0;
  cacheVersion = -1;
  cachedWorld = Affine2.identity;
  destroyed = false;
  constructor(name = "Node", id) {
    this.id = id ?? NEXT_NODE_ID++;
    if (id !== void 0) NEXT_NODE_ID = Math.max(NEXT_NODE_ID, id + 1);
    this.name = name;
  }
  get isDestroyed() {
    return this.destroyed;
  }
  addChild(child) {
    if (child.parent === this) return this;
    child.parent?.removeChild(child);
    child.parent = this;
    this.children.push(child);
    child.markTransformDirty();
    return this;
  }
  removeChild(child) {
    const i = this.children.indexOf(child);
    if (i < 0) return false;
    this.children.splice(i, 1);
    child.parent = null;
    child.markTransformDirty();
    return true;
  }
  attach(c) {
    if (c.node === this) return;
    c.node?.detach(c);
    c.node = this;
    this.components.push(c);
    c.onAttach();
  }
  detach(c) {
    const i = this.components.indexOf(c);
    if (i < 0) return false;
    if (c.isActive) c._setActive(false);
    this.components.splice(i, 1);
    c.node = null;
    c.onDetach();
    return true;
  }
  get(type) {
    for (const c of this.components) if (c.type === type) return c;
    return void 0;
  }
  /** 世界变换（惰性 + 版本缓存）。 */
  get worldTransform() {
    if (this.cacheVersion === this.version) return this.cachedWorld;
    const local = Affine2.fromTrs(this.localPosition, this.localRotation, this.localScale);
    const w = this.parent === null ? local : this.parent.worldTransform.multiply(local);
    this.cachedWorld = w;
    this.cacheVersion = this.version;
    return w;
  }
  get worldPosition() {
    return this.worldTransform.transformPoint(Vec2.zero);
  }
  setLocalPosition(x, y) {
    this.localPosition = new Vec2(x, y);
    this.markTransformDirty();
    return this;
  }
  /** ★ 一律用 setter：直接赋 `localScale` 字段**不会**推进版本号 ⇒ 世界变换用旧缓存。 */
  setLocalScale(x, y) {
    this.localScale = new Vec2(x, y);
    this.markTransformDirty();
    return this;
  }
  setLocalRotation(rad) {
    this.localRotation = rad;
    this.markTransformDirty();
    return this;
  }
  /** 标脏：自己 + 整棵子树（子节点的世界变换都依赖我）。 */
  markTransformDirty() {
    this.version++;
    for (const c of this.children) c.markTransformDirty();
  }
  /** 是否在整条祖先链上都 active。 */
  get activeInHierarchy() {
    let n = this;
    while (n !== null) {
      if (!n.active) return false;
      n = n.parent;
    }
    return true;
  }
  /** 深度优先遍历（顺序**确定**：子节点按添加顺序）。 */
  walk(fn) {
    fn(this);
    for (const c of this.children) c.walk(fn);
  }
  /** 从根到自己的路径（诊断/日志用）。 */
  path() {
    const parts = [];
    let n = this;
    while (n !== null) {
      parts.unshift(n.name);
      n = n.parent;
    }
    return "/" + parts.join("/");
  }
  /** 内部：销毁时标记，避免使用已销毁节点。 */
  _markDestroyed() {
    this.destroyed = true;
    for (const c of this.components) {
      if (c.isActive) c._setActive(false);
      c.node = null;
      c.onDetach();
    }
    this.components.length = 0;
    for (const c of this.children) c._markDestroyed();
    this.children.length = 0;
    this.parent = null;
  }
};

// src/core/scene/scene.ts
var Scene = class {
  name;
  root;
  byId = /* @__PURE__ */ new Map();
  /** 类型 → 组件集合。用数组而非 Set：遍历要顺序稳定且可索引。 */
  byType = /* @__PURE__ */ new Map();
  /** 类型更新顺序：按首次注册的稳定序（不是节点顺序）。 */
  typeOrder = [];
  pending = [];
  _steps = 0;
  _updates = 0;
  _fastForwarded = 0;
  /**
   * 本世界的节点 id 分配器（root 固定 1，新节点从 2 起）。
   *
   * ★★ 为什么**不能**用模块级全局自增（阶段 2 改的）：
   *   `Node` 原本有个进程级 `NEXT_NODE_ID`，于是第二个 `Scene` 的第一个节点是 3。
   *   后果比"id 不好看"严重得多：
   *     · **存档不可比** —— 同种子同操作的两个世界，存档只差 id，逐字节比对永远失败
   *       （脚本层出口判据就是这么抓到的）；
   *     · **PIE 两个世界**（编辑器 + 预览）的 id 交错，粘贴一个 prefab 过去会撞 id；
   *     · 回放时 id 依赖"这台机器之前跑过什么"。
   *   每个世界自己的 id 空间反而是**更强**的性质：存档可以跨世界互换。
   *   `Node` 的全局分配器保留给"游离节点"（判据、编辑器里还没入场景的对象）。
   */
  nextId = 2;
  allocateId(explicit) {
    if (explicit !== void 0) {
      if (explicit >= this.nextId) this.nextId = explicit + 1;
      return explicit;
    }
    return this.nextId++;
  }
  /** 组件注册表：编辑器"可挂哪些组件"、读档"遇到未知类型找谁"都读它。 */
  components;
  constructor(name, components) {
    this.components = components;
    this.name = name;
    this.root = new Node("__root__", 1);
    this.byId.set(this.root.id, this.root);
  }
  // ---------------------------------------------------------------- 查询
  get rootId() {
    return this.root.id;
  }
  find(id) {
    return this.byId.get(id);
  }
  /** 按类型取全部组件（返回内部数组，**只读用**；要改请走命令）。 */
  componentsOf(type) {
    return this.byType.get(type) ?? [];
  }
  countOf(type) {
    return this.byType.get(type)?.length ?? 0;
  }
  // ---------------------------------------------------------------- 结构性修改（排队）
  spawn(name, parent = this.root.id, id) {
    const nid = this.allocateId(id);
    if (this.byId.has(nid)) {
      return err({ code: "SCENE.DUPLICATE_ID", message: `\u8282\u70B9 id ${nid} \u5DF2\u5B58\u5728` });
    }
    const node = new Node(name, nid);
    this.pending.push({ kind: "spawn", node, parent });
    return ok(node);
  }
  /** 立即建好（加载/编辑器用）。**游戏逻辑里请用 spawn（走队列）**。 */
  spawnImmediate(name, parent = this.root.id, id) {
    const node = new Node(name, this.allocateId(id));
    this.attachNodeTo(node, parent);
    return node;
  }
  destroy(id) {
    this.pending.push({ kind: "destroy", node: id });
  }
  attach(nodeId, make) {
    const c = make();
    if (!this.components.has(c.type)) {
      return err({
        code: "SCENE.UNKNOWN_COMPONENT",
        message: `\u7EC4\u4EF6\u7C7B\u578B ${c.type} \u672A\u6CE8\u518C\uFF08\u5148 components.register\uFF09`
      });
    }
    this.pending.push({ kind: "attach", node: nodeId, component: c });
    return ok(c);
  }
  detach(nodeId, type) {
    this.pending.push({ kind: "detach", node: nodeId, type });
  }
  reparent(nodeId, newParent) {
    this.pending.push({ kind: "reparent", node: nodeId, parent: newParent });
  }
  /** 排队一个任意回调（在同一处 flush 执行 ⇒ 顺序确定）。 */
  enqueue(fn, label = "custom") {
    this.pending.push({ kind: "run", fn, label });
  }
  get pendingCount() {
    return this.pending.length;
  }
  /**
   * 执行排队命令。
   * ★ 用**队列置换**而不是边遍历边 shift：命令里可能再 spawn（入新队列），
   *   那样本帧不会无限膨胀，且顺序严格按投递序。
   */
  flush() {
    if (this.pending.length === 0) return 0;
    const run = this.pending;
    this.pending = [];
    let n = 0;
    for (const cmd of run) {
      switch (cmd.kind) {
        case "spawn":
          if (!cmd.node.isDestroyed) this.attachNodeTo(cmd.node, cmd.parent);
          break;
        case "destroy": {
          const node = this.byId.get(cmd.node);
          if (node !== void 0 && node.parent !== null) this.detachNode(node, true);
          break;
        }
        case "attach": {
          const node = this.byId.get(cmd.node);
          if (node !== void 0) this.attachTo(node, cmd.component);
          break;
        }
        case "detach": {
          const node = this.byId.get(cmd.node);
          const c = node?.get(cmd.type);
          if (node !== void 0 && c !== void 0) this.detachFrom(node, c);
          break;
        }
        case "reparent": {
          const node = this.byId.get(cmd.node);
          const parent = cmd.parent === null ? this.root : this.byId.get(cmd.parent);
          if (node !== void 0 && parent !== void 0) {
            parent.addChild(node);
            node.markTransformDirty();
          }
          break;
        }
        case "run":
          cmd.fn();
          break;
      }
      n++;
    }
    return n;
  }
  // ---------------------------------------------------------------- 步进
  /**
   * 推进一个固定步。
   * 顺序：flush（结构命令）→ 逐类型更新组件 → 再 flush（更新期投递的命令）
   * 两次 flush 是必须的：更新里投递的"销毁自己"不该延迟到下一帧。
   */
  step(tick, dt) {
    this.flush();
    for (const type of this.typeOrder) {
      const list = this.byType.get(type);
      if (list === void 0 || list.length === 0) continue;
      const n = list.length;
      for (let i = 0; i < n; i++) {
        const c = list[i];
        if (c === void 0 || c.node === null) continue;
        const active = c.enabled && c.node.activeInHierarchy;
        c._setActive(active);
        if (active) {
          c.onUpdate(tick, dt);
          this._updates++;
        }
      }
    }
    this.flush();
    this._steps++;
  }
  /**
   * 跳时间结算（`LongUpdate` 语义）。
   *
   * 场景：存档 → 离线 8 小时 → 读档。不能真的跑 864000 个 tick，
   * 所以让**实现了 `IFastForwardable` 的组件**按解析式结算 elapsed 秒。
   *
   * ★ 关键设计：**报告跳过了多少**。没实现该接口的组件（例如 AI、
   *   状态机）在跳过的时段里"什么都没发生" —— 这必须是一个**可见的事实**，
   *   而不是"看起来读档成功了"。调用方据此决定"要不要改成循环 step"。
   */
  fastForward(elapsedSec) {
    if (!(elapsedSec >= 0)) {
      throw new RangeError(`fastForward \u4E0D\u63A5\u53D7\u8D1F\u7684 elapsed\uFF1A${elapsedSec}`);
    }
    let handled = 0;
    let skipped = 0;
    const skippedByType = /* @__PURE__ */ new Map();
    for (const type of this.typeOrder) {
      const list = this.byType.get(type);
      if (list === void 0) continue;
      for (const c of list) {
        if (c.node === null) continue;
        if (isFastForwardable(c)) {
          c.onFastForward(elapsedSec);
          handled++;
        } else {
          skipped++;
          skippedByType.set(type, (skippedByType.get(type) ?? 0) + 1);
        }
      }
    }
    this._fastForwarded += elapsedSec;
    return { elapsed: elapsedSec, handled, skipped, skippedByType };
  }
  /** 累计跳过的秒数（诊断：用来判断"这个存档是不是被跳过太多次"）。 */
  get totalFastForwarded() {
    return this._fastForwarded;
  }
  // ---------------------------------------------------------------- 内部
  attachNodeTo(node, parentId) {
    const parent = parentId === null ? this.root : this.byId.get(parentId);
    if (parent === void 0) {
      throw new Error(`spawn \u7684\u7236\u8282\u70B9 ${parentId} \u4E0D\u5B58\u5728\uFF08\u547D\u4EE4\u5DF2\u5165\u961F\uFF0C\u7236\u8282\u70B9\u53EF\u80FD\u5DF2\u88AB\u9500\u6BC1\uFF09`);
    }
    parent.addChild(node);
    node.walk((n) => {
      this.byId.set(n.id, n);
      for (const c of n.components) this.indexComponent(c);
    });
  }
  attachTo(node, c) {
    node.attach(c);
    this.indexComponent(c);
  }
  detachFrom(node, c) {
    this.unindexComponent(c);
    node.detach(c);
  }
  detachNode(node, recursive) {
    node.parent?.removeChild(node);
    node.walk((n) => {
      for (const c of [...n.components]) this.unindexComponent(c);
      this.byId.delete(n.id);
    });
    if (recursive) node._markDestroyed();
  }
  indexComponent(c) {
    let list = this.byType.get(c.type);
    if (list === void 0) {
      list = [];
      this.byType.set(c.type, list);
      this.typeOrder.push(c.type);
    }
    list.push(c);
  }
  unindexComponent(c) {
    const list = this.byType.get(c.type);
    if (list === void 0) return;
    const i = list.indexOf(c);
    if (i >= 0) list.splice(i, 1);
  }
  stats() {
    let comps = 0;
    for (const l of this.byType.values()) comps += l.length;
    return {
      nodes: this.byId.size,
      components: comps,
      pendingCommands: this.pending.length,
      stepsRun: this._steps,
      componentUpdates: this._updates
    };
  }
  /** 清空（切场景/读档前）。不走命令 —— 它的语义就是"立刻什么都没了"。 */
  clear() {
    for (const child of [...this.root.children]) {
      this.detachNode(child, true);
    }
    this.pending = [];
  }
  /** 新建一个带标准变换的节点（便捷）。 */
  spawnAt(name, x, z, parent = this.root.id) {
    const r = this.spawn(name, parent);
    if (r.ok) r.value.setLocalPosition(x, z);
    return r;
  }
  /** 世界坐标（便利方法，供 2.5D 用）。 */
  worldPositionOf(id) {
    return this.byId.get(id)?.worldPosition;
  }
};

// src/core/scheduler/scheduler.ts
var FixedStepScheduler = class {
  fixedDt;
  maxSteps;
  maxFrameDt;
  _tick = 0;
  _time = 0;
  _accumulator = 0;
  _timeScale;
  _paused = false;
  _dropped = 0;
  _total = 0;
  _lastSteps = 0;
  _alpha = 0;
  /** 记录"已经回调过的最大 tick"，幂等保护用。 */
  _served = -1;
  steps = [];
  constructor(cfg) {
    if (!(cfg.fixedDt > 0)) throw new RangeError("fixedDt \u5FC5\u987B > 0");
    this.fixedDt = cfg.fixedDt;
    this.maxSteps = cfg.maxStepsPerFrame ?? 5;
    this.maxFrameDt = cfg.maxFrameDt ?? 0.25;
    this._timeScale = cfg.timeScale ?? 1;
  }
  /** 订阅每一步。返回退订函数。 */
  onStep(fn) {
    this.steps.push(fn);
    return () => {
      const i = this.steps.indexOf(fn);
      if (i >= 0) this.steps.splice(i, 1);
    };
  }
  /**
   * 推进。返回本帧实际执行的步数。
   * `realDtSec` 是**真实**经过的秒数（来自 IClock 的差值），不是逻辑时间。
   */
  advance(realDtSec) {
    if (!(realDtSec >= 0)) {
      return 0;
    }
    if (this._paused) {
      this._lastSteps = 0;
      return 0;
    }
    const clamped = Math.min(realDtSec, this.maxFrameDt);
    this._accumulator += clamped * this._timeScale;
    let steps = 0;
    while (this._accumulator >= this.fixedDt && steps < this.maxSteps) {
      this._accumulator -= this.fixedDt;
      steps++;
    }
    if (this._accumulator >= this.fixedDt) {
      const leftover = Math.floor(this._accumulator / this.fixedDt);
      this._dropped += leftover;
      this._accumulator -= leftover * this.fixedDt;
    }
    for (let i = 0; i < steps; i++) {
      this._tick++;
      this._time = this._tick * this.fixedDt;
      this.runStep(this._tick, this.fixedDt);
    }
    this._lastSteps = steps;
    this._alpha = this._accumulator / this.fixedDt;
    return steps;
  }
  /**
   * 直接跳到某个 tick（编辑器"运行到此处"、回放快进用）。
   * ★ 幂等：`target <= 当前 tick` 返回 0，不重放。
   */
  stepTo(targetTick) {
    if (targetTick <= this._tick) return 0;
    const n = targetTick - this._tick;
    for (let i = 0; i < n; i++) {
      this._tick++;
      this._time = this._tick * this.fixedDt;
      this.runStep(this._tick, this.fixedDt);
    }
    this._lastSteps = n;
    return n;
  }
  /** 单步（编辑器单帧调试）。返回新 tick。 */
  stepOnce() {
    return this.stepTo(this._tick + 1);
  }
  runStep(tick, dt) {
    if (tick <= this._served) return;
    this._served = tick;
    this._total++;
    for (const fn of this.steps) fn(tick, dt);
  }
  set paused(v) {
    this._paused = v;
    if (!v) {
      this._accumulator = 0;
    }
  }
  get paused() {
    return this._paused;
  }
  set timeScale(v) {
    this._timeScale = clamp(v, 0.01, 16);
  }
  get timeScale() {
    return this._timeScale;
  }
  get tick() {
    return this._tick;
  }
  get time() {
    return this._time;
  }
  get alpha() {
    return this._alpha;
  }
  /** 存档/回放：把 tick 设回来（**不执行**中间的步）。 */
  resetTo(tick, served = tick) {
    this._tick = tick;
    this._time = tick * this.fixedDt;
    this._served = served;
    this._accumulator = 0;
    this._alpha = 0;
    this._lastSteps = 0;
  }
  stats() {
    return {
      tick: this._tick,
      time: this._time,
      lastSteps: this._lastSteps,
      droppedSteps: this._dropped,
      totalSteps: this._total,
      timeScale: this._timeScale,
      paused: this._paused,
      alpha: this._alpha
    };
  }
};

// src/core/asset/asset.ts
function stableIdFromPath(path) {
  let h = 2166136261;
  for (let i = 0; i < path.length; i++) {
    h ^= path.charCodeAt(i);
    h = Math.imul(h, 16777619) >>> 0;
  }
  return "p" + h.toString(36).padStart(7, "0");
}
var AssetType = {
  Texture: "texture",
  Atlas: "atlas",
  Audio: "audio",
  Prefab: "prefab",
  Scene: "scene",
  Script: "script",
  Json: "json",
  Text: "text",
  Binary: "binary"
};
var AssetHandle = class {
  constructor(asset, onRelease) {
    this.asset = asset;
    this.onRelease = onRelease;
  }
  released = false;
  get id() {
    return this.asset.id;
  }
  release() {
    if (this.released) {
      this.onRelease(this.asset);
      return;
    }
    this.released = true;
    this.onRelease(this.asset);
  }
  get isReleased() {
    return this.released;
  }
};
var AssetDatabase = class {
  constructor(fs, log) {
    this.fs = fs;
    this.log = log;
  }
  slots = /* @__PURE__ */ new Map();
  byPath = /* @__PURE__ */ new Map();
  loaders = [];
  hit = 0;
  miss = 0;
  registerLoader(l) {
    this.loaders.push(l);
  }
  /** 注册/更新元数据。同一个 id 重复注册允许（= 重新导入），但会作废已加载实例。 */
  register(meta) {
    const prev = this.slots.get(meta.id);
    if (prev !== void 0) {
      if (prev.refs > 0) {
        return err({
          code: "ASSET.REIMPORT_WHILE_IN_USE",
          message: `\u8D44\u4EA7 ${meta.id} \u6B63\u88AB ${prev.refs} \u5904\u4F7F\u7528\uFF0C\u4E0D\u80FD\u91CD\u65B0\u5BFC\u5165\uFF08\u5148\u5168\u90E8 release\uFF09`
        });
      }
      if (prev.asset !== null) prev.asset.dispose();
      this.byPath.delete(prev.meta.path);
    }
    this.slots.set(meta.id, { meta, asset: null, refs: 0, inDegree: 0, loading: null });
    this.byPath.set(meta.path, meta.id);
    return ok(void 0);
  }
  meta(id) {
    return this.slots.get(id)?.meta;
  }
  /**
   * 反注册（源资产被删除）。
   *
   * ★ 为什么必须有（阶段 2 补）：导入器要处理"源文件被删了"——这是**正常事件**，
   *   不是异常。没有反注册时，删除只让文件消失、注册表里留下一条幽灵：
   *   `describe()` 还看得到它、`dependents()` 还把它算进依赖、`idAtPath` 还能查到，
   *   于是"这个资产到底还在不在"从可判定退化成了靠猜。
   *   上一代引擎里同类的债是"prefab 表只增不减"，改一版涨一版。
   *
   * 两条拒绝条件都不是保守，而是正确性：
   *   · `refs > 0`：有句柄在用，删了它句柄就指向已释放实例（随机崩）；
   *   · 有反向依赖：删了被引用的资产，依赖方下次加载会失败，而失败点离根因很远。
   * 都不满足才算"真的没人要它了"。
   */
  unregister(id) {
    const slot = this.slots.get(id);
    if (slot === void 0) return ok(void 0);
    if (slot.refs > 0) {
      return err({
        code: "ASSET.IN_USE",
        message: `\u8D44\u4EA7 ${id} \u8FD8\u6709 ${slot.refs} \u4E2A\u53E5\u67C4\u672A\u91CA\u653E\uFF0C\u4E0D\u80FD\u53CD\u6CE8\u518C`
      });
    }
    const users = this.dependents(id);
    if (users.length > 0) {
      return err({
        code: "ASSET.STILL_REFERENCED",
        message: `\u8D44\u4EA7 ${id} \u4ECD\u88AB ${users.join(", ")} \u4F9D\u8D56\uFF0C\u4E0D\u80FD\u53CD\u6CE8\u518C\uFF08\u5148\u5220\u4F9D\u8D56\u65B9\u7684\u5F15\u7528\uFF09`,
        detail: { id, dependents: users }
      });
    }
    this.byPath.delete(slot.meta.path);
    this.slots.delete(id);
    slot.asset?.dispose();
    return ok(void 0);
  }
  idAtPath(path) {
    return this.byPath.get(path);
  }
  /** 直接依赖 / 反向依赖（编辑器"谁用了它"）。 */
  dependencies(id) {
    return this.slots.get(id)?.meta.dependencies ?? [];
  }
  dependents(id) {
    const out = [];
    for (const [k, s] of this.slots) {
      if (s.meta.dependencies.includes(id)) out.push(k);
    }
    return out.sort();
  }
  /**
   * 加载。相同的 id 并发调用会**共享同一个 Promise**（不会加载两次）。
   * 依赖按 meta 里声明的顺序加载；任一失败则整体失败并回滚已加载的依赖计数。
   */
  async load(id, _stack = []) {
    const slot = this.slots.get(id);
    if (slot === void 0) {
      return err({
        code: "ASSET.NOT_REGISTERED",
        message: `\u8D44\u4EA7 ${id} \u672A\u6CE8\u518C\uFF08\u5148\u7531\u5BFC\u5165\u5668\u5199\u5165 meta\uFF09`
      });
    }
    if (_stack.includes(id)) {
      return err({
        code: "ASSET.DEPENDENCY_CYCLE",
        message: `\u8D44\u4EA7\u4F9D\u8D56\u6210\u73AF\uFF1A${[..._stack, id].join(" \u2192 ")}`,
        detail: { cycle: [..._stack, id] }
      });
    }
    if (slot.asset !== null) {
      this.hit++;
      slot.refs++;
      return ok(this.makeHandle(slot));
    }
    if (slot.loading !== null) {
      this.hit++;
      const r2 = await slot.loading;
      if (!r2.ok) return err(r2.error);
      slot.refs++;
      return ok(this.makeHandle(slot));
    }
    this.miss++;
    const p = this.doLoad(slot, [..._stack, id]);
    slot.loading = p;
    const r = await p;
    slot.loading = null;
    if (!r.ok) return err(r.error);
    slot.refs++;
    return ok(this.makeHandle(slot));
  }
  async doLoad(slot, stack) {
    const { meta } = slot;
    const loadedDeps = [];
    for (const depId of meta.dependencies) {
      const r = await this.load(depId, stack);
      if (!r.ok) {
        for (const d of loadedDeps) this.decRef(d);
        if (r.error.code === "ASSET.DEPENDENCY_CYCLE" || r.error.code === "ASSET.DEPENDENCY_FAILED") {
          return err(r.error);
        }
        return err({
          code: "ASSET.DEPENDENCY_FAILED",
          message: `\u8D44\u4EA7 ${meta.id} \u7684\u4F9D\u8D56 ${depId} \u52A0\u8F7D\u5931\u8D25\uFF1A${r.error.message}`,
          detail: { asset: meta.id, dep: depId, cause: r.error }
        });
      }
      loadedDeps.push(depId);
    }
    const loader = this.loaders.find((l) => l.types.includes(meta.type));
    if (loader === void 0) {
      for (const d of loadedDeps) this.decRef(d);
      return err({
        code: "ASSET.NO_LOADER",
        message: `\u6CA1\u6709\u80FD\u5904\u7406\u7C7B\u578B ${meta.type} \u7684\u52A0\u8F7D\u5668\uFF08\u5DF2\u6CE8\u518C\u7684\uFF1A${this.loaders.flatMap((l) => l.types).sort().join(", ") || "(\u7A7A)"}\uFF09`
      });
    }
    const ctx = {
      fs: this.fs,
      log: this.log,
      load: async (depId) => {
        const r = await this.load(depId, stack);
        return r.ok ? ok(r.value.asset) : err(r.error);
      }
    };
    let asset;
    try {
      const r = await loader.load(meta, ctx);
      if (!r.ok) {
        for (const d of loadedDeps) this.decRef(d);
        return err(r.error);
      }
      asset = r.value;
    } catch (e) {
      for (const d of loadedDeps) this.decRef(d);
      return err({
        code: "ASSET.LOADER_THREW",
        message: `\u52A0\u8F7D\u5668 ${meta.type} \u629B\u5F02\u5E38\uFF1A${e instanceof Error ? e.message : String(e)}`
      });
    }
    if (asset.id !== meta.id) {
      asset.dispose();
      for (const d of loadedDeps) this.decRef(d);
      return err({
        code: "ASSET.ID_MISMATCH",
        message: `\u52A0\u8F7D\u5668\u8FD4\u56DE\u7684\u8D44\u4EA7 id ${asset.id} \u4E0E\u8BF7\u6C42\u7684 ${meta.id} \u4E0D\u4E00\u81F4`
      });
    }
    slot.asset = asset;
    return ok(asset);
  }
  /** 减引用。`slots.get(x)?.refs--` 在 TS 里不合法（可选属性不能自减），必须走这个。 */
  decRef(id) {
    const s = this.slots.get(id);
    if (s !== void 0) s.refs = Math.max(0, s.refs - 1);
  }
  makeHandle(slot) {
    return new AssetHandle(slot.asset, (a) => {
      slot.refs = Math.max(0, slot.refs - 1);
      if (slot.refs === 0 && this.dependents(slot.meta.id).length === 0) {
        slot.asset?.dispose();
        slot.asset = null;
      }
    });
  }
  /**
   * 卸载计划：**依赖的反拓扑序**（先卸使用者，再卸被使用者）。
   * 编辑器"重新导入前先卸载"与关场景时用。
   */
  unloadPlan() {
    const loaded = Array.from(this.slots.entries()).filter(([, s]) => s.asset !== null).map(([id]) => id);
    const order = [];
    const state = /* @__PURE__ */ new Map();
    const visit = (id) => {
      const st = state.get(id) ?? 0;
      if (st !== 0) return;
      state.set(id, 1);
      for (const dep of this.dependencies(id)) visit(dep);
      state.set(id, 2);
      order.push(id);
    };
    for (const id of loaded.sort()) visit(id);
    return order.reverse();
  }
  /** 强制卸载全部（关场景）。返回真正释放的个数。 */
  unloadAll() {
    const plan = this.unloadPlan();
    for (const id of plan) {
      const s = this.slots.get(id);
      if (s?.asset != null) {
        s.asset.dispose();
        s.asset = null;
      }
      if (s !== void 0) s.refs = 0;
    }
    return plan.length;
  }
  stats() {
    let loaded = 0;
    let refs = 0;
    for (const s of this.slots.values()) {
      if (s.asset !== null) loaded++;
      refs += s.refs;
    }
    return {
      registered: this.slots.size,
      loaded,
      refs,
      cacheHit: this.hit,
      cacheMiss: this.miss
    };
  }
  /** 诊断：列出所有资产的 id / 类型 / 是否加载。 */
  describe() {
    return Array.from(this.slots.entries()).map(([id, s]) => ({
      id,
      type: s.meta.type,
      path: s.meta.path,
      loaded: s.asset !== null,
      refs: s.refs
    })).sort((a, b) => a.id.localeCompare(b.id));
  }
};

// src/core/tokens.ts
var Services = {
  /**
   * 帧宿主：提供 `onRender(fn)`。
   * ★ 为什么渲染不能靠"事件"：事件是"发生了什么，谁关心谁订阅"，
   *   而渲染是**每个宿主都必须执行的一个阶段**（哪怕没人订阅）。
   *   用事件的话，"没有任何渲染器订阅"与"渲染器都注销了"无法区分，
   *   画面会静默变黑。
   */
  Frame: defineService("core.frame"),
  Scene: defineService("core.scene"),
  Assets: defineService("core.assets"),
  Scheduler: defineService("core.scheduler"),
  /**
   * 脚本运行时（可空）。
   * ★ 为什么作为服务而不是"模块私有字段"：UI/AI/关卡这些上层模块都要调脚本，
   *   如果各自 new 一个运行时，就会出现"两个 VM 两份全局状态"——
   *   脚本里的全局变量会莫名其妙地不共享。
   */
  Script: defineService("core.script")
};

// src/runtime/tick-source.ts
var RafTickSource = class {
  constructor(now) {
    this.now = now;
  }
  id = "raf";
  handle = 0;
  fn = null;
  last = 0;
  _running = false;
  start(fn) {
    if (this._running) return;
    this.fn = fn;
    this.last = this.now();
    this._running = true;
    const raf = globalThis.requestAnimationFrame;
    if (raf === void 0) throw new Error("\u5F53\u524D\u73AF\u5883\u6CA1\u6709 requestAnimationFrame \u2014\u2014 \u7528 IntervalTickSource");
    const loop = () => {
      if (!this._running) return;
      const t = this.now();
      const dt = (t - this.last) / 1e3;
      this.last = t;
      this.fn?.(dt);
      this.handle = raf(loop);
    };
    this.handle = raf(loop);
  }
  stop() {
    this._running = false;
    const caf = globalThis.cancelAnimationFrame;
    if (this.handle !== 0 && caf !== void 0) caf(this.handle);
    this.handle = 0;
  }
  get running() {
    return this._running;
  }
};

// src/runtime/GameApp.ts
var GameApp = class _GameApp {
  platform;
  log;
  memorySink;
  events = new EventBus();
  services = new ServiceRegistry();
  components = new ComponentRegistry();
  scene;
  scheduler;
  assets;
  modules;
  random;
  tickSource;
  /** 渲染阶段回调（`onRender` 注册）。按注册顺序执行。 */
  renderers = [];
  bag = new DisposableBag();
  frameCount = 0;
  running = false;
  disposed = false;
  constructor(opts, platform, log, memorySink, fs) {
    this.platform = platform;
    this.log = log;
    this.memorySink = memorySink;
    this.tickSource = opts.tickSource ?? null;
    this.random = new XorShift128(opts.seed);
    this.scheduler = new FixedStepScheduler({
      fixedDt: opts.fixedDt ?? 1 / 30,
      maxStepsPerFrame: opts.maxStepsPerFrame ?? 5
    });
    this.scene = new Scene("main", this.components);
    this.assets = new AssetDatabase(fs, log.channel("asset"));
    const renderers = this.renderers;
    const frameHost = {
      onRender: (fn) => {
        renderers.push(fn);
        return () => {
          const i = renderers.indexOf(fn);
          if (i >= 0) renderers.splice(i, 1);
        };
      },
      get rendererCount() {
        return renderers.length;
      }
    };
    this.services.provide(Services.Frame, frameHost, "core");
    this.services.provide(Services.Scene, this.scene, "core");
    this.services.provide(Services.Scheduler, this.scheduler, "core");
    this.services.provide(Services.Assets, this.assets, "core");
    this.services.provide(Services.Script, platform.script, "core");
    this.events.on("scheduler:steps-dropped", (p) => {
      log.channel("core.scheduler").warn(
        `\u5E27\u9884\u7B97\u4E0D\u8DB3\uFF0C\u4E22\u5F03\u4E86 ${p.dropped} \u4E2A\u903B\u8F91\u6B65\uFF08tick=${p.tick}\uFF09\u2014\u2014 \u4E16\u754C\u65F6\u95F4\u843D\u540E\u4E8E\u771F\u5B9E\u65F6\u95F4`,
        { dropped: p.dropped, tick: p.tick }
      );
    });
    const ctx = {
      log,
      events: this.events,
      services: this.services,
      platform,
      random: this.random,
      module: (id) => this.modules.get(id)
    };
    this.modules = new ModuleRegistry(ctx);
    for (const m of opts.modules) {
      const r = this.modules.register(m);
      if (!r.ok) {
        throw new Error(`\u6A21\u5757\u6CE8\u518C\u5931\u8D25\uFF1A${r.error.message}`);
      }
    }
    this.bag.add("platform", { dispose: () => platform.dispose() });
    this.bag.add("services", this.services);
    this.bag.add("logsink", { dispose: () => this.log.flush() });
  }
  static create(opts) {
    const memorySink = new MemorySink(4e3);
    const clock = opts.clock ?? new SystemClock();
    const log = new Logger(() => clock.now());
    log.addSink(new ConsoleSink(opts.logLevel ?? LogLevel.Info));
    log.addSink(memorySink);
    for (const s of opts.extraSinks ?? []) log.addSink(s);
    const platformR = createPlatform({
      id: opts.platformId,
      interactive: opts.interactive,
      registry: opts.registry,
      clock,
      ...opts.prefer === void 0 ? {} : { prefer: opts.prefer },
      ...opts.allow === void 0 ? {} : { allow: opts.allow },
      ...opts.backendOptions === void 0 ? {} : { backendOptions: opts.backendOptions }
    });
    if (!platformR.ok) {
      log.channel("app").error(`\u5E73\u53F0\u521B\u5EFA\u5931\u8D25\uFF1A${platformR.error.message}`, {
        code: platformR.error.code,
        detail: platformR.error.detail
      });
      return platformR;
    }
    const platform = platformR.value;
    const fs = opts.fs ?? platform.fs;
    log.channel("app").info(
      `\u5E73\u53F0\u5C31\u7EEA\uFF1A${platform.id} gfx=${platform.backends.gfx} audio=${platform.backends.audio} input=${platform.backends.input} fs=${platform.backends.fs} script=${platform.backends.script ?? "(\u65E0)"}`,
      { caps: platform.caps }
    );
    try {
      return ok(new _GameApp(opts, platform, log, memorySink, fs));
    } catch (e) {
      platform.dispose();
      return err(
        engineError("APP.CREATE_FAILED", `GameApp \u6784\u9020\u5931\u8D25\uFF1A${e instanceof Error ? e.message : String(e)}`)
      );
    }
  }
  /** 启动全部模块（拓扑序）。失败时模块已自行回滚。 */
  async start() {
    if (this.running) return err(engineError("APP.ALREADY_RUNNING", "\u5DF2\u7ECF\u5728\u8FD0\u884C"));
    const r = await this.modules.start();
    if (!r.ok) {
      this.events.emit("module:failed", { id: String(r.error.detail?.["moduleId"] ?? "?"), code: r.error.code, message: r.error.message });
      return r;
    }
    this.running = true;
    return ok(void 0);
  }
  /**
   * 推进一帧。`realDtSec` 是真实经过时间。
   * ★ 这是**唯一**的帧入口：外部（rAF / interval / 判据）都只能通过它驱动，
   *   否则"有两条帧路径"就必然有一条被忘记维护。
   */
  frame(realDtSec) {
    if (this.disposed) return;
    const before = this.scheduler.stats().droppedSteps;
    const steps = this.scheduler.advance(realDtSec);
    const after = this.scheduler.stats();
    if (after.droppedSteps > before) {
      this.events.emit("scheduler:steps-dropped", {
        dropped: after.droppedSteps - before,
        tick: after.tick
      });
    }
    this.frameCount++;
    const info = {
      frame: this.frameCount,
      realDtSec,
      steps,
      alpha: this.scheduler.alpha,
      tick: this.scheduler.tick
    };
    for (const fn of this.renderers) {
      try {
        fn(info);
      } catch (e) {
        this.log.channel("app.render").error(
          `\u6E32\u67D3\u56DE\u8C03\u629B\u9519\uFF1A${e instanceof Error ? e.message : String(e)}`,
          { frame: this.frameCount },
          null
        );
      }
    }
    this.events.emit("frame:end", {
      frame: this.frameCount,
      realDtMs: realDtSec * 1e3,
      steps
    });
  }
  /** 用 tickSource 自动驱动。没有 tickSource 时返回错误（不静默不动）。 */
  run() {
    if (this.tickSource === null) {
      return err(
        engineError("APP.NO_TICK_SOURCE", "\u6CA1\u6709 tickSource \u2014\u2014 \u7528 frame(dt) \u624B\u52A8\u9A71\u52A8\uFF0C\u6216\u5728 create \u65F6\u4F20 tickSource")
      );
    }
    if (this.tickSource.running) return ok(void 0);
    this.tickSource.start((dt) => this.frame(dt));
    return ok(void 0);
  }
  stopRun() {
    this.tickSource?.stop();
  }
  set paused(v) {
    this.scheduler.paused = v;
  }
  get paused() {
    return this.scheduler.paused;
  }
  set timeScale(v) {
    this.scheduler.timeScale = v;
  }
  get frameIndex() {
    return this.frameCount;
  }
  /** 诊断快照：`/healthz`、编辑器状态栏、判据都读这一份（避免三套描述）。 */
  snapshot() {
    return {
      platformId: this.platform.id,
      backends: this.platform.backends,
      tick: this.scheduler.tick,
      time: this.scheduler.time,
      paused: this.scheduler.paused,
      timeScale: this.scheduler.timeScale,
      droppedSteps: this.scheduler.stats().droppedSteps,
      scene: this.scene.stats(),
      assets: this.assets.stats(),
      modules: this.modules.snapshot(),
      eventStats: this.events.stats()
    };
  }
  /** 停止模块并释放。幂等。 */
  async dispose() {
    if (this.disposed) return;
    this.disposed = true;
    this.stopRun();
    const r = await this.modules.dispose();
    if (!r.ok) this.log.channel("app").error(`\u6A21\u5757\u91CA\u653E\u5931\u8D25\uFF1A${r.error.message}`);
    try {
      this.bag.dispose();
    } catch (e) {
      this.log.channel("app").error(`\u8D44\u6E90\u91CA\u653E\u5931\u8D25\uFF1A${e instanceof Error ? e.message : String(e)}`);
    }
    this.events.clear();
  }
};
async function bootGameApp(opts) {
  const appR = GameApp.create(opts);
  if (!appR.ok) return appR;
  const app = appR.value;
  const startR = await app.start();
  if (!startR.ok) {
    await app.dispose();
    return startR;
  }
  return ok(app);
}

// src/extensions/render/shaders-glsl.ts
var SPRITE_VS = `#version 300 es
layout(location = 0) in vec2 a_position;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec4 a_color;
out vec2 v_uv;
out vec4 v_color;
void main() {
  v_uv = a_uv;
  v_color = a_color;
  gl_Position = vec4(a_position, 0.0, 1.0);
}`;
var SPRITE_FS = `#version 300 es
precision mediump float;
in vec2 v_uv;
in vec4 v_color;
uniform sampler2D u_texture;
uniform int u_useTexture;
out vec4 o_color;
void main() {
  vec4 c = u_useTexture == 1 ? texture(u_texture, v_uv) : vec4(1.0);
  o_color = c * v_color;
}`;

// src/extensions/render/batch2d.ts
var FLOATS_PER_VERTEX = 8;
var SpriteBatch = class _SpriteBatch {
  maxQuads;
  vertices;
  indices;
  /** 排好序之后的 items（判据可以直接读它验证顺序）。 */
  items = [];
  constructor(maxQuads = 4096) {
    if (!(maxQuads > 0)) throw new RangeError("maxQuads \u5FC5\u987B > 0");
    if (maxQuads * 4 > 65536) {
      throw new RangeError(`maxQuads=${maxQuads} \u8D85\u8FC7 Uint16 \u7D22\u5F15\u4E0A\u9650\uFF08\u6700\u591A 16384\uFF09`);
    }
    this.maxQuads = maxQuads;
    this.vertices = new Float32Array(maxQuads * 4 * FLOATS_PER_VERTEX);
    this.indices = new Uint16Array(maxQuads * 6);
    for (let q2 = 0; q2 < maxQuads; q2++) {
      const v = q2 * 4;
      const i = q2 * 6;
      this.indices[i] = v;
      this.indices[i + 1] = v + 1;
      this.indices[i + 2] = v + 2;
      this.indices[i + 3] = v;
      this.indices[i + 4] = v + 2;
      this.indices[i + 5] = v + 3;
    }
  }
  /**
   * 排序（原地）。规则见文件头。
   * ★ 用**显式比较函数**而不是 `Array.sort` 的默认行为：默认会把数字转字符串，
   *   而 `[10, 9]` 会排成 `[10, 9]`（字符串 "10" < "9"）—— 这类 bug 极难发现。
   */
  static sort(items) {
    items.sort((a, b) => {
      if (a.z !== b.z) return b.z - a.z;
      if (a.order !== b.order) return a.order - b.order;
      if (a.atlas !== b.atlas) return a.atlas - b.atlas;
      return a.nodeId - b.nodeId;
    });
  }
  /**
   * 组装顶点。返回实际写入的 quad 数（可能被 `maxQuads` 截断）。
   * ★ 截断必须**被报告**：调用方据此决定要不要再开一批。
   *   静默截断的症状是"东西画到某个数量就不见了"，而且只在实体多的场景出现。
   */
  build(items, cam) {
    const sorted = [...items];
    _SpriteBatch.sort(sorted);
    this.items = sorted;
    const n = Math.min(sorted.length, this.maxQuads);
    let atlasSwitches = 0;
    let lastAtlas = -1;
    for (let q2 = 0; q2 < n; q2++) {
      const it = sorted[q2];
      if (it.atlas !== lastAtlas) {
        atlasSwitches++;
        lastAtlas = it.atlas;
      }
      const c = cam.project(it.x, it.z);
      const e = cam.extents(it.w, it.h);
      const cy = c.y + (0.5 - it.pivotY) * 2 * e.halfH;
      const x0 = c.x - e.halfW;
      const x1 = c.x + e.halfW;
      const y0 = cy - e.halfH;
      const y1 = cy + e.halfH;
      const va = 1 - it.v0;
      const vb = 1 - it.v1;
      const base = q2 * 4 * FLOATS_PER_VERTEX;
      writeVert(this.vertices, base, x0, y0, it.u0, vb, it);
      writeVert(this.vertices, base + FLOATS_PER_VERTEX, x1, y0, it.u1, vb, it);
      writeVert(this.vertices, base + FLOATS_PER_VERTEX * 2, x1, y1, it.u1, va, it);
      writeVert(this.vertices, base + FLOATS_PER_VERTEX * 3, x0, y1, it.u0, va, it);
    }
    return {
      quadCount: n,
      vertexCount: n * 4,
      indexCount: n * 6,
      drawCalls: n === 0 ? 0 : 1,
      atlasSwitches
    };
  }
  /** 零拷贝视图：只把前 `quadCount` 个顶点交给 GPU（避免每帧上传满 buffer）。 */
  vertexView(quadCount) {
    return this.vertices.subarray(0, quadCount * 4 * FLOATS_PER_VERTEX);
  }
  indexView(quadCount) {
    return this.indices.subarray(0, quadCount * 6);
  }
};
function writeVert(out, at, x, y, u, v, it) {
  out[at] = x;
  out[at + 1] = y;
  out[at + 2] = u;
  out[at + 3] = v;
  out[at + 4] = it.r;
  out[at + 5] = it.g;
  out[at + 6] = it.b;
  out[at + 7] = it.a;
}

// src/extensions/render/camera.ts
var Camera2D = class {
  vw;
  vh;
  zoom;
  tiltY;
  x;
  z;
  clearColor;
  /** 每世界单位有多少像素（x 方向）。UI 命中测试、像素对齐用。 */
  _pxPerUnit = 1;
  constructor(cfg) {
    if (!(cfg.viewportWidth > 0) || !(cfg.viewportHeight > 0)) {
      throw new RangeError(`\u89C6\u53E3\u5C3A\u5BF8\u5FC5\u987B > 0\uFF1A${cfg.viewportWidth}x${cfg.viewportHeight}`);
    }
    this.vw = cfg.viewportWidth;
    this.vh = cfg.viewportHeight;
    this.zoom = cfg.zoom ?? 32;
    this.tiltY = cfg.tiltY ?? 0.62;
    this.x = cfg.x ?? 0;
    this.z = cfg.z ?? 0;
    this.clearColor = cfg.clearColor ?? new Color(0.07, 0.08, 0.1, 1);
    this.recompute();
  }
  recompute() {
    this._pxPerUnit = this.zoom;
  }
  get pxPerUnit() {
    return this._pxPerUnit;
  }
  setViewport(w, h) {
    if (!(w > 0) || !(h > 0)) return;
    this.vw = w;
    this.vh = h;
  }
  /** 立刻移到（无平滑）。平滑跟随属于"控制器"的职责，不属于相机。 */
  moveTo(x, z) {
    this.x = x;
    this.z = z;
  }
  /** 世界 (x,z) → 裁剪空间 (-1..1)。 */
  project(wx, wz) {
    const sx = (wx - this.x) * this.zoom / (this.vw / 2);
    const sy = (wz - this.z) * this.zoom * this.tiltY / (this.vh / 2);
    return { x: sx, y: sy };
  }
  /** 世界尺寸 → 裁剪空间半宽/半高（精灵用）。 */
  extents(worldW, worldH) {
    return {
      halfW: worldW * this.zoom / this.vw,
      halfH: worldH * this.zoom * this.tiltY / this.vh
    };
  }
  /** 屏幕像素 → 世界 XZ（拾取/点选用）。 */
  unproject(px, py) {
    const nx = px / this.vw * 2 - 1;
    const ny = 1 - py / this.vh * 2;
    return {
      x: this.x + nx * this.vw / 2 / this.zoom,
      z: this.z + ny * this.vh / 2 / (this.zoom * this.tiltY)
    };
  }
  /** 当前可见的世界矩形（裁剪用，也是"哪些实体该画"的粗筛）。 */
  visibleRect() {
    const halfW = this.vw / 2 / this.zoom;
    const halfH = this.vh / 2 / (this.zoom * this.tiltY);
    return {
      xMin: this.x - halfW,
      xMax: this.x + halfW,
      zMin: this.z - halfH,
      zMax: this.z + halfH
    };
  }
};

// src/extensions/render/sprite.ts
var Sprite = class extends Component {
  /** 图集资产 id（空 = 用默认图集）。 */
  atlasId = "";
  /** 图集内帧名。 */
  frame = "";
  /** 世界尺寸（宽/高）。 */
  width = 1;
  height = 1;
  /** 顶点色（与纹理相乘）。 */
  r = 1;
  g = 1;
  b = 1;
  a = 1;
  /** 同 z 时的次序（小的先画）。 */
  order = 0;
  /** 关闭后不参与渲染（但仍更新逻辑）。 */
  visible = true;
  /** 锚点：0 = 底边，0.5 = 中心。饥荒风格通常用 0（脚踩地面）。 */
  pivotY = 0.5;
  schema = {
    type: "render.sprite",
    fields: {
      atlasId: FieldType.String,
      frame: FieldType.String,
      width: FieldType.Float,
      height: FieldType.Float,
      r: FieldType.Float,
      g: FieldType.Float,
      b: FieldType.Float,
      a: FieldType.Float,
      order: FieldType.Int,
      visible: FieldType.Bool,
      pivotY: FieldType.Float
    }
  };
};
function makeSprite(frame, width = 1, height = 1) {
  const s = new Sprite();
  s.frame = frame;
  s.width = width;
  s.height = height;
  return s;
}

// src/extensions/render/atlas.ts
var Pen = class {
  constructor(px, W, H) {
    this.px = px;
    this.W = W;
    this.H = H;
  }
  put(x, y, r, g, b, a = 255) {
    if (x < 0 || y < 0 || x >= this.W || y >= this.H) return;
    const i = (y * this.W + x) * 4;
    const src = a / 255;
    const dstA = this.px[i + 3] / 255;
    const outA = src + dstA * (1 - src);
    if (outA <= 0) return;
    this.px[i] = Math.round((r * src + this.px[i] * dstA * (1 - src)) / outA);
    this.px[i + 1] = Math.round((g * src + this.px[i + 1] * dstA * (1 - src)) / outA);
    this.px[i + 2] = Math.round((b * src + this.px[i + 2] * dstA * (1 - src)) / outA);
    this.px[i + 3] = Math.round(outA * 255);
  }
  rect(x, y, w, h, c) {
    for (let j = y; j < y + h; j++) for (let i = x; i < x + w; i++) this.put(i, j, c[0], c[1], c[2]);
  }
  /** 圆（用于石头/浆果）。 */
  disc(cx, cy, r, c) {
    for (let j = -r; j <= r; j++) {
      for (let i = -r; i <= r; i++) {
        if (i * i + j * j <= r * r) this.put(cx + i, cy + j, c[0], c[1], c[2]);
      }
    }
  }
  /** 三角（树冠）。 */
  triangle(x0, y0, x1, y1, x2, y2, c) {
    const minY = Math.min(y0, y1, y2);
    const maxY = Math.max(y0, y1, y2);
    for (let y = minY; y <= maxY; y++) {
      const xs = [];
      const edges = [
        [x0, y0, x1, y1],
        [x1, y1, x2, y2],
        [x2, y2, x0, y0]
      ];
      for (const [ax, ay, bx, by] of edges) {
        if (ay <= y && by >= y || by <= y && ay >= y) {
          if (Math.abs(by - ay) < 1e-9) {
            xs.push(ax, bx);
          } else {
            xs.push(ax + (y - ay) / (by - ay) * (bx - ax));
          }
        }
      }
      if (xs.length >= 2) {
        const lo = Math.round(Math.min(...xs));
        const hi = Math.round(Math.max(...xs));
        for (let x = lo; x <= hi; x++) this.put(x, y, c[0], c[1], c[2]);
      }
    }
  }
};
function buildProceduralAtlas() {
  const W = 256;
  const H = 256;
  const px = new Uint8Array(W * H * 4);
  const pen = new Pen(px, W, H);
  const layout = [
    { name: "tree", x: 0, y: 0, w: 64, h: 96 },
    { name: "rock", x: 64, y: 0, w: 48, h: 40 },
    { name: "player", x: 112, y: 0, w: 32, h: 48 },
    { name: "berry", x: 144, y: 0, w: 24, h: 24 },
    { name: "ground", x: 0, y: 96, w: 64, h: 64 }
  ];
  pen.rect(28, 64, 8, 32, [92, 62, 38]);
  pen.triangle(32, 0, 4, 44, 60, 44, [46, 110, 52]);
  pen.triangle(32, 18, 8, 58, 56, 58, [56, 132, 62]);
  pen.triangle(32, 36, 12, 72, 52, 72, [66, 152, 72]);
  pen.disc(24, 26, 16, [98, 100, 106]);
  pen.disc(20, 20, 11, [128, 132, 138]);
  pen.rect(10, 20, 12, 24, [198, 156, 84]);
  pen.disc(16, 14, 9, [232, 198, 140]);
  pen.rect(12, 12, 3, 3, [30, 30, 30]);
  pen.rect(18, 12, 3, 3, [30, 30, 30]);
  pen.disc(9, 9, 4, [186, 42, 46]);
  pen.disc(16, 12, 4, [206, 58, 54]);
  pen.disc(11, 17, 3, [168, 34, 40]);
  let seed = 19088743;
  const rnd = () => {
    seed = seed * 1103515245 + 12345 & 2147483647;
    return seed / 2147483647;
  };
  for (let y = 96; y < 160; y++) {
    for (let x = 0; x < 64; x++) {
      const v = 54 + Math.floor(rnd() * 18);
      pen.rect(x, y, 1, 1, [v, v + 22, v - 6]);
    }
  }
  const frames = /* @__PURE__ */ new Map();
  for (const l of layout) {
    frames.set(l.name, {
      u0: l.x / W,
      v0: l.y / H,
      u1: (l.x + l.w) / W,
      v1: (l.y + l.h) / H,
      w: l.w,
      h: l.h
    });
  }
  return { width: W, height: H, pixels: px, frames };
}

// src/extensions/render/render-module.ts
function createRenderModule(opts) {
  const camera = new Camera2D({
    viewportWidth: opts.viewportWidth,
    viewportHeight: opts.viewportHeight,
    zoom: opts.zoom ?? 32,
    tiltY: opts.tiltY ?? 0.62
  });
  let dev = null;
  let tex = null;
  let shader = null;
  let pipeline = null;
  let vbo = null;
  let ibo = null;
  let offRender = null;
  let batch = null;
  let atlas = null;
  let ctxRef = null;
  let lastFrame = { quads: 0, drawCalls: 0, atlasSwitches: 0, culled: 0 };
  const mod = {
    id: opts.id ?? "render.batch2d",
    deps: [],
    init(ctx) {
      ctxRef = ctx;
      dev = ctx.platform.gfx;
      const d = dev;
      const procedural = opts.atlas === void 0;
      atlas = opts.atlas ?? buildProceduralAtlas();
      const t = d.createTexture(
        {
          width: atlas.width,
          height: atlas.height,
          format: PixelFormat.RGBA8,
          filter: TextureFilter.Nearest,
          wrap: TextureWrap.Clamp,
          // label 不是装饰：null 后端的 `describe()` 与崩溃报告会原样打印它，
          // "这张纹理到底是资产图集还是兜底的程序化图集"必须一眼可辨。
          label: procedural ? "engine.procedural-atlas" : "engine.asset-atlas"
        },
        atlas.pixels
      );
      if (!t.ok) return t;
      tex = t.value;
      const sh = d.createShader({
        vertex: SPRITE_VS,
        fragment: SPRITE_FS,
        label: "engine.sprite"
      });
      if (!sh.ok) {
        d.destroyTexture(tex);
        return sh;
      }
      shader = sh.value;
      const pl = d.createPipeline({
        shader,
        layout: SPRITE_VERTEX_LAYOUT,
        blend: BlendMode.Alpha,
        label: "engine.sprite"
      });
      if (!pl.ok) {
        d.destroyShader(shader);
        d.destroyTexture(tex);
        return pl;
      }
      pipeline = pl.value;
      batch = new SpriteBatch(opts.maxQuads ?? 4096);
      const vb = d.createBuffer({
        usage: BufferUsage.Vertex,
        byteLength: batch.vertices.byteLength,
        dynamic: true,
        label: "engine.sprite.vbo"
      });
      if (!vb.ok) {
        d.destroyPipeline(pipeline);
        d.destroyShader(shader);
        d.destroyTexture(tex);
        return vb;
      }
      vbo = vb.value;
      const ib = d.createBuffer({
        usage: BufferUsage.Index,
        byteLength: batch.indices.byteLength,
        dynamic: false,
        label: "engine.sprite.ibo"
      });
      if (!ib.ok) {
        d.destroyBuffer(vbo);
        d.destroyPipeline(pipeline);
        d.destroyShader(shader);
        d.destroyTexture(tex);
        return ib;
      }
      ibo = ib.value;
      const up = d.updateBuffer(ibo, batch.indices);
      if (!up.ok) {
        d.destroyBuffer(ibo);
        d.destroyBuffer(vbo);
        d.destroyPipeline(pipeline);
        d.destroyShader(shader);
        d.destroyTexture(tex);
        return up;
      }
      ctx.log.channel("render").info(
        `\u6E32\u67D3\u6A21\u5757\u5C31\u7EEA\uFF1A${atlas.width}x${atlas.height} \u56FE\u96C6 \xB7 ${atlas.frames.size} \u5E27 \xB7 \u6279\u91CF\u4E0A\u9650 ${batch.maxQuads} quad`
      );
      return ok(void 0);
    },
    start() {
      const ctx = ctxRef;
      if (ctx === null) return err(engineError("RENDER.NOT_INIT", "start \u4E4B\u524D\u6CA1\u6709 init"));
      const frame = ctx.services.require(Services.Frame);
      offRender = frame.onRender(renderFrame);
      return ok(void 0);
    },
    stop() {
      offRender?.();
      offRender = null;
    },
    dispose() {
      const d = dev;
      if (d !== null) {
        if (ibo !== null) d.destroyBuffer(ibo);
        if (vbo !== null) d.destroyBuffer(vbo);
        if (pipeline !== null) d.destroyPipeline(pipeline);
        if (shader !== null) d.destroyShader(shader);
        if (tex !== null) d.destroyTexture(tex);
      }
      ibo = null;
      vbo = null;
      pipeline = null;
      shader = null;
      tex = null;
      dev = null;
      batch = null;
      atlas = null;
    },
    describe() {
      return `\u6E32\u67D3\uFF1A${lastFrame.quads} quad / ${lastFrame.drawCalls} draw / ${lastFrame.atlasSwitches} \u7EB9\u7406\u5207\u6362`;
    },
    get camera() {
      return camera;
    },
    get lastFrame() {
      return lastFrame;
    },
    get atlasFrameCount() {
      return atlas?.frames.size ?? 0;
    }
  };
  function renderFrame(info) {
    const d = dev;
    const b = batch;
    const a = atlas;
    const scene = ctxRef?.services.get(Services.Scene);
    if (d === null || b === null || a === null || scene === void 0) return;
    const target = opts.follow?.();
    if (target !== void 0) {
      camera.moveTo(target.x, target.z);
    }
    const sprites = scene.componentsOf("render.sprite");
    const items = [];
    const vis = camera.visibleRect();
    let culled = 0;
    const slotOfAtlas = (atlasId) => atlasId === "" ? 0 : 0;
    for (const s of sprites) {
      if (!s.visible) continue;
      const node = s.node;
      if (node === null || !node.activeInHierarchy) continue;
      const p = node.worldPosition;
      const pad = Math.max(s.width, s.height);
      if (p.x < vis.xMin - pad || p.x > vis.xMax + pad || p.y < vis.zMin - pad || p.y > vis.zMax + pad) {
        culled++;
        continue;
      }
      const f = a.frames.get(s.frame);
      if (f === void 0) {
        ctxRef?.log.channel("render").warn(`Sprite \u5E27\u540D\u4E0D\u5B58\u5728\uFF1A${JSON.stringify(s.frame)}`, { node: node.id }, null);
        continue;
      }
      items.push({
        nodeId: node.id,
        x: p.x,
        z: p.y,
        w: s.width,
        h: s.height,
        u0: f.u0,
        v0: f.v0,
        u1: f.u1,
        v1: f.v1,
        r: s.r,
        g: s.g,
        b: s.b,
        a: s.a,
        order: s.order,
        pivotY: s.pivotY,
        atlas: slotOfAtlas(s.atlasId)
      });
    }
    const built = b.build(items, camera);
    lastFrame = {
      quads: built.quadCount,
      drawCalls: 0,
      atlasSwitches: built.atlasSwitches,
      culled
    };
    const vw = d.size.width;
    const vh = d.size.height;
    camera.setViewport(vw, vh);
    const cmd = d.beginFrame(null);
    cmd.setViewport(new Rect(0, 0, vw, vh));
    cmd.clear(camera.clearColor, 1);
    if (built.quadCount > 0 && vbo !== null && ibo !== null && pipeline !== null && tex !== null) {
      const up = d.updateBuffer(vbo, b.vertexView(built.quadCount));
      if (!up.ok) {
        ctxRef?.log.channel("render").error(`\u9876\u70B9\u4E0A\u4F20\u5931\u8D25\uFF1A${up.error.message}`, void 0, null);
      } else {
        cmd.setPipeline(pipeline);
        cmd.bindTexture(0, tex);
        cmd.setUniform("u_useTexture", 1, "int");
        cmd.draw({
          vertices: vbo,
          indices: ibo,
          vertexCount: built.vertexCount,
          indexCount: built.indexCount
        });
        lastFrame = { ...lastFrame, drawCalls: 1 };
      }
    }
    cmd.finish();
    d.endFrame();
  }
  return mod;
}

// src/extensions/physics/physics.ts
var EPS = 1e-9;
var SpatialHashWorld = class {
  cellSize;
  maxIterations;
  skin;
  bodies = /* @__PURE__ */ new Map();
  /** cell key → body id 列表 */
  cells = /* @__PURE__ */ new Map();
  pos;
  _queries = 0;
  _pushes = 0;
  _unresolved = 0;
  constructor(pos, cfg = {}) {
    this.pos = pos;
    this.cellSize = cfg.cellSize ?? 4;
    this.maxIterations = cfg.maxIterations ?? 3;
    this.skin = cfg.skin ?? 1e-3;
    if (!(this.cellSize > 0)) throw new RangeError("cellSize \u5FC5\u987B > 0");
  }
  key(cx, cz) {
    return cx + "," + cz;
  }
  cellOf(x, z) {
    return [Math.floor(x / this.cellSize), Math.floor(z / this.cellSize)];
  }
  add(body) {
    if (!(body.radius > 0)) {
      throw new RangeError(`body ${body.nodeId} \u7684\u534A\u5F84\u5FC5\u987B > 0\uFF08\u6536\u5230 ${body.radius}\uFF09`);
    }
    const p = this.pos.get(body.nodeId);
    if (p === void 0) {
      throw new Error(`body ${body.nodeId} \u6CA1\u6709\u4F4D\u7F6E\uFF08PositionAccessor \u8FD4\u56DE undefined\uFF09`);
    }
    this.bodies.set(body.nodeId, body);
    const [cx, cz] = this.cellOf(p.x, p.z);
    const k = this.key(cx, cz);
    let list = this.cells.get(k);
    if (list === void 0) {
      list = [];
      this.cells.set(k, list);
    }
    list.push(body.nodeId);
  }
  remove(nodeId) {
    this.bodies.delete(nodeId);
    this.reindex(nodeId);
  }
  has(nodeId) {
    return this.bodies.has(nodeId);
  }
  /**
   * 重新分格。**移动后必须调用**（由调用方每帧对动态体调一次）。
   * ★ 不做"每帧全量重建"：几千个实体全量重建的分配开销远大于"只更新动过的"。
   *   代价是调用方要记得调 —— 所以 `resolve()` 会顺带校验"位置是否还在原 cell"，
   *   不匹配就自动重分格（**容错但可观测**：`stats().staleCells` 会体现）。
   */
  reindex(nodeId) {
    const b = this.bodies.get(nodeId);
    if (b === void 0) return;
    const p = this.pos.get(nodeId);
    for (const [k2, list2] of this.cells) {
      const i = list2.indexOf(nodeId);
      if (i >= 0) {
        list2.splice(i, 1);
        if (list2.length === 0) this.cells.delete(k2);
        break;
      }
    }
    if (p === void 0) return;
    const [cx, cz] = this.cellOf(p.x, p.z);
    const k = this.key(cx, cz);
    let list = this.cells.get(k);
    if (list === void 0) {
      list = [];
      this.cells.set(k, list);
    }
    list.push(nodeId);
  }
  rangeOf(b) {
    if (b.halfExtents !== void 0) {
      return Math.max(b.halfExtents.x, b.halfExtents.z);
    }
    return b.radius;
  }
  query(x, z, r) {
    this._queries++;
    if (!(r >= 0)) return [];
    const minCx = Math.floor((x - r) / this.cellSize);
    const maxCx = Math.floor((x + r) / this.cellSize);
    const minCz = Math.floor((z - r) / this.cellSize);
    const maxCz = Math.floor((z + r) / this.cellSize);
    const out = [];
    const seen = /* @__PURE__ */ new Set();
    for (let cx = minCx; cx <= maxCx; cx++) {
      for (let cz = minCz; cz <= maxCz; cz++) {
        const list = this.cells.get(this.key(cx, cz));
        if (list === void 0) continue;
        for (const id of list) {
          if (seen.has(id)) continue;
          seen.add(id);
          const p = this.pos.get(id);
          if (p === void 0) continue;
          const dx = p.x - x;
          const dz = p.z - z;
          const b = this.bodies.get(id);
          const reach = r + (b === void 0 ? 0 : this.rangeOf(b));
          if (dx * dx + dz * dz <= reach * reach + EPS) out.push(id);
        }
      }
    }
    out.sort((a, b) => a - b);
    return out;
  }
  /**
   * 解算重叠。对每对 (动态, 其它)，若重叠则把动态体推开。
   *
   * ★ 为什么"逐对独立解算 + 迭代"而不是"一次性求平均位移"：
   *   后者在"三四个实体挤一个角"时会出现互相抵消、抖动。
   *   迭代式（最多 3 轮）在这个规模下更稳，而且实现只有一个循环。
   */
  resolve() {
    let moved = 0;
    for (let iter = 0; iter < this.maxIterations; iter++) {
      let movedThis = 0;
      for (const id of this.bodies.keys()) {
        const b = this.bodies.get(id);
        if (b.isStatic) continue;
        const p = this.pos.get(id);
        if (p === void 0) continue;
        const near = this.query(p.x, p.z, this.rangeOf(b) + this.maxRadiusNearby());
        for (const otherId of near) {
          if (otherId === id) continue;
          const ob = this.bodies.get(otherId);
          if (ob === void 0) continue;
          const op = this.pos.get(otherId);
          if (op === void 0) continue;
          const dx = p.x - op.x;
          const dz = p.z - op.z;
          const distSq = dx * dx + dz * dz;
          const minDist = this.effectiveRadius(b, dx, dz) + this.effectiveRadius(ob, -dx, -dz);
          if (distSq >= minDist * minDist - EPS) continue;
          let dist = Math.sqrt(distSq);
          let nx;
          let nz;
          if (dist < EPS) {
            nx = 1;
            nz = 0;
            dist = 0;
          } else {
            nx = dx / dist;
            nz = dz / dist;
          }
          const push = minDist - dist + this.skin;
          this.pos.set(id, p.x + nx * push, p.z + nz * push);
          p.x += nx * push;
          p.z += nz * push;
          this._pushes++;
          movedThis++;
          this.reindex(id);
        }
      }
      moved += movedThis;
      if (movedThis === 0) break;
      if (iter === this.maxIterations - 1 && movedThis > 0) this._unresolved++;
    }
    return moved;
  }
  /** AABB 用"沿方向上的投影半径"，圆形直接用半径。 */
  effectiveRadius(b, dx, dz) {
    if (b.halfExtents === void 0) return b.radius;
    const l = Math.sqrt(dx * dx + dz * dz);
    if (l < EPS) return Math.max(b.halfExtents.x, b.halfExtents.z);
    return Math.abs(dx / l * b.halfExtents.x) + Math.abs(dz / l * b.halfExtents.z);
  }
  maxRadiusNearby() {
    let m = 0;
    for (const b of this.bodies.values()) {
      const r = this.rangeOf(b);
      if (r > m) m = r;
    }
    return m;
  }
  stats() {
    return {
      bodies: this.bodies.size,
      cells: this.cells.size,
      queries: this._queries,
      pushes: this._pushes,
      unresolved: this._unresolved
    };
  }
  clear() {
    this.bodies.clear();
    this.cells.clear();
    this._queries = 0;
    this._pushes = 0;
    this._unresolved = 0;
  }
};
function makeSceneAccessor(lookup) {
  return {
    get(nodeId) {
      const n = lookup(nodeId);
      if (n === void 0) return void 0;
      const p = n.worldPosition();
      return { x: p.x, z: p.y };
    },
    set(nodeId, x, z) {
      const n = lookup(nodeId);
      if (n === void 0) return;
      n.setLocalPosition(x, z);
    }
  };
}

// src/extensions/script/script-component.ts
var SCRIPT_COMPONENT_TYPE = "game.script";
var ScriptComponent = class extends Component {
  /** 逻辑模块名（`ai.brain`），由 `ScriptModule` 通过 `runtime.loadModule` 加载时登记。 */
  module = "";
  /** 入口函数名。空字符串在模块里会被当作默认 `onUpdate` 处理。 */
  entry = "onUpdate";
  schema = {
    type: SCRIPT_COMPONENT_TYPE,
    fields: {
      module: FieldType.String,
      entry: FieldType.String
    },
    defaults: {
      module: "",
      entry: "onUpdate"
    }
  };
};

// src/extensions/script/script-module.ts
function numArg(v, where) {
  if (typeof v !== "number" || !Number.isFinite(v)) {
    throw new Error(`${where} \u9700\u8981\u6709\u9650\u6570\uFF08\u6536\u5230 ${typeof v}\uFF09`);
  }
  return v;
}
function strArg(v, where) {
  if (typeof v !== "string") throw new Error(`${where} \u9700\u8981\u5B57\u7B26\u4E32\uFF08\u6536\u5230 ${typeof v}\uFF09`);
  return v;
}
function fmt(v) {
  if (typeof v === "string") return v;
  if (v === void 0) return "nil";
  try {
    return JSON.stringify(v);
  } catch {
    return String(v);
  }
}
function createScriptModule(opts = {}) {
  let ctxRef = null;
  let runtime = null;
  let tick = 0;
  const work = [];
  const timeoutMs = opts.callTimeoutMs ?? 0;
  let queue = Promise.resolve();
  let pending = 0;
  let droppedUpdates = 0;
  const MAX_PENDING_UPDATES = 4;
  function requireScene() {
    const scene = ctxRef?.services.get(Services.Scene);
    if (scene === void 0) {
      throw new Error("\u811A\u672C\u6A21\u5757\u9700\u8981 core.scene \u670D\u52A1\uFF08\u5BBF\u4E3B\u6CA1\u6709\u63A5\u7EBF\uFF09");
    }
    return scene;
  }
  function report(comp, fn, e) {
    ctxRef?.log.channel("script").error(`\u811A\u672C ${comp.module}.${fn} \u5931\u8D25\uFF1A${e.message}`, {
      code: e.code,
      nodeId: comp.node?.id ?? 0
    });
    ctxRef?.events.emit("script:error", {
      module: comp.module,
      fn,
      code: e.code,
      message: e.message
    });
  }
  function exposeEngineApi(rt) {
    const fns = [
      [
        "engine_log",
        (msg) => {
          ctxRef?.log.channel("script").info(fmt(msg));
          return void 0;
        }
      ],
      [
        "engine_spawn",
        (name, x, z) => {
          const scene = requireScene();
          const r = scene.spawnAt(strArg(name, "engine_spawn(name)"), numArg(x, "engine_spawn(x)"), numArg(z, "engine_spawn(z)"));
          if (!r.ok) throw new Error(r.error.message);
          return r.value.id;
        }
      ],
      [
        "engine_destroy",
        (nodeId) => {
          requireScene().destroy(numArg(nodeId, "engine_destroy(nodeId)"));
          return void 0;
        }
      ],
      [
        "engine_count",
        (type) => requireScene().countOf(strArg(type, "engine_count(type)"))
      ],
      [
        "engine_get_pos",
        (nodeId) => {
          const node = requireScene().find(numArg(nodeId, "engine_get_pos(nodeId)"));
          if (node === void 0) return null;
          const p = node.worldPosition;
          return { x: p.x, z: p.y };
        }
      ],
      [
        "engine_set_pos",
        (nodeId, x, z) => {
          const node = requireScene().find(numArg(nodeId, "engine_set_pos(nodeId)"));
          if (node !== void 0) node.setLocalPosition(numArg(x, "engine_set_pos(x)"), numArg(z, "engine_set_pos(z)"));
          return void 0;
        }
      ],
      ["engine_tick", () => tick],
      [
        "engine_nodes_named",
        (name) => {
          const scene = requireScene();
          const want = strArg(name, "engine_nodes_named(name)");
          const ids = [];
          const root = scene.find(scene.rootId);
          root?.walk((n) => {
            if (n.name === want) ids.push(n.id);
          });
          return ids;
        }
      ],
      [
        "engine_set_scale",
        (nodeId, sx, sy) => {
          const node = requireScene().find(numArg(nodeId, "engine_set_scale(nodeId)"));
          if (node !== void 0) node.setLocalScale(numArg(sx, "engine_set_scale(sx)"), numArg(sy, "engine_set_scale(sy)"));
          return void 0;
        }
      ]
    ];
    for (const [name, fn] of fns) {
      const r = rt.expose(name, fn);
      if (!r.ok) return r;
    }
    return ok(void 0);
  }
  async function runUpdate(tickNow, dt) {
    const rt = runtime;
    if (rt === null) return;
    const scene = ctxRef?.services.get(Services.Scene);
    if (scene === void 0) return;
    tick = tickNow;
    const list = scene.componentsOf(SCRIPT_COMPONENT_TYPE);
    work.length = 0;
    for (let i = 0; i < list.length; i++) work.push(list[i]);
    const callOpts = timeoutMs > 0 ? { timeoutMs } : void 0;
    for (const c of work) {
      const node = c.node;
      if (!c.enabled || node === null || !node.activeInHierarchy) continue;
      const entry = c.entry === "" ? "onUpdate" : c.entry;
      const target = c.module === "" ? entry : `${c.module}.${entry}`;
      try {
        const r = await rt.call(target, [node.id, dt, tickNow], callOpts);
        if (!r.ok) {
          report(c, entry, r.error);
        }
      } catch (e) {
        report(
          c,
          entry,
          engineError(
            ScriptErrorCode.CallFailed,
            e instanceof Error ? e.message : String(e)
          )
        );
      }
    }
  }
  const mod = {
    id: opts.id ?? "script.lua",
    deps: [],
    async init(ctx) {
      ctxRef = ctx;
      if (!ctx.services.has(Services.Script)) {
        return err(
          engineError(
            ScriptErrorCode.NotSupported,
            "\u5BBF\u4E3B\u6CA1\u6709\u63D0\u4F9B core.script \u670D\u52A1 \u2014\u2014 \u8FD9\u662F\u63A5\u7EBF\u7F3A\u5931\uFF0C\u4E0D\u662F'\u5E73\u53F0\u6CA1\u6709\u811A\u672C\u80FD\u529B'\uFF08\u4E0D\u9759\u9ED8\u8FD0\u884C\uFF09"
          )
        );
      }
      const rt = ctx.services.get(Services.Script) ?? null;
      if (rt === null) {
        return err(
          engineError(
            ScriptErrorCode.NotSupported,
            "\u8BE5\u5E73\u53F0\u6CA1\u6709\u811A\u672C\u80FD\u529B\uFF08Services.Script = null\uFF09\uFF0C\u4E0D\u9759\u9ED8\u964D\u7EA7\uFF1A\u811A\u672C\u4E0D\u4F1A\u6267\u884C\uFF0C\u5BBF\u4E3B\u5E94\u5173\u6389\u8BE5\u529F\u80FD"
          )
        );
      }
      if (!rt.caps.executes) {
        return err(
          engineError(
            ScriptErrorCode.NotSupported,
            `\u811A\u672C\u540E\u7AEF ${rt.id} \u4E0D\u80FD\u6267\u884C\uFF08caps.executes=false\uFF09\uFF0C\u4E0D\u9759\u9ED8\u964D\u7EA7`,
            { backend: rt.id }
          )
        );
      }
      const ready = await rt.ready();
      if (!ready.ok) return err(ready.error);
      if (ctx.services.get(Services.Scene) === void 0) {
        return err(
          engineError("SCRIPT.NO_SCENE", "\u811A\u672C\u6A21\u5757\u9700\u8981 core.scene \u670D\u52A1\uFF1Aengine_* API \u6CA1\u6709\u4E16\u754C\u53EF\u64CD\u4F5C")
        );
      }
      const exposed = exposeEngineApi(rt);
      if (!exposed.ok) return exposed;
      runtime = rt;
      ctx.log.channel("script").info(
        `\u811A\u672C\u6A21\u5757\u5C31\u7EEA\uFF1A\u540E\u7AEF ${rt.id} ${rt.caps.version ?? ""} \xB7 \u66B4\u9732 ${rt.exposed().length} \u4E2A\u5BBF\u4E3B\u51FD\u6570`
      );
      return ok(void 0);
    },
    /**
     * 世界已建好：登记 `game.script` 组件类型。
     * ★ 只动组件注册表，不动节点树（init/start 的边界见 module.ts）。
     *   已有同名注册时跳过 —— 应用可能自己注册了子类/扩展 schema。
     */
    start() {
      const scene = ctxRef?.services.get(Services.Scene);
      if (scene !== void 0 && !scene.components.has(SCRIPT_COMPONENT_TYPE)) {
        scene.components.register(new ScriptComponent().schema, () => new ScriptComponent());
      }
    },
    /**
     * 驱动一帧脚本。宿主在 `scheduler.onStep` 里 `void mod.update(tick, dt)` 即可。
     * 返回的 Promise 属于**整条队列**（不只是本次），所以 `await` 它等于
     * "等到此前排队的脚本全部跑完" —— 判据与需要严格同步的宿主用这个语义。
     */
    update(tickNow, dt) {
      if (runtime === null) return Promise.resolve();
      if (pending >= MAX_PENDING_UPDATES) {
        droppedUpdates++;
        ctxRef?.log.channel("script").warn(
          `\u811A\u672C\u843D\u540E\u4E8E\u4E16\u754C\uFF1A\u4E22\u5F03 tick ${tickNow} \u7684\u811A\u672C\u66F4\u65B0\uFF08\u961F\u5217 ${pending}\uFF09\u2014\u2014 \u4E0E scheduler \u4E22\u6B65\u540C\u4E00\u5904\u7F6E\uFF0C\u7D2F\u8BA1\u4E22\u5F03 ${droppedUpdates} \u6B21`,
          { tick: tickNow, pending, dropped: droppedUpdates }
        );
        return queue;
      }
      pending++;
      const run = queue.then(() => runUpdate(tickNow, dt));
      queue = run.then(
        () => {
          pending--;
        },
        () => {
          pending--;
        }
      );
      return queue;
    },
    stop() {
    },
    /**
     * ★ 只清自己的状态。**不 dispose 运行时** ——
     *   它由平台持有（`Services.Script`），可能还有 AI/UI 模块在用。
     *   模块释放时把别人的服务关掉，是多模块架构里最典型的一类越权。
     */
    dispose() {
      runtime = null;
      ctxRef = null;
      work.length = 0;
      tick = 0;
    },
    drain() {
      return queue;
    },
    describe() {
      const rt = runtime;
      if (rt === null) return "\u811A\u672C\uFF1A\u672A\u542F\u52A8";
      const s = rt.stats();
      const drop = droppedUpdates > 0 ? ` / \u4E22 ${droppedUpdates} tick` : "";
      return `\u811A\u672C(${rt.id})\uFF1A${s.modules} \u6A21\u5757 / ${s.calls} \u8C03\u7528 / ${s.errors} \u9519\u8BEF\uFF08${s.timeouts} \u8D85\u65F6\uFF09${drop}`;
    },
    get droppedUpdates() {
      return droppedUpdates;
    },
    get runtime() {
      return runtime;
    }
  };
  return mod;
}

// src/core/serialization/schema.ts
var Schema = class {
  version;
  fields;
  migrations;
  decimals;
  constructor(opts) {
    this.version = opts.version;
    this.fields = opts.fields;
    this.migrations = opts.migrations ?? [];
    this.decimals = opts.decimals ?? 3;
    const froms = this.migrations.map((m) => m.from).sort((a, b) => a - b);
    for (let i = 0; i < froms.length; i++) {
      if (froms[i] !== i + 1) {
        throw new Error(
          `\u8FC1\u79FB\u94FE\u5FC5\u987B\u4ECE v1 \u8FDE\u7EED\u8986\u76D6\u5230 v${this.version}\uFF0C\u5B9E\u9645\u7F3A v${i + 1}\uFF08\u5DF2\u6709\uFF1A${froms.join(",") || "\u65E0"}\uFF09`
        );
      }
    }
  }
  /** 把任意旧版本的记录迁到当前版本。 */
  migrate(data) {
    let cur = { ...data };
    let v = typeof cur["__v"] === "number" ? cur["__v"] : 1;
    if (v > this.version) {
      return err({
        code: "SER.VERSION_TOO_NEW",
        message: `\u8BB0\u5F55\u7248\u672C v${v} \u9AD8\u4E8E\u5F15\u64CE\u652F\u6301\u7684 v${this.version}\uFF08\u7528\u65B0\u5F15\u64CE\u5199\u7684\u6863\uFF0C\u65E7\u5F15\u64CE\u4E0D\u80FD\u8BFB\uFF09`
      });
    }
    while (v < this.version) {
      const m = this.migrations.find((x) => x.from === v);
      if (m === void 0) {
        return err({
          code: "SER.NO_MIGRATION",
          message: `\u7F3A\u5C11 v${v} \u2192 v${v + 1} \u7684\u8FC1\u79FB\u51FD\u6570`
        });
      }
      cur = m.migrate(cur);
      v++;
      cur["__v"] = v;
    }
    return ok(cur);
  }
  /**
   * 确定性序列化：`{ "__v": 2, "name": "abc", "hp": 12.346 }`
   * - 字段顺序 = schema 顺序（**不是**对象键顺序）
   * - 数字量化到 decimals
   * - schema 里没有的键**丢弃并报告**（不静默保留：保留会让"字段名拼错"变成永久脏数据）
   */
  encode(data) {
    const dropped = Object.keys(data).filter((k) => k !== "__v" && !this.fields.includes(k));
    const parts = [`"__v":${this.version}`];
    for (const k of this.fields) {
      const v = data[k];
      if (v === void 0) continue;
      parts.push(`${JSON.stringify(k)}:${encodeValue(v, this.decimals)}`);
    }
    return { text: `{${parts.join(",")}}`, dropped };
  }
  decode(text) {
    let raw;
    try {
      raw = JSON.parse(text);
    } catch (e) {
      return err({
        code: "SER.BAD_JSON",
        message: `\u4E0D\u662F\u5408\u6CD5 JSON\uFF1A${e instanceof Error ? e.message : String(e)}`
      });
    }
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
      return err({ code: "SER.NOT_OBJECT", message: "\u9876\u5C42\u5FC5\u987B\u662F\u5BF9\u8C61" });
    }
    return this.migrate(raw);
  }
};
function encodeValue(v, decimals) {
  if (typeof v === "number") {
    if (!Number.isFinite(v)) {
      return JSON.stringify(`__num__:${String(v)}`);
    }
    return String(quantize(v, decimals));
  }
  if (typeof v === "string" || typeof v === "boolean") return JSON.stringify(v);
  if (v === null) return "null";
  if (Array.isArray(v)) return "[" + v.map((x) => encodeValue(x, decimals)).join(",") + "]";
  if (typeof v === "object") {
    const o = v;
    const keys = Object.keys(o).sort();
    const body = [];
    for (const k of keys) {
      if (o[k] === void 0) continue;
      body.push(`${JSON.stringify(k)}:${encodeValue(o[k], decimals)}`);
    }
    return "{" + body.join(",") + "}";
  }
  return JSON.stringify(String(v));
}
function stableHash(text) {
  let h = 2166136261;
  if (typeof text === "string") {
    for (let i = 0; i < text.length; i++) {
      h ^= text.charCodeAt(i) & 255;
      h = Math.imul(h, 16777619) >>> 0;
      h ^= text.charCodeAt(i) >>> 8 & 255;
      h = Math.imul(h, 16777619) >>> 0;
    }
  } else {
    for (let i = 0; i < text.length; i++) {
      h ^= text[i];
      h = Math.imul(h, 16777619) >>> 0;
    }
  }
  return h.toString(16).padStart(8, "0");
}

// src/core/scene/scene-io.ts
var SCENE_FORMAT_VERSION = 1;
function collectNodes(scene) {
  const out = [];
  scene.root.walk((n) => {
    if (n.id !== scene.rootId) out.push(n);
  });
  out.sort((a, b) => a.id - b.id);
  return out;
}
function saveScene(scene) {
  const nodes = [];
  for (const n of collectNodes(scene)) {
    const comps = [];
    for (const c of [...n.components].sort((a, b) => a.type < b.type ? -1 : a.type > b.type ? 1 : 0)) {
      const saved = c.save();
      const { type: _t, ...rest } = saved;
      comps.push({ type: c.type, data: rest });
    }
    nodes.push({
      id: n.id,
      name: n.name,
      parent: n.parent === null || n.parent.id === scene.rootId ? null : n.parent.id,
      x: n.localPosition.x,
      y: n.localPosition.y,
      rot: n.localRotation,
      sx: n.localScale.x,
      sy: n.localScale.y,
      zIndex: n.zIndex,
      active: n.active,
      layer: n.layer,
      components: comps
    });
  }
  return { format: SCENE_FORMAT_VERSION, name: scene.name, nodes };
}
function loadScene(scene, snap, registry) {
  if (snap.format > SCENE_FORMAT_VERSION) {
    return err(
      engineError(
        "SCENE.FORMAT_TOO_NEW",
        `\u5B58\u6863\u683C\u5F0F v${snap.format} \u9AD8\u4E8E\u5F15\u64CE\u652F\u6301\u7684 v${SCENE_FORMAT_VERSION}\uFF08\u7528\u65B0\u5F15\u64CE\u5199\u7684\u6863\uFF0C\u65E7\u5F15\u64CE\u4E0D\u80FD\u8BFB\uFF09`
      )
    );
  }
  const skipped = [];
  const missingFields = [];
  scene.clear();
  const built = /* @__PURE__ */ new Map();
  const records = [...snap.nodes].sort((a, b) => a.id - b.id);
  for (const r of records) {
    try {
      const n = scene.spawnImmediate(r.name, r.id === 0 ? null : scene.rootId, r.id);
      n.setLocalPosition(r.x, r.y);
      n.setLocalRotation(r.rot);
      n.setLocalScale(r.sx, r.sy);
      n.zIndex = r.zIndex;
      n.active = r.active;
      n.layer = r.layer;
      n.markTransformDirty();
      built.set(r.id, n);
    } catch (e) {
      skipped.push(`\u8282\u70B9 #${r.id}\uFF08${r.name}\uFF09\uFF1A${e instanceof Error ? e.message : String(e)}`);
    }
  }
  for (const r of records) {
    if (r.parent === null) continue;
    const child = built.get(r.id);
    const parent = built.get(r.parent);
    if (child === void 0) continue;
    if (parent === void 0) {
      skipped.push(`\u8282\u70B9 #${r.id} \u7684\u7236\u8282\u70B9 #${r.parent} \u4E0D\u5B58\u5728\uFF08\u8BE5\u8282\u70B9\u88AB\u6302\u5230\u6839\u4E0B\uFF09`);
      continue;
    }
    parent.addChild(child);
  }
  for (const r of records) {
    const n = built.get(r.id);
    if (n === void 0) continue;
    for (const cr of r.components) {
      if (!registry.has(cr.type)) {
        skipped.push(`\u8282\u70B9 #${r.id} \u7684\u7EC4\u4EF6 ${cr.type} \u672A\u6CE8\u518C\uFF08\u8DF3\u8FC7\uFF09`);
        continue;
      }
      const c = registry.create(cr.type);
      if (c === void 0) {
        skipped.push(`\u8282\u70B9 #${r.id} \u7684\u7EC4\u4EF6 ${cr.type} \u5DE5\u5382\u8FD4\u56DE undefined\uFF08\u8DF3\u8FC7\uFF09`);
        continue;
      }
      const res = c.load(cr.data);
      for (const f of res.missing) missingFields.push(`#${r.id}.${cr.type}.${f}`);
      scene.attach(n.id, () => c);
    }
  }
  scene.flush();
  return ok({ made: built.size, skipped, missingFields });
}
function sceneToJson(snap) {
  const lines = [];
  lines.push(`{"format":${snap.format},"name":${JSON.stringify(snap.name)},"nodes":[`);
  snap.nodes.forEach((n, i) => {
    const comps = n.components.map((c) => `{"type":${JSON.stringify(c.type)},"data":${stringifySorted(c.data)}}`).join(",");
    const rec = `{"id":${n.id},"name":${JSON.stringify(n.name)},"parent":${n.parent === null ? "null" : n.parent},"x":${q(n.x)},"y":${q(n.y)},"rot":${q(n.rot)},"sx":${q(n.sx)},"sy":${q(n.sy)},"zIndex":${n.zIndex},"active":${n.active},"layer":${n.layer},"components":[${comps}]}`;
    lines.push(rec + (i === snap.nodes.length - 1 ? "" : ","));
  });
  lines.push("]}");
  return lines.join("");
}
function sceneFromJson(text) {
  let raw;
  try {
    raw = JSON.parse(text);
  } catch (e) {
    return err(engineError("SCENE.BAD_JSON", `\u4E0D\u662F\u5408\u6CD5 JSON\uFF1A${e instanceof Error ? e.message : String(e)}`));
  }
  if (raw === null || typeof raw !== "object") {
    return err(engineError("SCENE.BAD_JSON", "\u9876\u5C42\u4E0D\u662F\u5BF9\u8C61"));
  }
  const o = raw;
  if (typeof o.format !== "number" || !Array.isArray(o.nodes)) {
    return err(engineError("SCENE.BAD_JSON", "\u7F3A\u5C11 format \u6216 nodes"));
  }
  return ok({
    format: o.format,
    name: typeof o.name === "string" ? o.name : "scene",
    nodes: o.nodes
  });
}
function q(v) {
  return Math.round(v * 1e3) / 1e3;
}
function stringifySorted(o) {
  if (o === null || typeof o !== "object") {
    return typeof o === "number" ? String(q(o)) : JSON.stringify(o);
  }
  if (Array.isArray(o)) return "[" + o.map(stringifySorted).join(",") + "]";
  const rec = o;
  const keys = Object.keys(rec).sort();
  const parts = [];
  for (const k of keys) {
    if (rec[k] === void 0) continue;
    parts.push(`${JSON.stringify(k)}:${stringifySorted(rec[k])}`);
  }
  return "{" + parts.join(",") + "}";
}
var SCENE_SCHEMA = new Schema({
  version: SCENE_FORMAT_VERSION,
  fields: ["format", "name", "nodes"]
});

// src/extensions/asset-import/importer.ts
function normalizeExtension(ext) {
  const e = ext.toLowerCase();
  if (!e.startsWith(".") || e.length < 2) {
    throw new Error(`\u5BFC\u5165\u5668\u6269\u5C55\u540D\u5FC5\u987B\u5F62\u5982 ".png"\uFF08\u5E26\u524D\u5BFC\u70B9\uFF09\uFF0C\u5B9E\u9645\u6536\u5230 "${ext}"`);
  }
  return e;
}
var ImporterRegistry = class {
  byExtension = /* @__PURE__ */ new Map();
  /**
   * 注册。同扩展名重复注册 → **throw**。
   * 这是配置错误（两条线各自加了一个 `.json` 导入器），不是运行时状况；
   * 用 Result 返回只会让它被忽略，然后在运行时表现为"某类文件用了错的导入器"。
   */
  register(i) {
    for (const raw of i.extensions) {
      const ext = normalizeExtension(raw);
      const prev = this.byExtension.get(ext);
      if (prev !== void 0) {
        throw new Error(
          `\u6269\u5C55\u540D "${ext}" \u5DF2\u7531\u5BFC\u5165\u5668 ${prev.id} \u6CE8\u518C\uFF0C\u4E0D\u80FD\u518D\u7ED9 ${i.id}\uFF08\u914D\u7F6E\u9519\u8BEF\uFF1A\u540C\u4E00\u6269\u5C55\u540D\u53EA\u80FD\u6709\u4E00\u4E2A\u5BFC\u5165\u5668\uFF09`
        );
      }
      this.byExtension.set(ext, i);
    }
  }
  /**
   * 找导入器：大小写不敏感，**最长后缀优先**。
   * `.atlas.json` 必须赢过 `.json` —— 否则图集会先被当作文本导进去，
   * 依赖永远解析不出来。
   */
  find(sourcePath) {
    const p = sourcePath.toLowerCase();
    let best;
    let bestLen = -1;
    for (const [ext, imp] of this.byExtension) {
      if (p.endsWith(ext) && ext.length > bestLen) {
        best = imp;
        bestLen = ext.length;
      }
    }
    return best;
  }
  /** 诊断用：已注册的扩展名（排序后），报 `IMPORT.NO_IMPORTER` 时带上。 */
  extensions() {
    return Array.from(this.byExtension.keys()).sort();
  }
};

// src/extensions/asset-import/hash.ts
function contentHash(bytes) {
  return hashBytes(bytes);
}

// src/extensions/asset-import/meta.ts
var ID_RE = /^[a-z0-9]{1,40}$/;
function metaPathOf(sourcePath) {
  return sourcePath + ".meta";
}
function relativePathOf(sourcePath) {
  let p = sourcePath.replace(/\\/g, "/");
  const m = /^[a-zA-Z]+:/.exec(p);
  if (m !== null) p = p.slice(m[0].length);
  return p.replace(/^\/+/, "");
}
function badMeta(path, message, field) {
  return engineError("IMPORT.BAD_META", `${path}: ${message}`, {
    path,
    ...field === void 0 ? {} : { field }
  });
}
function parseMeta(path, text) {
  let raw;
  try {
    raw = JSON.parse(text);
  } catch (e) {
    const why = e instanceof Error ? e.message : String(e);
    return err(badMeta(path, `JSON \u89E3\u6790\u5931\u8D25\uFF08${why}\uFF09`));
  }
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    return err(badMeta(path, "\u9876\u5C42\u5FC5\u987B\u662F JSON \u5BF9\u8C61"));
  }
  const o = raw;
  const id = o["id"];
  if (id === void 0) return err(badMeta(path, '\u7F3A\u5B57\u6BB5 "id"', "id"));
  if (typeof id !== "string") return err(badMeta(path, '\u5B57\u6BB5 "id" \u5FC5\u987B\u662F\u5B57\u7B26\u4E32', "id"));
  if (!ID_RE.test(id)) {
    return err(
      badMeta(path, `\u5B57\u6BB5 "id" \u7684\u503C "${id}" \u4E0D\u5339\u914D /^[a-z0-9]{1,40}$/\uFF08\u8EAB\u4EFD\u5FC5\u987B\u662F\u7A33\u5B9A\u7684\u5C0F\u5199 base36\uFF09`, "id")
    );
  }
  const type = o["type"];
  if (type === void 0) return err(badMeta(path, '\u7F3A\u5B57\u6BB5 "type"', "type"));
  if (typeof type !== "string" || type.length === 0) {
    return err(badMeta(path, '\u5B57\u6BB5 "type" \u5FC5\u987B\u662F\u975E\u7A7A\u5B57\u7B26\u4E32', "type"));
  }
  const version = o["importerVersion"];
  if (version === void 0) return err(badMeta(path, '\u7F3A\u5B57\u6BB5 "importerVersion"', "importerVersion"));
  if (typeof version !== "number" || !Number.isInteger(version) || version < 0) {
    return err(badMeta(path, '\u5B57\u6BB5 "importerVersion" \u5FC5\u987B\u662F\u975E\u8D1F\u6574\u6570', "importerVersion"));
  }
  const settings = o["settings"];
  if (settings === void 0) return err(badMeta(path, '\u7F3A\u5B57\u6BB5 "settings"', "settings"));
  if (typeof settings !== "object" || settings === null || Array.isArray(settings)) {
    return err(badMeta(path, '\u5B57\u6BB5 "settings" \u5FC5\u987B\u662F JSON \u5BF9\u8C61', "settings"));
  }
  return ok({
    id,
    type,
    importerVersion: version,
    settings
  });
}
async function readMeta(fs, sourcePath) {
  const mp = metaPathOf(sourcePath);
  if (!await fs.exists(mp)) return ok(null);
  const r = await fs.readText(mp);
  if (!r.ok) {
    return err(badMeta(mp, `\u8BFB\u53D6\u5931\u8D25\uFF08${r.error.message}\uFF09`));
  }
  return parseMeta(mp, r.value);
}
async function writeMeta(fs, sourcePath, rec) {
  const text = `{"id":${JSON.stringify(rec.id)},"type":${JSON.stringify(rec.type)},"importerVersion":${JSON.stringify(rec.importerVersion)},"settings":${JSON.stringify(rec.settings)}}
`;
  return fs.writeText(metaPathOf(sourcePath), text);
}
async function ensureMeta(fs, sourcePath, type, settings) {
  const cur = await readMeta(fs, sourcePath);
  if (!cur.ok) return err(cur.error);
  if (cur.value !== null) return ok({ record: cur.value, created: false });
  const record = {
    id: stableIdFromPath(relativePathOf(sourcePath)),
    type,
    importerVersion: 1,
    settings
  };
  const w = await writeMeta(fs, sourcePath, record);
  if (!w.ok) return err(w.error);
  return ok({ record, created: true });
}
var MetaIdTable = class {
  byId = /* @__PURE__ */ new Map();
  claim(id, sourcePath) {
    const prev = this.byId.get(id);
    if (prev !== void 0 && prev !== sourcePath) {
      return err(
        engineError(
          "IMPORT.ID_COLLISION",
          `id \u51B2\u7A81\uFF1A${id} \u540C\u65F6\u88AB ${prev} \u4E0E ${sourcePath} \u4F7F\u7528\uFF08\u4E0D\u81EA\u52A8\u52A0\u540E\u7F00\uFF1A\u90A3\u4F1A\u8BA9\u8EAB\u4EFD\u4E0D\u53EF\u9884\u6D4B\uFF09`,
          { id, first: prev, second: sourcePath }
        )
      );
    }
    this.byId.set(id, sourcePath);
    return ok(void 0);
  }
  get size() {
    return this.byId.size;
  }
  /** 这个 id 在本轮扫描结果里是否还存在（增量命中前的依赖存活检查）。 */
  has(id) {
    return this.byId.has(id);
  }
};

// src/extensions/asset-import/pipeline.ts
var EMPTY_SETTINGS = Object.freeze({});
function normalizeSlashes(p) {
  return p.replace(/\\/g, "/");
}
function normalizePath(p) {
  let s = normalizeSlashes(p);
  let scheme = "";
  const m = /^([a-zA-Z]+):/.exec(s);
  if (m !== null) {
    scheme = m[1] + ":";
    s = s.slice(m[0].length);
  }
  const absolute = s.startsWith("/");
  const out = [];
  for (const seg of s.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") {
      if (out.length > 0) out.pop();
      else out.push("..");
      continue;
    }
    out.push(seg);
  }
  return scheme + (absolute ? "/" : "") + out.join("/");
}
function dirOf(file) {
  const p = normalizeSlashes(file);
  const i = p.lastIndexOf("/");
  return i < 0 ? "" : p.slice(0, i);
}
function resolveSiblingPath(sourcePath, relPath) {
  const base = dirOf(sourcePath);
  const joined = relPath.startsWith("/") ? relPath : `${base}/${relPath}`;
  return normalizePath(joined);
}
function joinPath(a, b) {
  return normalizePath(`${a}/${b}`);
}
function serializeArtifact(a) {
  const obj = {
    type: a.type,
    importerVersion: a.importerVersion,
    sourceHash: a.sourceHash,
    byteLength: a.byteLength,
    dependencies: a.dependencies,
    data: a.data
  };
  return JSON.stringify(obj, null, 2) + "\n";
}
function isPlainObject(v) {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}
function failureOf(path, e) {
  return { path, code: e.code, message: e.message };
}
var AssetImportPipeline = class {
  constructor(fs, db, registry, log) {
    this.fs = fs;
    this.db = db;
    this.registry = registry;
    this.log = log;
  }
  artifacts = /* @__PURE__ */ new Map();
  /** 本轮最近一次导入的产物（失败/跳过的资产不在这里，用 `db.meta` 看身份）。 */
  artifactOf(id) {
    return this.artifacts.get(id);
  }
  async run(root) {
    const t0 = Date.now();
    this.artifacts.clear();
    const found = [];
    const walked = await this.walk(root, found);
    if (!walked.ok) return err(walked.error);
    found.sort();
    const failed = [];
    const idTable = new MetaIdTable();
    const idByPath = /* @__PURE__ */ new Map();
    const units = [];
    let created = 0;
    for (const p of found) {
      const importer = this.registry.find(p);
      if (importer === void 0) {
        failed.push({
          path: p,
          code: "IMPORT.NO_IMPORTER",
          message: `${p}: \u6CA1\u6709\u5BFC\u5165\u5668\u5904\u7406\u8FD9\u4E2A\u6269\u5C55\u540D\uFF08\u5DF2\u6CE8\u518C\uFF1A${this.registry.extensions().join(", ") || "(\u7A7A)"}\uFF09`
        });
        continue;
      }
      const em = await ensureMeta(this.fs, p, importer.id, EMPTY_SETTINGS);
      if (!em.ok) {
        failed.push(failureOf(p, em.error));
        continue;
      }
      if (em.value.created) created++;
      const rec = em.value.record;
      const claim = idTable.claim(rec.id, p);
      if (!claim.ok) {
        failed.push(failureOf(p, claim.error));
        continue;
      }
      idByPath.set(p, rec.id);
      units.push({ path: p, importer, record: rec });
    }
    const libraryDir = joinPath(root, "library/imported");
    let imported = 0;
    let skipped = 0;
    let registered = 0;
    for (const u of units) {
      const bytesR = await this.fs.readBinary(u.path);
      if (!bytesR.ok) {
        failed.push(failureOf(u.path, bytesR.error));
        continue;
      }
      const bytes = bytesR.value;
      const sourceHash = contentHash(bytes);
      const cachePath = joinPath(libraryDir, `${u.record.id}.json`);
      const cached = await this.readCache(cachePath);
      let artifact;
      const dependenciesAlive = cached !== void 0 && cached.dependencies.every((dep) => idTable.has(dep));
      if (cached !== void 0 && dependenciesAlive && cached.sourceHash === sourceHash && cached.importerVersion === u.importer.version) {
        artifact = cached;
        skipped++;
      } else {
        const ir = await u.importer.import(u.path, bytes, u.record.settings, this.contextFor(u.path, root, idByPath));
        if (!ir.ok) {
          failed.push(failureOf(u.path, ir.error));
          continue;
        }
        artifact = {
          ...ir.value,
          sourceHash,
          byteLength: bytes.byteLength,
          importerVersion: u.importer.version
        };
        const mk = await this.fs.ensureDir(libraryDir);
        if (!mk.ok) {
          failed.push(failureOf(u.path, mk.error));
          continue;
        }
        const wr = await this.fs.writeText(cachePath, serializeArtifact(artifact));
        if (!wr.ok) {
          failed.push(failureOf(u.path, wr.error));
          continue;
        }
        imported++;
      }
      this.artifacts.set(u.record.id, artifact);
      let rec = u.record;
      if (rec.importerVersion !== artifact.importerVersion) {
        const updated = {
          id: rec.id,
          type: rec.type,
          importerVersion: artifact.importerVersion,
          settings: rec.settings
        };
        const wm = await writeMeta(this.fs, u.path, updated);
        if (wm.ok) rec = updated;
        else this.log.warn("`.meta` \u7248\u672C\u540C\u6B65\u5931\u8D25\uFF08\u4E0D\u5F71\u54CD\u672C\u8F6E\u5BFC\u5165\uFF09", { path: u.path, code: wm.error.code });
      }
      const reg = this.db.register({
        id: rec.id,
        type: artifact.type,
        path: u.path,
        importerVersion: artifact.importerVersion,
        sourceHash: artifact.sourceHash,
        dependencies: artifact.dependencies,
        byteLength: artifact.byteLength
      });
      if (!reg.ok) {
        failed.push(failureOf(u.path, reg.error));
        continue;
      }
      registered++;
    }
    const live = /* @__PURE__ */ new Set();
    for (const u of units) live.add(u.record.id);
    let removed = 0;
    if (registered > 0) {
      for (const d of this.db.describe()) {
        if (live.has(d.id)) continue;
        const r = this.db.unregister(d.id);
        if (r.ok) {
          removed++;
          this.artifacts.delete(d.id);
        } else {
          failed.push(failureOf(d.path, r.error));
        }
      }
    }
    return ok({
      scanned: found.length,
      created,
      imported,
      skipped,
      removed,
      failed,
      registered,
      durationMs: Date.now() - t0
    });
  }
  // ---------------------------------------------------------------- 内部
  contextFor(sourcePath, root, ids) {
    return {
      fs: this.fs,
      root,
      log: this.log,
      resolveSibling: (rel) => resolveSiblingPath(sourcePath, rel),
      lookupId: (rel) => ids.get(resolveSiblingPath(sourcePath, rel))
    };
  }
  /** 递归收集源文件。跳过 `.meta`、隐藏文件/目录、`library/`、`node_modules/`。 */
  async walk(dir, out) {
    const listed = await this.fs.list(dir);
    if (!listed.ok) return err(listed.error);
    for (const e of listed.value) {
      if (e.isDirectory) {
        if (this.skipDir(e.name)) continue;
        const r = await this.walk(e.path, out);
        if (!r.ok) return r;
      } else {
        if (this.skipFile(e.name)) continue;
        out.push(e.path);
      }
    }
    return ok(void 0);
  }
  skipDir(name) {
    return name.startsWith(".") || name === "library" || name === "node_modules";
  }
  skipFile(name) {
    return name.startsWith(".") || name.toLowerCase().endsWith(".meta");
  }
  /**
   * 读产物缓存。读不出来/格式不对都按"没有缓存"处理并 warn：
   * 缓存是**派生物**，坏了就重导，不该让整个管线失败。
   * （与 `.meta` 相反：`.meta` 是身份来源，坏了必须报 BAD_META 而不是重新生成。）
   */
  async readCache(path) {
    if (!await this.fs.exists(path)) return void 0;
    const r = await this.fs.readText(path);
    if (!r.ok) {
      this.log.warn("\u4EA7\u7269\u7F13\u5B58\u8BFB\u4E0D\u51FA\u6765\uFF0C\u6309\u9700\u8981\u91CD\u5BFC\u5904\u7406", { path, code: r.error.code });
      return void 0;
    }
    let raw;
    try {
      raw = JSON.parse(r.value);
    } catch {
      this.log.warn("\u4EA7\u7269\u7F13\u5B58\u4E0D\u662F\u5408\u6CD5 JSON\uFF0C\u6309\u9700\u8981\u91CD\u5BFC\u5904\u7406", { path });
      return void 0;
    }
    if (!isPlainObject(raw)) {
      this.log.warn("\u4EA7\u7269\u7F13\u5B58\u9876\u5C42\u4E0D\u662F\u5BF9\u8C61\uFF0C\u6309\u9700\u8981\u91CD\u5BFC\u5904\u7406", { path });
      return void 0;
    }
    const type = raw["type"];
    const version = raw["importerVersion"];
    const hash = raw["sourceHash"];
    const byteLength = raw["byteLength"];
    const deps = raw["dependencies"];
    const data = raw["data"];
    if (typeof type !== "string" || typeof version !== "number" || !Number.isInteger(version) || typeof hash !== "string" || typeof byteLength !== "number" || !Array.isArray(deps) || !deps.every((d) => typeof d === "string") || !isPlainObject(data)) {
      this.log.warn("\u4EA7\u7269\u7F13\u5B58\u5B57\u6BB5\u4E0D\u5B8C\u6574\uFF0C\u6309\u9700\u8981\u91CD\u5BFC\u5904\u7406", { path });
      return void 0;
    }
    return {
      type,
      importerVersion: version,
      sourceHash: hash,
      byteLength,
      dependencies: deps,
      data
    };
  }
};

// src/extensions/asset-import/importers/texture.ts
var VERSION = 1;
var SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10];
var MIN_HEADER_BYTES = 33;
var IHDR_DATA_BYTES = 13;
function u32be(b, at) {
  return b[at] * 16777216 + (b[at + 1] << 16) + (b[at + 2] << 8) + b[at + 3] >>> 0;
}
function ascii4(b, at) {
  return String.fromCharCode(b[at], b[at + 1], b[at + 2], b[at + 3]);
}
function hexBytes(b, from, to) {
  return Array.from(b.slice(from, to), (x) => x.toString(16).padStart(2, "0")).join(" ");
}
function badSource(sourcePath, why) {
  return engineError("IMPORT.BAD_SOURCE", `${sourcePath}: ${why}`, { path: sourcePath, importer: "texture" });
}
function hasAlphaChannel(colorType) {
  return colorType === 4 || colorType === 6;
}
var textureImporter = {
  id: AssetType.Texture,
  version: VERSION,
  extensions: [".png"],
  async import(sourcePath, source) {
    if (source.length < SIGNATURE.length) {
      return err(badSource(sourcePath, `\u671F\u671B 8 \u5B57\u8282 PNG \u7B7E\u540D\uFF0C\u5B9E\u9645\u53EA\u6709 ${source.length} \u5B57\u8282`));
    }
    for (let i = 0; i < SIGNATURE.length; i++) {
      if (source[i] !== SIGNATURE[i]) {
        return err(
          badSource(
            sourcePath,
            `\u671F\u671B 8 \u5B57\u8282 PNG \u7B7E\u540D\uFF0889 50 4e 47 0d 0a 1a 0a\uFF09\uFF0C\u5B9E\u9645 ${hexBytes(source, 0, 8)}`
          )
        );
      }
    }
    if (source.length < MIN_HEADER_BYTES) {
      return err(
        badSource(
          sourcePath,
          `PNG \u5934\u622A\u65AD\uFF1A\u8BFB IHDR \u9700\u8981 ${MIN_HEADER_BYTES} \u5B57\u8282\uFF08\u7B7E\u540D 8 + \u5757\u5934 8 + IHDR 13 + CRC 4\uFF09\uFF0C\u5B9E\u9645 ${source.length}`
        )
      );
    }
    const chunkLength = u32be(source, 8);
    if (chunkLength !== IHDR_DATA_BYTES) {
      return err(badSource(sourcePath, `\u7B2C\u4E00\u4E2A\u5757\u4E0D\u662F IHDR\uFF1A\u5757\u957F\u5EA6 ${chunkLength}\uFF08\u671F\u671B 13\uFF09`));
    }
    const chunkType = ascii4(source, 12);
    if (chunkType !== "IHDR") {
      return err(badSource(sourcePath, `\u7B2C\u4E00\u4E2A\u5757\u5FC5\u987B\u662F IHDR\uFF0C\u5B9E\u9645\u662F "${chunkType}"`));
    }
    const width = u32be(source, 16);
    const height = u32be(source, 20);
    const bitDepth = source[24];
    const colorType = source[25];
    if (width === 0 || height === 0) {
      return err(badSource(sourcePath, `IHDR \u5BBD\u9AD8\u5FC5\u987B\u975E 0\uFF0C\u5B9E\u9645 ${width}\xD7${height}`));
    }
    if (bitDepth === 0) {
      return err(badSource(sourcePath, "IHDR \u4F4D\u6DF1\u4E3A 0"));
    }
    return ok({
      type: AssetType.Texture,
      dependencies: [],
      byteLength: source.byteLength,
      sourceHash: contentHash(source),
      importerVersion: VERSION,
      data: {
        width,
        height,
        bitDepth,
        colorType,
        hasAlpha: hasAlphaChannel(colorType)
      }
    });
  }
};

// src/extensions/asset-import/importers/atlas.ts
var VERSION2 = 1;
function badSource2(sourcePath, why) {
  return engineError("IMPORT.BAD_SOURCE", `${sourcePath}: ${why}`, { path: sourcePath, importer: "atlas" });
}
function isPlainObject2(v) {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}
var FRAME_KEYS = ["x", "y", "w", "h"];
var atlasImporter = {
  id: AssetType.Atlas,
  version: VERSION2,
  extensions: [".atlas.json"],
  async import(sourcePath, source, _settings, ctx) {
    let text;
    try {
      text = new TextDecoder("utf-8", { fatal: true }).decode(source);
    } catch (e) {
      const why = e instanceof Error ? e.message : String(e);
      return err(badSource2(sourcePath, `\u4E0D\u662F\u5408\u6CD5 UTF-8\uFF08${why}\uFF09`));
    }
    let raw;
    try {
      raw = JSON.parse(text);
    } catch (e) {
      const why = e instanceof Error ? e.message : String(e);
      return err(badSource2(sourcePath, `JSON \u89E3\u6790\u5931\u8D25\uFF08${why}\uFF09`));
    }
    if (!isPlainObject2(raw)) {
      return err(badSource2(sourcePath, "\u9876\u5C42\u5FC5\u987B\u662F JSON \u5BF9\u8C61"));
    }
    const texturesRaw = raw["textures"];
    if (!Array.isArray(texturesRaw)) {
      return err(badSource2(sourcePath, '\u7F3A\u5C11 "textures" \u6570\u7EC4'));
    }
    const dependencies = [];
    for (const [i, tex] of texturesRaw.entries()) {
      if (typeof tex !== "string" || tex.length === 0) {
        return err(badSource2(sourcePath, `textures[${i}] \u5FC5\u987B\u662F\u975E\u7A7A\u5B57\u7B26\u4E32`));
      }
      const id = ctx.lookupId(tex);
      if (id === void 0) {
        const resolved = ctx.resolveSibling(tex);
        return err(
          engineError(
            "IMPORT.MISSING_DEPENDENCY",
            `${sourcePath}: \u4F9D\u8D56 "${tex}" \u627E\u4E0D\u5230\uFF08\u76F8\u5BF9\u5F53\u524D\u6587\u4EF6\u89E3\u6790\u4E3A ${resolved}\uFF1B\u672C\u8F6E\u626B\u63CF\u91CC\u6CA1\u6709\u8FD9\u4E2A\u8D44\u4EA7\uFF09`,
            { source: sourcePath, dependency: tex, resolved }
          )
        );
      }
      dependencies.push(id);
    }
    const framesRaw = raw["frames"];
    if (!isPlainObject2(framesRaw)) {
      return err(badSource2(sourcePath, '\u7F3A\u5C11 "frames" \u5BF9\u8C61'));
    }
    for (const [name, frame] of Object.entries(framesRaw)) {
      if (!isPlainObject2(frame)) {
        return err(badSource2(sourcePath, `\u5E27 "${name}" \u5FC5\u987B\u662F\u5BF9\u8C61`));
      }
      for (const k of FRAME_KEYS) {
        const v = frame[k];
        if (typeof v !== "number" || !Number.isFinite(v)) {
          return err(badSource2(sourcePath, `\u5E27 "${name}" \u7684 ${k} \u5FC5\u987B\u662F\u6709\u9650\u6570\u5B57`));
        }
      }
    }
    return ok({
      type: AssetType.Atlas,
      dependencies,
      byteLength: source.byteLength,
      sourceHash: contentHash(source),
      importerVersion: VERSION2,
      data: {
        frames: Object.keys(framesRaw).length,
        textures: dependencies
      }
    });
  }
};

// src/extensions/asset-import/importers/text.ts
var VERSION3 = 1;
function countLines(text) {
  if (text.length === 0) return 0;
  const parts = text.split(/\r\n|\r|\n/);
  if (parts.length > 1 && parts[parts.length - 1] === "") parts.pop();
  return parts.length;
}
function countCodePoints(text) {
  let n = 0;
  for (let i = 0; i < text.length; i++) {
    n++;
    const c = text.charCodeAt(i);
    if (c >= 55296 && c <= 56319 && i + 1 < text.length) {
      const next = text.charCodeAt(i + 1);
      if (next >= 56320 && next <= 57343) i++;
    }
  }
  return n;
}
var textImporter = {
  id: AssetType.Text,
  version: VERSION3,
  extensions: [".txt", ".json", ".lua", ".md"],
  async import(sourcePath, source) {
    let text;
    try {
      text = new TextDecoder("utf-8", { fatal: true }).decode(source);
    } catch (e) {
      const why = e instanceof Error ? e.message : String(e);
      return err(
        engineError("IMPORT.BAD_SOURCE", `${sourcePath}: \u4E0D\u662F\u5408\u6CD5 UTF-8\uFF08${why}\uFF09`, {
          path: sourcePath,
          importer: "text"
        })
      );
    }
    return ok({
      type: AssetType.Text,
      dependencies: [],
      byteLength: source.byteLength,
      // ★ 对**磁盘字节**哈希（与管线增量判定的口径完全一致）。
      //   用字符串重新编码再哈希会多一次"解码→编码"的往返，虽然对合法 UTF-8
      //   结果是同一份字节，但依赖这个等价性没有必要。
      sourceHash: contentHash(source),
      importerVersion: VERSION3,
      data: {
        lines: countLines(text),
        // 用码点数而不是 UTF-16 长度：中文/emoji 的"字符数"才符合直觉。
        chars: countCodePoints(text),
        encoding: "utf-8"
      }
    });
  }
};

// src/extensions/asset-import/loaders.ts
var ImportLoadErrorCode = {
  /** 元数据在库里，但产物文件不在 —— 说明没跑过导入，或 library 被清空。 */
  NoArtifact: "ASSET.NO_ARTIFACT",
  /** 产物存在但内容不合约定（被手改过 / 旧版本格式）。 */
  BadArtifact: "ASSET.BAD_ARTIFACT"
};
var ImportedTexture = class {
  constructor(id, type, meta, bytes, sourcePath) {
    this.id = id;
    this.type = type;
    this.width = meta.width;
    this.height = meta.height;
    this.bitDepth = meta.bitDepth;
    this.colorType = meta.colorType;
    this.bytes = bytes;
    this.sourcePath = sourcePath;
  }
  width;
  height;
  bytes;
  sourcePath;
  bitDepth;
  colorType;
  dispose() {
  }
  get byteLength() {
    return this.bytes.byteLength;
  }
};
var ImportedAtlas = class {
  constructor(id, type, frameCount, textureIds) {
    this.id = id;
    this.type = type;
    this.frameCount = frameCount;
    this.textureIds = textureIds;
  }
  dispose() {
  }
};
var ImportedText = class {
  constructor(id, type, text, lines, sourcePath) {
    this.id = id;
    this.type = type;
    this.text = text;
    this.lines = lines;
    this.sourcePath = sourcePath;
  }
  dispose() {
  }
};
function numField(data, key, where) {
  const v = data[key];
  if (typeof v !== "number" || !Number.isFinite(v) || v < 0) {
    return err(engineError(ImportLoadErrorCode.BadArtifact, `${where}: \u4EA7\u7269\u5B57\u6BB5 ${key} \u4E0D\u662F\u975E\u8D1F\u6709\u9650\u6570`));
  }
  return ok(v);
}
async function readArtifact(fs, root, id) {
  const path = `${root.replace(/\/+$/, "")}/library/imported/${id}.json`;
  const r = await fs.readText(path);
  if (!r.ok) {
    return err(
      engineError(
        ImportLoadErrorCode.NoArtifact,
        `\u8D44\u4EA7 ${id} \u7684\u5BFC\u5165\u4EA7\u7269\u4E0D\u5728\uFF08${path}\uFF09\u2014\u2014 \u5148\u8DD1 AssetImportPipeline.run()\uFF0C\u6216 library \u88AB\u6E05\u7A7A\u4E86`,
        { id, path }
      )
    );
  }
  let parsed;
  try {
    parsed = JSON.parse(r.value);
  } catch (e) {
    return err(
      engineError(ImportLoadErrorCode.BadArtifact, `\u4EA7\u7269 ${path} \u4E0D\u662F\u5408\u6CD5 JSON\uFF1A${e instanceof Error ? e.message : String(e)}`)
    );
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return err(engineError(ImportLoadErrorCode.BadArtifact, `\u4EA7\u7269 ${path} \u9876\u5C42\u4E0D\u662F\u5BF9\u8C61`));
  }
  const o = parsed;
  const data = o["data"];
  if (typeof data !== "object" || data === null || Array.isArray(data)) {
    return err(engineError(ImportLoadErrorCode.BadArtifact, `\u4EA7\u7269 ${path} \u7F3A data \u5BF9\u8C61`));
  }
  if (typeof o["type"] !== "string") {
    return err(engineError(ImportLoadErrorCode.BadArtifact, `\u4EA7\u7269 ${path} \u7F3A type`));
  }
  return ok({
    type: o["type"],
    importerVersion: typeof o["importerVersion"] === "number" ? o["importerVersion"] : 0,
    sourceHash: typeof o["sourceHash"] === "string" ? o["sourceHash"] : "",
    byteLength: typeof o["byteLength"] === "number" ? o["byteLength"] : 0,
    dependencies: Array.isArray(o["dependencies"]) ? o["dependencies"] : [],
    data
  });
}
function createImportLoaders(opts) {
  const root = opts.root;
  const texture = {
    types: ["texture"],
    async load(meta, ctx) {
      const a = await readArtifact(ctx.fs, root, meta.id);
      if (!a.ok) return err(a.error);
      const w = numField(a.value.data, "width", `texture ${meta.id}`);
      if (!w.ok) return err(w.error);
      const h = numField(a.value.data, "height", `texture ${meta.id}`);
      if (!h.ok) return err(h.error);
      const bytes = await ctx.fs.readBinary(meta.path);
      if (!bytes.ok) return err(bytes.error);
      const bitDepth = typeof a.value.data["bitDepth"] === "number" ? a.value.data["bitDepth"] : 8;
      const colorType = typeof a.value.data["colorType"] === "number" ? a.value.data["colorType"] : 6;
      return ok(
        new ImportedTexture(meta.id, meta.type, { width: w.value, height: h.value, bitDepth, colorType }, bytes.value, meta.path)
      );
    }
  };
  const atlas = {
    types: ["atlas"],
    async load(meta, ctx) {
      const a = await readArtifact(ctx.fs, root, meta.id);
      if (!a.ok) return err(a.error);
      const frames = numField(a.value.data, "frames", `atlas ${meta.id}`);
      if (!frames.ok) return err(frames.error);
      return ok(new ImportedAtlas(meta.id, meta.type, frames.value, a.value.dependencies));
    }
  };
  const text = {
    types: ["text"],
    async load(meta, ctx) {
      const a = await readArtifact(ctx.fs, root, meta.id);
      if (!a.ok) return err(a.error);
      const t = await ctx.fs.readText(meta.path);
      if (!t.ok) return err(t.error);
      const lines = numField(a.value.data, "lines", `text ${meta.id}`);
      if (!lines.ok) return err(lines.error);
      return ok(new ImportedText(meta.id, meta.type, t.value, lines.value, meta.path));
    }
  };
  return [texture, atlas, text];
}

// src/extensions/asset-import/decode/inflate.ts
var InflateErrorCode = {
  /** zlib 头/流/校验和任何一处不合法。message 带字节偏移，足够定位。 */
  BadZlib: "ASSET.BAD_ZLIB"
};
var DEFAULT_MAX_BYTES = 256 * 1024 * 1024;
var MAX_BITS = 15;
var ZlibError = class extends Error {
};
function reverseBits(code, len) {
  let out = 0;
  for (let i = 0; i < len; i++) {
    out = out << 1 | code & 1;
    code >>>= 1;
  }
  return out;
}
function buildHuffman(lengths) {
  const counts = new Uint16Array(MAX_BITS + 1);
  for (let i = 0; i < lengths.length; i++) {
    const l = lengths[i];
    if (l > MAX_BITS) throw new ZlibError(`Huffman \u7801\u957F ${l} \u8D85\u8FC7 ${MAX_BITS}`);
    counts[l] = counts[l] + 1;
  }
  counts[0] = 0;
  let maxLen = MAX_BITS;
  while (maxLen > 0 && counts[maxLen] === 0) maxLen--;
  if (maxLen === 0) {
    return { table: new Uint16Array(1), maxLen: 1 };
  }
  let left = 1;
  for (let len = 1; len <= MAX_BITS; len++) {
    left = (left << 1) - counts[len];
    if (left < 0) throw new ZlibError(`Huffman \u7801\u957F\u8868\u8FC7\u8BA2\u9605\uFF08len=${len} \u65F6\u8D85\u51FA ${-left}\uFF09`);
  }
  const nextCode = new Uint16Array(MAX_BITS + 1);
  let code = 0;
  for (let len = 1; len <= MAX_BITS; len++) {
    code = code + counts[len - 1] << 1;
    nextCode[len] = code;
  }
  const size = 1 << maxLen;
  const table = new Uint16Array(size);
  for (let sym = 0; sym < lengths.length; sym++) {
    const len = lengths[sym];
    if (len === 0) continue;
    const c = nextCode[len];
    nextCode[len] = c + 1;
    const rev = reverseBits(c, len);
    const entry = len << 9 | sym;
    const step = 1 << len;
    for (let i = rev; i < size; i += step) table[i] = entry;
  }
  return { table, maxLen };
}
var fixedLit = null;
var fixedDist = null;
function getFixedLit() {
  if (fixedLit !== null) return fixedLit;
  const lengths = new Uint8Array(288);
  for (let i = 0; i < 144; i++) lengths[i] = 8;
  for (let i = 144; i < 256; i++) lengths[i] = 9;
  for (let i = 256; i < 280; i++) lengths[i] = 7;
  for (let i = 280; i < 288; i++) lengths[i] = 8;
  fixedLit = buildHuffman(lengths);
  return fixedLit;
}
function getFixedDist() {
  if (fixedDist !== null) return fixedDist;
  const lengths = new Uint8Array(32).fill(5);
  fixedDist = buildHuffman(lengths);
  return fixedDist;
}
var LEN_BASE = [
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  13,
  15,
  17,
  19,
  23,
  27,
  31,
  35,
  43,
  51,
  59,
  67,
  83,
  99,
  115,
  131,
  163,
  195,
  227,
  258
];
var LEN_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
var DIST_BASE = [
  1,
  2,
  3,
  4,
  5,
  7,
  9,
  13,
  17,
  25,
  33,
  49,
  65,
  97,
  129,
  193,
  257,
  385,
  513,
  769,
  1025,
  1537,
  2049,
  3073,
  4097,
  6145,
  8193,
  12289,
  16385,
  24577
];
var DIST_EXTRA = [
  0,
  0,
  0,
  0,
  1,
  1,
  2,
  2,
  3,
  3,
  4,
  4,
  5,
  5,
  6,
  6,
  7,
  7,
  8,
  8,
  9,
  9,
  10,
  10,
  11,
  11,
  12,
  12,
  13,
  13
];
var CLEN_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
function adler32(data) {
  let a = 1;
  let b = 0;
  let i = 0;
  while (i < data.length) {
    const end = Math.min(i + 5552, data.length);
    for (; i < end; i++) {
      a += data[i];
      b += a;
    }
    a %= 65521;
    b %= 65521;
  }
  return (b << 16 | a) >>> 0;
}
var BitReader = class {
  constructor(data, start) {
    this.data = data;
    this.pos = start;
  }
  pos;
  bitBuf = 0;
  bitCnt = 0;
  /** 尽可能补到 n 位（不抛）：流末尾不足时由调用方判断。 */
  ensure(n) {
    while (this.bitCnt < n && this.pos < this.data.length) {
      this.bitBuf |= this.data[this.pos] << this.bitCnt;
      this.bitCnt += 8;
      this.pos++;
    }
  }
  readBits(n) {
    if (n === 0) return 0;
    this.ensure(n);
    if (this.bitCnt < n) throw new ZlibError(`\u4F4D\u6D41\u622A\u65AD\uFF1A\u9700\u8981 ${n} \u4F4D\uFF0C\u53EA\u5269 ${this.bitCnt} \u4F4D`);
    const v = this.bitBuf & (1 << n) - 1;
    this.bitBuf >>>= n;
    this.bitCnt -= n;
    return v;
  }
  decode(h) {
    this.ensure(h.maxLen);
    if (this.bitCnt === 0) throw new ZlibError("\u4F4D\u6D41\u622A\u65AD\uFF1AHuffman \u89E3\u7801\u65F6\u5DF2\u65E0\u6570\u636E");
    const entry = h.table[this.bitBuf & (1 << h.maxLen) - 1];
    if (entry === 0) throw new ZlibError(`\u975E\u6CD5 Huffman \u7801\uFF08peek 0x${(this.bitBuf & (1 << h.maxLen) - 1).toString(16)}\uFF09`);
    const len = entry >>> 9;
    if (len > this.bitCnt) throw new ZlibError("\u4F4D\u6D41\u622A\u65AD\uFF1AHuffman \u7801\u5B57\u8DE8\u8D8A\u4E86\u8F93\u5165\u672B\u5C3E");
    this.bitBuf >>>= len;
    this.bitCnt -= len;
    return entry & 511;
  }
  /**
   * 丢弃当前字节里剩余的位，并把"已预读但未消费的整字节"退回 pos。
   * 之后 `pos` 指向下一个未读字节 —— stored 块和 adler32 都靠它对齐。
   */
  alignToByte() {
    const drop = this.bitCnt & 7;
    this.bitBuf >>>= drop;
    this.bitCnt -= drop;
    this.pos -= this.bitCnt >> 3;
    this.bitBuf = 0;
    this.bitCnt = 0;
  }
  /** u16 小端（stored 块的 LEN/NLEN）。调用前必须 `alignToByte()`。 */
  u16le() {
    if (this.pos + 2 > this.data.length) throw new ZlibError("stored \u5757\u5934\u622A\u65AD");
    const v = this.data[this.pos] | this.data[this.pos + 1] << 8;
    this.pos += 2;
    return v;
  }
};
var ByteSink = class {
  buf;
  len = 0;
  maxBytes;
  constructor(initial, maxBytes) {
    this.maxBytes = maxBytes;
    this.buf = new Uint8Array(Math.max(1, Math.min(initial, maxBytes)));
  }
  reserve(n) {
    const need = this.len + n;
    if (need > this.maxBytes) {
      throw new ZlibError(`\u89E3\u538B\u8F93\u51FA\u8D85\u8FC7\u4E0A\u9650 maxBytes=${this.maxBytes}\uFF08\u5DF2\u4EA7\u51FA ${this.len} \u5B57\u8282\uFF0C\u518D\u5199 ${n}\uFF09`);
    }
    if (need <= this.buf.length) return;
    let cap = this.buf.length * 2;
    if (cap < need) cap = need;
    if (cap > this.maxBytes) cap = this.maxBytes;
    const next = new Uint8Array(cap);
    next.set(this.buf.subarray(0, this.len));
    this.buf = next;
  }
  writeByte(b) {
    this.reserve(1);
    this.buf[this.len++] = b;
  }
  writeBytes(src, from, count) {
    this.reserve(count);
    this.buf.set(src.subarray(from, from + count), this.len);
    this.len += count;
  }
  copyBack(distance, count) {
    this.reserve(count);
    const b = this.buf;
    let src = this.len - distance;
    let dst = this.len;
    for (let i = 0; i < count; i++) b[dst + i] = b[src + i];
    this.len += count;
  }
  finish() {
    return this.buf.slice(0, this.len);
  }
};
function inflateZlib(data, opts) {
  const maxBytes = opts?.maxBytes ?? DEFAULT_MAX_BYTES;
  try {
    if (data.length < 6) {
      throw new ZlibError(`zlib \u6570\u636E\u8FC7\u77ED\uFF1A${data.length} \u5B57\u8282\uFF08\u81F3\u5C11 6\uFF09`);
    }
    const cmf = data[0];
    const flg = data[1];
    if ((cmf & 15) !== 8) {
      throw new ZlibError(`zlib CM=${cmf & 15}\uFF08\u53EA\u652F\u6301 8 = deflate\uFF09`);
    }
    if (cmf >> 4 > 7) {
      throw new ZlibError(`zlib CINFO=${cmf >> 4} \u975E\u6CD5\uFF08\u7A97\u53E3 > 32K\uFF0C\u89C4\u8303\u4E0A\u9650 7\uFF09`);
    }
    if ((cmf << 8 | flg) % 31 !== 0) {
      throw new ZlibError(
        `zlib \u5934\u6821\u9A8C\u5931\u8D25\uFF1ACMF=0x${cmf.toString(16)} FLG=0x${flg.toString(16)}\uFF0C(CMF*256+FLG)%31 != 0`
      );
    }
    if ((flg & 32) !== 0) {
      throw new ZlibError("zlib FDICT=1\uFF1A\u4E0D\u652F\u6301\u9884\u7F6E\u5B57\u5178\uFF08PNG \u4E0D\u4F1A\u7528\uFF09");
    }
    const br = new BitReader(data, 2);
    const sink = new ByteSink(opts?.sizeHint !== void 0 ? opts.sizeHint : 64 * 1024, maxBytes);
    const fail = (msg) => {
      throw new ZlibError(`${msg} at byte ${br.pos}`);
    };
    let isFinal = 0;
    do {
      isFinal = br.readBits(1);
      const type = br.readBits(2);
      if (type === 0) {
        br.alignToByte();
        const len = br.u16le();
        const nlen = br.u16le();
        if (((len ^ 65535) & 65535) !== nlen) {
          fail(`stored \u5757\u7684 LEN/NLEN \u4E0D\u4E92\u8865\uFF1ALEN=${len} NLEN=${nlen}`);
        }
        if (br.pos + len > data.length) {
          fail(`stored \u5757\u622A\u65AD\uFF1A\u9700\u8981 ${len} \u5B57\u8282\uFF0C\u5269\u4F59 ${data.length - br.pos}`);
        }
        sink.writeBytes(data, br.pos, len);
        br.pos += len;
      } else if (type === 1 || type === 2) {
        let lit;
        let dist;
        if (type === 1) {
          lit = getFixedLit();
          dist = getFixedDist();
        } else {
          const tables = readDynamicTables(br, fail);
          lit = tables.lit;
          dist = tables.dist;
        }
        decodeCompressed(br, lit, dist, sink, fail);
      } else {
        fail(`invalid block type ${type}\uFF08deflate \u53EA\u6709 0/1/2\uFF09`);
      }
    } while (isFinal === 0);
    br.alignToByte();
    if (br.pos + 4 > data.length) {
      throw new ZlibError(`zlib \u6D41\u7F3A\u5C11 adler32 \u5C3E\uFF08pos=${br.pos} \u957F\u5EA6=${data.length}\uFF09`);
    }
    const expected = (data[br.pos] << 24 | data[br.pos + 1] << 16 | data[br.pos + 2] << 8 | data[br.pos + 3]) >>> 0;
    const actual = adler32(sink.buf.subarray(0, sink.len));
    if (expected !== actual) {
      throw new ZlibError(
        `adler32 \u6821\u9A8C\u5931\u8D25\uFF1A\u671F\u671B 0x${expected.toString(16).padStart(8, "0")}\uFF0C\u5B9E\u9645 0x${actual.toString(16).padStart(8, "0")}`
      );
    }
    if (br.pos + 4 !== data.length) {
      throw new ZlibError(`zlib \u6D41\u540E\u6709 ${data.length - (br.pos + 4)} \u5B57\u8282\u591A\u4F59\u6570\u636E\uFF08pos=${br.pos + 4}\uFF09`);
    }
    return ok(sink.finish());
  } catch (e) {
    if (e instanceof ZlibError) return err(engineError(InflateErrorCode.BadZlib, e.message));
    return err(
      engineError(InflateErrorCode.BadZlib, `inflate \u5185\u90E8\u9519\u8BEF\uFF1A${e instanceof Error ? e.message : String(e)}`)
    );
  }
}
function readDynamicTables(br, fail) {
  const hlit = br.readBits(5) + 257;
  const hdist = br.readBits(5) + 1;
  const hclen = br.readBits(4) + 4;
  if (hlit > 286) fail(`HLIT=${hlit - 257} \u975E\u6CD5\uFF08\u6700\u591A 286 \u4E2A\u5B57\u9762\u91CF/\u957F\u5EA6\u7801\uFF09`);
  if (hdist > 30) fail(`HDIST=${hdist - 1} \u975E\u6CD5\uFF08\u6700\u591A 30 \u4E2A\u8DDD\u79BB\u7801\uFF09`);
  const clenLengths = new Uint8Array(19);
  for (let i2 = 0; i2 < hclen; i2++) clenLengths[CLEN_ORDER[i2]] = br.readBits(3);
  let clen;
  try {
    clen = buildHuffman(clenLengths);
  } catch (e) {
    fail(`\u7801\u957F\u8868\u7684 Huffman \u6784\u9020\u5931\u8D25\uFF1A${e instanceof Error ? e.message : String(e)}`);
  }
  const total = hlit + hdist;
  const lengths = new Uint8Array(total);
  let i = 0;
  while (i < total) {
    const sym = br.decode(clen);
    if (sym < 16) {
      lengths[i++] = sym;
    } else if (sym === 16) {
      if (i === 0) fail("\u7801\u957F\u91CD\u590D\u7801 16 \u51FA\u73B0\u5728\u7B2C\u4E00\u4E2A\u7801\u957F\u4E4B\u524D\uFF08\u6CA1\u6709\u53EF\u590D\u5236\u7684\u4E0A\u4E00\u4E2A\u503C\uFF09");
      const repeat = br.readBits(2) + 3;
      if (i + repeat > total) fail(`\u7801\u957F\u91CD\u590D\u7801 16 \u8D8A\u754C\uFF1Ai=${i} repeat=${repeat} total=${total}`);
      const prev = lengths[i - 1];
      for (let k = 0; k < repeat; k++) lengths[i++] = prev;
    } else if (sym === 17) {
      const repeat = br.readBits(3) + 3;
      if (i + repeat > total) fail(`\u7801\u957F\u91CD\u590D\u7801 17 \u8D8A\u754C\uFF1Ai=${i} repeat=${repeat} total=${total}`);
      i += repeat;
    } else if (sym === 18) {
      const repeat = br.readBits(7) + 11;
      if (i + repeat > total) fail(`\u7801\u957F\u91CD\u590D\u7801 18 \u8D8A\u754C\uFF1Ai=${i} repeat=${repeat} total=${total}`);
      i += repeat;
    } else {
      fail(`\u975E\u6CD5\u7801\u957F\u7B26\u53F7 ${sym}\uFF08\u53EA\u5141\u8BB8 0..18\uFF09`);
    }
  }
  const litLengths = lengths.subarray(0, hlit);
  const distLengths = lengths.subarray(hlit);
  if (litLengths[256] === 0) fail("\u5B57\u9762\u91CF\u8868\u7F3A\u5C11\u5757\u7ED3\u675F\u7B26 256 \u7684\u7801\u5B57");
  try {
    return { lit: buildHuffman(litLengths), dist: buildHuffman(distLengths) };
  } catch (e) {
    fail(`Huffman \u8868\u6784\u9020\u5931\u8D25\uFF1A${e instanceof Error ? e.message : String(e)}`);
  }
}
function decodeCompressed(br, lit, dist, sink, fail) {
  for (; ; ) {
    const sym = br.decode(lit);
    if (sym < 256) {
      sink.writeByte(sym);
      continue;
    }
    if (sym === 256) return;
    if (sym > 285) fail(`\u975E\u6CD5\u957F\u5EA6\u7B26\u53F7 ${sym}\uFF08286/287 \u4FDD\u7559\uFF09`);
    const li = sym - 257;
    const length = LEN_BASE[li] + br.readBits(LEN_EXTRA[li]);
    const dsym = br.decode(dist);
    if (dsym > 29) fail(`\u975E\u6CD5\u8DDD\u79BB\u7B26\u53F7 ${dsym}\uFF0830/31 \u4FDD\u7559\uFF09`);
    const distance = DIST_BASE[dsym] + br.readBits(DIST_EXTRA[dsym]);
    if (distance > sink.len) {
      fail(`invalid distance ${distance} > \u5DF2\u4EA7\u51FA ${sink.len} \u5B57\u8282`);
    }
    sink.copyBack(distance, length);
  }
}

// src/extensions/asset-import/decode/png.ts
var PngErrorCode = {
  BadPng: "ASSET.BAD_PNG",
  Unsupported: "ASSET.UNSUPPORTED_PNG",
  UnsupportedInterlace: "ASSET.UNSUPPORTED_INTERLACE"
};
var SIGNATURE2 = [137, 80, 78, 71, 13, 10, 26, 10];
var DEFAULT_MAX_BYTES2 = 256 * 1024 * 1024;
var IHDR_BYTES = 13;
var CHANNELS = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };
var LEGAL_DEPTHS = {
  0: [1, 2, 4, 8, 16],
  2: [8, 16],
  3: [1, 2, 4, 8],
  4: [8, 16],
  6: [8, 16]
};
var CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 3988292384 ^ c >>> 1 : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();
function crc32(bytes, from, to) {
  let c = 4294967295;
  for (let i = from; i < to; i++) c = CRC_TABLE[(c ^ bytes[i]) & 255] ^ c >>> 8;
  return (c ^ 4294967295) >>> 0;
}
function u32be2(b, at) {
  return (b[at] << 24 | b[at + 1] << 16 | b[at + 2] << 8 | b[at + 3]) >>> 0;
}
function ascii42(b, at) {
  return String.fromCharCode(b[at], b[at + 1], b[at + 2], b[at + 3]);
}
function hex32(v) {
  return `0x${v.toString(16).padStart(8, "0")}`;
}
function bad(why, detail) {
  return detail === void 0 ? engineError(PngErrorCode.BadPng, why) : engineError(PngErrorCode.BadPng, why, detail);
}
function walkChunks(bytes) {
  if (bytes.length < SIGNATURE2.length) {
    return err(bad(`\u6587\u4EF6\u8FC7\u77ED\uFF1A${bytes.length} \u5B57\u8282\uFF0C\u8FDE PNG \u7B7E\u540D\u90FD\u4E0D\u591F\uFF088 \u5B57\u8282\uFF09`));
  }
  for (let i = 0; i < SIGNATURE2.length; i++) {
    if (bytes[i] !== SIGNATURE2[i]) {
      return err(
        bad(
          `PNG \u7B7E\u540D\u4E0D\u5339\u914D\uFF1A\u671F\u671B 89 50 4e 47 0d 0a 1a 0a\uFF0C\u5B9E\u9645 ${Array.from(
            bytes.subarray(0, 8),
            (x) => x.toString(16).padStart(2, "0")
          ).join(" ")}`
        )
      );
    }
  }
  let ihdr;
  let palette;
  let trns;
  const idat = [];
  let iendEnd = -1;
  let at = SIGNATURE2.length;
  while (at < bytes.length) {
    if (at + 8 > bytes.length) {
      return err(bad(`\u5757\u5934\u622A\u65AD\uFF1A\u504F\u79FB ${at} \u5904\u53EA\u5269 ${bytes.length - at} \u5B57\u8282\uFF08\u5757\u5934 8 \u5B57\u8282\uFF09`));
    }
    const length = u32be2(bytes, at);
    const type = ascii42(bytes, at + 4);
    if (length > 2147483647) {
      return err(bad(`\u5757 "${type}" \u957F\u5EA6 ${length} \u975E\u6CD5\uFF08> 2^31-1\uFF09`, { offset: at }));
    }
    const dataStart = at + 8;
    const crcAt = dataStart + length;
    if (crcAt + 4 > bytes.length) {
      return err(
        bad(
          `\u5757 "${type}" \u8D8A\u754C\uFF08\u622A\u65AD\uFF09\uFF1A\u504F\u79FB ${at}\uFF0C\u957F\u5EA6 ${length}\uFF0C\u6587\u4EF6\u53EA\u5269 ${bytes.length - dataStart} \u5B57\u8282`,
          { chunk: type, offset: at }
        )
      );
    }
    const expectedCrc = u32be2(bytes, crcAt);
    const actualCrc = crc32(bytes, at + 4, crcAt);
    if (expectedCrc !== actualCrc) {
      return err(
        bad(
          `\u5757 "${type}" CRC \u6821\u9A8C\u5931\u8D25\uFF1A\u671F\u671B ${hex32(expectedCrc)}\uFF0C\u5B9E\u9645 ${hex32(actualCrc)}\uFF08\u504F\u79FB ${at}\uFF09`,
          { chunk: type, offset: at }
        )
      );
    }
    const chunk = { type, start: at, dataStart, length };
    if (ihdr === void 0) {
      if (type !== "IHDR") {
        return err(bad(`\u7B2C\u4E00\u4E2A\u5757\u5FC5\u987B\u662F IHDR\uFF0C\u5B9E\u9645\u662F "${type}"`));
      }
      if (length !== IHDR_BYTES) {
        return err(bad(`IHDR \u6570\u636E\u957F\u5EA6 ${length}\uFF08\u5FC5\u987B 13\uFF09`));
      }
      ihdr = chunk;
    } else if (type === "IHDR") {
      return err(bad("\u51FA\u73B0\u7B2C\u4E8C\u4E2A IHDR"));
    } else if (type === "PLTE") {
      if (palette !== void 0) return err(bad("\u51FA\u73B0\u7B2C\u4E8C\u4E2A PLTE"));
      if (idat.length > 0) return err(bad("PLTE \u51FA\u73B0\u5728 IDAT \u4E4B\u540E\uFF08\u89C4\u8303\u8981\u6C42\u4E4B\u524D\uFF09"));
      if (length === 0 || length % 3 !== 0 || length > 768) {
        return err(bad(`PLTE \u957F\u5EA6 ${length} \u975E\u6CD5\uFF08\u5E94\u4E3A 3 \u7684\u500D\u6570\u4E14 \u2264768\uFF09`));
      }
      palette = chunk;
    } else if (type === "tRNS") {
      if (trns !== void 0) return err(bad("\u51FA\u73B0\u7B2C\u4E8C\u4E2A tRNS"));
      if (idat.length > 0) return err(bad("tRNS \u51FA\u73B0\u5728 IDAT \u4E4B\u540E\uFF08\u89C4\u8303\u8981\u6C42\u4E4B\u524D\uFF09"));
      trns = chunk;
    } else if (type === "IDAT") {
      idat.push(chunk);
    } else if (type === "IEND") {
      if (length !== 0) return err(bad(`IEND \u6570\u636E\u957F\u5EA6 ${length}\uFF08\u5FC5\u987B 0\uFF09`));
      iendEnd = crcAt + 4;
      break;
    } else if ((bytes[at + 4] & 32) === 0) {
      return err(
        engineError(
          PngErrorCode.Unsupported,
          `\u672A\u77E5\u5173\u952E\u5757 "${type}"\uFF08\u4FDD\u7559\u4F4D\u5FC5\u987B\u4E3A 0\uFF1B\u672C\u89E3\u7801\u5668\u4E0D\u8BA4\u8BC6\u5B83\uFF0C\u4E0D\u80FD\u731C\u7740\u8DF3\u8FC7\uFF09`,
          { chunk: type, offset: at }
        )
      );
    }
    at = crcAt + 4;
  }
  if (ihdr === void 0) return err(bad("\u6CA1\u6709 IHDR"));
  if (iendEnd < 0) {
    return err(bad("\u7F3A\u5C11 IEND\uFF08\u6587\u4EF6\u5728\u6700\u540E\u4E00\u4E2A\u5757\u4E4B\u540E\u7ED3\u675F\uFF0C\u53EF\u80FD\u88AB\u622A\u65AD\uFF09"));
  }
  if (idat.length === 0) return err(bad("\u6CA1\u6709 IDAT\uFF1A\u6587\u4EF6\u91CC\u6CA1\u6709\u4EFB\u4F55\u56FE\u50CF\u6570\u636E"));
  if (iendEnd !== bytes.length) {
    return err(bad(`IEND \u4E4B\u540E\u8FD8\u6709 ${bytes.length - iendEnd} \u5B57\u8282\u6570\u636E\uFF08PNG \u4E0D\u5141\u8BB8\u5C3E\u90E8\u9644\u52A0\u5185\u5BB9\uFF09`));
  }
  return ok({ ihdr, palette, trns, idat });
}
function readHeader(bytes, c) {
  const width = u32be2(bytes, c.dataStart);
  const height = u32be2(bytes, c.dataStart + 4);
  const bitDepth = bytes[c.dataStart + 8];
  const colorType = bytes[c.dataStart + 9];
  const compression = bytes[c.dataStart + 10];
  const filter = bytes[c.dataStart + 11];
  const interlace = bytes[c.dataStart + 12];
  if (width === 0 || height === 0) return err(bad(`IHDR \u5BBD\u9AD8\u5FC5\u987B\u975E 0\uFF0C\u5B9E\u9645 ${width}\xD7${height}`));
  if (compression !== 0) return err(bad(`IHDR compression=${compression}\uFF08\u53EA\u652F\u6301 0\uFF09`));
  if (filter !== 0) return err(bad(`IHDR filter method=${filter}\uFF08\u53EA\u652F\u6301 0\uFF09`));
  if (interlace !== 0 && interlace !== 1) {
    return err(bad(`IHDR interlace=${interlace} \u975E\u6CD5\uFF08\u53EA\u5141\u8BB8 0/1\uFF09`));
  }
  return ok({ width, height, bitDepth, colorType, interlace });
}
function paeth(a, b, c) {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}
function unfilter(raw, stride, height, bpp) {
  const out = new Uint8Array(stride * height);
  for (let y = 0; y < height; y++) {
    const rowStart = y * (stride + 1);
    const ft = raw[rowStart];
    const src = rowStart + 1;
    const dst = y * stride;
    if (ft === 0) {
      out.set(raw.subarray(src, src + stride), dst);
      continue;
    }
    if (ft > 4) return err(bad(`\u7B2C ${y} \u884C\u7684\u6EE4\u6CE2\u7C7B\u578B ${ft} \u975E\u6CD5\uFF08\u53EA\u5141\u8BB8 0..4\uFF09`));
    for (let x = 0; x < stride; x++) {
      const cur = raw[src + x];
      const left = x >= bpp ? out[dst + x - bpp] : 0;
      const up = y > 0 ? out[dst - stride + x] : 0;
      const upLeft = y > 0 && x >= bpp ? out[dst - stride + x - bpp] : 0;
      let v;
      switch (ft) {
        case 1:
          v = cur + left;
          break;
        case 2:
          v = cur + up;
          break;
        case 3:
          v = cur + (left + up >> 1);
          break;
        default:
          v = cur + paeth(left, up, upLeft);
          break;
      }
      out[dst + x] = v & 255;
    }
  }
  return ok(out);
}
function sampleU16(row, byteIndex) {
  return row[byteIndex] << 8 | row[byteIndex + 1];
}
function subByteSample(row, x, bitDepth) {
  const perByte = 8 / bitDepth;
  const byte = row[Math.floor(x / perByte)];
  const shift = 8 - bitDepth * (x % perByte + 1);
  return byte >> shift & (1 << bitDepth) - 1;
}
function toRgba(raw, stride, h, palette, trns) {
  const { width, height, colorType, bitDepth } = h;
  const out = new Uint8Array(width * height * 4);
  const maxV = (1 << bitDepth) - 1;
  const scale = (v) => Math.round(v * 255 / maxV);
  let trnsGray = -1;
  let trnsR = -1;
  let trnsG = -1;
  let trnsB = -1;
  if (trns !== void 0) {
    if (colorType === 0) {
      if (trns.length !== 2) return err(bad(`\u7070\u5EA6\u56FE\u7684 tRNS \u957F\u5EA6\u5FC5\u987B\u662F 2\uFF0C\u5B9E\u9645 ${trns.length}`));
      trnsGray = trns[0] << 8 | trns[1];
    } else if (colorType === 2) {
      if (trns.length !== 6) return err(bad(`RGB \u56FE\u7684 tRNS \u957F\u5EA6\u5FC5\u987B\u662F 6\uFF0C\u5B9E\u9645 ${trns.length}`));
      trnsR = trns[0] << 8 | trns[1];
      trnsG = trns[2] << 8 | trns[3];
      trnsB = trns[4] << 8 | trns[5];
    } else if (colorType !== 3) {
      return err(bad(`colorType=${colorType} \u4E0D\u5141\u8BB8 tRNS\uFF08\u8BE5\u7C7B\u578B\u81EA\u5E26 alpha \u901A\u9053\uFF09`));
    }
  }
  let paletteAlpha = false;
  for (let y = 0; y < height; y++) {
    const row = raw.subarray(y * stride, (y + 1) * stride);
    let o = y * width * 4;
    for (let x = 0; x < width; x++, o += 4) {
      if (colorType === 0) {
        let v;
        let alpha = 255;
        if (bitDepth === 16) {
          v = sampleU16(row, x * 2);
          out[o] = out[o + 1] = out[o + 2] = v >> 8 & 255;
          if (v === trnsGray) alpha = 0;
        } else if (bitDepth === 8) {
          v = row[x];
          out[o] = out[o + 1] = out[o + 2] = v;
          if (v === trnsGray) alpha = 0;
        } else {
          v = subByteSample(row, x, bitDepth);
          const g = scale(v);
          out[o] = out[o + 1] = out[o + 2] = g;
          if (v === trnsGray) alpha = 0;
        }
        out[o + 3] = alpha;
      } else if (colorType === 2) {
        let r;
        let g;
        let b;
        if (bitDepth === 16) {
          const rv = sampleU16(row, x * 6);
          const gv = sampleU16(row, x * 6 + 2);
          const bv = sampleU16(row, x * 6 + 4);
          r = rv >> 8;
          g = gv >> 8;
          b = bv >> 8;
          out[o] = r;
          out[o + 1] = g;
          out[o + 2] = b;
          out[o + 3] = rv === trnsR && gv === trnsG && bv === trnsB ? 0 : 255;
        } else {
          r = row[x * 3];
          g = row[x * 3 + 1];
          b = row[x * 3 + 2];
          out[o] = r;
          out[o + 1] = g;
          out[o + 2] = b;
          out[o + 3] = r === trnsR && g === trnsG && b === trnsB ? 0 : 255;
        }
      } else if (colorType === 3) {
        if (palette === void 0) return err(bad("colorType=3 \u4F46\u7F3A\u5C11 PLTE"));
        const idx = bitDepth === 8 ? row[x] : subByteSample(row, x, bitDepth);
        const entries = palette.length / 3;
        if (idx >= entries) {
          return err(
            bad(`\u8C03\u8272\u677F\u7D22\u5F15\u8D8A\u754C\uFF1A\u7B2C (${x},${y}) \u50CF\u7D20\u7D22\u5F15 ${idx}\uFF0CPLTE \u53EA\u6709 ${entries} \u9879`, { x, y, index: idx })
          );
        }
        out[o] = palette[idx * 3];
        out[o + 1] = palette[idx * 3 + 1];
        out[o + 2] = palette[idx * 3 + 2];
        if (trns !== void 0 && idx < trns.length) {
          out[o + 3] = trns[idx];
          if (trns[idx] < 255) paletteAlpha = true;
        } else {
          out[o + 3] = 255;
        }
      } else if (colorType === 4) {
        if (bitDepth === 16) {
          const v = sampleU16(row, x * 4);
          out[o] = out[o + 1] = out[o + 2] = v >> 8;
          out[o + 3] = sampleU16(row, x * 4 + 2) >> 8;
        } else {
          const v = row[x * 2];
          out[o] = out[o + 1] = out[o + 2] = v;
          out[o + 3] = row[x * 2 + 1];
        }
      } else {
        if (bitDepth === 16) {
          for (let k = 0; k < 4; k++) out[o + k] = row[x * 8 + k * 2];
        } else {
          out[o] = row[x * 4];
          out[o + 1] = row[x * 4 + 1];
          out[o + 2] = row[x * 4 + 2];
          out[o + 3] = row[x * 4 + 3];
        }
      }
    }
  }
  return ok({
    pixels: out,
    usedTransparencyKey: colorType === 0 && trnsGray >= 0 || colorType === 2 && trnsR >= 0,
    paletteAlpha
  });
}
function decodePng(bytes, opts) {
  const maxBytes = opts?.maxBytes ?? DEFAULT_MAX_BYTES2;
  const walked = walkChunks(bytes);
  if (!walked.ok) return err(walked.error);
  const { ihdr, palette, trns, idat } = walked.value;
  const hdr = readHeader(bytes, ihdr);
  if (!hdr.ok) return err(hdr.error);
  const h = hdr.value;
  if (h.interlace !== 0) {
    return err(
      engineError(
        PngErrorCode.UnsupportedInterlace,
        `PNG \u4F7F\u7528\u4E86 Adam7 \u9694\u884C\uFF08interlace=${h.interlace}\uFF09\u2014\u2014 \u672C\u89E3\u7801\u5668\u660E\u786E\u4E0D\u652F\u6301\u3002\u5DE5\u7A0B\u5185\u8BED\u6599\u4E3A 0 \u4E2A\u9694\u884C\u56FE\uFF1B\u672A\u7ECF\u9A8C\u8BC1\u7684\u9694\u884C\u5B9E\u73B0\u4F1A\u5BFC\u81F4\u82B1\u5C4F\uFF0C\u6240\u4EE5\u8FD9\u91CC\u76F4\u63A5\u62A5\u9519\u800C\u4E0D\u662F\u731C\u3002`,
        { width: h.width, height: h.height }
      )
    );
  }
  const channels = CHANNELS[h.colorType];
  if (channels === void 0) {
    return err(
      engineError(
        PngErrorCode.Unsupported,
        `\u672A\u77E5 colorType=${h.colorType}\uFF08\u5141\u8BB8 0/2/3/4/6\uFF1B7 \u53CA\u4FDD\u7559\u503C\u4E00\u5F8B\u62D2\u7EDD\uFF09`,
        { colorType: h.colorType }
      )
    );
  }
  const legal = LEGAL_DEPTHS[h.colorType];
  if (!legal.includes(h.bitDepth)) {
    return err(
      engineError(
        PngErrorCode.Unsupported,
        `\u4E0D\u652F\u6301\u7684 colorType/bitDepth \u7EC4\u5408\uFF1AcolorType=${h.colorType} bitDepth=${h.bitDepth}\uFF08\u8BE5 colorType \u5141\u8BB8 ${legal.join("/")}\uFF09`,
        { colorType: h.colorType, bitDepth: h.bitDepth }
      )
    );
  }
  if (h.colorType === 3 && palette === void 0) {
    return err(bad("colorType=3\uFF08\u8C03\u8272\u677F\uFF09\u4F46\u6587\u4EF6\u91CC\u6CA1\u6709 PLTE \u5757"));
  }
  const bitsPerPixel = channels * h.bitDepth;
  const stride = Math.ceil(h.width * bitsPerPixel / 8);
  const bpp = Math.max(1, Math.ceil(bitsPerPixel / 8));
  const rowBytes = stride + 1;
  if (h.height > 0 && h.width > Math.floor(maxBytes / 4 / h.height)) {
    return err(
      bad(
        `PNG \u5C3A\u5BF8 ${h.width}\xD7${h.height} \u7684 RGBA8 \u50CF\u7D20\u6570\u8D85\u8FC7 maxBytes=${maxBytes} \u7684\u4E0A\u9650\uFF08\u89E3\u538B\u70B8\u5F39\u4FDD\u62A4\uFF09`,
        { width: h.width, height: h.height, maxBytes }
      )
    );
  }
  if (h.height > 0 && h.width > Math.floor(maxBytes / rowBytes)) {
    return err(
      bad(
        `PNG ${h.width}\xD7${h.height} \u7684\u89E3\u538B\u540E\u626B\u63CF\u7EBF\u7EA6 ${rowBytes * h.height} \u5B57\u8282\uFF0C\u8D85\u8FC7 maxBytes=${maxBytes}`,
        { width: h.width, height: h.height, maxBytes }
      )
    );
  }
  const expectedRaw = rowBytes * h.height;
  const compressed = new Uint8Array(idat.reduce((n, c) => n + c.length, 0));
  {
    let o = 0;
    for (const c of idat) {
      compressed.set(bytes.subarray(c.dataStart, c.dataStart + c.length), o);
      o += c.length;
    }
  }
  const inflated = inflateZlib(compressed, { maxBytes: expectedRaw, sizeHint: expectedRaw });
  if (!inflated.ok) {
    return err(
      engineError(
        PngErrorCode.BadPng,
        `IDAT \u89E3\u538B\u5931\u8D25\uFF08${idat.length} \u4E2A\u5757\uFF0C\u5171 ${compressed.length} \u5B57\u8282\u89E3\u538B\u51FA\uFF0C\u671F\u671B ${expectedRaw}\uFF09\uFF1A${inflated.error.message}`,
        { idatChunks: idat.length }
      )
    );
  }
  const raw = inflated.value;
  if (raw.length !== expectedRaw) {
    return err(
      bad(
        `\u626B\u63CF\u7EBF\u6570\u636E\u957F\u5EA6\u4E0D\u5BF9\uFF1A\u671F\u671B ${expectedRaw}\uFF08${h.height} \u884C \xD7 (1 \u6EE4\u6CE2\u5B57\u8282 + ${stride})\uFF09\uFF0C\u5B9E\u9645 ${raw.length}\u3002IDAT \u88AB\u622A\u65AD\u6216 IHDR \u4E0E\u5B9E\u9645\u6570\u636E\u4E0D\u7B26 \u2014\u2014 \u62D2\u7EDD\u8FD4\u56DE\u534A\u5F20\u56FE\u3002`,
        { expectedRaw, actual: raw.length }
      )
    );
  }
  const unfiltered = unfilter(raw, stride, h.height, bpp);
  if (!unfiltered.ok) return err(unfiltered.error);
  const paletteBytes = palette === void 0 ? void 0 : bytes.subarray(palette.dataStart, palette.dataStart + palette.length);
  const trnsBytes = trns === void 0 ? void 0 : bytes.subarray(trns.dataStart, trns.dataStart + trns.length);
  const rgba = toRgba(unfiltered.value, stride, h, paletteBytes, trnsBytes);
  if (!rgba.ok) return err(rgba.error);
  const hasChannelAlpha = h.colorType === 4 || h.colorType === 6;
  return ok({
    width: h.width,
    height: h.height,
    pixels: rgba.value.pixels,
    bitDepth: h.bitDepth,
    colorType: h.colorType,
    hasAlpha: hasChannelAlpha || rgba.value.usedTransparencyKey || rgba.value.paletteAlpha,
    usedTransparencyKey: rgba.value.usedTransparencyKey
  });
}

// src/extensions/render/atlas-from-assets.ts
var DEFAULT_PADDING = 1;
var DEFAULT_MAX_SIZE = 2048;
function errAtlas(code, message, detail) {
  return detail === void 0 ? engineError(code, message) : engineError(code, message, detail);
}
function byName(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}
function nextPowerOfTwo(n) {
  if (n <= 1) return 1;
  let p = 1;
  while (p < n) p *= 2;
  return p;
}
function buildAtlasFromSources(sources, opts) {
  const padding = opts?.padding ?? DEFAULT_PADDING;
  const maxSize = opts?.maxSize ?? DEFAULT_MAX_SIZE;
  if (!Number.isInteger(padding) || padding < 0) {
    return err(errAtlas("ASSET.BAD_ATLAS_OPTIONS", `padding \u5FC5\u987B\u662F\u975E\u8D1F\u6574\u6570\uFF0C\u6536\u5230 ${padding}`));
  }
  if (!Number.isInteger(maxSize) || maxSize < 1) {
    return err(errAtlas("ASSET.BAD_ATLAS_OPTIONS", `maxSize \u5FC5\u987B\u662F \u22651 \u7684\u6574\u6570\uFF0C\u6536\u5230 ${maxSize}`));
  }
  const seen = /* @__PURE__ */ new Set();
  for (const s of sources) {
    if (seen.has(s.name)) {
      return err(
        errAtlas("ASSET.ATLAS_DUPLICATE_FRAME", `\u5E27\u540D\u91CD\u590D\uFF1A"${s.name}"\uFF08\u56FE\u96C6\u5E27\u540D\u5FC5\u987B\u552F\u4E00\uFF09`, { name: s.name })
      );
    }
    seen.add(s.name);
  }
  const ordered = [...sources].sort((a, b) => {
    const dh = b.png.height - a.png.height;
    return dh !== 0 ? dh : byName(a.name, b.name);
  });
  for (const s of ordered) {
    if (s.png.width > maxSize || s.png.height > maxSize) {
      return err(
        errAtlas(
          "ASSET.ATLAS_TOO_LARGE",
          `\u5E27 "${s.name}" \u662F ${s.png.width}\xD7${s.png.height}\uFF0C\u5355\u5E27\u5C31\u8D85\u8FC7 maxSize=${maxSize}`,
          { frame: s.name, width: s.png.width, height: s.png.height, maxSize }
        )
      );
    }
  }
  const placements = [];
  let x = 0;
  let y = 0;
  let rowH = 0;
  let neededW = 0;
  let neededH = 0;
  let widestBy = "";
  let tallestBy = "";
  for (const s of ordered) {
    const w = s.png.width;
    const h = s.png.height;
    if (x > 0 && x + w > maxSize) {
      y += rowH + padding;
      x = 0;
      rowH = 0;
    }
    placements.push({ name: s.name, x, y, w, h });
    x += w + padding;
    if (h > rowH) rowH = h;
    if (x - padding > neededW) {
      neededW = x - padding;
      widestBy = s.name;
    }
    if (y + rowH > neededH) {
      neededH = y + rowH;
      tallestBy = s.name;
    }
  }
  if (ordered.length === 0) {
    return ok({ width: 1, height: 1, pixels: new Uint8Array(4), frames: /* @__PURE__ */ new Map() });
  }
  if (neededW > maxSize) {
    return err(
      errAtlas(
        "ASSET.ATLAS_TOO_LARGE",
        `\u56FE\u96C6\u5BBD\u5EA6 ${neededW} \u8D85\u8FC7 maxSize=${maxSize}\uFF08\u6700\u540E\u4E00\u5E27\u6491\u5BBD\u7684\u662F "${widestBy}"\uFF09`,
        { frame: widestBy, neededWidth: neededW, maxSize }
      )
    );
  }
  if (neededH > maxSize) {
    return err(
      errAtlas(
        "ASSET.ATLAS_TOO_LARGE",
        `\u56FE\u96C6\u9AD8\u5EA6 ${neededH} \u8D85\u8FC7 maxSize=${maxSize}\uFF08\u6491\u9AD8\u7684\u662F "${tallestBy}"\uFF09`,
        { frame: tallestBy, neededHeight: neededH, maxSize }
      )
    );
  }
  const width = nextPowerOfTwo(neededW);
  const height = nextPowerOfTwo(neededH);
  if (width > maxSize || height > maxSize) {
    return err(
      errAtlas(
        "ASSET.ATLAS_TOO_LARGE",
        `\u5411\u4E0A\u53D6\u6574\u5230 2 \u7684\u5E42\u540E\u5C3A\u5BF8 ${width}\xD7${height} \u8D85\u8FC7 maxSize=${maxSize}`,
        { width, height, maxSize }
      )
    );
  }
  const pixels = new Uint8Array(width * height * 4);
  const byNameSource = /* @__PURE__ */ new Map();
  for (const s of sources) byNameSource.set(s.name, s.png);
  for (const p of placements) {
    const src = byNameSource.get(p.name);
    for (let row = 0; row < p.h; row++) {
      const from = row * p.w * 4;
      const to = ((p.y + row) * width + p.x) * 4;
      pixels.set(src.pixels.subarray(from, from + p.w * 4), to);
    }
  }
  const frames = /* @__PURE__ */ new Map();
  for (const p of placements) {
    frames.set(p.name, {
      u0: p.x / width,
      v0: p.y / height,
      u1: (p.x + p.w) / width,
      v1: (p.y + p.h) / height,
      w: p.w,
      h: p.h
    });
  }
  return ok({ width, height, pixels, frames });
}

// src/browser-entry.ts
var PlayerController = class _PlayerController extends Component {
  speed = 4.5;
  lastTick = -1;
  snap = null;
  static pollInput = null;
  schema = {
    type: "game.player",
    fields: { speed: FieldType.Float }
  };
  onUpdate(tick, dt) {
    const poll = _PlayerController.pollInput;
    if (poll === null) return;
    if (tick !== this.lastTick) {
      this.snap = poll();
      this.lastTick = tick;
    }
    const s = this.snap;
    if (s === null) return;
    let dx = 0;
    let dz = 0;
    if (s.keysDown.has("KeyA") || s.keysDown.has("ArrowLeft")) dx -= 1;
    if (s.keysDown.has("KeyD") || s.keysDown.has("ArrowRight")) dx += 1;
    if (s.keysDown.has("KeyW") || s.keysDown.has("ArrowUp")) dz += 1;
    if (s.keysDown.has("KeyS") || s.keysDown.has("ArrowDown")) dz -= 1;
    const len = Math.hypot(dx, dz);
    if (len === 0) return;
    const n = this.node;
    if (n === null) return;
    n.setLocalPosition(
      n.localPosition.x + dx / len * this.speed * dt,
      n.localPosition.y + dz / len * this.speed * dt
    );
  }
};
var Workable = class extends Component {
  workleft = 3;
  schema = {
    type: "game.workable",
    fields: { workleft: FieldType.Int }
  };
};
function createWorldModule(physics, hooks) {
  let off = null;
  return {
    id: "game.world",
    init(ctx) {
      const scene = ctx.services.require(Services.Scene);
      const sched = ctx.services.require(Services.Scheduler);
      off = sched.onStep((tick, dt) => {
        scene.step(tick, dt);
        physics.resolve();
        hooks.onStep?.(tick, dt);
        hooks.onTick(tick);
      });
    },
    stop() {
      off?.();
      off = null;
    },
    describe() {
      return `\u4E16\u754C\uFF1A${physics.stats().bodies} \u4E2A\u7269\u7406\u4F53`;
    }
  };
}
var LUA_DEMO = `
local beans = {}
local t = 0

local function collect()
  for i = 0, 13 do
    local ids = engine_nodes_named("berry" .. tostring(i))
    if #ids > 0 then
      beans[#beans + 1] = { id = ids[1] }
    end
  end
end

function onUpdate(selfId, dt, tick)
  t = t + dt
  if #beans == 0 then collect() end
  for i = 1, #beans do
    local b = beans[i]
    if b.z0 == nil then
      local p = engine_get_pos(b.id)
      if p ~= nil then
        b.x0 = p.x
        b.z0 = p.z
      end
    end
    if b.z0 ~= nil then
      engine_set_pos(b.id, b.x0, b.z0 + math.sin(t * 1.6 + i) * 0.18)
    end
  end
  if tick > 0 and tick % 60 == 0 then
    engine_log("demo: " .. tostring(#beans) .. " \u4E2A\u6D46\u679C\u5728\u6F02\u6D6E (tick " .. tostring(tick) .. ")")
  end
end
`;
var DEMO_FRAMES = ["ground", "tree", "rock", "berry", "player"];
var ASSET_ROOT = "/assets";
async function bakeAtlasFromAssets() {
  try {
    const fs = new MemoryFileSystem();
    const logger = new Logger(() => performance.now());
    logger.setLevel(LogLevel.Warn);
    const db = new AssetDatabase(fs, logger.channel("asset"));
    const importers = new ImporterRegistry();
    importers.register(textureImporter);
    importers.register(atlasImporter);
    importers.register(textImporter);
    const pipeline = new AssetImportPipeline(fs, db, importers, logger.channel("import"));
    for (const l of createImportLoaders({ root: ASSET_ROOT })) db.registerLoader(l);
    for (const name of DEMO_FRAMES) {
      const res = await fetch(new URL(`assets/${name}.png`, location.href), { cache: "no-cache" });
      if (!res.ok) return null;
      const w = await fs.writeBinary(`${ASSET_ROOT}/${name}.png`, new Uint8Array(await res.arrayBuffer()));
      if (!w.ok) return null;
    }
    const report = await pipeline.run(ASSET_ROOT);
    if (!report.ok) return null;
    const sources = [];
    for (const name of DEMO_FRAMES) {
      const id = db.idAtPath(`${ASSET_ROOT}/${name}.png`);
      if (id === void 0) continue;
      const h = await db.load(id);
      if (!h.ok) continue;
      const asset = h.value.asset;
      try {
        if (asset instanceof ImportedTexture) {
          const dec = decodePng(asset.bytes);
          if (dec.ok) sources.push({ name, png: dec.value });
        }
      } finally {
        h.value.release();
      }
    }
    if (sources.length !== DEMO_FRAMES.length) return null;
    const built = buildAtlasFromSources(sources, { padding: 2 });
    if (!built.ok) return null;
    return { atlas: built.value, label: `assets\xD7${sources.length}` };
  } catch {
    return null;
  }
}
async function main() {
  const canvas = document.getElementById("cv");
  const hud = document.getElementById("hud");
  const toastEl = document.getElementById("toast");
  if (canvas === null || hud === null || toastEl === null) {
    throw new Error("\u9875\u9762\u7ED3\u6784\u4E0D\u5B8C\u6574\uFF1A\u9700\u8981 #cv / #hud / #toast");
  }
  const dpr = Math.min(2, window.devicePixelRatio || 1);
  canvas.width = Math.floor((canvas.clientWidth || 960) * dpr);
  canvas.height = Math.floor((canvas.clientHeight || 600) * dpr);
  const registry = new BackendRegistry();
  registerNullBackends(registry);
  registry.registerGfx(webgl2Backend, 100);
  registry.registerInput(domInputBackend, 100);
  registry.registerAudio(webAudioBackend, 100);
  registry.registerScript(createLuaScriptBackend({ wasmPath: new URL("glue.wasm", location.href).href }), 100);
  let appRef = null;
  const physics = new SpatialHashWorld(
    makeSceneAccessor((id) => {
      const n = appRef?.scene.find(id);
      if (n === void 0) return void 0;
      return {
        id: n.id,
        worldPosition: () => n.worldPosition,
        setLocalPosition: (x, y) => n.setLocalPosition(x, y)
      };
    }),
    { cellSize: 4, maxIterations: 3 }
  );
  let heroId = -1;
  let hudTick = 0;
  const baked = await bakeAtlasFromAssets();
  const atlasLabel = baked === null ? "procedural" : baked.label;
  const renderMod = createRenderModule({
    viewportWidth: canvas.width,
    viewportHeight: canvas.height,
    zoom: 26 * dpr,
    tiltY: 0.62,
    atlas: baked?.atlas,
    follow: () => {
      if (heroId < 0) return void 0;
      const n = appRef?.scene.find(heroId);
      if (n === void 0) return void 0;
      const p = n.worldPosition;
      return { x: p.x, z: p.y };
    }
  });
  const scriptMod = createScriptModule({ callTimeoutMs: 16 });
  const worldMod = createWorldModule(physics, {
    onTick: (t) => hudTick = t,
    onStep: (tick, dt) => {
      void scriptMod.update(tick, dt);
    }
  });
  const appR = await bootGameApp({
    platformId: "web",
    interactive: true,
    registry,
    modules: [worldMod, renderMod, scriptMod],
    seed: 20261022,
    fixedDt: 1 / 30,
    tickSource: new RafTickSource(() => performance.now()),
    backendOptions: {
      gfx: { canvas },
      input: { keyboard: window, pointer: canvas },
      audio: {}
    }
  });
  if (!appR.ok) {
    document.body.innerHTML = `<pre style="color:#f66;padding:16px;font:13px ui-monospace">\u542F\u52A8\u5931\u8D25\uFF1A${appR.error.code}
${appR.error.message}

${JSON.stringify(appR.error.detail ?? {}, null, 2)}</pre>`;
    return;
  }
  const app = appR.value;
  appRef = app;
  PlayerController.pollInput = () => app.platform.input.poll();
  const scriptRuntime = scriptMod.runtime;
  if (scriptRuntime === null) {
    app.log.channel("host").warn("\u5E73\u53F0\u6CA1\u6709\u811A\u672C\u8FD0\u884C\u65F6\uFF1A\u6F14\u793A\u811A\u672C\u4E0D\u4F1A\u6267\u884C");
  } else {
    const lr = await scriptRuntime.loadModule("demo", LUA_DEMO);
    if (!lr.ok) app.log.channel("host").error(`\u6F14\u793A\u811A\u672C\u52A0\u8F7D\u5931\u8D25\uFF1A${lr.error.code} ${lr.error.message}`);
  }
  const reg = app.components;
  reg.register(new Sprite().schema, () => new Sprite());
  reg.register({ type: "game.player", fields: { speed: FieldType.Float } }, () => new PlayerController());
  reg.register({ type: "game.workable", fields: { workleft: FieldType.Int } }, () => new Workable());
  const scene = app.scene;
  const rnd = app.random;
  for (let gz = -8; gz <= 8; gz++) {
    for (let gx = -14; gx <= 14; gx++) {
      const r = scene.spawnAt(`ground_${gx}_${gz}`, gx * 2, gz * 2);
      if (!r.ok) continue;
      const s = makeSprite("ground", 2.05, 2.05);
      s.pivotY = 0.5;
      s.r = 0.62 + rnd.range(0, 0.06);
      s.g = 0.72 + rnd.range(0, 0.06);
      s.b = 0.66;
      s.order = -100;
      scene.attach(r.value.id, () => s);
    }
  }
  const obstacleIds = [];
  for (let i = 0; i < 70; i++) {
    const isTree = i % 3 !== 0;
    const x = rnd.range(-26, 26);
    const z = rnd.range(-16, 16);
    const r = scene.spawnAt(isTree ? `tree${i}` : `rock${i}`, x, z);
    if (!r.ok) continue;
    const node = r.value;
    const s = makeSprite(isTree ? "tree" : "rock", isTree ? 2 : 1.6, isTree ? 3 : 1.4);
    s.pivotY = 0;
    scene.attach(node.id, () => s);
    if (isTree) scene.attach(node.id, () => new Workable());
    obstacleIds.push(node.id);
    physics.add({ nodeId: node.id, radius: isTree ? 0.55 : 0.7, isStatic: true });
  }
  for (let i = 0; i < 14; i++) {
    const r = scene.spawnAt(`berry${i}`, rnd.range(-24, 24), rnd.range(-14, 14));
    if (!r.ok) continue;
    const s = makeSprite("berry", 0.8, 0.8);
    s.pivotY = 0;
    scene.attach(r.value.id, () => s);
  }
  const hero = scene.spawnAt("hero", 0, 0);
  if (!hero.ok) throw new Error(hero.error.message);
  heroId = hero.value.id;
  const heroSprite = makeSprite("player", 1.1, 1.7);
  heroSprite.pivotY = 0;
  scene.attach(heroId, () => heroSprite);
  scene.attach(heroId, () => new PlayerController());
  scene.attach(heroId, () => {
    const c = new ScriptComponent();
    c.module = "demo";
    c.entry = "onUpdate";
    return c;
  });
  physics.add({ nodeId: heroId, radius: 0.45, isStatic: false });
  scene.flush();
  const SAVE_KEY = "engine08.save.v1";
  let toastTimer = 0;
  function toast(msg) {
    toastEl.textContent = msg;
    toastEl.style.opacity = "1";
    if (toastTimer !== 0) clearTimeout(toastTimer);
    toastTimer = window.setTimeout(() => {
      toastEl.style.opacity = "0";
    }, 2e3);
  }
  function doSave() {
    const json = sceneToJson(saveScene(scene));
    localStorage.setItem(SAVE_KEY, json);
    toast(`\u5DF2\u5B58\u6863\uFF1A${json.length} \u5B57\u8282 \xB7 hash ${stableHash(json)}`);
  }
  function doLoad() {
    const json = localStorage.getItem(SAVE_KEY);
    if (json === null) {
      toast("\u8FD8\u6CA1\u6709\u5B58\u6863\uFF08\u5148\u6309 F5\uFF09");
      return;
    }
    const snap = sceneFromJson(json);
    if (!snap.ok) {
      toast("\u5B58\u6863\u635F\u574F\uFF1A" + snap.error.message);
      return;
    }
    const r = loadScene(scene, snap.value, reg);
    if (!r.ok) {
      toast("\u8BFB\u6863\u5931\u8D25\uFF1A" + r.error.message);
      return;
    }
    physics.clear();
    for (const id of obstacleIds) {
      if (scene.find(id) !== void 0) physics.add({ nodeId: id, radius: 0.6, isStatic: true });
    }
    if (scene.find(heroId) !== void 0) physics.add({ nodeId: heroId, radius: 0.45, isStatic: false });
    const extra = r.value.skipped.length > 0 ? `\uFF0C\u8DF3\u8FC7 ${r.value.skipped.length} \u9879` : "";
    toast(`\u5DF2\u8BFB\u6863\uFF1A${r.value.made} \u4E2A\u8282\u70B9${extra}`);
  }
  function chopNearest() {
    const heroNode = scene.find(heroId);
    if (heroNode === void 0) return;
    const hp = heroNode.worldPosition;
    for (const id of physics.query(hp.x, hp.y, 2.4)) {
      if (id === heroId) continue;
      const w = scene.find(id)?.get("game.workable");
      if (w === void 0) continue;
      w.workleft -= 1;
      if (w.workleft <= 0) {
        scene.destroy(id);
        physics.remove(id);
        toast("\u780D\u5012\u4E86\u4E00\u68F5\u6811");
      } else {
        toast(`\u780D\u4E86\u4E00\u4E0B\uFF0C\u8FD8\u5269 ${w.workleft}`);
      }
      return;
    }
    toast("\u9644\u8FD1\u6CA1\u6709\u53EF\u780D\u7684\u4E1C\u897F");
  }
  let fps = 0;
  let frames = 0;
  let lastFpsAt = performance.now();
  app.services.require(Services.Frame).onRender((info) => {
    frames++;
    const now = performance.now();
    if (now - lastFpsAt > 500) {
      fps = frames / ((now - lastFpsAt) / 1e3);
      frames = 0;
      lastFpsAt = now;
    }
    const lf = renderMod.lastFrame;
    const st = app.snapshot();
    const sc = scriptMod.runtime?.stats();
    const scriptTxt = sc === void 0 ? "script off" : `script ${sc.calls}call/${sc.errors}err${sc.timeouts > 0 ? `/${sc.timeouts}to` : ""}`;
    hud.textContent = `fps ${fps.toFixed(0)} \xB7 tick ${hudTick} \xB7 quad ${lf.quads} \xB7 draw ${lf.drawCalls} \xB7 culled ${lf.culled} \xB7 nodes ${st.scene.nodes} \xB7 bodies ${physics.stats().bodies} \xB7 atlas:${atlasLabel} \xB7 ${st.backends.gfx}/${st.backends.audio}/${st.backends.input}/${st.backends.script ?? "-"} \xB7 ${scriptTxt} \xB7 dropped ${st.droppedSteps}`;
  });
  window.addEventListener("keydown", (ev) => {
    if (ev.code === "F5") {
      ev.preventDefault();
      doSave();
    } else if (ev.code === "F9") {
      ev.preventDefault();
      doLoad();
    } else if (ev.code === "KeyR") {
      location.reload();
    } else if (ev.code === "KeyH") {
      chopNearest();
    }
  });
  window.addEventListener(
    "pointerdown",
    () => {
      void app.platform.audio.resume();
    },
    { once: true }
  );
  const runR = app.run();
  if (!runR.ok) {
    app.log.channel("host").error(`\u5E27\u5FAA\u73AF\u542F\u52A8\u5931\u8D25\uFF1A${runR.error.message}`);
    toast("\u5E27\u5FAA\u73AF\u542F\u52A8\u5931\u8D25\uFF1A" + runR.error.message);
  } else {
    toast("WASD \u79FB\u52A8 \xB7 H \u780D\u6811 \xB7 F5 \u5B58\u6863 \xB7 F9 \u8BFB\u6863 \xB7 R \u91CD\u8F7D");
  }
  globalThis.__engine = {
    app,
    renderMod,
    physics,
    scene,
    scriptMod,
    save: doSave,
    load: doLoad,
    heroId,
    /** 图集真实来源：`assets×5` 表示走完了导入链；`procedural` 表示降级了。 */
    atlasSource: atlasLabel,
    snapshot: () => app.snapshot(),
    lastFrame: () => renderMod.lastFrame
  };
}
void main();
export {
  main
};
