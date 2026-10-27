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
function hashText(s) {
  return hashBytes(new TextEncoder().encode(s));
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
  /**
   * 16 位无符号归一化，每通道 0..65535（8 字节/像素）。
   * 进 GPU 的类型是 `UNSIGNED_SHORT` + 归一化采样：片元里拿到的仍是 0..1 的 float，
   * 只是**中间精度**不再被 8 位截断（渐变/法线/高度图不会出带状色块）。
   *
   * ★ 字节序边界：`Uint16Array` 的内存布局是宿主字节序；WebGL 的
   *   `UNSIGNED_SHORT` 纹理同样按宿主字节序解释，所以「值数组 → texImage2D」
   *   不需要交换字节。反过来说，**不能**把 PNG 里的大端原始字节直接塞进来。
   */
  RGBA16: "rgba16",
  /** 半精度浮点（8 字节/像素）。上传时需要真正的 half 字节流，不能直传 Float32Array。 */
  RGBA16F: "rgba16f"
};
function bytesPerPixel(format) {
  switch (format) {
    case PixelFormat.RGBA8:
      return 4;
    case PixelFormat.RGB8:
      return 3;
    case PixelFormat.R8:
      return 1;
    case PixelFormat.RGBA16:
      return 8;
    case PixelFormat.RGBA16F:
      return 8;
    default:
      throw new Error(`\u672A\u77E5 PixelFormat\uFF1A${String(format)}\uFF08bytesPerPixel \u6CA1\u6709\u9ED8\u8BA4\u503C\uFF0C\u4E0D\u731C\uFF09`);
  }
}
var TextureFilter = { Nearest: "nearest", Linear: "linear" };
var TextureWrap = { Clamp: "clamp", Repeat: "repeat" };
var SPRITE_VERTEX_LAYOUT = {
  attributes: [
    { name: "a_position", components: 2 },
    { name: "a_uv", components: 2 },
    { name: "a_color", components: 4 }
  ]
};
var FLOATS_PER_SPRITE_VERTEX = 8;
var BlendMode = { None: 0, Alpha: 1, Additive: 2, Premultiplied: 3 };
var Topology = { Triangles: 0, TriangleStrip: 1 };

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
    const format = desc.format ?? PixelFormat.RGBA8;
    const bpp = bytesPerPixel(format);
    if (data !== void 0 && data !== null) {
      const expect = desc.width * desc.height * bpp;
      if (data.byteLength !== expect) {
        this.rejectedCalls.push(`createTexture(\u6570\u636E ${data.byteLength} != ${desc.width}x${desc.height}x${bpp})`);
        return err(
          engineError(
            "GFX.SIZE_MISMATCH",
            `\u7EB9\u7406\u6570\u636E ${data.byteLength} \u5B57\u8282\uFF0C\u4F46 ${desc.width}x${desc.height} \u7684 ${format} \u9700\u8981 ${expect}`,
            { label: desc.label ?? "", format }
          )
        );
      }
    }
    const hash = hashStateCreate();
    if (data !== void 0 && data !== null) hashStateUpdate(hash, asBytes(data));
    this.textures.set(h, {
      width: desc.width,
      height: desc.height,
      label: desc.label ?? "",
      format,
      bytesPerPixel: bpp,
      wrap: desc.wrap ?? TextureWrap.Clamp,
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
    const expect = region.width * region.height * rec.bytesPerPixel;
    if (data.byteLength !== expect) {
      this.rejectedCalls.push(
        `updateTexture(\u6570\u636E ${data.byteLength} != ${region.width}x${region.height}x${rec.bytesPerPixel} ${rec.format})`
      );
      return err(
        engineError(
          "GFX.SIZE_MISMATCH",
          `\u4E0A\u4F20\u5B57\u8282\u6570 ${data.byteLength} \u4E0E\u533A\u57DF\u671F\u671B ${expect} \u4E0D\u7B26\uFF08${rec.format}\uFF0C${region.width}x${region.height}\uFF09`,
          { label: rec.label, format: rec.format }
        )
      );
    }
    this._stats = { ...this._stats, bytesUploaded: this._stats.bytesUploaded + data.byteLength };
    hashStateUpdate(rec.hash, asBytes(data));
    return ok(void 0);
  }
  /**
   * 纹理的像素格式（句柄不存在 → `undefined`，与 `textureDigest` 同语气）。
   *
   * ★ 为什么必须有它：`textureDigest` 只能证明"字节到了"，证明不了
   *   "以什么格式到的"—— 同一份 8 字节/像素的数据，声明成 rgba16 还是
   *   rgba16f、或者干脆被当成 rgba8 上传，摘要都可能一样（前者一样，后者长度就不同）。
   *   判据要断言"上传的真的是 16 位"，就必须能把设备记录的格式读出来。
   */
  textureFormat(handle) {
    return this.textures.get(handle)?.format;
  }
  /**
   * 纹理的环绕方式（句柄不存在 → `undefined`，与 `textureFormat` 同语气）。
   *
   * ★ 为什么必须有它（T288）：地形平铺要求瓦片页是 `repeat`、主图集是 `clamp`。
   *   两者传错的表现都**不报错**：主图集开 repeat ⇒ 邻居帧被采进来；
   *   瓦片页开 clamp ⇒ 接缝被抻成脏边。而字节摘要、格式、帧表全都一样 ——
   *   没有这个访问器，"哪张页是什么 wrap"在 headless 里根本无法断言。
   */
  textureWrap(handle) {
    return this.textures.get(handle)?.wrap;
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
      firstIndex: batch.firstIndex ?? 0,
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
  /** 内存盘/真实盘都能列目录。 */
  canList = true;
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
      if (this.dirs.has(k.value)) {
        return err(engineError("FS.IS_DIR", `${k.value} \u662F\u76EE\u5F55\uFF08\u8FD9\u4E2A\u63A5\u53E3\u53EA\u8BFB\u6587\u4EF6\uFF09`));
      }
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
      if (this.dirs.has(k.value)) {
        return err(engineError("FS.IS_DIR", `${k.value} \u662F\u76EE\u5F55\uFF08\u8FD9\u4E2A\u63A5\u53E3\u53EA\u5220\u6587\u4EF6\uFF09`));
      }
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
    if (this.files.has(k.value)) {
      return err(engineError("FS.NOT_A_DIR", `${k.value} \u662F\u6587\u4EF6\uFF0C\u4E0D\u662F\u76EE\u5F55`));
    }
    if (!this.dirs.has(k.value)) {
      return err(engineError("FS.NOT_FOUND", `\u76EE\u5F55\u4E0D\u5B58\u5728\uFF1A${k.value}`));
    }
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

// src/platform/fs/virtual-path.ts
function normalizeVirtualPath(path) {
  if (typeof path !== "string" || path === "") {
    return err(engineError("FS.BAD_PATH", "\u8DEF\u5F84\u5FC5\u987B\u662F\u975E\u7A7A\u5B57\u7B26\u4E32"));
  }
  if (path.includes("\0")) {
    return err(engineError("FS.BAD_PATH", "\u8DEF\u5F84\u91CC\u4E0D\u80FD\u6709 NUL\uFF08OS \u4F1A\u9759\u9ED8\u622A\u65AD\uFF0CJS \u4E0D\u4F1A\uFF09"));
  }
  if (path.includes("\\")) {
    return err(engineError("FS.BAD_PATH", `\u8DEF\u5F84\u91CC\u4E0D\u80FD\u6709\u53CD\u659C\u6760\uFF1A${path}`));
  }
  const out = [];
  for (const seg of path.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") {
      return err(engineError("FS.PATH_ESCAPE", `\u8DEF\u5F84\u542B ..\uFF08\u62D2\u7EDD\u8D8A\u754C\uFF09\uFF1A${path}`));
    }
    out.push(seg);
  }
  return ok(out);
}
function virtualPathOf(segs) {
  return "/" + segs.join("/");
}

// src/backends/fs-http/fs.ts
var DEFAULT_TIMEOUT_MS = 15e3;
var HttpFileSystem = class {
  scheme = "http";
  canList = false;
  base;
  doFetch;
  timeoutMs;
  constructor(opts) {
    const base = typeof opts.base === "string" ? new URL(opts.base) : new URL(opts.base.href);
    if (base.protocol !== "http:" && base.protocol !== "https:") {
      throw new Error(`fs-http\uFF1Abase \u5FC5\u987B\u662F http/https\uFF0C\u5B9E\u9645 ${base.protocol}`);
    }
    if (!base.pathname.endsWith("/")) base.pathname += "/";
    this.base = base;
    const f = opts.fetch ?? (typeof globalThis.fetch === "function" ? globalThis.fetch.bind(globalThis) : void 0);
    if (f === void 0) {
      throw new Error("fs-http\uFF1A\u73AF\u5883\u91CC\u6CA1\u6709 fetch\uFF08\u6D4F\u89C8\u5668\u9700\u8981 polyfill\uFF0CNode < 18 \u8BF7\u663E\u5F0F\u4F20\u5165\uFF09");
    }
    this.doFetch = f;
    this.timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  }
  // ---------------------------------------------------------------- 读
  async readBinary(path) {
    const url = this.urlOf(path);
    if (!url.ok) return url;
    const res = await this.request(url.value, "GET", path);
    if (!res.ok) return res;
    try {
      const buf = await res.value.arrayBuffer();
      return ok(new Uint8Array(buf));
    } catch (e) {
      return err(engineError("FS.IO", `\u8BFB\u54CD\u5E94\u4F53\u5931\u8D25\uFF1A${path}\uFF08${msg(e)}\uFF09`));
    }
  }
  async readText(path) {
    const b = await this.readBinary(path);
    if (!b.ok) return b;
    try {
      return ok(new TextDecoder("utf-8", { fatal: true }).decode(b.value));
    } catch (e) {
      return err(engineError("FS.NOT_UTF8", `\u4E0D\u662F\u5408\u6CD5 UTF-8\uFF1A${path}\uFF08${msg(e)}\uFF09`));
    }
  }
  /**
   * 用 HEAD 探存在性；有的静态服务器不支持 HEAD（405/501），退回带 `Range` 的 GET。
   *
   * ★ 返回 boolean 而不是 Result：`exists` 的签名没有错误通道。
   *   所以这里对"说不清"的响应（500、超时）一律 false ——
   *   **保守**是关键：把不确定说成"存在"会让调用方去读一个读不到的东西。
   */
  async exists(path) {
    const url = this.urlOf(path);
    if (!url.ok) return false;
    let res = await this.raw(url.value, "HEAD");
    if (res !== null && (res.status === 405 || res.status === 501)) {
      res = await this.raw(url.value, "GET", { Range: "bytes=0-0" });
      res?.body?.cancel();
    }
    return res !== null && res.status >= 200 && res.status < 300;
  }
  async stat(path) {
    const url = this.urlOf(path);
    if (!url.ok) return url;
    let res = await this.request(url.value, "HEAD", path, { allowBodyless: true });
    if (!res.ok && res.error.code === "FS.NOT_SUPPORTED") {
      res = await this.request(url.value, "GET", path, { headers: { Range: "bytes=0-0" } });
    }
    if (!res.ok) return res;
    const lenText = res.value.headers.get("content-length");
    const len = lenText === null ? NaN : Number(lenText);
    const lm = res.value.headers.get("last-modified");
    return ok({
      // 没有 Content-Length（分块传输）时给 0：**未知 ≠ 非零**，0 是唯一不会撒谎的默认
      size: Number.isFinite(len) && len >= 0 ? len : 0,
      mtimeMs: lm === null ? 0 : parseHttpDate(lm),
      isDirectory: false
    });
  }
  async list(dir) {
    return err(
      engineError(
        "FS.NOT_SUPPORTED",
        `HTTP \u540E\u7AEF\u6CA1\u6709\u76EE\u5F55\u5217\u4E3E\u80FD\u529B\uFF08\u9759\u6001\u8D44\u6E90\u670D\u52A1\u5668\u4E0D\u63D0\u4F9B\u5217\u76EE\u5F55\uFF09\uFF1A${dir}`
      )
    );
  }
  // ---------------------------------------------------------------- 内部
  /** 虚拟路径 → URL。三道防线：归一、编码、前缀核对。 */
  urlOf(path) {
    const segs = normalizeVirtualPath(path);
    if (!segs.ok) return segs;
    const rel = segs.value.map((s) => encodeURIComponent(s)).join("/");
    let url;
    try {
      url = new URL(rel, this.base);
    } catch (e) {
      return err(engineError("FS.BAD_PATH", `\u8DEF\u5F84\u65E0\u6CD5\u62FC\u6210 URL\uFF1A${path}\uFF08${msg(e)}\uFF09`));
    }
    if (!url.href.startsWith(this.base.href)) {
      return err(engineError("FS.PATH_ESCAPE", `\u8DEF\u5F84\u9003\u51FA\u4E86\u8D44\u6E90\u6839\uFF1A${path}`));
    }
    return ok(url);
  }
  /** 发请求并做状态码映射（唯一一处把 HTTP 状态翻成引擎错误码）。 */
  async request(url, method, path, opts = {}) {
    let res;
    try {
      res = await this.doFetch(url.href, {
        method,
        ...opts.headers === void 0 ? {} : { headers: opts.headers },
        signal: AbortSignal.timeout(this.timeoutMs)
      });
    } catch (e) {
      return err(engineError("FS.IO", `\u8BF7\u6C42\u5931\u8D25\uFF1A${path}\uFF08${msg(e)}\uFF09`));
    }
    const st = res.status;
    if (st >= 200 && st < 300) return ok(res);
    if (st === 404 || st === 410) return err(engineError("FS.NOT_FOUND", `\u8D44\u6E90\u4E0D\u5B58\u5728\uFF1A${path}\uFF08HTTP ${st}\uFF09`));
    if (st === 401 || st === 403) {
      return err(engineError("FS.PERMISSION", `\u6CA1\u6709\u6743\u9650\u8BFB\u53D6\uFF1A${path}\uFF08HTTP ${st}\uFF09`));
    }
    if (st === 405 || st === 501) {
      return err(engineError("FS.NOT_SUPPORTED", `\u670D\u52A1\u5668\u4E0D\u652F\u6301 ${method}\uFF1A${path}\uFF08HTTP ${st}\uFF09`));
    }
    return err(engineError("FS.IO", `HTTP ${st}\uFF1A${path}`));
  }
  /** 只要状态码的场景（`exists`）。失败返回 null，不抛。 */
  async raw(url, method, headers) {
    try {
      return await this.doFetch(url.href, {
        method,
        ...headers === void 0 ? {} : { headers },
        signal: AbortSignal.timeout(this.timeoutMs)
      });
    } catch {
      return null;
    }
  }
};
function parseHttpDate(s) {
  const t = Date.parse(s);
  return Number.isFinite(t) ? t : 0;
}
function msg(e) {
  return e instanceof Error ? e.message : String(e);
}

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
-- ★ 返回 tbl, created：created 是"本次真正新建的那几张表"的记录（父表 + 键 + 表本身），
--   顺序是**从外到内**，最后一条就是模块自己的那张表。卸载时靠它精确摘除。
--   只记"新建"的：复用的表是别人的，动它就是删别人的数据。
local function __engine_compat_findtable(name)
  local cur = _G
  local created = {}
  for part in string.gmatch(name, "[^.]+") do
    local nxt = cur[part]
    if __type(nxt) ~= "table" then
      nxt = {}
      cur[part] = nxt
      created[#created + 1] = { parent = cur, key = part, value = nxt }
    end
    cur = nxt
  end
  return cur, created
end

-- "模块名的点号路径 → 我建过哪些表"。卸载时按记录反向摘除。
__engine_compat_modtables = {}

-- "当时还不能删的空容器"。例：shared.a 与 shared.b 是两个模块先后建的，
-- 卸 a 时 shared 里还有 b，不能删 —— 但也不能忘，否则 shared 这张空表会永远留在 _G 里。
-- 每次卸载都扫一遍待办，谁变空了就摘谁。
__engine_compat_pending = {}

-- 释放一条"容器"记录：身份还对上、且已经空 ⇒ 摘掉并返回 true；
-- 身份被换掉（别人接管了这个键）⇒ 记录作废，返回 true（不用再管）；
-- 还非空 ⇒ false（转入待办）。
local function __engine_compat_release(e)
  if e.parent[e.key] ~= e.value then return true end
  for _ in pairs(e.value) do return false end
  e.parent[e.key] = nil
  return true
end

-- 摘掉 module() 往真 _G 写的表。规则只有一条：**身份必须还是我建的那张**。
--   · 叶子（模块自己的表）：身份对上就摘，不管里面还有多少函数 —— 那些函数随模块一起作废。
--   · 中间容器（a.b 里的 a）：只有变成空表才摘。别人往 a 里加过东西就留着并转入待办，
--     否则会把别人的模块一起摘掉（这是最容易写错的一步）。
function __engine_compat_unmodule(name)
  if __type(name) ~= "string" then return false end
  local removed = 0
  local rec = __engine_compat_modtables[name]
  if __type(rec) == "table" then
    __engine_compat_modtables[name] = nil
    for i = #rec, 1, -1 do
      local e = rec[i]
      if i == #rec then
        if e.parent[e.key] == e.value then
          e.parent[e.key] = nil
          removed = removed + 1
        end
      elseif not __engine_compat_release(e) then
        __engine_compat_pending[#__engine_compat_pending + 1] = e
      else
        removed = removed + 1
      end
    end
  end
  -- 扫待办：随别的模块卸载，之前非空的容器可能已经空了
  local keep = {}
  for i = 1, #__engine_compat_pending do
    local e = __engine_compat_pending[i]
    if not __engine_compat_release(e) then
      keep[#keep + 1] = e
    else
      removed = removed + 1
    end
  end
  __engine_compat_pending = keep
  return removed > 0
end

function module(name, ...)
  if __type(name) ~= "string" or name == "" then
    __error("module: 模块名必须是非空字符串", 2)
  end

  -- ① 建/取模块表，并登记到 package.loaded
  local mod = package.loaded[name]
  if __type(mod) ~= "table" then
    local created
    mod, created = __engine_compat_findtable(name)
    if #created > 0 then
      local log = __engine_compat_modtables[name]
      if __type(log) ~= "table" then
        log = {}
        __engine_compat_modtables[name] = log
      end
      for i = 1, #created do log[#log + 1] = created[i] end
    end
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
  -- \u2605 5.1 \u7684 module("a.b") \u5F80**\u771F _G** \u5199\u4E86\u5D4C\u5957\u8868\uFF0C\u8FD9\u91CC\u6309"\u521B\u5EFA\u65F6\u7684\u8EAB\u4EFD"\u6458\u6389\u3002
  --   \u57AB\u7247\u6CA1\u88C5\uFF08\u7EAF 5.4 \u73AF\u5883\uFF09\u65F6\u8FD9\u4E2A\u51FD\u6570\u4E0D\u5B58\u5728\uFF0C\u8DF3\u8FC7 \u2014\u2014 \u4E0D\u5047\u88C5\u6E05\u6389\u4E86\u3002
  if type(__engine_compat_unmodule) == "function" then
    __engine_compat_unmodule(name)
  end
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
    const format = desc.format ?? PixelFormat.RGBA8;
    const fmt2 = glFormat(format);
    if (data !== void 0 && data !== null) {
      const need = desc.width * desc.height * fmt2.bytesPerPixel;
      if (data.byteLength !== need) {
        return err(
          engineError(
            "GFX.SIZE_MISMATCH",
            `\u7EB9\u7406\u6570\u636E ${data.byteLength} \u5B57\u8282\uFF0C\u4F46 ${desc.width}x${desc.height} \u7684 ${format} \u9700\u8981 ${need}`,
            { label: desc.label ?? "", format }
          )
        );
      }
    }
    const gl = this.gl;
    const tex = gl.createTexture();
    if (tex === null || tex === void 0) {
      return err(engineError("GFX.OUT_OF_MEMORY", "createTexture \u8FD4\u56DE null\uFF08\u663E\u5B58\u4E0D\u8DB3\uFF09"));
    }
    gl.bindTexture(GL.TEXTURE_2D, tex);
    gl.texImage2D(
      GL.TEXTURE_2D,
      0,
      fmt2.internal,
      desc.width,
      desc.height,
      0,
      fmt2.format,
      fmt2.type,
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
        // 记下格式：updateTexture 必须按**同一格式**的字节数校验，
        // 否则"往 RGBA16 纹理里写 4 字节/像素"会以小图片段的形式静默成功。
        format,
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
    const format = rec.meta["format"];
    const fmt2 = glFormat(format);
    const need = region.width * region.height * fmt2.bytesPerPixel;
    if (data.byteLength !== need) {
      return err(
        engineError(
          "GFX.SIZE_MISMATCH",
          `\u4E0A\u4F20\u5B57\u8282\u6570 ${data.byteLength} \u4E0E\u533A\u57DF\u671F\u671B ${need} \u4E0D\u7B26\uFF08${format}\uFF0C${region.width}x${region.height}\uFF09`
        )
      );
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
      fmt2.format,
      fmt2.type,
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
  /** 本帧已落到 GL 上的混合方式（`null` = 还没设过）。避免同一帧重复 blendFunc。 */
  blendMode = null;
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
    this.applyBlend(rec.meta.blend);
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
    const firstIndex = batch.firstIndex ?? 0;
    const mode = (pipe.meta.topology ?? Topology.Triangles) === Topology.TriangleStrip ? GL.TRIANGLE_STRIP : GL.TRIANGLES;
    if (batch.indices !== null) {
      const irec = this.dev._bufferRec(batch.indices);
      if (irec === void 0) throw new Error(`draw \u7684\u7D22\u5F15\u7F13\u51B2\u53E5\u67C4 ${batch.indices} \u4E0D\u5B58\u5728`);
      this.gl.bindBuffer(GL.ELEMENT_ARRAY_BUFFER, irec.gl);
      this.gl.drawElements(mode, batch.indexCount, GL.UNSIGNED_SHORT, firstIndex * 2);
    } else {
      this.gl.drawArrays(mode, firstIndex, batch.vertexCount);
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
  /**
   * 把管线的 `blend` 落到 GL 上。
   *
   * ★ 为什么必须在这里做：混合方式是**管线**的属性（一条不透明管线和一条半透明
   *   精灵管线可以同帧共存）。设备初始化时写死 `SRC_ALPHA / ONE_MINUS_SRC_ALPHA`
   *   的版本会让 `None / Additive / Premultiplied` 静默退化成 Alpha ——
   *   画面"看着还行"，只是叠加不发光、某些特效莫名半透。与 `firstIndex` 同一类：
   *   字段被存下来，却从没被用。
   */
  applyBlend(mode) {
    const m = mode ?? BlendMode.Alpha;
    if (this.blendMode === m) return;
    this.blendMode = m;
    switch (m) {
      case BlendMode.None:
        this.gl.disable(GL.BLEND);
        break;
      case BlendMode.Additive:
        this.gl.enable(GL.BLEND);
        this.gl.blendFunc(GL.SRC_ALPHA, GL.ONE);
        break;
      case BlendMode.Premultiplied:
        this.gl.enable(GL.BLEND);
        this.gl.blendFunc(GL.ONE, GL.ONE_MINUS_SRC_ALPHA);
        break;
      default:
        this.gl.enable(GL.BLEND);
        this.gl.blendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA);
        break;
    }
  }
};
var GL_FORMAT = {
  RGB8: 32849,
  RGBA16: 32859,
  RGBA16F: 34842,
  HALF_FLOAT: 5131
};
function glFormat(f) {
  const bpp = bytesPerPixel(f);
  switch (f) {
    case PixelFormat.RGB8:
      return { internal: GL_FORMAT.RGB8, format: GL.RGB, type: GL.UNSIGNED_BYTE, bytesPerPixel: bpp };
    case PixelFormat.R8:
      return { internal: GL.R8, format: GL.R8, type: GL.UNSIGNED_BYTE, bytesPerPixel: bpp };
    case PixelFormat.RGBA16:
      return { internal: GL_FORMAT.RGBA16, format: GL.RGBA, type: GL.UNSIGNED_SHORT, bytesPerPixel: bpp };
    case PixelFormat.RGBA16F:
      return { internal: GL_FORMAT.RGBA16F, format: GL.RGBA, type: GL_FORMAT.HALF_FLOAT, bytesPerPixel: bpp };
    case PixelFormat.RGBA8:
      return { internal: GL.RGBA8, format: GL.RGBA, type: GL.UNSIGNED_BYTE, bytesPerPixel: bpp };
    default:
      throw new Error(`webgl2 \u540E\u7AEF\u4E0D\u8BA4\u8BC6 PixelFormat\uFF1A${String(f)}`);
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
var PAD_BUTTONS = [
  "A",
  "B",
  "X",
  "Y",
  "LB",
  "RB",
  "LT",
  "RT",
  "Select",
  "Start",
  "L3",
  "R3",
  "DPadUp",
  "DPadDown",
  "DPadLeft",
  "DPadRight"
];
var PREVENT = /* @__PURE__ */ new Set(["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Space", "Tab"]);
var DomInputDevice = class {
  caps = {
    backend: "dom",
    pointer: true,
    touch: true,
    // 构造时按环境改（有 `navigator.getGamepads` 才是 true）—— 写死 true 就是假能力声明
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
  gamepads;
  deadzone;
  /** 上一次 poll 时手柄按下的键码（用来算"刚按下 / 刚松开"的边缘）。 */
  padDown = /* @__PURE__ */ new Set();
  bound = [];
  /** 有输入框聚焦时，键盘不驱动游戏（编辑器输入场景名时不能同时让角色走）。 */
  textFocus = false;
  constructor(opts) {
    if (opts.keyboard === void 0 || opts.pointer === void 0) {
      throw new Error("DomInputDevice \u9700\u8981 keyboard \u4E0E pointer \u4E24\u4E2A\u76D1\u542C\u76EE\u6807");
    }
    this.kb = opts.keyboard;
    this.ptr = opts.pointer;
    this.gamepads = opts.gamepads ?? defaultGamepads();
    this.deadzone = opts.stickDeadzone ?? 0.35;
    this.caps = { ...this.caps, gamepad: this.gamepads !== null };
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
    const padNow = this.samplePads();
    const padPressed = [];
    const padReleased = [];
    for (const k of padNow) if (!this.padDown.has(k)) padPressed.push(k);
    for (const k of this.padDown) if (!padNow.has(k)) padReleased.push(k);
    this.padDown = padNow;
    const down = new Set(this.down);
    const pressedSet = new Set(this.pressed);
    const releasedSet = new Set(this.released);
    for (const k of padNow) down.add(k);
    for (const k of padPressed) pressedSet.add(k);
    for (const k of padReleased) releasedSet.add(k);
    const snap = {
      keysDown: down,
      keysPressed: pressedSet,
      keysReleased: releasedSet,
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
  /**
   * 读一次手柄，返回"当前按下的逻辑键码"。
   *
   * ★ 只读 `standard` 布局的前 16 个键与两个轴。非标准手柄（`mapping !== "standard"`）
   *   的键位因厂商而异 —— 假装能读会让"这个手柄不能用"变成"按 A 触发了 B"。
   *   这里不判断 mapping（结构接口里没有），但**名字按标准布局给**，
   *   文档里写明"非标准手柄需要在宿主侧做映射表"。
   */
  samplePads() {
    const out = /* @__PURE__ */ new Set();
    if (this.gamepads === null) return out;
    const pads = this.gamepads();
    for (const pad of pads) {
      if (pad === null || pad === void 0 || pad.connected === false) continue;
      const prefix = `Gamepad${pad.index ?? 0}.`;
      const btns = pad.buttons ?? [];
      for (let i = 0; i < PAD_BUTTONS.length && i < btns.length; i++) {
        const b = btns[i];
        if (b === void 0) continue;
        if (b.pressed === true || (b.value ?? 0) > 0.5) out.add(prefix + PAD_BUTTONS[i]);
      }
      const ax = pad.axes ?? [];
      const lx = ax[0] ?? 0;
      const ly = ax[1] ?? 0;
      if (lx < -this.deadzone) out.add(prefix + "LStickLeft");
      if (lx > this.deadzone) out.add(prefix + "LStickRight");
      if (ly < -this.deadzone) out.add(prefix + "LStickUp");
      if (ly > this.deadzone) out.add(prefix + "LStickDown");
    }
    return out;
  }
  reset() {
    this.down.clear();
    this.pressed.clear();
    this.released.clear();
    this.padDown = /* @__PURE__ */ new Set();
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
function defaultGamepads() {
  const nav = globalThis.navigator;
  if (typeof nav?.getGamepads !== "function") return null;
  return () => nav.getGamepads();
}
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
  trace(msg3, fields) {
    this.root.log(LogLevel.Trace, this.name, msg3, fields);
  }
  debug(msg3, fields) {
    this.root.log(LogLevel.Debug, this.name, msg3, fields);
  }
  info(msg3, fields) {
    this.root.log(LogLevel.Info, this.name, msg3, fields);
  }
  warn(msg3, fields, limit = DEFAULT_LIMIT) {
    this.root.log(LogLevel.Warn, this.name, msg3, fields, limit);
  }
  error(msg3, fields, limit = DEFAULT_LIMIT) {
    this.root.log(LogLevel.Error, this.name, msg3, fields, limit);
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
   * 通用读取。**缺字段时保留实例上的值**（类初始化器就是这个字段的出生默认值），
   * 同时把缺失的字段名报告给调用方（AssetDatabase / 存档）判断"是不是旧版本"。
   *
   * ★★ 为什么不是"缺字段填类型零值"（这是被一条真判据逼出来的改动）：
   *   schema 演化时唯一可能正确的默认值写在**类的初始化器**里
   *   （`pivotX = 0.5`）。压成零值的话，旧存档读回来 `pivotX = 0` ——
   *   所有已有精灵右移半格，而**新存档完全正常**，所以新写的判据一个都不会红。
   *   这类错误只在"用户打开旧档"时出现，也就是永远不会在开发机上出现。
   *   实测：`Sprite.pivotX` 加进来的当天，这一条就抓到了（world-visuals 的旧档判据）。
   *
   * 顺序：实例已有值 → `schema.defaults`（显式声明的默认值） → 类型零值（字段压根没声明）。
   */
  load(data) {
    const missing = [];
    const self2 = this;
    for (const [k, t] of Object.entries(this.schema.fields)) {
      if (data[k] === void 0) {
        missing.push(k);
        if (self2[k] !== void 0) continue;
        self2[k] = this.schema.defaults?.[k] ?? zeroValue(t);
        continue;
      }
      self2[k] = data[k];
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
  /**
   * `other` 是不是自己的**祖先**（含父、祖父……直到根）。
   *
   * ★ 单独抽出来是因为它有两个消费者：`addChild` 的环检查（批81）与编辑器的
   *   `ReparentOp`（批77 里手写过一份同样的上溯循环）。两份会在"根节点算不算祖先"
   *   这类边界上漂开，而漂开的表现是"编辑器允许、核心拒绝"或反过来。
   */
  isAncestorOf(other) {
    let p = other.parent;
    while (p !== null) {
      if (p === this) return true;
      p = p.parent;
    }
    return false;
  }
  addChild(child) {
    if (child.parent === this) return this;
    if (child === this || child.isAncestorOf(this)) {
      throw new Error(
        `\u4E0D\u80FD\u628A\u8282\u70B9 #${String(child.id)}\uFF08${child.name}\uFF09\u6302\u5230\u5B83\u81EA\u5DF1\u7684\u5B50\u6811\u91CC\uFF1A#${String(this.id)}\uFF08${this.name}\uFF09\u662F\u5B83\u7684\u540E\u4EE3\u4E4B\u4E00`
      );
    }
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
  /** 剩余冻结步数（hitstop，见文件头 ★★）。 */
  _freeze = 0;
  /** 冻结期间累计的真实时间（秒），够一个 `fixedDt` 就收一步。 */
  _freezeAcc = 0;
  /** 累计消耗的冻结步数。 */
  _totalFreeze = 0;
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
    if (this._freeze > 0) {
      this._freezeAcc += Math.min(realDtSec, this.maxFrameDt);
      while (this._freezeAcc >= this.fixedDt && this._freeze > 0) {
        this._freezeAcc -= this.fixedDt;
        this._freeze--;
        this._totalFreeze++;
      }
      if (this._freeze === 0) this._freezeAcc = 0;
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
  /**
   * 请求冻结 `ticks` 个逻辑步（hitstop）。重复触发取**最长剩余**，不累加 ——
   * 与 `feedback.ts` 的闪色同一条理由：累加会让连击时冻结越来越久，
   * 而"冻多久"变成取决于历史的东西，回放对不上。
   *
   * @throws RangeError 步数不是正整数（0 想表达"取消"没有意义 —— 不请求就不会冻）。
   */
  freeze(ticks) {
    if (!Number.isInteger(ticks) || ticks <= 0) {
      throw new RangeError(`\u51BB\u7ED3\u6B65\u6570\u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF0C\u6536\u5230 ${String(ticks)}`);
    }
    this._freeze = Math.max(this._freeze, ticks);
  }
  /** 当前是否在冻结。 */
  get frozen() {
    return this._freeze > 0;
  }
  /** 剩余冻结步数。 */
  get freezeTicks() {
    return this._freeze;
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
    this._freeze = 0;
    this._freezeAcc = 0;
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
      alpha: this._alpha,
      frozen: this._freeze > 0,
      freezeTicks: this._freeze,
      totalFreezeTicks: this._totalFreeze
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
      frozen: this.scheduler.frozen,
      freezeTicks: this.scheduler.freezeTicks,
      totalFreezeTicks: this.scheduler.stats().totalFreezeTicks,
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
   * ★ `?? 1`：缺 layer 的 RenderItem 当实体。0 是背景，把旧数据默认成背景
   *   会让所有东西一夜之间消失在地形后面 —— 与 Sprite 的默认值同思路。
   */
  static sort(items) {
    items.sort((a, b) => {
      const la = a.layer ?? 1;
      const lb = b.layer ?? 1;
      if (la !== lb) return la - lb;
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
    const runsMut = [];
    for (let q2 = 0; q2 < n; q2++) {
      const it = sorted[q2];
      if (it.atlas !== lastAtlas) {
        atlasSwitches++;
        lastAtlas = it.atlas;
        runsMut.push({ atlas: it.atlas, start: q2, count: 1 });
      } else {
        const prev = runsMut[runsMut.length - 1];
        if (prev === void 0) throw new Error("batch2d \u5185\u90E8\u9519\u8BEF\uFF1A\u7B2C\u4E00\u6BB5\u6CA1\u5EFA\u8D77\u6765");
        prev.count++;
      }
      const c = cam.project(it.x, it.z);
      const e = cam.extents(it.w, it.h);
      const cy = c.y + (0.5 - it.pivotY) * 2 * e.halfH;
      const cx = c.x + (0.5 - it.pivotX) * 2 * e.halfW;
      const x0 = cx - e.halfW;
      const x1 = cx + e.halfW;
      const y0 = cy - e.halfH;
      const y1 = cy + e.halfH;
      const tileX = Math.max(1, Math.floor(it.tileX ?? 1));
      const tileY = Math.max(1, Math.floor(it.tileY ?? 1));
      const ua = it.u0;
      const ub = it.u0 + (it.u1 - it.u0) * tileX;
      const va = it.v0;
      const vb = it.v0 + (it.v1 - it.v0) * tileY;
      const base = q2 * 4 * FLOATS_PER_VERTEX;
      writeVert(this.vertices, base, x0, y0, ua, vb, it);
      writeVert(this.vertices, base + FLOATS_PER_VERTEX, x1, y0, ub, vb, it);
      writeVert(this.vertices, base + FLOATS_PER_VERTEX * 2, x1, y1, ub, va, it);
      writeVert(this.vertices, base + FLOATS_PER_VERTEX * 3, x0, y1, ua, va, it);
    }
    return {
      quadCount: n,
      vertexCount: n * 4,
      indexCount: n * 6,
      drawCalls: runsMut.length,
      atlasSwitches,
      runs: runsMut
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
var SPRITE_TYPE = "render.sprite";
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
  /**
   * 绘制层：0 = 背景（地面），1 = 实体（默认）。层在 z **之前**比较。
   *
   * ★ 默认 1 而不是 0：旧内容/旧存档没有这个字段，它们该保持"实体"行为。
   *   缺字段拿到 0 会让所有旧精灵掉到地形背后 —— 一帧都不显示，且没有任何报错。
   *
   * ★ 用整数而不是枚举：层数由宿主定（背景/实体/UI/ overlay…），引擎不替宿主
   *   决定有哪些层，只保证"小的先画"。
   */
  layer = 1;
  /** 关闭后不参与渲染（但仍更新逻辑）。 */
  visible = true;
  /** 锚点：0 = 底边，0.5 = 中心。饥荒风格通常用 0（脚踩地面）。 */
  pivotY = 0.5;
  /**
   * 水平锚点：0 = 左边界，0.5 = 中心。
   *
   * ★ 为什么需要它（这是"地形一直画不出来"的根因）：
   *   地形节点是**矩形**，位置是矩形左上角的格子坐标。只有 `pivotY` 时，
   *   精灵永远以节点位置为水平中心 —— 一块 8×5 的地形要么整体右移半块，
   *   要么就得把节点位置改成矩形中心（那会破坏「地形节点位置 = 格子坐标」，
   *   连带破坏反查与存档往返）。加一个对称的 `pivotX` 是唯一不动代价的解法。
   *
   * ★ 默认 0.5 = 与"只有 pivotY"时的行为完全一致：旧内容/旧代码的显示不变。
   *   也正因为如此，旧存档里没有这个字段时**必须**拿到 0.5（不是 0）——
   *   见 scene-io 的 `missingFields`：缺字段会走类里的默认值，不会被写成 0。
   */
  pivotX = 0.5;
  /**
   * 沿精灵宽度重复贴图多少次（T288）。
   *
   * ★ 为什么它是"次数"而不是"UV 缩放量"：调用方想的是"这一块 8 格宽的地形，
   *   每格铺一张 64×64 的噪点"—— 8 次，一个整数。乘出来的 UV 是 8×帧宽，
   *   那是实现细节。写成"缩放量"会让每个宿主都得自己算 `宽 / 贴图像素宽`，
   *   而那正是 T288 想消灭的"每处各算一遍"。
   *
   * ★ 只能用在 `wrap: repeat` 的**瓦片页**上（见 `buildTilePages`）。
   *   在 clamp 页上平铺，GPU 会把边缘像素抻出去 —— 画面是一条脏边，
   *   而精灵的所有数字都对。渲染模块对这种组合**告警**（不静默跳过）。
   *
   * ★ 默认 1 = 与旧行为逐字节一致：旧存档没有这个字段时也必须拿到 1
   *   （`scene-io` 的缺字段走类默认值，不会被写成 0 —— 0 会让精灵整块消失）。
   */
  tileX = 1;
  /** 沿精灵高度重复贴图多少次。语义同 `tileX`。 */
  tileY = 1;
  schema = {
    type: SPRITE_TYPE,
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
      layer: FieldType.Int,
      visible: FieldType.Bool,
      pivotY: FieldType.Float,
      pivotX: FieldType.Float,
      tileX: FieldType.Float,
      tileY: FieldType.Float
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
  /** 当前绘制原点：**每个帧块都必须先 `origin()` 到自己的矩形左上角**。 */
  ox = 0;
  oy = 0;
  /**
   * ★ 这个方法是 T330 顺带抓出来的第二个缺陷的解药：
   *   原来每个帧的绘制用的是**绝对坐标**，而 `layout` 里 rock/player/berry 分别在
   *   x=64/112/144 —— 于是那三帧的图形全被画进了 tree 的矩形（x 0..64），
   *   三帧本身**一个不透明像素都没有**。
   *   症状是"兜底图集里少三类东西"，而所有既有判据（帧在不在、UV 对不对、
   *   尺寸对不对）都是绿的：它们查的是地图，不是地图上有没有东西。
   */
  origin(x, y) {
    this.ox = x;
    this.oy = y;
  }
  put(x, y, r, g, b, a = 255) {
    const ax = this.ox + x;
    const ay = this.oy + y;
    if (ax < 0 || ay < 0 || ax >= this.W || ay >= this.H) return;
    const i = (ay * this.W + ax) * 4;
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
    { name: "ground", x: 0, y: 96, w: 64, h: 64 },
    { name: "terrain", x: 64, y: 96, w: 64, h: 64 }
  ];
  const at = (n) => {
    const l = layout.find((e) => e.name === n);
    if (l === void 0) throw new Error(`\u5E03\u5C40\u91CC\u6CA1\u6709\u5E27 "${n}"\uFF08\u5185\u90E8\u4E00\u81F4\u6027\u9519\u8BEF\uFF09`);
    return { x: l.x, y: l.y };
  };
  pen.origin(at("tree").x, at("tree").y);
  pen.rect(28, 64, 8, 32, [92, 62, 38]);
  pen.triangle(32, 0, 4, 44, 60, 44, [46, 110, 52]);
  pen.triangle(32, 18, 8, 58, 56, 58, [56, 132, 62]);
  pen.triangle(32, 36, 12, 72, 52, 72, [66, 152, 72]);
  pen.origin(at("rock").x, at("rock").y);
  pen.disc(24, 26, 16, [98, 100, 106]);
  pen.disc(20, 20, 11, [128, 132, 138]);
  pen.origin(at("player").x, at("player").y);
  pen.rect(10, 20, 12, 24, [198, 156, 84]);
  pen.disc(16, 14, 9, [232, 198, 140]);
  pen.rect(12, 12, 3, 3, [30, 30, 30]);
  pen.rect(18, 12, 3, 3, [30, 30, 30]);
  pen.origin(at("berry").x, at("berry").y);
  pen.disc(9, 9, 4, [186, 42, 46]);
  pen.disc(16, 12, 4, [206, 58, 54]);
  pen.disc(11, 17, 3, [168, 34, 40]);
  let seed = 19088743;
  const rnd = () => {
    seed = seed * 1103515245 + 12345 & 2147483647;
    return seed / 2147483647;
  };
  pen.origin(at("ground").x, at("ground").y);
  for (let y = 0; y < 64; y++) {
    for (let x = 0; x < 64; x++) {
      const v = 54 + Math.floor(rnd() * 18);
      pen.rect(x, y, 1, 1, [v, v + 22, v - 6]);
    }
  }
  pen.origin(at("terrain").x, at("terrain").y);
  for (let y = 0; y < 64; y++) {
    for (let x = 0; x < 64; x++) {
      const v = 188 + Math.floor(rnd() * 31);
      pen.rect(x, y, 1, 1, [v, v, v]);
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
function buildTilePages(main2, frameNames) {
  const out = [];
  for (const name of frameNames) {
    const f = main2.frames.get(name);
    if (f === void 0) continue;
    const x0 = Math.round(f.u0 * main2.width);
    const y0 = Math.round(f.v0 * main2.height);
    const w = f.w;
    const h = f.h;
    const px = new Uint8Array(w * h * 4);
    for (let y = 0; y < h; y++) {
      const from = ((y0 + y) * main2.width + x0) * 4;
      px.set(main2.pixels.subarray(from, from + w * 4), y * w * 4);
    }
    let page = {
      width: w,
      height: h,
      pixels: px,
      wrap: "repeat",
      name: tilePageName(name),
      frames: /* @__PURE__ */ new Map([[name, { u0: 0, v0: 0, u1: 1, v1: 1, w, h }]])
    };
    if (main2.pixels16 !== void 0) {
      const p16 = new Uint16Array(w * h * 4);
      for (let y = 0; y < h; y++) {
        const from = ((y0 + y) * main2.width + x0) * 4;
        p16.set(main2.pixels16.subarray(from, from + w * 4), y * w * 4);
      }
      page = { ...page, format: PixelFormat.RGBA16, pixels16: p16 };
      for (let i = 0; i < px.length; i++) px[i] = Math.round(p16[i] / 257);
    }
    out.push(page);
  }
  return out;
}
function tilePageName(frame) {
  return `${frame}.tile`;
}

// src/extensions/render/render-module.ts
function spriteToRenderItem(s, f, nodeId, x, z, atlas) {
  return {
    nodeId,
    x,
    z,
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
    layer: s.layer,
    pivotY: s.pivotY,
    pivotX: s.pivotX,
    atlas,
    tileX: s.tileX,
    tileY: s.tileY
  };
}
function frameRect(a, f, name) {
  const px = Math.min(a.width - 1, Math.max(0, Math.floor((f.u0 + f.u1) / 2 * a.width)));
  const py = Math.min(a.height - 1, Math.max(0, Math.floor((f.v0 + f.v1) / 2 * a.height)));
  const i = (py * a.width + px) * 4;
  const x0 = Math.floor(f.u0 * a.width);
  const x1 = Math.max(x0, Math.floor(f.u1 * a.width) - 1);
  const y0 = Math.floor(f.v0 * a.height);
  const y1 = Math.max(y0, Math.floor(f.v1 * a.height) - 1);
  const midX = x0 + x1 >> 1;
  let opaqueRows = 0;
  for (let y = y0; y <= y1; y++) {
    if ((a.pixels[(y * a.width + midX) * 4 + 3] ?? 0) > 0) opaqueRows++;
  }
  return {
    u0: f.u0,
    v0: f.v0,
    u1: f.u1,
    v1: f.v1,
    w: f.w,
    h: f.h,
    atlasW: a.width,
    atlasH: a.height,
    opaqueRows,
    sample: {
      r: a.pixels[i] ?? 0,
      g: a.pixels[i + 1] ?? 0,
      b: a.pixels[i + 2] ?? 0,
      a: a.pixels[i + 3] ?? 0
    }
  };
}
function curtainQuad(alpha) {
  const a = Number.isFinite(alpha) ? Math.max(0, Math.min(1, alpha)) : 0;
  const xy = [
    [-1, -1],
    [1, -1],
    [1, 1],
    [-1, -1],
    [1, 1],
    [-1, 1]
  ];
  const out = new Float32Array(xy.length * FLOATS_PER_SPRITE_VERTEX);
  for (const [i, p] of xy.entries()) {
    const at = i * FLOATS_PER_SPRITE_VERTEX;
    out[at] = p[0];
    out[at + 1] = p[1];
    out[at + 2] = 0;
    out[at + 3] = 0;
    out[at + 4] = 0;
    out[at + 5] = 0;
    out[at + 6] = 0;
    out[at + 7] = a;
  }
  return out;
}
function createRenderModule(opts) {
  const camera = new Camera2D({
    viewportWidth: opts.viewportWidth,
    viewportHeight: opts.viewportHeight,
    zoom: opts.zoom ?? 32,
    tiltY: opts.tiltY ?? 0.62
  });
  let dev = null;
  let tex = [];
  let slotOfName = /* @__PURE__ */ new Map();
  let shader = null;
  let pipeline = null;
  let vbo = null;
  let ibo = null;
  let offRender = null;
  let overlay = null;
  let curtain = 0;
  let curtainVbo = null;
  let lastCurtain = { alpha: 0, drawn: false };
  let batch = null;
  let pages = [];
  let atlasFmt = PixelFormat.RGBA8;
  let ctxRef = null;
  let warnedAtlasIds = /* @__PURE__ */ new Set();
  let lastFrame = { quads: 0, drawCalls: 0, atlasSwitches: 0, culled: 0 };
  const mod = {
    id: opts.id ?? "render.batch2d",
    deps: [],
    init(ctx) {
      ctxRef = ctx;
      dev = ctx.platform.gfx;
      const d = dev;
      const procedural = opts.atlas === void 0;
      const main2 = opts.atlas ?? buildProceduralAtlas();
      pages = [main2, ...buildTilePages(main2, opts.tileFrames ?? ["terrain"]), ...opts.extraPages ?? []];
      const slots = /* @__PURE__ */ new Map();
      for (const [i, p] of pages.entries()) {
        const name = p.name;
        if (name !== void 0 && name !== "") {
          if (slots.has(name)) {
            return err(engineError("RENDER.DUP_PAGE", `\u4E24\u4E2A\u56FE\u96C6\u9875\u91CD\u540D\uFF1A${name}\uFF08atlasId \u4F1A\u6307\u5411\u4E0D\u786E\u5B9A\u7684\u90A3\u4E00\u9875\uFF09`));
          }
          slots.set(name, i);
        }
      }
      slotOfName = slots;
      const uploaded = [];
      for (const [i, page] of pages.entries()) {
        const fmt2 = page.format ?? PixelFormat.RGBA8;
        const p16 = page.pixels16;
        if (fmt2 === PixelFormat.RGBA16 && p16 === void 0) {
          for (const h of uploaded) d.destroyTexture(h);
          return err(
            engineError("RENDER.BAD_ATLAS", `\u56FE\u96C6\u9875 ${i}\uFF08${page.name ?? "main"}\uFF09format \u662F rgba16\uFF0C\u4F46\u6CA1\u7ED9 pixels16\uFF08\u89E3\u7801\u5668\u5077\u5077\u964D\u91C7\u6837\u4E86\uFF1F\uFF09`)
          );
        }
        const upload = fmt2 === PixelFormat.RGBA16 && p16 !== void 0 ? p16 : page.pixels;
        const t = d.createTexture(
          {
            width: page.width,
            height: page.height,
            format: fmt2,
            filter: TextureFilter.Nearest,
            // ★ wrap 是**页级**的：瓦片页 repeat（平铺），主图集 clamp（不抻边）。
            //   两页混用同一张 wrap 的两种错法都试过：主图集开 repeat ⇒ 邻居帧被采进来；
            //   瓦片页开 clamp ⇒ 平铺的接缝处一条脏边。两种都不报错，只难看。
            wrap: page.wrap ?? TextureWrap.Clamp,
            // label 不是装饰：null 后端的 `describe()` 与崩溃报告会原样打印它，
            // "这张纹理到底是资产图集还是兜底的程序化图集"必须一眼可辨；
            // 精度同理 —— 一个 "atlas:rgba16" 比翻像素快得多。
            label: (procedural && i === 0 ? "engine.procedural-atlas" : `engine.atlas[${i}]`) + (page.name !== void 0 ? `:${page.name}` : "") + (fmt2 === PixelFormat.RGBA16 ? ":rgba16" : "") + (page.wrap === TextureWrap.Repeat ? ":repeat" : "")
          },
          upload
        );
        if (!t.ok) {
          for (const h of uploaded) d.destroyTexture(h);
          return t;
        }
        uploaded.push(t.value);
      }
      tex = uploaded;
      atlasFmt = main2.format ?? PixelFormat.RGBA8;
      const sh = d.createShader({
        vertex: SPRITE_VS,
        fragment: SPRITE_FS,
        label: "engine.sprite"
      });
      if (!sh.ok) {
        for (const h of uploaded) d.destroyTexture(h);
        tex = [];
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
        for (const h of uploaded) d.destroyTexture(h);
        tex = [];
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
        for (const h of uploaded) d.destroyTexture(h);
        tex = [];
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
        for (const h of uploaded) d.destroyTexture(h);
        tex = [];
        return ib;
      }
      ibo = ib.value;
      const up = d.updateBuffer(ibo, batch.indices);
      if (!up.ok) {
        d.destroyBuffer(ibo);
        d.destroyBuffer(vbo);
        d.destroyPipeline(pipeline);
        d.destroyShader(shader);
        for (const h of uploaded) d.destroyTexture(h);
        tex = [];
        return up;
      }
      const cvb = d.createBuffer({
        usage: BufferUsage.Vertex,
        byteLength: curtainQuad(0).byteLength,
        dynamic: true,
        label: "engine.curtain.vbo"
      });
      if (cvb.ok) {
        curtainVbo = cvb.value;
      } else {
        ctx.log.channel("render").error(
          `\u5E55\u5E03\u9876\u70B9\u7F13\u51B2\u5EFA\u4E0D\u51FA\u6765\uFF08\u8FC7\u573A\u4E0D\u4F1A\u6709\u6DE1\u5165\u6DE1\u51FA\uFF0C\u5176\u4F59\u7167\u5E38\uFF09\uFF1A${cvb.error.message}`,
          void 0,
          null
        );
      }
      ctx.log.channel("render").info(
        `\u6E32\u67D3\u6A21\u5757\u5C31\u7EEA\uFF1A${pages.map((p) => `${p.name ?? "main"} ${p.width}x${p.height}`).join(" + ")} \xB7 \u4E3B\u56FE\u96C6 ${main2.frames.size} \u5E27 \xB7 ${atlasFmt} \xB7 \u6279\u91CF\u4E0A\u9650 ${batch.maxQuads} quad`
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
        if (curtainVbo !== null) d.destroyBuffer(curtainVbo);
        if (ibo !== null) d.destroyBuffer(ibo);
        if (vbo !== null) d.destroyBuffer(vbo);
        if (pipeline !== null) d.destroyPipeline(pipeline);
        if (shader !== null) d.destroyShader(shader);
        for (const h of tex) d.destroyTexture(h);
      }
      curtainVbo = null;
      curtain = 0;
      lastCurtain = { alpha: 0, drawn: false };
      ibo = null;
      vbo = null;
      pipeline = null;
      shader = null;
      tex = [];
      dev = null;
      batch = null;
      pages = [];
      slotOfName = /* @__PURE__ */ new Map();
      atlasFmt = PixelFormat.RGBA8;
    },
    describe() {
      return `\u6E32\u67D3\uFF1A${lastFrame.quads} quad / ${lastFrame.drawCalls} draw / ${lastFrame.atlasSwitches} \u7EB9\u7406\u5207\u6362`;
    },
    get camera() {
      return camera;
    },
    resize(width, height) {
      if (!(width > 0) || !(height > 0)) return;
      dev?.resize(width, height);
    },
    get lastFrame() {
      return lastFrame;
    },
    get atlasFrameCount() {
      return pages[0]?.frames.size ?? 0;
    },
    get atlasFormat() {
      return atlasFmt;
    },
    /** 图集页数（主图集 + 瓦片页 + 附加页）。init 之前是 0。 */
    get atlasPageCount() {
      return pages.length;
    },
    atlasFrame(name) {
      const main2 = pages[0];
      const mf = main2?.frames.get(name);
      if (main2 !== void 0 && mf !== void 0) return frameRect(main2, mf, name);
      for (const a of pages) {
        const f = a.frames.get(name);
        if (f !== void 0) return frameRect(a, f, name);
      }
      return void 0;
    },
    lastVertices(quads) {
      const b = batch;
      if (b === null) return new Float32Array(0);
      return b.vertexView(Math.max(0, quads)).slice();
    },
    setOverlay(fn) {
      overlay = fn;
    },
    setCurtain(alpha) {
      curtain = Number.isFinite(alpha) ? Math.max(0, Math.min(1, alpha)) : 0;
    },
    get lastCurtain() {
      return lastCurtain;
    }
  };
  function renderFrame(info) {
    const d = dev;
    const b = batch;
    const scene = ctxRef?.services.get(Services.Scene);
    lastCurtain = { alpha: curtain, drawn: false };
    if (d === null || b === null || pages.length === 0 || scene === void 0) return;
    const target = opts.follow?.();
    if (target !== void 0) {
      camera.moveTo(target.x, target.z);
    }
    const sprites = scene.componentsOf("render.sprite");
    const items = [];
    const vis = camera.visibleRect();
    let culled = 0;
    warnedAtlasIds.clear();
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
      let slot = 0;
      if (s.atlasId !== "") {
        const found = slotOfName.get(s.atlasId);
        if (found === void 0) {
          if (!warnedAtlasIds.has(s.atlasId)) {
            warnedAtlasIds.add(s.atlasId);
            ctxRef?.log.channel("render").warn(
              `Sprite \u7684 atlasId \u6CA1\u6709\u5BF9\u5E94\u56FE\u96C6\u9875\uFF1A${JSON.stringify(s.atlasId)}\uFF08\u5DF2\u56DE\u843D\u5230\u4E3B\u56FE\u96C6\uFF09`,
              { node: node.id },
              null
            );
          }
        } else {
          slot = found;
        }
      }
      const f = frameOf(slot, s.frame);
      if (f === void 0) {
        ctxRef?.log.channel("render").warn(`Sprite \u5E27\u540D\u4E0D\u5B58\u5728\uFF1A${JSON.stringify(s.frame)}`, { node: node.id }, null);
        continue;
      }
      items.push(spriteToRenderItem(s, f, node.id, p.x, p.y, slot));
      if ((s.tileX > 1 || s.tileY > 1) && (pages[slot]?.wrap ?? "clamp") !== "repeat") {
        ctxRef?.log.channel("render").warn(
          `Sprite \u5728 clamp \u9875\u4E0A\u5E73\u94FA\uFF08tileX=${s.tileX}, tileY=${s.tileY}, atlasId=${JSON.stringify(s.atlasId)}\uFF09\u2014\u2014 \u63A5\u7F1D\u4F1A\u88AB\u62BB\u6210\u810F\u8FB9\uFF1B\u8BF7\u6539\u7528 buildTilePages \u62BD\u51FA\u7684 repeat \u9875`,
          { node: node.id },
          null
        );
      }
    }
    const built = b.build(items, camera);
    lastFrame = {
      quads: built.quadCount,
      drawCalls: built.drawCalls,
      atlasSwitches: built.atlasSwitches,
      culled
    };
    const vw = d.size.width;
    const vh = d.size.height;
    camera.setViewport(vw, vh);
    const cmd = d.beginFrame(null);
    cmd.setViewport(new Rect(0, 0, vw, vh));
    cmd.clear(camera.clearColor, 1);
    if (built.quadCount > 0 && vbo !== null && ibo !== null && pipeline !== null) {
      const up = d.updateBuffer(vbo, b.vertexView(built.quadCount));
      if (!up.ok) {
        ctxRef?.log.channel("render").error(`\u9876\u70B9\u4E0A\u4F20\u5931\u8D25\uFF1A${up.error.message}`, void 0, null);
      } else {
        cmd.setPipeline(pipeline);
        for (const run of built.runs) {
          const page = tex[run.atlas];
          if (page === void 0) {
            ctxRef?.log.channel("render").error(`\u56FE\u96C6\u69FD\u4F4D ${run.atlas} \u6CA1\u6709\u7EB9\u7406\uFF08\u6BB5\u88AB\u8DF3\u8FC7\uFF09`, void 0, null);
            continue;
          }
          cmd.bindTexture(0, page);
          cmd.setUniform("u_useTexture", 1, "int");
          cmd.draw({
            vertices: vbo,
            indices: ibo,
            vertexCount: (run.start + run.count) * 4,
            indexCount: run.count * 6,
            // ★ 段在索引缓冲里的偏移：顶点是连续排的，索引也是按 quad 顺序生成的，
            //   所以第 q 个 quad 的索引起点就是 q*6。少了这个偏移，第二段会把
            //   **第一段的几何**再画一遍（画面重复而不是切换贴图）。
            firstIndex: run.start * 6
          });
        }
      }
    }
    if (overlay !== null) {
      try {
        overlay(cmd);
      } catch (e) {
        ctxRef?.log.channel("render").error(
          `\u8986\u76D6\u5C42\u7ED8\u5236\u629B\u9519\uFF08\u672C\u5E27\u4ECD\u63D0\u4EA4\uFF0C\u753B\u9762\u53EF\u80FD\u7F3A UI\uFF09\uFF1A${e instanceof Error ? e.message : String(e)}`,
          void 0,
          null
        );
      }
    }
    if (curtain > 0 && curtainVbo !== null && pipeline !== null) {
      const cu = d.updateBuffer(curtainVbo, curtainQuad(curtain));
      if (cu.ok) {
        cmd.setPipeline(pipeline);
        cmd.setUniform("u_useTexture", 0, "int");
        cmd.draw({ vertices: curtainVbo, indices: null, vertexCount: 6, indexCount: 6 });
        lastCurtain = { alpha: curtain, drawn: true };
      } else {
        ctxRef?.log.channel("render").error(`\u5E55\u5E03\u9876\u70B9\u4E0A\u4F20\u5931\u8D25\uFF1A${cu.error.message}`, void 0, null);
      }
    }
    cmd.finish();
    d.endFrame();
  }
  function frameOf(slot, frame) {
    return pages[slot]?.frames.get(frame);
  }
  return mod;
}

// src/extensions/physics/sweep.ts
var NO_NODE = -1;
function finite(name, v) {
  if (!Number.isFinite(v)) throw new TypeError(`sweepCircleVsBox \u7684 ${name} \u5FC5\u987B\u662F\u6709\u9650\u6570\uFF08\u6536\u5230 ${String(v)}\uFF09`);
}
function closestOnBox(px, pz, box) {
  const x = px < box.cx - box.hx ? box.cx - box.hx : px > box.cx + box.hx ? box.cx + box.hx : px;
  const z = pz < box.cz - box.hz ? box.cz - box.hz : pz > box.cz + box.hz ? box.cz + box.hz : pz;
  return { x, z, inside: x === px && z === pz };
}
function overlapNormal(px, pz, box) {
  const dxL = px - (box.cx - box.hx);
  const dxR = box.cx + box.hx - px;
  const dzL = pz - (box.cz - box.hz);
  const dzR = box.cz + box.hz - pz;
  const m = Math.min(dxL, dxR, dzL, dzR);
  if (m === dxL) return { nx: -1, nz: 0 };
  if (m === dxR) return { nx: 1, nz: 0 };
  if (m === dzL) return { nx: 0, nz: -1 };
  return { nx: 0, nz: 1 };
}
function sweepCircleVsBox(px, pz, dx, dz, r, box) {
  finite("px", px);
  finite("pz", pz);
  finite("dx", dx);
  finite("dz", dz);
  finite("r", r);
  if (!(r > 0)) throw new RangeError(`sweepCircleVsBox \u7684\u534A\u5F84\u5FC5\u987B > 0\uFF08\u6536\u5230 ${String(r)}\uFF09`);
  const nodeId = box.nodeId ?? NO_NODE;
  const cp = closestOnBox(px, pz, box);
  if (cp.inside) {
    const n = overlapNormal(px, pz, box);
    return { t: 0, nx: n.nx, nz: n.nz, nodeId };
  }
  const ddx = px - cp.x;
  const ddz = pz - cp.z;
  const d2 = ddx * ddx + ddz * ddz;
  if (d2 < r * r) {
    const len = Math.sqrt(d2);
    return { t: 0, nx: ddx / len, nz: ddz / len, nodeId };
  }
  if (dx === 0 && dz === 0) return null;
  let best = Number.POSITIVE_INFINITY;
  let bestNx = 0;
  let bestNz = 0;
  const faces = [
    { axis: 0, plane: box.cx - box.hx - r, lo: box.cz - box.hz, hi: box.cz + box.hz, nx: -1, nz: 0 },
    { axis: 0, plane: box.cx + box.hx + r, lo: box.cz - box.hz, hi: box.cz + box.hz, nx: 1, nz: 0 },
    { axis: 1, plane: box.cz - box.hz - r, lo: box.cx - box.hx, hi: box.cx + box.hx, nx: 0, nz: -1 },
    { axis: 1, plane: box.cz + box.hz + r, lo: box.cx - box.hx, hi: box.cx + box.hx, nx: 0, nz: 1 }
  ];
  for (const f of faces) {
    const p = f.axis === 0 ? px : pz;
    const d = f.axis === 0 ? dx : dz;
    if (d === 0) continue;
    const t = (f.plane - p) / d;
    if (!(t >= 0 && t <= 1)) continue;
    const other = f.axis === 0 ? pz + dz * t : px + dx * t;
    if (other < f.lo || other > f.hi) continue;
    if (t < best) {
      best = t;
      bestNx = f.nx;
      bestNz = f.nz;
    }
  }
  const corners = [
    { cx: box.cx - box.hx, cz: box.cz - box.hz },
    { cx: box.cx + box.hx, cz: box.cz - box.hz },
    { cx: box.cx - box.hx, cz: box.cz + box.hz },
    { cx: box.cx + box.hx, cz: box.cz + box.hz }
  ];
  for (const c of corners) {
    const hit = rayVsCircle(px - c.cx, pz - c.cz, dx, dz, r);
    if (hit === null) continue;
    if (hit > best) continue;
    const hx0 = px + dx * hit - c.cx;
    const hz0 = pz + dz * hit - c.cz;
    const outwardX = px < c.cx ? hx0 <= 0 : hx0 >= 0;
    const outwardZ = pz < c.cz ? hz0 <= 0 : hz0 >= 0;
    if (!outwardX || !outwardZ) continue;
    const len = Math.sqrt(hx0 * hx0 + hz0 * hz0);
    if (len === 0) continue;
    best = hit;
    bestNx = hx0 / len;
    bestNz = hz0 / len;
  }
  if (!Number.isFinite(best)) return null;
  return { t: best, nx: bestNx, nz: bestNz, nodeId };
}
function rayVsCircle(px, pz, dx, dz, r) {
  const c = px * px + pz * pz - r * r;
  if (c <= 0) return 0;
  const a = dx * dx + dz * dz;
  if (a === 0) return null;
  const b = px * dx + pz * dz;
  if (b >= 0) return null;
  const disc = b * b - a * c;
  if (disc < 0) return null;
  return (-b - Math.sqrt(disc)) / a;
}
function sweepCircleVsCircle(px, pz, dx, dz, r, cx, cz, otherR, nodeId = NO_NODE) {
  finite("cx", cx);
  finite("cz", cz);
  finite("otherR", otherR);
  const sum = r + otherR;
  const t = rayVsCircle(px - cx, pz - cz, dx, dz, sum);
  if (t === null || t > 1) return null;
  const hx = px + dx * t - cx;
  const hz = pz + dz * t - cz;
  const len = Math.hypot(hx, hz);
  if (len === 0) return { t, nx: 0, nz: 0, nodeId };
  return { t, nx: hx / len, nz: hz / len, nodeId };
}
function earliestHit(hits) {
  let best = null;
  for (const h of hits) {
    if (h === null) continue;
    if (best === null || h.t < best.t || h.t === best.t && h.nodeId < best.nodeId) best = h;
  }
  return best;
}

// src/extensions/physics/physics.ts
var AUTO_CELL_MIN = 0.5;
var AUTO_CELL_MAX = 16;
var AUTO_CELL_FALLBACK = 1;
var EPS = 1e-9;
var SpatialHashWorld = class {
  cellSize;
  autoCell;
  maxIterations;
  skin;
  bodies = /* @__PURE__ */ new Map();
  /** cell key → body id 列表 */
  cells = /* @__PURE__ */ new Map();
  /**
   * body id → 它现在在哪个格键里。
   *
   * ★ 没有它的时候，`reindex` 只能**遍历所有格**去找这个 id（`indexOf`）——
   *   O(#格) 每次。密集场景里每一步要推几千次，于是 2000 实体 × 250 格 = 几十万次
   *   `indexOf`，实测把 2.8ms 的解算拖到 21ms。性能闸门（physics-perf.test.ts）
   *   第一次跑就把这笔账算出来了。
   */
  cellOfBody = /* @__PURE__ */ new Map();
  /**
   * 全场最大 `rangeOf` 的缓存。
   *
   * ★ 它原来是在 `resolve()` 的内层循环里**每个体每次迭代都重算一遍**（O(n)），
   *   于是整个解算是 O(n²·迭代)。而实体只在 add/remove 时增减 —— 这是个纯缓存问题，
   *   不是算法问题：`maxRadiusNearby()` 现在 O(1)。
   *   失效点只有 add / remove / clear 三处（body 的半径是 add 时定的，之后不可变）。
   */
  maxRange = 0;
  /** 工作量计数（见 `PhysicsStats` 的三个同名注释）：只增不减，`clear()` 归零。 */
  _bodyScans = 0;
  _maxRangeScans = 0;
  _cellScans = 0;
  _settlePasses = 0;
  _settleStaticPushes = 0;
  _cellMoves = 0;
  _pairChecks = 0;
  _candidateScans = 0;
  /**
   * 动态体的 id 集合。
   *
   * ★ `resolve()` 原来遍历**所有** body 再 `if (b.isStatic) continue` ——
   *   于是"加 1900 棵静态树"会让 50 个动态体的解算慢 4.6 倍（实测），
   *   而静态树本不该影响动态体的成本。维护一个集合就把这一侧的开销从 O(全场)
   *   变成 O(动态数)。
   * ★ 不变量：`isStatic` 在 `add` 时确定，之后不可变（要变就先 remove 再 add）。
   */
  dynamicIds = /* @__PURE__ */ new Set();
  pos;
  _queries = 0;
  _pushes = 0;
  _unresolved = 0;
  constructor(pos, cfg = {}) {
    this.pos = pos;
    this.autoCell = cfg.cellSize === void 0;
    this.cellSize = cfg.cellSize ?? AUTO_CELL_FALLBACK;
    this.maxIterations = cfg.maxIterations ?? 3;
    this.skin = cfg.skin ?? 1e-3;
    if (!(this.cellSize > 0)) throw new RangeError("cellSize \u5FC5\u987B > 0");
  }
  /**
   * ★★ 自动格宽（T338）：`cellSize ≈ 2 × 全场最大 range`。
   *
   * 为什么是这个值 —— 一次解算的候选扫描量是
   *   `(覆盖格数) × (每格占用) ≈ (2r_q / cellSize + 1)² × (cellSize / 间距)²·n`
   * 其中 `r_q = 自身 range + 最大 range ≤ 2R`。格宽远大于实体尺寸时，"每格占用"
   * 按平方涨；远小于时，"覆盖格数"按平方涨。实测（2000 体 / 间距 0.5 / R=0.3）：
   * `cellSize=4`（默认值）**13.8ms** → `cellSize=1.6` 7.4ms → `1.0` 6.7ms → `0.7` **6.3ms**。
   * 最优点正好落在 `2R = 0.6` 附近。这是**成本模型**，不是"把场景调快"。
   *
   * 为什么只在**跨档**时才重建（而不是每次 add 都试）：
   *   重建是 O(n)。若按半径从小到大的顺序加载，每次 add 都想缩格 ⇒ 退化成 O(n²)。
   *   所以只有当新尺寸与当前尺寸相差 ≥ 2 倍时才重建 —— 每次重建都至少让尺寸减半/翻倍，
   *   一次加载里最多重建 O(log) 次。
   */
  resizeCellsIfNeeded() {
    if (!this.autoCell) return;
    const want = Math.min(AUTO_CELL_MAX, Math.max(AUTO_CELL_MIN, 2 * this.maxRange));
    if (this.cells.size > 0) {
      const ratio = want / this.cellSize;
      if (ratio < 2 && ratio > 0.5) return;
    }
    this.cellSize = want;
    this.cells.clear();
    this.cellOfBody.clear();
    for (const [id] of this.bodies) {
      const p = this.pos.get(id);
      if (p === void 0) continue;
      const [cx, cz] = this.cellOf(p.x, p.z);
      const k = this.key(cx, cz);
      let list = this.cells.get(k);
      if (list === void 0) {
        list = [];
        this.cells.set(k, list);
      }
      list.push(id);
      this.cellOfBody.set(id, k);
      this._cellMoves++;
    }
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
    this.cellOfBody.set(body.nodeId, k);
    if (!body.isStatic) this.dynamicIds.add(body.nodeId);
    const r = this.rangeOf(body);
    if (r > this.maxRange) {
      this.maxRange = r;
      this.resizeCellsIfNeeded();
    }
  }
  remove(nodeId) {
    const k = this.cellOfBody.get(nodeId);
    const wasMax = this.bodies.get(nodeId) !== void 0 && this.rangeOf(this.bodies.get(nodeId)) >= this.maxRange;
    if (k !== void 0) {
      const list = this.cells.get(k);
      if (list !== void 0) {
        const i = list.indexOf(nodeId);
        if (i >= 0) list.splice(i, 1);
        if (list.length === 0) this.cells.delete(k);
      }
      this.cellOfBody.delete(nodeId);
    }
    this.bodies.delete(nodeId);
    this.dynamicIds.delete(nodeId);
    if (wasMax) {
      this.recomputeMaxRange();
      this.resizeCellsIfNeeded();
    }
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
    if (p !== void 0) {
      const [ncx, ncz] = this.cellOf(p.x, p.z);
      const nk = this.key(ncx, ncz);
      if (this.cellOfBody.get(nodeId) === nk) return;
    }
    const oldKey = this.findCellOf(nodeId);
    if (oldKey !== void 0) {
      const old = this.cells.get(oldKey);
      if (old !== void 0) {
        const i = old.indexOf(nodeId);
        if (i >= 0) old.splice(i, 1);
        if (old.length === 0) this.cells.delete(oldKey);
      }
      this.cellOfBody.delete(nodeId);
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
    this.cellOfBody.set(nodeId, k);
    this._cellMoves++;
  }
  /**
   * 这个体现在在哪个格键里。
   *
   * ★ 快路径是 `cellOfBody`（O(1)）。慢路径（遍历所有格）是**兜底**：
   *   表里没有它时（例如有人绕开 `add` 手工往 `cells` 里塞过东西）仍然能找到，
   *   而且会被 `cellScans` 如实计入 —— 否则"索引没建好"会表现成"偶尔慢一下"，
   *   没人会去查。慢路径被**频繁走到**就说明索引出了问题。
   */
  findCellOf(nodeId) {
    const fast = this.cellOfBody.get(nodeId);
    if (fast !== void 0) return fast;
    for (const [key, list] of this.cells) {
      this._cellScans++;
      if (list.includes(nodeId)) return key;
    }
    return void 0;
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
    const scanR = r + this.maxRadiusNearby();
    const minCx = Math.floor((x - scanR) / this.cellSize);
    const maxCx = Math.floor((x + scanR) / this.cellSize);
    const minCz = Math.floor((z - scanR) / this.cellSize);
    const maxCz = Math.floor((z + scanR) / this.cellSize);
    const out = [];
    const seen = /* @__PURE__ */ new Set();
    for (let cx = minCx; cx <= maxCx; cx++) {
      for (let cz = minCz; cz <= maxCz; cz++) {
        const list = this.cells.get(this.key(cx, cz));
        if (list === void 0) continue;
        for (const id of list) {
          this._candidateScans++;
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
   * `query` 的饥荒同签名别名 —— **同一份实现**，不是转发到另一套逻辑。
   *
   * 判据钉的是"两个名字返回完全相同的数组"，不是"看起来一样"：
   * 一旦有人为了"内容层兼容"另写一遍查询，那条判据立刻红。
   */
  findEntities(x, z, r) {
    return this.query(x, z, r);
  }
  /**
   * 解算重叠。对每对 (动态, 其它)，若重叠则把动态体推开。
   *
   * ★ 为什么"逐对独立解算 + 迭代"而不是"一次性求平均位移"：
   *   后者在"三四个实体挤一个角"时会出现互相抵消、抖动。
   *   迭代式（最多 3 轮）在这个规模下更稳，而且实现只有一个循环。
   *
   * ★★ T338：每一对**每轮只处理一次**，动态-动态各让一半。
   *   原来两侧都会看到对方、各自按**全部**重叠量推 —— 于是同一对被推了两遍
   *   （总位移 2 倍，下一轮又推回来，正是密集场景抖个不停的一半原因）。
   *   两个后果都实测过：
   *   ① 工作量翻倍：密集布局 9154 次推动/步，其中一半是重复的；
   *   ② **结果带有 id 偏差**：先被遍历到的那个体不推、后来的那个被推全程，
   *      所以"挤在一起时总是同一只怪被弹开"，而判据只看距离，看不出来。
   *   现在：`otherId < id` 的动态对由**先遍历到的那一侧**处理（它已经在上一轮/本轮
   *   推过自己这一半），另外半程由对面承担 —— 总位移与原来相同（`overlap + skin`），
   *   但每对每轮只算一次，且两侧对称。
   */
  /**
   * 连续碰撞（扫掠）的实现：把候选体换成"静态障碍"再交给纯函数。
   *
   * ★ 候选集用 `query(起点, 位移长度 + 自身半径 + 最大障碍半径)`：那是**圆**的保守范围。
   *   用轴对齐的方框范围会漏掉斜方向的候选 —— 而漏掉的症状正是"偶尔穿过去"，
   *   与这段代码要修的问题一模一样，所以这里宁可多扫几个。
   */
  sweepMove(nodeId, dx, dz) {
    const self2 = this.bodies.get(nodeId);
    if (self2 === void 0) return null;
    const p = this.pos.get(nodeId);
    if (p === void 0) return null;
    const reach = Math.hypot(dx, dz) + self2.radius + this.maxRange;
    const boxes = [];
    const circles = [];
    for (const id of this.query(p.x, p.z, reach)) {
      if (id === nodeId) continue;
      const other = this.bodies.get(id);
      if (other === void 0 || !other.isStatic) continue;
      const q2 = this.pos.get(id);
      if (q2 === void 0) continue;
      if (other.halfExtents !== void 0) {
        boxes.push({ cx: q2.x, cz: q2.z, hx: other.halfExtents.x, hz: other.halfExtents.z, nodeId: id });
      } else {
        circles.push({ cx: q2.x, cz: q2.z, r: other.radius, nodeId: id });
      }
    }
    const fromBoxes = boxes.map((b) => sweepCircleVsBox(p.x, p.z, dx, dz, self2.radius, b));
    const fromCircles = circles.map((c) => sweepCircleVsCircle(p.x, p.z, dx, dz, self2.radius, c.cx, c.cz, c.r, c.nodeId));
    return earliestHit([...fromBoxes, ...fromCircles]);
  }
  resolve() {
    let moved = 0;
    for (let iter = 0; iter < this.maxIterations; iter++) {
      let movedThis = 0;
      for (const id of this.dynamicIds) {
        this._bodyScans++;
        const b = this.bodies.get(id);
        if (b === void 0) continue;
        const p = this.pos.get(id);
        if (p === void 0) continue;
        const near = this.query(p.x, p.z, this.rangeOf(b));
        for (const otherId of near) {
          if (otherId === id) continue;
          this._pairChecks++;
          const ob = this.bodies.get(otherId);
          if (ob === void 0) continue;
          if (ob.isStatic !== true && otherId < id) continue;
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
      if (iter === this.maxIterations - 1 && movedThis > 0) {
        this._unresolved++;
        moved += this.settleOnce();
      }
    }
    return moved;
  }
  /**
   * 兜底分离：**一次性**把仍然重叠的对按重叠量分开，不再迭代。
   *
   * ★ 三条性质必须同时成立，缺一条这个兜底就比抖动更糟：
   *   ① **确定性**：完全重合时沿 +x 分（不给随机方向）—— 否则同种子同操作的两个世界
   *      会跑出不同位置，存档比对与回放全部失效；
   *   ② **静态体不动**：静态体是"墙"，被兜底推动等于物理规则在最后一帧变了；
   *   ③ **每对只处理一次**：用 `id < otherId` 过滤，否则同一对会被推两遍（双倍位移）。
   *
   * 它**不保证**一次分开（三角堆叠仍然需要多帧），但保证"每帧都在往分开的方向走"，
   * 而不是在两个位置之间来回。重叠是否真的消掉仍由调用方看 `unresolved` 与实测决定。
   */
  settleOnce() {
    let moved = 0;
    for (const id of this.dynamicIds) {
      const b = this.bodies.get(id);
      if (b === void 0) continue;
      const p = this.pos.get(id);
      if (p === void 0) continue;
      const near = this.query(p.x, p.z, this.rangeOf(b));
      for (const otherId of near) {
        if (otherId === id) continue;
        const ob = this.bodies.get(otherId);
        if (ob === void 0) continue;
        if (ob.isStatic !== true && otherId < id) continue;
        const op = this.pos.get(otherId);
        if (op === void 0) continue;
        const dx = p.x - op.x;
        const dz = p.z - op.z;
        const distSq = dx * dx + dz * dz;
        const minDist = this.effectiveRadius(b, dx, dz) + this.effectiveRadius(ob, -dx, -dz);
        if (distSq >= minDist * minDist - EPS) continue;
        let dist = Math.sqrt(distSq);
        let nx = 1;
        let nz = 0;
        if (dist >= EPS) {
          nx = dx / dist;
          nz = dz / dist;
        } else {
          dist = 0;
        }
        const overlap = minDist - dist + this.skin;
        const bStatic = b.isStatic === true;
        const oStatic = ob.isStatic === true;
        if (bStatic && oStatic) continue;
        if (oStatic) this._settleStaticPushes++;
        const shareSelf = bStatic ? 0 : oStatic ? 1 : 0.5;
        const shareOther = oStatic ? 0 : bStatic ? 1 : 0.5;
        if (shareSelf > 0) {
          this.pos.set(id, p.x + nx * overlap * shareSelf, p.z + nz * overlap * shareSelf);
          p.x += nx * overlap * shareSelf;
          p.z += nz * overlap * shareSelf;
        }
        if (shareOther > 0) {
          this.pos.set(otherId, op.x - nx * overlap * shareOther, op.z - nz * overlap * shareOther);
          op.x -= nx * overlap * shareOther;
          op.z -= nz * overlap * shareOther;
        }
        this._pushes++;
        moved++;
      }
    }
    if (moved > 0) {
      this._settlePasses++;
      for (const id of this.dynamicIds) this.reindex(id);
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
  /**
   * O(1)：直接读缓存。
   *
   * ★★ 这里曾经是 `for (const b of this.bodies.values())` —— 也就是**注释写着 O(1)，
   *   代码是 O(n)**，而且被 `resolve()` 的内层循环每个体每次迭代各调一次（O(n²·迭代)）。
   *   缓存 `maxRange` 当时就已经在维护了（add / remove / clear 三处都更新），
   *   只是**没有任何地方读它**。批47 引入 `maxRangeScans` 计数后立刻显形：
   *   一次 2000 体的解算扫了 6000 个 body 去算一个从没变过的数。
   */
  maxRadiusNearby() {
    return this.maxRange;
  }
  /**
   * **唯一的**全量扫描入口（自带计数）。
   *
   * ★ 为什么要有这个"唯一入口"：`maxRangeScans` 只有在这里加，才可能在
   *   "有人把缓存换回扫描"时报警。如果扫描能绕过它，计数就是摆设 ——
   *   而摆设比没有更坏：它会让人以为"扫没扫"这件事已经被守住了。
   */
  scanMaxRange() {
    let m = 0;
    for (const b of this.bodies.values()) {
      this._maxRangeScans++;
      const r = this.rangeOf(b);
      if (r > m) m = r;
    }
    return m;
  }
  recomputeMaxRange() {
    this.maxRange = this.scanMaxRange();
  }
  stats() {
    return {
      bodies: this.bodies.size,
      cells: this.cells.size,
      queries: this._queries,
      pushes: this._pushes,
      unresolved: this._unresolved,
      bodyScans: this._bodyScans,
      maxRangeScans: this._maxRangeScans,
      cellScans: this._cellScans,
      settlePasses: this._settlePasses,
      settleStaticPushes: this._settleStaticPushes,
      cellMoves: this._cellMoves,
      pairChecks: this._pairChecks,
      candidateScans: this._candidateScans
    };
  }
  clear() {
    this.bodies.clear();
    this.cells.clear();
    this.cellOfBody.clear();
    this.dynamicIds.clear();
    this.maxRange = 0;
    this._queries = 0;
    this._pushes = 0;
    this._unresolved = 0;
    this._bodyScans = 0;
    this._maxRangeScans = 0;
    this._cellScans = 0;
    this._settlePasses = 0;
    this._settleStaticPushes = 0;
    this._cellMoves = 0;
    this._pairChecks = 0;
    this._candidateScans = 0;
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

// src/extensions/physics/world-step-module.ts
function createWorldModule(physics, hooks = {}) {
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
        hooks.onTick?.(tick);
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
        (msg3) => {
          ctxRef?.log.channel("script").info(fmt(msg3));
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
  versionKey;
  migrations;
  decimals;
  constructor(opts) {
    this.version = opts.version;
    this.fields = opts.fields;
    this.versionKey = opts.versionKey ?? "__v";
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
    const need = this.version - 1;
    if (froms.length !== need) {
      throw new Error(
        `v${this.version} \u9700\u8981 ${need} \u6761\u8FC1\u79FB\uFF08v1\u2192v2 \u2026 v${need}\u2192v${this.version}\uFF09\uFF0C\u5B9E\u9645 ${froms.length} \u6761\uFF08\u5DF2\u6709\uFF1A${froms.join(",") || "\u65E0"}\uFF09`
      );
    }
  }
  /** 把任意旧版本的记录迁到当前版本。 */
  migrate(data) {
    let cur = { ...data };
    const raw = cur[this.versionKey];
    const declared = Object.prototype.hasOwnProperty.call(cur, this.versionKey);
    let v = 1;
    if (declared) {
      if (typeof raw !== "number") {
        return err({
          code: "SER.BAD_VERSION",
          message: `\u7248\u672C\u5B57\u6BB5 ${this.versionKey}=${JSON.stringify(raw)} \u4E0D\u662F\u6570\u5B57\uFF08\u5B58\u6863\u5934\u635F\u574F\uFF09`
        });
      }
      v = raw;
    }
    if (!Number.isInteger(v) || v < 1) {
      return err({
        code: "SER.BAD_VERSION",
        message: `\u7248\u672C\u5B57\u6BB5 ${this.versionKey}=${JSON.stringify(raw)} \u4E0D\u662F \u22651 \u7684\u6574\u6570\uFF08\u5B58\u6863\u5934\u635F\u574F\uFF09`
      });
    }
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
      cur[this.versionKey] = v;
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
    const dropped = Object.keys(data).filter((k) => k !== this.versionKey && !this.fields.includes(k));
    const parts = [`${JSON.stringify(this.versionKey)}:${this.version}`];
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
function recordOf(scene, n) {
  const comps = [];
  for (const c of [...n.components].sort((a, b) => a.type < b.type ? -1 : a.type > b.type ? 1 : 0)) {
    const saved = c.save();
    const { type: _t, ...rest } = saved;
    comps.push({ type: c.type, data: rest });
  }
  return {
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
  };
}
function saveScene(scene) {
  const nodes = [];
  for (const n of collectNodes(scene)) nodes.push(recordOf(scene, n));
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
    try {
      parent.addChild(child);
    } catch (e) {
      skipped.push(`\u8282\u70B9 #${r.id} \u7684\u7236\u5B50\u5173\u7CFB\u4E0D\u6210\u7ACB\uFF1A${e instanceof Error ? e.message : String(e)}`);
    }
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
  const dec = SCENE_SCHEMA.decode(text);
  if (!dec.ok) {
    switch (dec.error.code) {
      case "SER.VERSION_TOO_NEW":
        return err(engineError("SCENE.FORMAT_TOO_NEW", dec.error.message));
      case "SER.NO_MIGRATION":
        return err(engineError("SCENE.FORMAT_NO_MIGRATION", dec.error.message));
      case "SER.BAD_VERSION":
        return err(engineError("SCENE.FORMAT_BAD", dec.error.message));
      default:
        return err(engineError("SCENE.BAD_JSON", dec.error.message));
    }
  }
  const o = dec.value;
  if (typeof o.format !== "number" || !Array.isArray(o.nodes)) {
    return err(engineError("SCENE.BAD_JSON", "\u7F3A\u5C11 format \u6216 nodes"));
  }
  return ok({
    // 迁移过的记录已经是当前版本；写 v1 档读回来也是 v1，所以这里恒等于 SCENE_FORMAT_VERSION
    format: SCENE_FORMAT_VERSION,
    name: typeof o.name === "string" ? o.name : "scene",
    nodes: o.nodes
  });
}
var SAVE_SCALE = 1e9;
var SAVE_SCALE_LIMIT = 1e6;
function q(v) {
  if (!Number.isFinite(v)) return v;
  if (!(Math.abs(v) < SAVE_SCALE_LIMIT)) return v;
  return Math.round(v * SAVE_SCALE) / SAVE_SCALE;
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
  fields: ["name", "nodes"],
  versionKey: "format"
});

// src/backends/fs-storage/fs.ts
var StorageFileSystem = class {
  scheme = "storage";
  canList = true;
  storage;
  prefix;
  clock = 1;
  constructor(opts) {
    this.storage = opts.storage;
    this.prefix = opts.prefix ?? "";
  }
  // ---------------------------------------------------------------- 写
  async writeText(path, text) {
    return this.writeBinary(path, new TextEncoder().encode(text));
  }
  async writeBinary(path, data) {
    const segs = normalizeVirtualPath(path);
    if (!segs.ok) return segs;
    if (segs.value.length === 0) {
      return err(engineError("FS.IS_DIR", "\u4E0D\u80FD\u5F80\u6839\u8DEF\u5F84\u5199\u6587\u4EF6"));
    }
    const vpath = virtualPathOf(segs.value);
    const dirs = this.dirs();
    for (let i = 1; i < segs.value.length; i++) {
      dirs.add(virtualPathOf(segs.value.slice(0, i)));
    }
    if (dirs.has(vpath)) {
      return err(engineError("FS.IS_DIR", `\u76EE\u6807\u662F\u4E00\u4E2A\u76EE\u5F55\uFF1A${vpath}`));
    }
    const rec = { t: this.now(), n: data.byteLength, b: toBase64(data) };
    const w = this.set(this.keyOf(vpath), JSON.stringify(rec));
    if (!w.ok) return w;
    return this.writeDirs(dirs);
  }
  async remove(path) {
    const segs = normalizeVirtualPath(path);
    if (!segs.ok) return segs;
    const vpath = virtualPathOf(segs.value);
    const dirs = this.dirs();
    if (dirs.has(vpath)) {
      return err(engineError("FS.IS_DIR", `\u8FD9\u662F\u4E00\u4E2A\u76EE\u5F55\uFF0C\u4E0D\u80FD\u5F53\u6587\u4EF6\u5220\uFF1A${vpath}`));
    }
    if (this.storage.getItem(this.keyOf(vpath)) === null) {
      return err(engineError("FS.NOT_FOUND", `\u8981\u5220\u9664\u7684\u8DEF\u5F84\u4E0D\u5B58\u5728\uFF1A${vpath}`));
    }
    this.storage.removeItem(this.keyOf(vpath));
    return ok(void 0);
  }
  async ensureDir(dir) {
    const segs = normalizeVirtualPath(dir);
    if (!segs.ok) return segs;
    const dirs = this.dirs();
    for (let i = 0; i <= segs.value.length; i++) {
      dirs.add(virtualPathOf(segs.value.slice(0, i)));
    }
    return this.writeDirs(dirs);
  }
  // ---------------------------------------------------------------- 读
  async readText(path) {
    const b = await this.readBinary(path);
    if (!b.ok) return b;
    try {
      return ok(new TextDecoder("utf-8", { fatal: true }).decode(b.value));
    } catch (e) {
      return err(engineError("FS.NOT_UTF8", `\u4E0D\u662F\u5408\u6CD5 UTF-8\uFF1A${path}\uFF08${msg2(e)}\uFF09`));
    }
  }
  async readBinary(path) {
    const segs = normalizeVirtualPath(path);
    if (!segs.ok) return segs;
    const vpath = virtualPathOf(segs.value);
    if (this.dirs().has(vpath)) {
      return err(engineError("FS.IS_DIR", `\u8DEF\u5F84\u662F\u4E00\u4E2A\u76EE\u5F55\uFF1A${vpath}`));
    }
    const rec = this.record(vpath);
    if (!rec.ok) return rec;
    try {
      return ok(fromBase64(rec.value.b));
    } catch (e) {
      return err(engineError("FS.IO", `\u5B58\u6863\u8BB0\u5F55\u635F\u574F\uFF08base64 \u89E3\u4E0D\u5F00\uFF09\uFF1A${vpath}\uFF08${msg2(e)}\uFF09`));
    }
  }
  async exists(path) {
    const segs = normalizeVirtualPath(path);
    if (!segs.ok) return false;
    const vpath = virtualPathOf(segs.value);
    return this.dirs().has(vpath) || this.storage.getItem(this.keyOf(vpath)) !== null;
  }
  async stat(path) {
    const segs = normalizeVirtualPath(path);
    if (!segs.ok) return segs;
    const vpath = virtualPathOf(segs.value);
    if (this.dirs().has(vpath)) return ok({ size: 0, mtimeMs: 0, isDirectory: true });
    const rec = this.record(vpath);
    if (!rec.ok) return rec;
    return ok({ size: rec.value.n, mtimeMs: rec.value.t, isDirectory: false });
  }
  async list(dir) {
    const segs = normalizeVirtualPath(dir);
    if (!segs.ok) return segs;
    const base = virtualPathOf(segs.value);
    const dirs = this.dirs();
    if (!dirs.has(base)) {
      return err(engineError("FS.NOT_FOUND", `\u76EE\u5F55\u4E0D\u5B58\u5728\uFF1A${base}`));
    }
    const prefix = base === "/" ? "/" : base + "/";
    const seen = /* @__PURE__ */ new Map();
    for (const d of dirs) {
      if (!d.startsWith(prefix) || d === base) continue;
      const rest = d.slice(prefix.length);
      if (rest === "" || rest.includes("/")) continue;
      seen.set(rest, { name: rest, path: prefix + rest, isDirectory: true, size: 0 });
    }
    for (const k of this.filePaths()) {
      if (!k.startsWith(prefix)) continue;
      const rest = k.slice(prefix.length);
      if (rest === "" || rest.includes("/")) continue;
      if (seen.has(rest)) continue;
      const rec = this.recordRaw(k);
      seen.set(rest, {
        name: rest,
        path: prefix + rest,
        isDirectory: false,
        size: rec === null ? 0 : rec.n
      });
    }
    const out = [...seen.values()].sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
    return ok(out);
  }
  // ---------------------------------------------------------------- 内部
  now() {
    this.clock = Math.max(Date.now(), this.clock + 1);
    return this.clock;
  }
  keyOf(vpath) {
    return `${this.prefix}f:${vpath}`;
  }
  dirsKey() {
    return `${this.prefix}d`;
  }
  set(key, value) {
    try {
      this.storage.setItem(key, value);
      return ok(void 0);
    } catch (e) {
      return err(engineError("FS.NO_SPACE", `\u5199\u5165\u5931\u8D25\uFF08storage \u6EE1\u6216\u4E0D\u53EF\u5199\uFF09\uFF1A${msg2(e)}`));
    }
  }
  /** 目录索引。读坏了就当空集（自愈），不把用户卡在"删 storage 才能用"。 */
  dirs() {
    const out = /* @__PURE__ */ new Set(["/"]);
    const raw = this.storage.getItem(this.dirsKey());
    if (raw === null) return out;
    try {
      const arr = JSON.parse(raw);
      if (Array.isArray(arr)) {
        for (const p of arr) if (typeof p === "string") out.add(p);
      }
    } catch {
      const rebuilt = /* @__PURE__ */ new Set(["/"]);
      for (const p of this.filePaths()) {
        const segs = p.split("/").filter((s) => s !== "");
        for (let i = 0; i < segs.length; i++) rebuilt.add("/" + segs.slice(0, i).join("/"));
      }
      return rebuilt;
    }
    return out;
  }
  writeDirs(dirs) {
    return this.set(this.dirsKey(), JSON.stringify([...dirs].sort()));
  }
  /** 所有以 `prefix + "f:"` 开头的键 → 虚拟路径。 */
  filePaths() {
    const out = [];
    const head = `${this.prefix}f:`;
    for (let i = 0; i < this.storage.length; i++) {
      const k = this.storage.key(i);
      if (k === null || !k.startsWith(head)) continue;
      out.push(k.slice(head.length));
    }
    return out;
  }
  recordRaw(vpath) {
    const raw = this.storage.getItem(this.keyOf(vpath));
    if (raw === null) return null;
    try {
      const o = JSON.parse(raw);
      if (typeof o.b !== "string" || typeof o.n !== "number" || typeof o.t !== "number") return null;
      return { t: o.t, n: o.n, b: o.b };
    } catch {
      return null;
    }
  }
  record(vpath) {
    const raw = this.storage.getItem(this.keyOf(vpath));
    if (raw === null) return err(engineError("FS.NOT_FOUND", `\u6587\u4EF6\u4E0D\u5B58\u5728\uFF1A${vpath}`));
    const rec = this.recordRaw(vpath);
    if (rec === null) return err(engineError("FS.IO", `\u5B58\u6863\u8BB0\u5F55\u635F\u574F\uFF08\u4E0D\u662F\u5408\u6CD5\u8BB0\u5F55\uFF09\uFF1A${vpath}`));
    return ok(rec);
  }
};
var B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
function toBase64(bytes) {
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i];
    const b = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const c = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += B64[a >> 2];
    out += B64[(a & 3) << 4 | b >> 4];
    out += i + 1 < bytes.length ? B64[(b & 15) << 2 | c >> 6] : "=";
    out += i + 2 < bytes.length ? B64[c & 63] : "=";
  }
  return out;
}
function fromBase64(s) {
  const clean = s.replace(/=+$/, "");
  const out = new Uint8Array(Math.floor(clean.length * 3 / 4));
  let o = 0;
  let acc = 0;
  let bits = 0;
  for (let i = 0; i < clean.length; i++) {
    const v = B64.indexOf(clean[i]);
    if (v < 0) throw new Error(`\u975E\u6CD5 base64 \u5B57\u7B26 ${JSON.stringify(clean[i])}\uFF08\u4F4D\u7F6E ${i}\uFF09`);
    acc = acc << 6 | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[o++] = acc >> bits & 255;
    }
  }
  return o === out.length ? out : out.subarray(0, o);
}
function msg2(e) {
  return e instanceof Error ? e.message : String(e);
}

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
var IMPORT_LIBRARY_REL = "library/imported";
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
    const libraryDir = joinPath(root, IMPORT_LIBRARY_REL);
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

// src/extensions/asset-import/decode/jpeg/types.ts
var DEFAULT_MAX_PIXELS = 64 * 1024 * 1024;
var JpegFailure = class extends Error {
  constructor(code, message, detail) {
    super(message);
    this.code = code;
    this.detail = detail;
    this.name = "JpegFailure";
  }
};
function fail(code, message, detail) {
  throw new JpegFailure(code, message, detail);
}

// src/extensions/asset-import/decode/jpeg/bits.ts
var BitReader = class {
  constructor(data, start, end) {
    this.data = data;
    this.end = end;
    this.pos = start;
  }
  pos;
  buf = 0;
  cnt = 0;
  /** 区间里意外出现了标记（说明预切分与数据不一致）：之后全部补 0，让解码"跑完"而不是死循环。 */
  stalled = false;
  push(b) {
    this.buf = (this.buf << 8 | b) >>> 0;
    this.cnt += 8;
  }
  fill() {
    while (this.cnt <= 24) {
      if (this.stalled || this.pos >= this.end) {
        this.push(0);
        continue;
      }
      const b = this.data[this.pos];
      if (b !== 255) {
        this.pos++;
        this.push(b);
        continue;
      }
      const next = this.pos + 1 < this.end ? this.data[this.pos + 1] : 0;
      if (next === 0) {
        this.pos += 2;
        this.push(255);
        continue;
      }
      this.stalled = true;
    }
  }
  readBit() {
    if (this.cnt === 0) this.fill();
    this.cnt--;
    return this.buf >>> this.cnt & 1;
  }
  /** 读 n 位（n ≤ 16），按 JPEG 的 MSB-first 顺序。 */
  receive(n) {
    let v = 0;
    for (let i = 0; i < n; i++) v = v << 1 | this.readBit();
    return v;
  }
};
function extend(v, n) {
  if (n === 0) return 0;
  return v < 1 << n - 1 ? v - (1 << n) + 1 : v;
}
var HuffTable = class {
  constructor(counts, values) {
    this.counts = counts;
    this.values = values;
    let code = 0;
    let k = 0;
    for (let len = 1; len <= 16; len++) {
      const n = counts[len - 1];
      this.valptr[len] = k;
      this.mincode[len] = code;
      if (n > 0) this.maxcode[len] = code + n - 1;
      k += n;
      code = code + n << 1;
    }
    if (k !== values.length) {
      fail("ASSET.BAD_JPEG", `DHT \u8868\u81EA\u76F8\u77DB\u76FE\uFF1Acode length \u8BA1\u6570\u5408\u8BA1 ${k}\uFF0C\u5B9E\u9645\u7ED9\u4E86 ${values.length} \u4E2A\u7B26\u53F7`);
    }
  }
  mincode = new Int32Array(17);
  maxcode = new Int32Array(18).fill(-1);
  valptr = new Int32Array(17);
  decode(r) {
    let code = 0;
    for (let len = 1; len <= 16; len++) {
      code = code << 1 | r.readBit();
      const mx = this.maxcode[len];
      if (mx >= 0 && code <= mx) {
        const at = this.valptr[len] + code - this.mincode[len];
        const v = this.values[at];
        if (v === void 0) {
          fail("ASSET.BAD_JPEG", `DHT \u67E5\u8868\u8D8A\u754C\uFF1Alen=${len} code=${code} at=${at}`);
        }
        return v;
      }
    }
    fail("ASSET.BAD_JPEG", "\u54C8\u592B\u66FC\u7801\u6D41\u975E\u6CD5\uFF1A\u8FDE\u7EED 16 \u4F4D\u90FD\u6CA1\u6709\u5339\u914D\u7684\u7801\u5B57\uFF08\u6587\u4EF6\u88AB\u622A\u65AD\u6216\u71B5\u6570\u636E\u9519\u4F4D\uFF09");
  }
};

// src/extensions/asset-import/decode/jpeg/tables.ts
var ZIGZAG = new Uint8Array([
  0,
  1,
  8,
  16,
  9,
  2,
  3,
  10,
  17,
  24,
  32,
  25,
  18,
  11,
  4,
  5,
  12,
  19,
  26,
  33,
  40,
  48,
  41,
  34,
  27,
  20,
  13,
  6,
  7,
  14,
  21,
  28,
  35,
  42,
  49,
  56,
  57,
  50,
  43,
  36,
  29,
  22,
  15,
  23,
  30,
  37,
  44,
  51,
  58,
  59,
  52,
  45,
  38,
  31,
  39,
  46,
  53,
  60,
  61,
  54,
  47,
  55,
  62,
  63
]);
var COS = (() => {
  const t = new Float64Array(64);
  for (let u = 0; u < 8; u++) {
    for (let x = 0; x < 8; x++) {
      t[u * 8 + x] = (u === 0 ? Math.SQRT1_2 : 1) * Math.cos((2 * x + 1) * u * Math.PI / 16) / 2;
    }
  }
  return t;
})();

// src/extensions/asset-import/decode/jpeg/frame.ts
var SOF_NAMES = {
  192: "SOF0 \u57FA\u7EBF\u987A\u5E8F\uFF08Huffman\uFF09",
  193: "SOF1 \u6269\u5C55\u987A\u5E8F\uFF08Huffman\uFF09",
  194: "SOF2 \u6E10\u8FDB\uFF08Huffman\uFF09",
  195: "SOF3 \u65E0\u635F\uFF08Huffman\uFF09",
  197: "SOF5 \u5DEE\u5206\u987A\u5E8F\uFF08Huffman\uFF09",
  198: "SOF6 \u5DEE\u5206\u6E10\u8FDB\uFF08Huffman\uFF09",
  199: "SOF7 \u5DEE\u5206\u65E0\u635F\uFF08Huffman\uFF09",
  201: "SOF9 \u6269\u5C55\u987A\u5E8F\uFF08\u7B97\u672F\uFF09",
  202: "SOF10 \u6E10\u8FDB\uFF08\u7B97\u672F\uFF09",
  203: "SOF11 \u65E0\u635F\uFF08\u7B97\u672F\uFF09",
  205: "SOF13 \u5DEE\u5206\u987A\u5E8F\uFF08\u7B97\u672F\uFF09",
  206: "SOF14 \u5DEE\u5206\u6E10\u8FDB\uFF08\u7B97\u672F\uFF09",
  207: "SOF15 \u5DEE\u5206\u65E0\u635F\uFF08\u7B97\u672F\uFF09"
};
function isArithmeticSof(sof) {
  return sof === 201 || sof === 202 || sof === 203 || sof === 205 || sof === 206 || sof === 207;
}
function isLosslessSof(sof) {
  return sof === 195 || sof === 199 || sof === 203 || sof === 207;
}
function isProgressiveSof(sof) {
  return sof === 194 || sof === 198 || sof === 202 || sof === 206;
}
function isDifferentialSof(sof) {
  return sof === 197 || sof === 198 || sof === 199 || sof === 205 || sof === 206 || sof === 207;
}
function u16be(b, at) {
  return b[at] << 8 | b[at + 1];
}
function readExifOrientation(seg) {
  if (seg.length < 14) return 1;
  if (seg[0] !== 69 || seg[1] !== 120 || seg[2] !== 105 || seg[3] !== 102) return 1;
  const tiff = 6;
  const le = seg[tiff] === 73 && seg[tiff + 1] === 73;
  const be = seg[tiff] === 77 && seg[tiff + 1] === 77;
  if (!le && !be) return 1;
  const rd16 = (at) => le ? seg[at] | seg[at + 1] << 8 : seg[at] << 8 | seg[at + 1];
  const rd32 = (at) => le ? (seg[at] | seg[at + 1] << 8 | seg[at + 2] << 16 | seg[at + 3] << 24) >>> 0 : (seg[at] << 24 | seg[at + 1] << 16 | seg[at + 2] << 8 | seg[at + 3]) >>> 0;
  const ifd0 = tiff + rd32(tiff + 4);
  if (ifd0 + 2 > seg.length) return 1;
  const count = rd16(ifd0);
  for (let i = 0; i < count; i++) {
    const entry = ifd0 + 2 + i * 12;
    if (entry + 12 > seg.length) return 1;
    if (rd16(entry) === 274) {
      const v = rd16(entry + 8);
      return v >= 1 && v <= 8 ? v : 1;
    }
  }
  return 1;
}
function checkProcessSupport(sof, precision) {
  const name = SOF_NAMES[sof];
  if (name === void 0) return { ok: false, reason: `\u672A\u77E5\u7684 SOF \u6807\u8BB0 0x${sof.toString(16)}` };
  if (isLosslessSof(sof)) {
    if (precision < 2 || precision > 16) {
      return { ok: false, reason: `${name}\uFF1A\u6837\u672C\u7CBE\u5EA6\u5FC5\u987B\u662F 2..16\uFF0C\u6587\u4EF6\u58F0\u660E ${precision} bit` };
    }
  } else if (precision !== 8 && precision !== 12) {
    return { ok: false, reason: `${name}\uFF1ADCT \u8FC7\u7A0B\u7684\u6837\u672C\u7CBE\u5EA6\u53EA\u652F\u6301 8 \u6216 12 bit\uFF0C\u6587\u4EF6\u58F0\u660E ${precision} bit` };
  }
  return { ok: true };
}
function parseSof(seg, sof, index, maxPixels) {
  if (seg.length < 6) fail("ASSET.BAD_JPEG", "SOF \u6BB5\u957F\u5EA6\u4E0D\u8DB3");
  const precision = seg[0];
  const height = u16be(seg, 1);
  const width = u16be(seg, 3);
  const n = seg[5];
  const lossless = isLosslessSof(sof);
  const support = checkProcessSupport(sof, precision);
  if (!support.ok) fail("ASSET.UNSUPPORTED_JPEG", support.reason ?? "\u4E0D\u652F\u6301\u7684 JPEG \u8FC7\u7A0B", { precision, sof });
  if (width === 0 || height === 0) {
    fail("ASSET.BAD_JPEG", `SOF \u7684\u5BBD\u9AD8\u5FC5\u987B\u975E 0\uFF0C\u5B9E\u9645 ${width}\xD7${height}\uFF08\u9AD8\u5EA6\u5728 DNL \u91CC\u7684\u5199\u6CD5\u4E0D\u652F\u6301\uFF09`);
  }
  if (width * height > maxPixels) {
    fail("ASSET.BAD_JPEG", `\u56FE\u50CF ${width}\xD7${height} \u8D85\u8FC7\u50CF\u7D20\u4E0A\u9650 ${maxPixels}`, { width, height, maxPixels });
  }
  if (n !== 1 && n !== 3 && n !== 4) {
    fail("ASSET.UNSUPPORTED_JPEG", `\u4E0D\u652F\u6301 ${n} \u4E2A\u5206\u91CF\u7684 JPEG\uFF08\u652F\u6301 1 \u7070\u5EA6 / 3 YCbCr-RGB / 4 CMYK-YCCK\uFF09`, {
      components: n
    });
  }
  if (seg.length < 6 + n * 3) fail("ASSET.BAD_JPEG", `SOF \u58F0\u660E ${n} \u4E2A\u5206\u91CF\uFF0C\u4F46\u6BB5\u91CC\u53EA\u6709 ${seg.length - 6} \u5B57\u8282`);
  let maxH = 1;
  let maxV = 1;
  const raw = [];
  for (let i = 0; i < n; i++) {
    const at = 6 + i * 3;
    const id = seg[at];
    const hv = seg[at + 1];
    const h = hv >> 4;
    const v = hv & 15;
    const tq = seg[at + 2];
    if (h < 1 || h > 4 || v < 1 || v > 4) {
      fail("ASSET.BAD_JPEG", `\u5206\u91CF ${id} \u7684\u91C7\u6837\u56E0\u5B50 ${h}\xD7${v} \u975E\u6CD5\uFF081..4\uFF09`);
    }
    if (tq > 3) fail("ASSET.BAD_JPEG", `\u5206\u91CF ${id} \u5F15\u7528\u4E86\u4E0D\u5B58\u5728\u7684\u91CF\u5316\u8868 ${tq}`);
    raw.push({ id, h, v, tq });
    if (h > maxH) maxH = h;
    if (v > maxV) maxV = v;
  }
  const mcusX = Math.ceil(width / (8 * maxH));
  const mcusY = Math.ceil(height / (8 * maxV));
  const components = raw.map((r) => {
    const compW = Math.ceil(width * r.h / maxH);
    const compH = Math.ceil(height * r.v / maxV);
    const blocksW = Math.ceil(compW / 8);
    const blocksH = Math.ceil(compH / 8);
    const strideBlocksW = mcusX * r.h;
    const strideBlocksH = mcusY * r.v;
    return {
      id: r.id,
      h: r.h,
      v: r.v,
      tq: r.tq,
      blocksW,
      blocksH,
      strideBlocksW,
      strideBlocksH,
      // 无损帧不分配系数数组（长度 0），省下 64 倍内存
      coefs: lossless ? new Int16Array(0) : new Int16Array(strideBlocksW * strideBlocksH * 64),
      pred: 0,
      compW,
      compH,
      td: 0,
      ta: 0,
      plane: lossless ? new Uint16Array(compW * compH) : null,
      qtTable: null
    };
  });
  return {
    index,
    sof,
    precision,
    width,
    height,
    progressive: isProgressiveSof(sof),
    lossless,
    arithmetic: isArithmeticSof(sof),
    differential: isDifferentialSof(sof),
    components,
    // 量化表/哈夫曼表由 parse 统一持有（一次文件可以有多张表、多趟扫描），
    // parseSof 只负责几何与分量，这里先占位，parse 紧接着替换成真实数组。
    qt: [],
    dcTables: [],
    acTables: [],
    dcCond: [],
    acCond: [],
    restartInterval: 0,
    scanCount: 0,
    pt: 0,
    expansions: /* @__PURE__ */ new Map(),
    expandH: 1,
    expandV: 1,
    adobeTransform: null
  };
}
function parseDqt(seg, qt) {
  let at = 0;
  while (at < seg.length) {
    const pq = seg[at] >> 4;
    const tq = seg[at] & 15;
    at++;
    if (tq > 3) fail("ASSET.BAD_JPEG", `DQT \u8868\u53F7 ${tq} \u975E\u6CD5\uFF080..3\uFF09`);
    const bytesPer = pq === 1 ? 2 : 1;
    if (at + 64 * bytesPer > seg.length) fail("ASSET.BAD_JPEG", "DQT \u6BB5\u88AB\u622A\u65AD");
    const t = new Uint16Array(64);
    for (let i = 0; i < 64; i++) {
      t[ZIGZAG[i]] = bytesPer === 2 ? u16be(seg, at + i * 2) : seg[at + i];
    }
    qt[tq] = t;
    at += 64 * bytesPer;
  }
}
function parseDht(seg, dc, ac) {
  let at = 0;
  while (at < seg.length) {
    if (at + 17 > seg.length) fail("ASSET.BAD_JPEG", "DHT \u6BB5\u88AB\u622A\u65AD\uFF08\u8868\u5934\u4E0D\u8DB3 17 \u5B57\u8282\uFF09");
    const tc = seg[at] >> 4;
    const th = seg[at] & 15;
    at++;
    if (tc > 1) fail("ASSET.BAD_JPEG", `DHT \u8868\u7C7B\u578B ${tc} \u975E\u6CD5\uFF080=DC, 1=AC\uFF09`);
    if (th > 3) fail("ASSET.BAD_JPEG", `DHT \u8868\u53F7 ${th} \u975E\u6CD5\uFF080..3\uFF09`);
    const counts = seg.subarray(at, at + 16);
    at += 16;
    let total = 0;
    for (let i = 0; i < 16; i++) total += counts[i];
    if (at + total > seg.length) fail("ASSET.BAD_JPEG", "DHT \u6BB5\u88AB\u622A\u65AD\uFF08\u7B26\u53F7\u6570\u4E0D\u8DB3\uFF09");
    const values = seg.subarray(at, at + total);
    at += total;
    const table = new HuffTable(Uint8Array.from(counts), Uint8Array.from(values));
    if (tc === 0) dc[th] = table;
    else ac[th] = table;
  }
}
function parseDac(seg, dcCond, acCond) {
  let at = 0;
  while (at + 2 <= seg.length) {
    const index = seg[at];
    const val = seg[at + 1];
    at += 2;
    if (index >= 16) {
      const t = index - 16;
      if (t > 3) fail("ASSET.BAD_JPEG", `DAC \u7684 AC \u8868\u53F7 ${t} \u975E\u6CD5\uFF080..3\uFF09`);
      acCond[t] = val;
    } else {
      if (index > 3) fail("ASSET.BAD_JPEG", `DAC \u7684 DC \u8868\u53F7 ${index} \u975E\u6CD5\uFF080..3\uFF09`);
      const l = val & 15;
      const u = val >> 4;
      if (l > u) fail("ASSET.BAD_JPEG", `DAC \u7684 DC \u6761\u4EF6\u53C2\u6570\u975E\u6CD5\uFF1AL=${l} U=${u}\uFF08\u8981\u6C42 L \u2264 U\uFF09`);
      dcCond[index] = { l, u };
    }
  }
  if (at !== seg.length) fail("ASSET.BAD_JPEG", "DAC \u6BB5\u957F\u5EA6\u4E0D\u662F 2 \u7684\u500D\u6570\uFF08\u88AB\u622A\u65AD\uFF09");
}

// src/extensions/asset-import/importers/texture.ts
var VERSION = 1;
var PNG_SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10];
var MIN_PNG_HEADER_BYTES = 33;
var IHDR_DATA_BYTES = 13;
function u32be(b, at) {
  return b[at] * 16777216 + (b[at + 1] << 16) + (b[at + 2] << 8) + b[at + 3] >>> 0;
}
function u16be2(b, at) {
  return b[at] << 8 | b[at + 1];
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
function readPngHeader(sourcePath, source) {
  if (source.length < MIN_PNG_HEADER_BYTES) {
    return err(
      badSource(
        sourcePath,
        `PNG \u5934\u622A\u65AD\uFF1A\u8BFB IHDR \u9700\u8981 ${MIN_PNG_HEADER_BYTES} \u5B57\u8282\uFF08\u7B7E\u540D 8 + \u5757\u5934 8 + IHDR 13 + CRC 4\uFF09\uFF0C\u5B9E\u9645 ${source.length}`
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
  return ok({ width, height, bitDepth, colorType, hasAlpha: hasAlphaChannel(colorType), format: "png" });
}
function readJpegHeader(sourcePath, source) {
  if (source.length < 4) return err(badSource(sourcePath, "JPEG \u5934\u622A\u65AD\uFF1A\u8FDE SOI \u90FD\u4E0D\u5B8C\u6574"));
  let dhpWidth = 0;
  let dhpHeight = 0;
  let pos = 2;
  while (pos + 3 < source.length) {
    if (source[pos] !== 255) {
      pos++;
      continue;
    }
    const marker = source[pos + 1];
    if (marker === 255) {
      pos++;
      continue;
    }
    if (marker === 216 || marker === 1 || marker >= 208 && marker <= 215) {
      pos += 2;
      continue;
    }
    if (marker === 217) break;
    const segLen = u16be2(source, pos + 2);
    if (segLen < 2) return err(badSource(sourcePath, `JPEG \u6BB5 0x${marker.toString(16)} \u957F\u5EA6\u975E\u6CD5\uFF1A${segLen}`));
    if (marker === 222 && segLen >= 8) {
      const d = pos + 4;
      if (d + 6 <= source.length) {
        dhpHeight = u16be2(source, d + 1);
        dhpWidth = u16be2(source, d + 3);
      }
      pos += 2 + segLen;
      continue;
    }
    const isSof = marker >= 192 && marker <= 207 && marker !== 196 && marker !== 200 && marker !== 204;
    if (isSof) {
      const dataStart = pos + 4;
      if (dataStart + 6 > source.length) return err(badSource(sourcePath, "JPEG SOF \u6BB5\u88AB\u622A\u65AD"));
      const precision = source[dataStart];
      const frameHeight = u16be2(source, dataStart + 1);
      const frameWidth = u16be2(source, dataStart + 3);
      const components = source[dataStart + 5];
      const support = checkProcessSupport(marker, precision);
      if (!support.ok) {
        return err(
          engineError("IMPORT.UNSUPPORTED_SOURCE", `${sourcePath}: ${support.reason ?? "\u4E0D\u652F\u6301\u7684 JPEG \u8FC7\u7A0B"}`, {
            path: sourcePath,
            marker: `0x${marker.toString(16)}`,
            precision
          })
        );
      }
      const hier = dhpWidth > 0 && dhpHeight > 0;
      const width = hier ? dhpWidth : frameWidth;
      const height = hier ? dhpHeight : frameHeight;
      if (width === 0 || height === 0) {
        return err(badSource(sourcePath, `SOF \u5BBD\u9AD8\u5FC5\u987B\u975E 0\uFF0C\u5B9E\u9645 ${width}\xD7${height}`));
      }
      if (components !== 1 && components !== 3 && components !== 4) {
        return err(
          engineError("IMPORT.UNSUPPORTED_SOURCE", `${sourcePath}: \u4E0D\u652F\u6301 ${components} \u4E2A\u5206\u91CF\u7684 JPEG`, {
            path: sourcePath,
            components
          })
        );
      }
      return ok({
        width,
        height,
        // 源精度，与 PNG 的 IHDR 位深同义（输出恒为 RGBA8，全精度走 pixels16）
        bitDepth: precision,
        // 分层文件报"分层"而不是参考帧的 SOF —— 只报 SOF1 会让元数据说"这是扩展顺序图"，
        // 而它其实是两帧合成的；同一条流里同时存在参考帧与差分帧两个不同的 SOF。
        // 这里能看到的只有先出现的**参考帧**（轻量扫头不跨熵数据，看不到末帧）。
        process: hier ? `\u5206\u5C42\uFF08DHP + \u5DEE\u5206\u5E27\uFF0C\u53C2\u8003\u5E27 ${SOF_NAMES[marker] ?? `SOF 0x${marker.toString(16)}`}\uFF09` : SOF_NAMES[marker] ?? `SOF 0x${marker.toString(16)}`,
        colorType: components === 1 ? 0 : 2,
        hasAlpha: false,
        format: "jpeg",
        hierarchical: hier
      });
    }
    pos += 2 + segLen;
  }
  return err(badSource(sourcePath, "JPEG \u91CC\u6CA1\u6709\u627E\u5230 SOF \u5E27\u5934\uFF08\u53EF\u80FD\u53EA\u6709\u5934\u3001\u6CA1\u6709\u56FE\u50CF\u6570\u636E\uFF09"));
}
var textureImporter = {
  id: AssetType.Texture,
  version: VERSION,
  extensions: [".png", ".jpg", ".jpeg"],
  async import(sourcePath, source) {
    let header;
    if (source.length >= 3 && source[0] === 255 && source[1] === 216 && source[2] === 255) {
      header = readJpegHeader(sourcePath, source);
    } else {
      if (source.length < PNG_SIGNATURE.length) {
        return err(badSource(sourcePath, `\u671F\u671B 8 \u5B57\u8282 PNG \u7B7E\u540D\u6216 JPEG SOI\uFF0C\u5B9E\u9645\u53EA\u6709 ${source.length} \u5B57\u8282`));
      }
      for (let i = 0; i < PNG_SIGNATURE.length; i++) {
        if (source[i] !== PNG_SIGNATURE[i]) {
          return err(
            badSource(
              sourcePath,
              `\u671F\u671B 8 \u5B57\u8282 PNG \u7B7E\u540D\uFF0889 50 4e 47 0d 0a 1a 0a\uFF09\u6216 JPEG SOI\uFF08ff d8 ff\uFF09\uFF0C\u5B9E\u9645 ${hexBytes(source, 0, 8)}`
            )
          );
        }
      }
      header = readPngHeader(sourcePath, source);
    }
    if (!header.ok) return err(header.error);
    return ok({
      type: AssetType.Texture,
      dependencies: [],
      byteLength: source.byteLength,
      sourceHash: contentHash(source),
      importerVersion: VERSION,
      data: { ...header.value }
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
  // ★ `.fnt` 是 BMFont 的**文本**格式（`parseBmFont` 的输入），本质就是文本资产：
  //   它的 `chars` / `common` 行要按行解析，走文本导入器才有增量哈希与 .meta 身份。
  //   不加这一条的症状是"字体文件在资产目录里、导入报告里却没有它"，
  //   于是加载期报"字体未注册" —— 而文件明明在那儿。
  extensions: [".txt", ".json", ".lua", ".md", ".fnt"],
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
    const step2 = 1 << len;
    for (let i = rev; i < size; i += step2) table[i] = entry;
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
var BitReader2 = class {
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
    const br = new BitReader2(data, 2);
    const sink = new ByteSink(opts?.sizeHint !== void 0 ? opts.sizeHint : 64 * 1024, maxBytes);
    const fail2 = (msg3) => {
      throw new ZlibError(`${msg3} at byte ${br.pos}`);
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
          fail2(`stored \u5757\u7684 LEN/NLEN \u4E0D\u4E92\u8865\uFF1ALEN=${len} NLEN=${nlen}`);
        }
        if (br.pos + len > data.length) {
          fail2(`stored \u5757\u622A\u65AD\uFF1A\u9700\u8981 ${len} \u5B57\u8282\uFF0C\u5269\u4F59 ${data.length - br.pos}`);
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
          const tables = readDynamicTables(br, fail2);
          lit = tables.lit;
          dist = tables.dist;
        }
        decodeCompressed(br, lit, dist, sink, fail2);
      } else {
        fail2(`invalid block type ${type}\uFF08deflate \u53EA\u6709 0/1/2\uFF09`);
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
function readDynamicTables(br, fail2) {
  const hlit = br.readBits(5) + 257;
  const hdist = br.readBits(5) + 1;
  const hclen = br.readBits(4) + 4;
  if (hlit > 286) fail2(`HLIT=${hlit - 257} \u975E\u6CD5\uFF08\u6700\u591A 286 \u4E2A\u5B57\u9762\u91CF/\u957F\u5EA6\u7801\uFF09`);
  if (hdist > 30) fail2(`HDIST=${hdist - 1} \u975E\u6CD5\uFF08\u6700\u591A 30 \u4E2A\u8DDD\u79BB\u7801\uFF09`);
  const clenLengths = new Uint8Array(19);
  for (let i2 = 0; i2 < hclen; i2++) clenLengths[CLEN_ORDER[i2]] = br.readBits(3);
  let clen;
  try {
    clen = buildHuffman(clenLengths);
  } catch (e) {
    fail2(`\u7801\u957F\u8868\u7684 Huffman \u6784\u9020\u5931\u8D25\uFF1A${e instanceof Error ? e.message : String(e)}`);
  }
  const total = hlit + hdist;
  const lengths = new Uint8Array(total);
  let i = 0;
  while (i < total) {
    const sym = br.decode(clen);
    if (sym < 16) {
      lengths[i++] = sym;
    } else if (sym === 16) {
      if (i === 0) fail2("\u7801\u957F\u91CD\u590D\u7801 16 \u51FA\u73B0\u5728\u7B2C\u4E00\u4E2A\u7801\u957F\u4E4B\u524D\uFF08\u6CA1\u6709\u53EF\u590D\u5236\u7684\u4E0A\u4E00\u4E2A\u503C\uFF09");
      const repeat = br.readBits(2) + 3;
      if (i + repeat > total) fail2(`\u7801\u957F\u91CD\u590D\u7801 16 \u8D8A\u754C\uFF1Ai=${i} repeat=${repeat} total=${total}`);
      const prev = lengths[i - 1];
      for (let k = 0; k < repeat; k++) lengths[i++] = prev;
    } else if (sym === 17) {
      const repeat = br.readBits(3) + 3;
      if (i + repeat > total) fail2(`\u7801\u957F\u91CD\u590D\u7801 17 \u8D8A\u754C\uFF1Ai=${i} repeat=${repeat} total=${total}`);
      i += repeat;
    } else if (sym === 18) {
      const repeat = br.readBits(7) + 11;
      if (i + repeat > total) fail2(`\u7801\u957F\u91CD\u590D\u7801 18 \u8D8A\u754C\uFF1Ai=${i} repeat=${repeat} total=${total}`);
      i += repeat;
    } else {
      fail2(`\u975E\u6CD5\u7801\u957F\u7B26\u53F7 ${sym}\uFF08\u53EA\u5141\u8BB8 0..18\uFF09`);
    }
  }
  const litLengths = lengths.subarray(0, hlit);
  const distLengths = lengths.subarray(hlit);
  if (litLengths[256] === 0) fail2("\u5B57\u9762\u91CF\u8868\u7F3A\u5C11\u5757\u7ED3\u675F\u7B26 256 \u7684\u7801\u5B57");
  try {
    return { lit: buildHuffman(litLengths), dist: buildHuffman(distLengths) };
  } catch (e) {
    fail2(`Huffman \u8868\u6784\u9020\u5931\u8D25\uFF1A${e instanceof Error ? e.message : String(e)}`);
  }
}
function decodeCompressed(br, lit, dist, sink, fail2) {
  for (; ; ) {
    const sym = br.decode(lit);
    if (sym < 256) {
      sink.writeByte(sym);
      continue;
    }
    if (sym === 256) return;
    if (sym > 285) fail2(`\u975E\u6CD5\u957F\u5EA6\u7B26\u53F7 ${sym}\uFF08286/287 \u4FDD\u7559\uFF09`);
    const li = sym - 257;
    const length = LEN_BASE[li] + br.readBits(LEN_EXTRA[li]);
    const dsym = br.decode(dist);
    if (dsym > 29) fail2(`\u975E\u6CD5\u8DDD\u79BB\u7B26\u53F7 ${dsym}\uFF0830/31 \u4FDD\u7559\uFF09`);
    const distance = DIST_BASE[dsym] + br.readBits(DIST_EXTRA[dsym]);
    if (distance > sink.len) {
      fail2(`invalid distance ${distance} > \u5DF2\u4EA7\u51FA ${sink.len} \u5B57\u8282`);
    }
    sink.copyBack(distance, length);
  }
}

// src/extensions/asset-import/decode/png.ts
var PngErrorCode = {
  BadPng: "ASSET.BAD_PNG",
  BadApng: "ASSET.BAD_APNG",
  Unsupported: "ASSET.UNSUPPORTED_PNG",
  /** 仅在 `interlace: "reject"` 时出现：解码器有能力，但调用方显式关掉了。 */
  UnsupportedInterlace: "ASSET.UNSUPPORTED_INTERLACE",
  /** 仅在 `apng: "reject"` 时出现。 */
  UnsupportedAnimation: "ASSET.UNSUPPORTED_ANIMATION"
};
var SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10];
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
var ADAM7_PASSES = [
  { xStart: 0, yStart: 0, xStep: 8, yStep: 8 },
  { xStart: 4, yStart: 0, xStep: 8, yStep: 8 },
  { xStart: 0, yStart: 4, xStep: 4, yStep: 8 },
  { xStart: 2, yStart: 0, xStep: 4, yStep: 4 },
  { xStart: 0, yStart: 2, xStep: 2, yStep: 4 },
  { xStart: 1, yStart: 0, xStep: 2, yStep: 2 },
  { xStart: 0, yStart: 1, xStep: 1, yStep: 2 }
];
var SINGLE_PASS = [{ xStart: 0, yStart: 0, xStep: 1, yStep: 1 }];
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
function scanPng(bytes) {
  if (bytes.length < SIGNATURE.length) {
    return err(bad(`\u6587\u4EF6\u8FC7\u77ED\uFF1A${bytes.length} \u5B57\u8282\uFF0C\u8FDE PNG \u7B7E\u540D\u90FD\u4E0D\u591F\uFF088 \u5B57\u8282\uFF09`));
  }
  for (let i = 0; i < SIGNATURE.length; i++) {
    if (bytes[i] !== SIGNATURE[i]) {
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
  const chunks = [];
  let iendEnd = -1;
  let at = SIGNATURE.length;
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
      chunks.push(chunk);
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
    chunks.push(chunk);
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
  const header = readHeader(bytes, ihdr);
  if (!header.ok) return err(header.error);
  return ok({ header: header.value, ihdr, palette, trns, idat, chunks });
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
function validateFormat(header, palette) {
  const channels = CHANNELS[header.colorType];
  if (channels === void 0) {
    return err(
      engineError(
        PngErrorCode.Unsupported,
        `\u672A\u77E5 colorType=${header.colorType}\uFF08\u5141\u8BB8 0/2/3/4/6\uFF1B7 \u53CA\u4FDD\u7559\u503C\u4E00\u5F8B\u62D2\u7EDD\uFF09`,
        { colorType: header.colorType }
      )
    );
  }
  const legal = LEGAL_DEPTHS[header.colorType];
  if (!legal.includes(header.bitDepth)) {
    return err(
      engineError(
        PngErrorCode.Unsupported,
        `\u4E0D\u652F\u6301\u7684 colorType/bitDepth \u7EC4\u5408\uFF1AcolorType=${header.colorType} bitDepth=${header.bitDepth}\uFF08\u8BE5 colorType \u5141\u8BB8 ${legal.join("/")}\uFF09`,
        { colorType: header.colorType, bitDepth: header.bitDepth }
      )
    );
  }
  if (header.colorType === 3 && palette === void 0) {
    return err(bad("colorType=3\uFF08\u8C03\u8272\u677F\uFF09\u4F46\u6587\u4EF6\u91CC\u6CA1\u6709 PLTE \u5757"));
  }
  return ok(channels);
}
function planPasses(width, height, bitsPerPixel, interlace) {
  const defs = interlace === 1 ? ADAM7_PASSES : SINGLE_PASS;
  const out = [];
  for (const d of defs) {
    const w = width > d.xStart ? Math.ceil((width - d.xStart) / d.xStep) : 0;
    const h = height > d.yStart ? Math.ceil((height - d.yStart) / d.yStep) : 0;
    if (w === 0 || h === 0) continue;
    out.push({ ...d, width: w, height: h, stride: Math.ceil(w * bitsPerPixel / 8) });
  }
  return out;
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
function narrow16(v) {
  return Math.round(v / 257);
}
function put(ctx, o, r, g, b, a, r16, g16, b16, a16) {
  ctx.out[o] = r;
  ctx.out[o + 1] = g;
  ctx.out[o + 2] = b;
  ctx.out[o + 3] = a;
  if (ctx.out16 !== void 0) {
    ctx.out16[o] = r16;
    ctx.out16[o + 1] = g16;
    ctx.out16[o + 2] = b16;
    ctx.out16[o + 3] = a16;
  }
}
function writeGray(ctx, passes, bitDepth, trnsGray) {
  const maxV = (1 << bitDepth) - 1;
  for (const p of passes) {
    for (let py = 0; py < p.height; py++) {
      const row = p.raw.subarray(py * p.stride, (py + 1) * p.stride);
      const y = p.yStart + py * p.yStep;
      for (let px = 0; px < p.width; px++) {
        const x = p.xStart + px * p.xStep;
        const o = (y * ctx.imageWidth + x) * 4;
        let v;
        if (bitDepth === 16) v = sampleU16(row, px * 2);
        else if (bitDepth === 8) v = row[px];
        else v = subByteSample(row, px, bitDepth);
        const a = v === trnsGray ? 0 : 255;
        if (bitDepth === 16) {
          put(ctx, o, narrow16(v), narrow16(v), narrow16(v), a, v, v, v, a === 0 ? 0 : 65535);
        } else {
          const g = bitDepth === 8 ? v : Math.round(v * 255 / maxV);
          const g16 = bitDepth === 8 ? v * 257 : Math.round(v * 65535 / maxV);
          put(ctx, o, g, g, g, a, g16, g16, g16, a === 0 ? 0 : 65535);
        }
      }
    }
  }
}
function writeRgb(ctx, passes, bitDepth, trnsR, trnsG, trnsB) {
  for (const p of passes) {
    for (let py = 0; py < p.height; py++) {
      const row = p.raw.subarray(py * p.stride, (py + 1) * p.stride);
      const y = p.yStart + py * p.yStep;
      for (let px = 0; px < p.width; px++) {
        const x = p.xStart + px * p.xStep;
        const o = (y * ctx.imageWidth + x) * 4;
        let r;
        let g;
        let b;
        let r16;
        let g16;
        let b16;
        if (bitDepth === 16) {
          r16 = sampleU16(row, px * 6);
          g16 = sampleU16(row, px * 6 + 2);
          b16 = sampleU16(row, px * 6 + 4);
          r = narrow16(r16);
          g = narrow16(g16);
          b = narrow16(b16);
        } else {
          r = r16 = row[px * 3];
          g = g16 = row[px * 3 + 1];
          b = b16 = row[px * 3 + 2];
          r16 *= 257;
          g16 *= 257;
          b16 *= 257;
        }
        const keyed = bitDepth === 16 ? r16 === trnsR && g16 === trnsG && b16 === trnsB : r === trnsR && g === trnsG && b === trnsB;
        put(ctx, o, r, g, b, keyed ? 0 : 255, r16, g16, b16, keyed ? 0 : 65535);
      }
    }
  }
}
function writePalette(ctx, passes, bitDepth, palette, trns, state) {
  const entries = palette.length / 3;
  for (const p of passes) {
    for (let py = 0; py < p.height; py++) {
      const row = p.raw.subarray(py * p.stride, (py + 1) * p.stride);
      const y = p.yStart + py * p.yStep;
      for (let px = 0; px < p.width; px++) {
        const x = p.xStart + px * p.xStep;
        const idx = bitDepth === 8 ? row[px] : subByteSample(row, px, bitDepth);
        if (idx >= entries) {
          return err(
            bad(`\u8C03\u8272\u677F\u7D22\u5F15\u8D8A\u754C\uFF1A\u7B2C (${x},${y}) \u50CF\u7D20\u7D22\u5F15 ${idx}\uFF0CPLTE \u53EA\u6709 ${entries} \u9879`, { x, y, index: idx })
          );
        }
        const o = (y * ctx.imageWidth + x) * 4;
        const r = palette[idx * 3];
        const g = palette[idx * 3 + 1];
        const b = palette[idx * 3 + 2];
        const a = trns !== void 0 && idx < trns.length ? trns[idx] : 255;
        if (a < 255) state.paletteAlpha = true;
        put(ctx, o, r, g, b, a, r * 257, g * 257, b * 257, a * 257);
      }
    }
  }
  return ok(void 0);
}
function writeGrayAlpha(ctx, passes, bitDepth) {
  for (const p of passes) {
    for (let py = 0; py < p.height; py++) {
      const row = p.raw.subarray(py * p.stride, (py + 1) * p.stride);
      const y = p.yStart + py * p.yStep;
      for (let px = 0; px < p.width; px++) {
        const x = p.xStart + px * p.xStep;
        const o = (y * ctx.imageWidth + x) * 4;
        if (bitDepth === 16) {
          const v = sampleU16(row, px * 4);
          const a = sampleU16(row, px * 4 + 2);
          const g = narrow16(v);
          put(ctx, o, g, g, g, narrow16(a), v, v, v, a);
        } else {
          const v = row[px * 2];
          const a = row[px * 2 + 1];
          put(ctx, o, v, v, v, a, v * 257, v * 257, v * 257, a * 257);
        }
      }
    }
  }
}
function writeRgba(ctx, passes, bitDepth) {
  for (const p of passes) {
    for (let py = 0; py < p.height; py++) {
      const row = p.raw.subarray(py * p.stride, (py + 1) * p.stride);
      const y = p.yStart + py * p.yStep;
      for (let px = 0; px < p.width; px++) {
        const x = p.xStart + px * p.xStep;
        const o = (y * ctx.imageWidth + x) * 4;
        if (bitDepth === 16) {
          const r = sampleU16(row, px * 8);
          const g = sampleU16(row, px * 8 + 2);
          const b = sampleU16(row, px * 8 + 4);
          const a = sampleU16(row, px * 8 + 6);
          put(ctx, o, narrow16(r), narrow16(g), narrow16(b), narrow16(a), r, g, b, a);
        } else {
          const r = row[px * 4];
          const g = row[px * 4 + 1];
          const b = row[px * 4 + 2];
          const a = row[px * 4 + 3];
          put(ctx, o, r, g, b, a, r * 257, g * 257, b * 257, a * 257);
        }
      }
    }
  }
}
function toRgba(passes, header, palette, trns, keep16) {
  const { width, height, colorType, bitDepth } = header;
  const pixels = new Uint8Array(width * height * 4);
  const pixels16 = keep16 ? new Uint16Array(width * height * 4) : void 0;
  const ctx = { out: pixels, out16: pixels16, imageWidth: width };
  const state = { paletteAlpha: false };
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
  switch (colorType) {
    case 0:
      writeGray(ctx, passes, bitDepth, trnsGray);
      break;
    case 2:
      writeRgb(ctx, passes, bitDepth, trnsR, trnsG, trnsB);
      break;
    case 3: {
      const r = writePalette(ctx, passes, bitDepth, palette, trns, state);
      if (!r.ok) return err(r.error);
      break;
    }
    case 4:
      writeGrayAlpha(ctx, passes, bitDepth);
      break;
    default:
      writeRgba(ctx, passes, bitDepth);
      break;
  }
  return ok({
    pixels,
    pixels16,
    usedTransparencyKey: colorType === 0 && trnsGray >= 0 || colorType === 2 && trnsR >= 0,
    paletteAlpha: state.paletteAlpha
  });
}
function decodeZlibImage(compressed, header, width, height, palette, trns, opts = {}) {
  const channels = CHANNELS[header.colorType];
  if (channels === void 0) {
    return err(
      engineError(PngErrorCode.Unsupported, `\u672A\u77E5 colorType=${header.colorType}`, { colorType: header.colorType })
    );
  }
  const bitsPerPixel = channels * header.bitDepth;
  const bpp = Math.max(1, Math.ceil(bitsPerPixel / 8));
  const passes = planPasses(width, height, bitsPerPixel, header.interlace);
  const rawBytes = passes.reduce((n, p) => n + (p.stride + 1) * p.height, 0);
  const label = opts.label ?? "PNG";
  const maxBytes = opts.maxBytes ?? DEFAULT_MAX_BYTES2;
  if (rawBytes > maxBytes) {
    return err(
      bad(
        `${label} \u7684\u626B\u63CF\u7EBF\u7EA6 ${rawBytes} \u5B57\u8282\uFF0C\u8D85\u8FC7 maxBytes=${maxBytes}\uFF08\u89E3\u538B\u70B8\u5F39\u4FDD\u62A4\uFF09`,
        { width, height, rawBytes, maxBytes }
      )
    );
  }
  const inflated = inflateZlib(compressed, { maxBytes: rawBytes, sizeHint: rawBytes });
  if (!inflated.ok) {
    return err(
      engineError(
        PngErrorCode.BadPng,
        `${label} \u89E3\u538B\u5931\u8D25\uFF08${compressed.length} \u5B57\u8282\u538B\u7F29\u6570\u636E\uFF0C\u671F\u671B ${rawBytes}\uFF09\uFF1A${inflated.error.message}`
      )
    );
  }
  const raw = inflated.value;
  if (raw.length !== rawBytes) {
    return err(
      bad(
        `${label} \u626B\u63CF\u7EBF\u6570\u636E\u957F\u5EA6\u4E0D\u5BF9\uFF1A\u671F\u671B ${rawBytes}${header.interlace === 1 ? `\uFF08Adam7 \u4E03\u4E2A pass \u4E4B\u548C\uFF0C\u975E\u9694\u884C\u5E94\u4E3A ${height * (Math.ceil(width * bitsPerPixel / 8) + 1)}\uFF09` : ""}\uFF0C\u5B9E\u9645 ${raw.length}\u3002IDAT \u88AB\u622A\u65AD\u6216 IHDR \u4E0E\u5B9E\u9645\u6570\u636E\u4E0D\u7B26 \u2014\u2014 \u62D2\u7EDD\u8FD4\u56DE\u534A\u5F20\u56FE\u3002`,
        { expectedRaw: rawBytes, actual: raw.length, interlace: header.interlace }
      )
    );
  }
  const filled = [];
  let at = 0;
  for (const p of passes) {
    const bytes = (p.stride + 1) * p.height;
    const slice = raw.subarray(at, at + bytes);
    at += bytes;
    const u = unfilter(slice, p.stride, p.height, bpp);
    if (!u.ok) return err(u.error);
    filled.push({ ...p, raw: u.value });
  }
  const rgba = toRgba(filled, { ...header, width, height }, palette, trns, opts.keep16 === true);
  if (!rgba.ok) return err(rgba.error);
  return ok({ ...rgba.value, bitDepth: header.bitDepth, colorType: header.colorType });
}
function readAnimationInfo(bytes, chunks) {
  const actl = chunks.find((c) => c.type === "acTL");
  if (actl === void 0) return ok(void 0);
  if (actl.length !== 8) {
    return err(
      engineError(PngErrorCode.BadApng, `acTL \u6570\u636E\u957F\u5EA6 ${actl.length}\uFF08\u5FC5\u987B 8\uFF09`, { chunk: "acTL" })
    );
  }
  const frameCount = u32be2(bytes, actl.dataStart);
  const loopCount = u32be2(bytes, actl.dataStart + 4);
  if (frameCount === 0) {
    return err(engineError(PngErrorCode.BadApng, "acTL.num_frames=0\uFF08\u52A8\u56FE\u81F3\u5C11\u8981\u6709\u4E00\u5E27\uFF09", { chunk: "acTL" }));
  }
  const firstIdat = chunks.find((c) => c.type === "IDAT");
  if (firstIdat !== void 0 && actl.start > firstIdat.start) {
    return err(
      engineError(PngErrorCode.BadApng, "acTL \u51FA\u73B0\u5728 IDAT \u4E4B\u540E\uFF08APNG \u89C4\u8303\u8981\u6C42\u4E4B\u524D\uFF09", { chunk: "acTL" })
    );
  }
  return ok({ frameCount, loopCount });
}
function decodePng(bytes, opts) {
  const maxBytes = opts?.maxBytes ?? DEFAULT_MAX_BYTES2;
  const scanned = scanPng(bytes);
  if (!scanned.ok) return err(scanned.error);
  const { header: h, palette, trns, idat, chunks } = scanned.value;
  if (h.interlace !== 0 && opts?.interlace === "reject") {
    return err(
      engineError(
        PngErrorCode.UnsupportedInterlace,
        `PNG \u4F7F\u7528\u4E86 Adam7 \u9694\u884C\uFF08interlace=${h.interlace}\uFF09\uFF0C\u4F46\u8C03\u7528\u65B9\u8981\u6C42 reject\u3002\u672C\u89E3\u7801\u5668\u652F\u6301\u9694\u884C\uFF0C\u53BB\u6389 interlace:"reject" \u5373\u53EF\u89E3\u51FA\u50CF\u7D20\u3002`,
        { width: h.width, height: h.height }
      )
    );
  }
  const channels = validateFormat(h, palette);
  if (!channels.ok) return err(channels.error);
  const animation = readAnimationInfo(bytes, chunks);
  if (!animation.ok) return err(animation.error);
  if (animation.value !== void 0 && opts?.apng === "reject") {
    return err(
      engineError(
        PngErrorCode.UnsupportedAnimation,
        `\u8FD9\u662F APNG \u52A8\u56FE\uFF08${animation.value.frameCount} \u5E27\uFF09\uFF0C\u4F46\u8C03\u7528\u65B9\u8981\u6C42 reject\u3002\u8981\u5355\u5E27\u8BF7\u7528\u9ED8\u8BA4\u7684 apng:"first-frame"\uFF0C\u8981\u5168\u90E8\u5E27\u8BF7\u7528 decodeApng()\u3002`,
        { frameCount: animation.value.frameCount }
      )
    );
  }
  const bitsPerPixel = channels.value * h.bitDepth;
  if (h.height > 0 && h.width > Math.floor(maxBytes / 4 / h.height)) {
    return err(
      bad(
        `PNG \u5C3A\u5BF8 ${h.width}\xD7${h.height} \u7684 RGBA8 \u50CF\u7D20\u6570\u8D85\u8FC7 maxBytes=${maxBytes} \u7684\u4E0A\u9650\uFF08\u89E3\u538B\u70B8\u5F39\u4FDD\u62A4\uFF09`,
        { width: h.width, height: h.height, maxBytes }
      )
    );
  }
  const rawBytes = planPasses(h.width, h.height, bitsPerPixel, h.interlace).reduce(
    (n, p) => n + (p.stride + 1) * p.height,
    0
  );
  if (rawBytes > maxBytes) {
    return err(
      bad(
        `PNG ${h.width}\xD7${h.height} \u7684\u89E3\u538B\u540E\u626B\u63CF\u7EBF\u7EA6 ${rawBytes} \u5B57\u8282\uFF0C\u8D85\u8FC7 maxBytes=${maxBytes}`,
        { width: h.width, height: h.height, maxBytes }
      )
    );
  }
  const compressed = new Uint8Array(idat.reduce((n, c) => n + c.length, 0));
  {
    let o = 0;
    for (const c of idat) {
      compressed.set(bytes.subarray(c.dataStart, c.dataStart + c.length), o);
      o += c.length;
    }
  }
  const paletteBytes = palette === void 0 ? void 0 : bytes.subarray(palette.dataStart, palette.dataStart + palette.length);
  const trnsBytes = trns === void 0 ? void 0 : bytes.subarray(trns.dataStart, trns.dataStart + trns.length);
  const decoded = decodeZlibImage(compressed, h, h.width, h.height, paletteBytes, trnsBytes, {
    keep16: opts?.keep16,
    maxBytes,
    label: `PNG ${h.width}\xD7${h.height}`
  });
  if (!decoded.ok) return err(decoded.error);
  const hasChannelAlpha = h.colorType === 4 || h.colorType === 6;
  return ok({
    width: h.width,
    height: h.height,
    pixels: decoded.value.pixels,
    pixels16: decoded.value.pixels16,
    bitDepth: h.bitDepth,
    colorType: h.colorType,
    hasAlpha: hasChannelAlpha || decoded.value.usedTransparencyKey || decoded.value.paletteAlpha,
    usedTransparencyKey: decoded.value.usedTransparencyKey,
    interlaced: h.interlace === 1,
    isApng: animation.value !== void 0,
    animation: animation.value
  });
}

// src/extensions/asset-import/decode/jpeg/reconstruct.ts
function clampSample(v, maxval) {
  return v < 0 ? 0 : v > maxval ? maxval : v;
}
function maxValueOf(precision) {
  return (1 << precision) - 1;
}
function idctBlock(coefs, bo, qt, plane, planeW, planeH, originX, originY, offset, maxval) {
  const block = new Float64Array(64);
  for (let i = 0; i < 64; i++) block[i] = coefs[bo + i] * qt[i];
  const tmp = new Float64Array(64);
  for (let y = 0; y < 8; y++) {
    const o = y * 8;
    for (let x = 0; x < 8; x++) {
      let s = 0;
      for (let u = 0; u < 8; u++) s += block[o + u] * COS[u * 8 + x];
      tmp[o + x] = s;
    }
  }
  for (let y = 0; y < 8; y++) {
    const py = originY + y;
    if (py >= planeH) break;
    for (let x = 0; x < 8; x++) {
      const px = originX + x;
      if (px >= planeW) continue;
      let s = 0;
      for (let v = 0; v < 8; v++) s += tmp[v * 8 + x] * COS[v * 8 + y];
      plane[py * planeW + px] = clampSample(Math.round(s + offset), maxval);
    }
  }
}
function buildPlane(c, qt, precision) {
  const offset = 1 << precision - 1;
  const maxval = maxValueOf(precision);
  const plane = new Uint16Array(c.compW * c.compH);
  for (let by = 0; by < c.blocksH; by++) {
    for (let bx = 0; bx < c.blocksW; bx++) {
      const bo = (by * c.strideBlocksW + bx) * 64;
      idctBlock(c.coefs, bo, qt, plane, c.compW, c.compH, bx * 8, by * 8, offset, maxval);
    }
  }
  return plane;
}
function buildFramePlanes(frame) {
  if (frame.lossless) {
    if (frame.pt > 0) {
      for (const c of frame.components) {
        const p = c.plane;
        for (let i = 0; i < p.length; i++) p[i] = p[i] << frame.pt;
      }
    }
    return;
  }
  for (const c of frame.components) {
    const q2 = c.qtTable ?? frame.qt[c.tq] ?? null;
    if (q2 === null) {
      fail("ASSET.BAD_JPEG", `\u5206\u91CF ${c.id} \u5F15\u7528\u7684\u91CF\u5316\u8868 ${c.tq} \u6CA1\u6709\u5728\u6587\u4EF6\u91CC\u5B9A\u4E49\uFF08DQT \u7F3A\u5931\uFF09`);
    }
    c.plane = buildPlane(c, q2, frame.precision);
  }
}
function sampleComponent(plane, w, h, factorH, factorV, x, y) {
  const axis = (pos, factor, n, fancy) => {
    if (factor === 1) {
      const p2 = pos < n ? pos : n - 1;
      return [p2, p2, 0, 1];
    }
    if (factor === 2) {
      if (!fancy) {
        const p2 = pos >> 1 < n ? pos >> 1 : n - 1;
        return [p2, p2, 0, 1];
      }
      const i = pos >> 1;
      if (i >= n) return [n - 1, n - 1, 0, 1];
      if ((pos & 1) === 1) {
        const j2 = i + 1 < n ? i + 1 : i;
        return [i, j2, 0.75, 0.25];
      }
      const j = i - 1 >= 0 ? i - 1 : i;
      return [j, i, 0.25, 0.75];
    }
    const p = Math.floor(pos / factor);
    const q2 = p < n ? p : n - 1;
    return [q2, q2, 0, 1];
  };
  const fancyH = factorH === 2 && w > 2;
  const fancyV = factorV === 2 && (factorH === 2 ? w > 2 : h > 2);
  const [x0, x1, wx0, wx1] = axis(x, factorH, w, fancyH);
  const [y0, y1, wy0, wy1] = axis(y, factorV, h, fancyV);
  const a = plane[y0 * w + x0];
  const b = plane[y0 * w + x1];
  const c = plane[y1 * w + x0];
  const d = plane[y1 * w + x1];
  const top = a * wx0 + b * wx1;
  const bottom = c * wx0 + d * wx1;
  return top * wy0 + bottom * wy1;
}
function subsamplingName(c0, maxH, maxV, components) {
  if (components === 1) return "none";
  const hs = c0.h;
  const vs = c0.v;
  if (hs === maxH && vs === maxV) {
    if (maxH === 1 && maxV === 1) return "4:4:4";
    if (maxH === 2 && maxV === 1) return "4:2:2";
    if (maxH === 2 && maxV === 2) return "4:2:0";
    if (maxH === 4 && maxV === 1) return "4:1:1";
    if (maxH === 4 && maxV === 2) return "4:1:0";
    if (maxH === 1 && maxV === 2) return "4:4:0";
    return `${maxH}x${maxV}`;
  }
  return `${hs}x${vs}/${maxH}x${maxV}`;
}
function applyOrientation(src, w, h, orientation) {
  if (orientation <= 1 || orientation > 8) return { data: src, width: w, height: h };
  const swap = orientation >= 5;
  const outW = swap ? h : w;
  const outH = swap ? w : h;
  const Ctor = src.constructor;
  const out = new Ctor(outW * outH * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let ox = x;
      let oy = y;
      switch (orientation) {
        case 2:
          ox = w - 1 - x;
          break;
        case 3:
          ox = w - 1 - x;
          oy = h - 1 - y;
          break;
        case 4:
          oy = h - 1 - y;
          break;
        case 5:
          ox = y;
          oy = x;
          break;
        case 6:
          ox = h - 1 - y;
          oy = x;
          break;
        case 7:
          ox = h - 1 - y;
          oy = w - 1 - x;
          break;
        case 8:
          ox = y;
          oy = w - 1 - x;
          break;
        default:
          break;
      }
      const s = (y * w + x) * 4;
      const d = (oy * outW + ox) * 4;
      out[d] = src[s];
      out[d + 1] = src[s + 1];
      out[d + 2] = src[s + 2];
      out[d + 3] = src[s + 3];
    }
  }
  return { data: out, width: outW, height: outH };
}
function planesToRgba(frame, opts) {
  const { width, height, components, precision } = frame;
  const maxH = Math.max(...components.map((c) => c.h));
  const maxV = Math.max(...components.map((c) => c.v));
  const maxval = maxValueOf(precision);
  const offset = 1 << precision - 1;
  const n = components.length;
  const planes = [];
  for (const c of components) {
    if (c.plane === null) {
      fail("ASSET.BAD_JPEG", `\u5206\u91CF ${c.id} \u7684\u5E73\u9762\u8FD8\u6CA1\u6709\u89E3\u7801\u51FA\u6765\uFF08\u5185\u90E8\u9519\u8BEF\uFF1A\u91CD\u5EFA\u987A\u5E8F\u9519\u4E86\uFF09`);
    }
    planes.push(c.plane);
  }
  const keep16 = opts.keep16 === true;
  const pixels = new Uint8Array(width * height * 4);
  const pixels16 = keep16 ? new Uint16Array(width * height * 4) : void 0;
  const rgbDirect = n === 3 && (frame.adobeTransform === 0 || components[0].id === 82 && components[1].id === 71 && components[2].id === 66);
  const ycck = n === 4 && frame.adobeTransform === 2;
  const toFull16 = (v) => {
    if (precision === 16) return v;
    if (precision === 8) return v * 257;
    return Math.round(v * 65535 / maxval);
  };
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const o = (y * width + x) * 4;
      if (n === 1) {
        const g2 = sampleComponent(
          planes[0],
          components[0].compW,
          components[0].compH,
          maxH / components[0].h,
          maxV / components[0].v,
          x,
          y
        );
        const v = clampSample(Math.round(g2), maxval);
        writePixel(o, v, v, v);
        continue;
      }
      const s0 = sampleComponent(planes[0], components[0].compW, components[0].compH, maxH / components[0].h, maxV / components[0].v, x, y);
      const s1 = sampleComponent(planes[1], components[1].compW, components[1].compH, maxH / components[1].h, maxV / components[1].v, x, y);
      const s2 = sampleComponent(planes[2], components[2].compW, components[2].compH, maxH / components[2].h, maxV / components[2].v, x, y);
      let r;
      let g;
      let b;
      if (n === 4) {
        const k = sampleComponent(
          planes[3],
          components[3].compW,
          components[3].compH,
          maxH / components[3].h,
          maxV / components[3].v,
          x,
          y
        );
        let c0;
        let c1;
        let c2;
        if (ycck) {
          const cb = s1 - offset;
          const cr = s2 - offset;
          c0 = maxval - (s0 + 1.402 * cr);
          c1 = maxval - (s0 - 0.344136 * cb - 0.714136 * cr);
          c2 = maxval - (s0 + 1.772 * cb);
        } else {
          c0 = s0;
          c1 = s1;
          c2 = s2;
        }
        r = c0 * k / maxval;
        g = c1 * k / maxval;
        b = c2 * k / maxval;
      } else if (rgbDirect) {
        r = s0;
        g = s1;
        b = s2;
      } else {
        const cb = s1 - offset;
        const cr = s2 - offset;
        r = s0 + 1.402 * cr;
        g = s0 - 0.344136 * cb - 0.714136 * cr;
        b = s0 + 1.772 * cb;
      }
      writePixel(o, r, g, b);
    }
  }
  function writePixel(o, r, g, b) {
    const rv = clampSample(Math.round(r), maxval);
    const gv = clampSample(Math.round(g), maxval);
    const bv = clampSample(Math.round(b), maxval);
    if (pixels16 !== void 0) {
      pixels16[o] = toFull16(rv);
      pixels16[o + 1] = toFull16(gv);
      pixels16[o + 2] = toFull16(bv);
      pixels16[o + 3] = 65535;
      pixels[o] = Math.round(pixels16[o] / 257);
      pixels[o + 1] = Math.round(pixels16[o + 1] / 257);
      pixels[o + 2] = Math.round(pixels16[o + 2] / 257);
      pixels[o + 3] = 255;
      return;
    }
    pixels[o] = Math.round(toFull16(rv) / 257);
    pixels[o + 1] = Math.round(toFull16(gv) / 257);
    pixels[o + 2] = Math.round(toFull16(bv) / 257);
    pixels[o + 3] = 255;
  }
  return { pixels, pixels16, width, height };
}
function toDecodedJpeg(frame, meta, opts) {
  const rgba = planesToRgba(frame, opts);
  const apply = opts.orientation === "apply";
  const o8 = apply ? applyOrientation(rgba.pixels, rgba.width, rgba.height, meta.orientation) : null;
  const o16 = apply && rgba.pixels16 !== void 0 ? applyOrientation(rgba.pixels16, rgba.width, rgba.height, meta.orientation) : null;
  const maxH = Math.max(...frame.components.map((c) => c.h));
  const maxV = Math.max(...frame.components.map((c) => c.v));
  const c0 = frame.components[0];
  const n = frame.components.length;
  return {
    width: o8?.width ?? rgba.width,
    height: o8?.height ?? rgba.height,
    pixels: o8?.data ?? rgba.pixels,
    ...o16 !== null ? { pixels16: o16.data } : rgba.pixels16 !== void 0 ? { pixels16: rgba.pixels16 } : {},
    bitDepth: frame.precision,
    // 4 分量（CMYK/YCCK）也还原成 RGB，alpha 恒不透明；
    // colorType 用 2（RGB）而不是 6（RGBA）—— JPEG 没有 alpha 通道，写 6 就是撒谎。
    colorType: 2,
    hasAlpha: false,
    usedTransparencyKey: false,
    interlaced: false,
    isApng: false,
    jpeg: {
      process: processName(frame),
      sof: frame.sof,
      progressive: frame.progressive,
      arithmetic: frame.arithmetic,
      lossless: frame.lossless,
      differential: frame.differential,
      precision: frame.precision,
      pointTransform: frame.pt,
      subsampling: subsamplingName(c0, maxH, maxV, n),
      components: n,
      restartInterval: frame.restartInterval,
      orientation: meta.orientation,
      adobeTransform: frame.adobeTransform,
      truncated: meta.truncated,
      frames: meta.frames,
      hierarchical: meta.hierarchical
    }
  };
}
function processName(frame) {
  const huff = frame.arithmetic ? "\u7B97\u672F" : "Huffman";
  const kind = frame.lossless ? "\u65E0\u635F" : frame.progressive ? "\u6E10\u8FDB" : "\u987A\u5E8F";
  const diff = frame.differential ? "\u5DEE\u5206" : "";
  return `SOF${frame.sof & 15} ${diff}${kind}\uFF08${huff}\uFF09`;
}

// src/extensions/asset-import/decode/jpeg/hierarchy.ts
function upsamplePlane(src, sw, sh, dw, dh) {
  const out = new Uint16Array(dw * dh);
  const cx = (x) => x < 0 ? 0 : x >= sw ? sw - 1 : x;
  const cy = (y) => y < 0 ? 0 : y >= sh ? sh - 1 : y;
  const at = (x, y) => src[cy(y) * sw + cx(x)];
  for (let y = 0; y < dh; y++) {
    const y0 = Math.floor(y / 2);
    const yc = y % 2 === 0 ? y0 - 1 : y0 + 1;
    for (let x = 0; x < dw; x++) {
      const x0 = Math.floor(x / 2);
      const xc = x % 2 === 0 ? x0 - 1 : x0 + 1;
      const v = at(x0, y0) * 9 + at(xc, y0) * 3 + at(x0, yc) * 3 + at(xc, yc);
      out[y * dw + x] = Math.floor((v + 8) / 16);
    }
  }
  return out;
}
function pairComponent(cur, prev, ci) {
  const c = cur.components[ci];
  const p = prev.components.find((x) => x.id === c.id) ?? prev.components[ci];
  if (p === void 0) {
    fail("ASSET.BAD_JPEG", `\u5206\u5C42 JPEG \u7684\u5DEE\u5206\u5E27\u627E\u4E0D\u5230\u5206\u91CF ${c.id} \u7684\u53C2\u8003\u5206\u91CF`);
  }
  return { c, p };
}
function checkPairing(cur, prev) {
  if (cur.components.length !== prev.components.length) {
    fail(
      "ASSET.BAD_JPEG",
      `\u5206\u5C42 JPEG \u7684\u5DEE\u5206\u5E27\u6709 ${cur.components.length} \u4E2A\u5206\u91CF\uFF0C\u53C2\u8003\u5E27\u6709 ${prev.components.length} \u4E2A\uFF08\u5206\u91CF\u6570\u4E0D\u4E00\u81F4\u5C31\u65E0\u6CD5\u9010\u5206\u91CF\u505A\u9884\u6D4B\uFF09`
    );
  }
  if (cur.precision !== prev.precision) {
    fail(
      "ASSET.BAD_JPEG",
      `\u5206\u5C42 JPEG \u7684\u5DEE\u5206\u5E27\u7CBE\u5EA6 ${cur.precision} \u4E0E\u53C2\u8003\u5E27 ${prev.precision} \u4E0D\u4E00\u81F4\uFF08\u4E0D\u540C\u4F4D\u6DF1\u7684\u5DEE\u6CA1\u6709\u5B9A\u4E49\uFF0C\u53EA\u80FD\u62A5\u9519\u800C\u4E0D\u662F\u731C\uFF09`
    );
  }
}
function addReferencePlanes(cur, prev) {
  checkPairing(cur, prev);
  const maxval = maxValueOf(cur.precision);
  const shift = cur.lossless ? 0 : 1 << cur.precision - 1;
  for (let ci = 0; ci < cur.components.length; ci++) {
    const { c, p } = pairComponent(cur, prev, ci);
    const dst = c.plane;
    const src = p.plane;
    if (dst === null || src === null) {
      fail("ASSET.BAD_JPEG", `\u5206\u91CF ${c.id} \u7684\u5E73\u9762\u8FD8\u6CA1\u89E3\u51FA\u6765\uFF08\u5185\u90E8\u9519\u8BEF\uFF1A\u5206\u5C42\u5408\u6210\u7684\u987A\u5E8F\u9519\u4E86\uFF09`);
    }
    const w = c.compW;
    const h = c.compH;
    const up = p.compW === w && p.compH === h ? src : upsamplePlane(src, p.compW, p.compH, w, h);
    for (let y = 0; y < h; y++) {
      const row = y * w;
      for (let x = 0; x < w; x++) {
        const sum = dst[row + x] - shift + up[row + x];
        dst[row + x] = cur.lossless ? sum & maxval : clampSample(sum, maxval);
      }
    }
  }
}
function expansionMatchesGeometry(prev, cur) {
  for (let ci = 0; ci < prev.components.length; ci++) {
    const c = prev.components[ci];
    const e = cur.expansions.get(c.id);
    if (e === void 0) continue;
    const n = cur.components.find((x) => x.id === c.id) ?? cur.components[ci];
    if (n === void 0) return false;
    if (Math.abs(n.compW / c.compW - e.eh) > 1e-9) return false;
    if (Math.abs(n.compH / c.compH - e.ev) > 1e-9) return false;
  }
  return true;
}

// src/extensions/asset-import/decode/jpeg/lossless-pred.ts
function predictLossless(psv, ra, rb, rc) {
  switch (psv) {
    case 1:
      return ra;
    case 2:
      return rb;
    case 3:
      return rc;
    case 4:
      return ra + rb - rc;
    case 5:
      return ra + (rb - rc >> 1);
    case 6:
      return rb + (ra - rc >> 1);
    case 7:
      return ra + rb >> 1;
    default:
      return fail("ASSET.BAD_JPEG", `\u65E0\u635F\u9884\u6D4B\u5668\u9009\u62E9\u503C\u5FC5\u987B\u662F 1..7\uFF0C\u5B9E\u9645 ${psv}`);
  }
}
var LosslessSampleWriter = class {
  constructor(precision, pt, psv, comps) {
    this.psv = psv;
    this.comps = comps;
    this.initial = 1 << precision - pt - 1;
  }
  initial;
  /** 每个分量在当前区间里"第一行"的行号；-1 = 该区间还没落过样本。 */
  firstRow = /* @__PURE__ */ new Map();
  beginInterval() {
    for (const c of this.comps) this.firstRow.set(c, -1);
  }
  /** `diff` 是解出的差分；`x/y` 是分量平面坐标。 */
  write(c, x, y, diff) {
    const plane = c.plane;
    const w = c.compW;
    let rt = this.firstRow.get(c);
    if (rt === -1) {
      rt = y;
      this.firstRow.set(c, y);
    }
    let pred;
    if (y === rt) {
      pred = x === 0 ? this.initial : plane[y * w + x - 1];
    } else if (x === 0) {
      pred = plane[(y - 1) * w + x];
    } else {
      pred = predictLossless(this.psv, plane[y * w + x - 1], plane[(y - 1) * w + x], plane[(y - 1) * w + x - 1]);
    }
    plane[y * w + x] = pred + diff & 65535;
  }
};

// src/extensions/asset-import/decode/jpeg/qm.ts
var QM_QE = new Uint16Array([
  23069,
  9606,
  4372,
  2059,
  984,
  474,
  229,
  111,
  54,
  26,
  13,
  6,
  3,
  1,
  23167,
  16165,
  11506,
  8316,
  6073,
  4482,
  3311,
  2465,
  1839,
  1372,
  1030,
  771,
  576,
  433,
  324,
  245,
  183,
  138,
  104,
  78,
  59,
  44,
  23265,
  18508,
  14861,
  12017,
  9759,
  7987,
  6568,
  5400,
  4471,
  3700,
  3067,
  2552,
  2145,
  1798,
  1485,
  1246,
  1039,
  867,
  724,
  604,
  504,
  420,
  352,
  293,
  246,
  203,
  171,
  143,
  23314,
  19716,
  16684,
  14296,
  12264,
  10556,
  9081,
  7903,
  6825,
  5966,
  5156,
  4508,
  3947,
  3409,
  2998,
  2624,
  22578,
  19740,
  17294,
  15325,
  13550,
  11950,
  10650,
  9494,
  21872,
  19625,
  17625,
  15906,
  14372,
  12980,
  11799,
  22184,
  20294,
  18405,
  16847,
  15421,
  14174,
  21041,
  19471,
  17977,
  16734,
  22055,
  20711,
  19333,
  21911,
  20559,
  23056,
  21794,
  23019,
  23069
]);
var QM_NLPS_RAW = [
  1,
  14,
  16,
  18,
  20,
  23,
  25,
  28,
  30,
  33,
  35,
  9,
  10,
  12,
  15,
  36,
  38,
  39,
  40,
  42,
  43,
  45,
  46,
  48,
  49,
  51,
  52,
  54,
  56,
  57,
  59,
  60,
  62,
  63,
  32,
  33,
  37,
  64,
  65,
  67,
  68,
  69,
  70,
  72,
  73,
  74,
  75,
  77,
  78,
  79,
  48,
  50,
  50,
  51,
  52,
  53,
  54,
  55,
  56,
  57,
  58,
  59,
  61,
  61,
  65,
  80,
  81,
  82,
  83,
  84,
  86,
  87,
  87,
  72,
  72,
  74,
  74,
  75,
  77,
  77,
  80,
  88,
  89,
  90,
  91,
  92,
  93,
  86,
  88,
  95,
  96,
  97,
  99,
  99,
  93,
  95,
  101,
  102,
  103,
  104,
  99,
  105,
  106,
  107,
  103,
  105,
  108,
  109,
  110,
  111,
  110,
  112,
  112,
  113
];
var QM_SWITCH_STATES = [0, 14, 36, 64, 80, 88, 95, 105, 110, 112];
var QM_NLPS = new Uint8Array(114);
for (let i = 0; i < 114; i++) {
  QM_NLPS[i] = QM_NLPS_RAW[i] | (QM_SWITCH_STATES.includes(i) ? 128 : 0);
}
var QM_NMPS = new Uint8Array([
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  13,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  24,
  25,
  26,
  27,
  28,
  29,
  30,
  31,
  32,
  33,
  34,
  35,
  9,
  37,
  38,
  39,
  40,
  41,
  42,
  43,
  44,
  45,
  46,
  47,
  48,
  49,
  50,
  51,
  52,
  53,
  54,
  55,
  56,
  57,
  58,
  59,
  60,
  61,
  62,
  63,
  32,
  65,
  66,
  67,
  68,
  69,
  70,
  71,
  72,
  73,
  74,
  75,
  76,
  77,
  78,
  79,
  48,
  81,
  82,
  83,
  84,
  85,
  86,
  87,
  71,
  89,
  90,
  91,
  92,
  93,
  94,
  86,
  96,
  97,
  98,
  99,
  100,
  93,
  102,
  103,
  104,
  99,
  106,
  107,
  103,
  109,
  107,
  111,
  109,
  111,
  113
]);
var FIXED_BIN_STATE = 113;
var DC_STAT_BINS = 64;
var AC_STAT_BINS = 256;
function newStats(size) {
  return new Uint8Array(size);
}
var QmDecoder = class {
  constructor(data, start, end) {
    this.data = data;
    this.end = end;
    this.pos = start;
  }
  c = 0;
  a = 0;
  ct = -16;
  // -16 ⇒ 先读 2 个字节把 C 填满
  pos;
  stalled = false;
  /** 熵数据里是否撞到了标记（预切分与数据不一致 / 扫描提前结束）。 */
  get hitMarker() {
    return this.stalled;
  }
  nextByte() {
    if (this.stalled || this.pos >= this.end) {
      this.stalled = true;
      return 0;
    }
    let data = this.data[this.pos++];
    if (data === 255) {
      do {
        if (this.pos >= this.end) {
          this.stalled = true;
          return 0;
        }
        data = this.data[this.pos++];
      } while (data === 255);
      if (data === 0) {
        data = 255;
      } else {
        this.stalled = true;
        return 0;
      }
    }
    return data;
  }
  /**
   * 解一位。
   *
   * ★ 重归一化必须**在**解码之前跑（Annex D.2.6 / 图 D.2）：A 小于 0x8000 时
   *   先把 A、C 左移并补入新字节，再拿 A 与 Qe 比。写成"解码后再归一化"也能跑，
   *   但 `ct` 的进位时机差一个字节，整条流会从某个符号起全错。
   */
  decode(stats, at) {
    while (this.a < 32768) {
      if (--this.ct < 0) {
        const data = this.nextByte();
        this.c = (this.c << 8 | data) >>> 0;
        this.ct += 8;
        if (this.ct < 0) {
          this.ct++;
          if (this.ct === 0) this.a = 32768;
        }
      }
      this.a <<= 1;
    }
    let sv = stats[at];
    const qe = QM_QE[sv & 127];
    const nl = QM_NLPS[sv & 127];
    const nm = QM_NMPS[sv & 127];
    const temp = this.a - qe;
    this.a = temp;
    const shifted = this.ct >= 0 ? temp << this.ct >>> 0 : temp >>> -this.ct >>> 0;
    if (this.c >= shifted) {
      this.c = this.c - shifted >>> 0;
      if (this.a < qe) {
        this.a = qe;
        stats[at] = sv & 128 ^ nm;
      } else {
        this.a = qe;
        stats[at] = sv & 128 ^ nl;
        sv ^= 128;
      }
    } else if (this.a < 32768) {
      if (this.a < qe) {
        stats[at] = sv & 128 ^ nl;
        sv ^= 128;
      } else {
        stats[at] = sv & 128 ^ nm;
      }
    }
    return sv >> 7;
  }
};

// src/extensions/asset-import/decode/jpeg/scan-common.ts
function readScanHeader(bytes, dataStart, dataLen, frame) {
  if (dataLen < 1) fail("ASSET.BAD_JPEG", "SOS \u6BB5\u4E3A\u7A7A");
  const ns = bytes[dataStart];
  if (ns < 1 || ns > 4) fail("ASSET.BAD_JPEG", `SOS \u58F0\u660E\u4E86 ${ns} \u4E2A\u5206\u91CF\uFF081..4\uFF09`);
  if (dataLen < 1 + ns * 2 + 3) fail("ASSET.BAD_JPEG", "SOS \u6BB5\u88AB\u622A\u65AD");
  const comps = [];
  for (let i = 0; i < ns; i++) {
    const at2 = dataStart + 1 + i * 2;
    const id = bytes[at2];
    const tables = bytes[at2 + 1];
    const c = frame.components.find((x) => x.id === id);
    if (c === void 0) {
      fail(
        "ASSET.BAD_JPEG",
        `SOS \u5F15\u7528\u4E86\u5E27\u91CC\u4E0D\u5B58\u5728\u7684\u5206\u91CF id=${id}\uFF08\u5E27\u91CC\u662F ${frame.components.map((x) => x.id).join(",")}\uFF09`
      );
    }
    c.td = tables >> 4;
    c.ta = tables & 15;
    if (c.td > 3 || c.ta > 3) fail("ASSET.BAD_JPEG", `\u5206\u91CF ${id} \u7684\u8868\u53F7\u975E\u6CD5`);
    if (!comps.includes(c)) comps.push(c);
  }
  const at = dataStart + 1 + ns * 2;
  return {
    comps,
    ss: bytes[at],
    se: bytes[at + 1],
    ah: bytes[at + 2] >> 4,
    al: bytes[at + 2] & 15,
    entropyStart: dataStart + dataLen
  };
}
function splitEntropy(bytes, start) {
  const ranges = [];
  let segStart = start;
  let i = start;
  while (i + 1 < bytes.length) {
    if (bytes[i] !== 255) {
      i++;
      continue;
    }
    const m = bytes[i + 1];
    if (m === 0) {
      i += 2;
      continue;
    }
    if (m === 255) {
      i += 1;
      continue;
    }
    if (m >= 208 && m <= 215) {
      ranges.push([segStart, i]);
      i += 2;
      segStart = i;
      continue;
    }
    break;
  }
  ranges.push([segStart, i]);
  return { ranges, next: i };
}
function expectIntervals(found, restartInterval, totalMcus) {
  const expected = restartInterval > 0 ? Math.ceil(totalMcus / restartInterval) : 1;
  if (found !== expected) {
    fail(
      "ASSET.BAD_JPEG",
      `\u91CD\u542F\u533A\u95F4\u6570\u4E0D\u7B26\uFF1A\u71B5\u6570\u636E\u91CC\u627E\u5230 ${found} \u6BB5\uFF0C\u6309 DRI=${restartInterval} \u4E0E ${totalMcus} \u4E2A MCU \u5E94\u4E3A ${expected} \u6BB5\uFF08RST \u6807\u8BB0\u7F3A\u5931/\u591A\u4F59\u4F1A\u8BA9 DC \u9884\u6D4B\u5668\u9519\u4F4D\uFF0C\u89E3\u51FA\u7684\u56FE\u4E0D\u4F1A\u62A5\u9519\u4F46\u4F1A\u82B1\uFF09`
    );
  }
}
function scanGeometry(frame, comps, interleaved) {
  if (interleaved) {
    const maxH = Math.max(...frame.components.map((c2) => c2.h));
    const maxV = Math.max(...frame.components.map((c2) => c2.v));
    if (frame.lossless) {
      const mcusX2 = Math.ceil(frame.width / maxH);
      const mcusY2 = Math.ceil(frame.height / maxV);
      return { interleaved, mcusX: mcusX2, mcusY: mcusY2, totalMcus: mcusX2 * mcusY2 };
    }
    const mcusX = Math.ceil(frame.width / (8 * maxH));
    const mcusY = Math.ceil(frame.height / (8 * maxV));
    return { interleaved, mcusX, mcusY, totalMcus: mcusX * mcusY };
  }
  const c = comps[0];
  return {
    interleaved,
    mcusX: c.blocksW,
    mcusY: c.blocksH,
    // 非交错扫描按"数据单元"遍历：有损是 8×8 块，无损是单个样本
    totalMcus: frame.lossless ? c.compW * c.compH : c.blocksW * c.blocksH
  };
}

// src/extensions/asset-import/decode/jpeg/scan-arith.ts
function decodeArithScan(bytes, dataStart, dataLen, frame, restartInterval) {
  const head = readScanHeader(bytes, dataStart, dataLen, frame);
  const { ss, se, ah, al } = head;
  const progressive = frame.progressive;
  const lossless = frame.lossless;
  if (lossless) {
    if (ss < 1 || ss > 7) fail("ASSET.BAD_JPEG", `\u65E0\u635F\u626B\u63CF\u7684\u9884\u6D4B\u5668\u9009\u62E9\u503C\u5FC5\u987B\u662F 1..7\uFF08Ss\uFF09\uFF0C\u5B9E\u9645 ${ss}`);
    if (se !== 0) fail("ASSET.BAD_JPEG", `\u65E0\u635F\u626B\u63CF\u7684 Se \u5FC5\u987B\u662F 0\uFF0C\u5B9E\u9645 ${se}`);
    if (ah !== 0) fail("ASSET.BAD_JPEG", `\u65E0\u635F\u626B\u63CF\u7684 Ah \u5FC5\u987B\u662F 0\uFF0C\u5B9E\u9645 ${ah}`);
    if (al >= frame.precision) {
      fail("ASSET.BAD_JPEG", `\u65E0\u635F\u626B\u63CF\u7684\u70B9\u53D8\u6362 Pt=${al} \u5FC5\u987B\u5C0F\u4E8E\u7CBE\u5EA6 ${frame.precision}`);
    }
    frame.pt = al;
  } else if (progressive) {
    if (ss > se || se > 63) fail("ASSET.BAD_JPEG", `\u6E10\u8FDB\u5F0F\u626B\u63CF\u7684\u8C31\u6BB5\u975E\u6CD5\uFF1ASs=${ss} Se=${se}`);
    if (ss === 0 && se !== 0) fail("ASSET.BAD_JPEG", "DC \u626B\u63CF\uFF08Ss=0\uFF09\u5FC5\u987B Se=0");
    if (ss > 0 && head.comps.length !== 1) fail("ASSET.BAD_JPEG", "AC \u626B\u63CF\uFF08Ss>0\uFF09\u5FC5\u987B\u662F\u5355\u5206\u91CF\u626B\u63CF");
    if (al > 13 || ah > 13) fail("ASSET.BAD_JPEG", `\u6E10\u8FDB\u5F0F\u9010\u6B21\u903C\u8FD1\u4F4D\u6570\u975E\u6CD5\uFF1AAl=${al} Ah=${ah}`);
    if (ah !== 0 && ah !== al + 1) {
      fail("ASSET.BAD_JPEG", `\u6E10\u8FDB\u5F0F\u903C\u8FD1\u53C2\u6570\u4E0D\u8FDE\u7EED\uFF1AAh=${ah} Al=${al}\uFF08\u8981\u6C42 Ah = Al+1\uFF09`);
    }
  } else {
    if (ss !== 0 || se !== 63) fail("ASSET.BAD_JPEG", `\u987A\u5E8F\u5F0F\u626B\u63CF\u7684 Ss/Se \u5FC5\u987B\u662F 0/63\uFF0C\u5B9E\u9645 ${ss}/${se}`);
    if (ah !== 0 || al !== 0) fail("ASSET.BAD_JPEG", `\u987A\u5E8F\u5F0F\u626B\u63CF\u7684 Ah/Al \u5FC5\u987B\u662F 0/0\uFF0C\u5B9E\u9645 ${ah}/${al}`);
  }
  const interleaved = head.comps.length > 1;
  const geo = scanGeometry(frame, head.comps, interleaved);
  const split = splitEntropy(bytes, head.entropyStart);
  expectIntervals(split.ranges.length, restartInterval, geo.totalMcus);
  const fixed = new Uint8Array([FIXED_BIN_STATE]);
  let dcStats = [null, null, null, null];
  let acStats = [null, null, null, null];
  const lastDc = /* @__PURE__ */ new Map();
  const dcContext = /* @__PURE__ */ new Map();
  let reader = null;
  let currentInterval = -1;
  const writer = lossless ? new LosslessSampleWriter(frame.precision, al, ss, head.comps) : null;
  const beginInterval = (idx) => {
    const r = split.ranges[idx];
    reader = new QmDecoder(bytes, r[0], r[1]);
    dcStats = [null, null, null, null];
    acStats = [null, null, null, null];
    for (const c of head.comps) {
      if (!progressive || ss === 0 && ah === 0) {
        dcStats[c.td] = newStats(DC_STAT_BINS);
        lastDc.set(c, 0);
        dcContext.set(c, 0);
      }
      if (!progressive || se !== 0) {
        acStats[c.ta] = newStats(AC_STAT_BINS);
      }
    }
    writer?.beginInterval();
  };
  const dec = (stats, at) => reader.decode(stats, at);
  const dcStatsOf = (c) => {
    const s = dcStats[c.td];
    if (s === null || s === void 0) {
      fail("ASSET.BAD_JPEG", `\u5206\u91CF ${c.id} \u9700\u8981\u7B97\u672F DC \u8868 ${c.td}\uFF0C\u4F46\u7EDF\u8BA1\u533A\u6CA1\u6709\u5EFA\u7ACB\uFF08\u626B\u63CF\u53C2\u6570\u81EA\u76F8\u77DB\u76FE\uFF09`);
    }
    return s;
  };
  const acStatsOf = (c) => {
    const s = acStats[c.ta];
    if (s === null || s === void 0) {
      fail("ASSET.BAD_JPEG", `\u5206\u91CF ${c.id} \u9700\u8981\u7B97\u672F AC \u8868 ${c.ta}\uFF0C\u4F46\u7EDF\u8BA1\u533A\u6CA1\u6709\u5EFA\u7ACB\uFF08\u626B\u63CF\u53C2\u6570\u81EA\u76F8\u77DB\u76FE\uFF09`);
    }
    return s;
  };
  const decodeDiff = (c, st, ctx) => {
    if (dec(st, ctx) === 0) return { diff: 0, ctx: 0 };
    const sign = dec(st, ctx + 1);
    let at = ctx + 2 + sign;
    let m = dec(st, at);
    if (m !== 0) {
      at = 20;
      while (dec(st, at) !== 0) {
        m <<= 1;
        if (m === 32768) fail("ASSET.BAD_JPEG", "\u7B97\u672F\u7F16\u7801\u7684 DC \u5E45\u5EA6\u7C7B\u522B\u6EA2\u51FA\uFF08\u2265 0x8000\uFF09");
        at += 1;
      }
    }
    const cond = frame.dcCond[c.td] ?? { l: 0, u: 1 };
    const nextCtx = m < 1 << cond.l >> 1 ? 0 : m > 1 << cond.u >> 1 ? 12 + sign * 4 : 4 + sign * 4;
    let v = m;
    at += 14;
    while ((m >>= 1) !== 0) {
      if (dec(st, at) !== 0) v |= m;
    }
    v += 1;
    return { diff: sign !== 0 ? -v : v, ctx: nextCtx };
  };
  const decodeSequentialBlock = (c, bo) => {
    const st = dcStatsOf(c);
    const r = decodeDiff(c, st, dcContext.get(c));
    dcContext.set(c, r.ctx);
    lastDc.set(c, lastDc.get(c) + r.diff);
    c.coefs[bo] = lastDc.get(c) << 16 >> 16;
    const ac = acStatsOf(c);
    const K = frame.acCond[c.ta] ?? 5;
    for (let k = 1; k <= 63; k++) {
      let at = 3 * (k - 1);
      if (dec(ac, at) !== 0) break;
      while (dec(ac, at + 1) === 0) {
        at += 3;
        k++;
        if (k > 63) fail("ASSET.BAD_JPEG", "\u7B97\u672F AC \u7CFB\u6570\u8D8A\u8FC7\u5757\u5C3E\uFF08\u9891\u8C31\u6EA2\u51FA\uFF09");
      }
      const sign = dec(fixed, 0);
      at += 2;
      let m = dec(ac, at);
      if (m !== 0) {
        if (dec(ac, at) !== 0) {
          m <<= 1;
          at = k <= K ? 189 : 217;
          while (dec(ac, at) !== 0) {
            m <<= 1;
            if (m === 32768) fail("ASSET.BAD_JPEG", "\u7B97\u672F\u7F16\u7801\u7684 AC \u5E45\u5EA6\u7C7B\u522B\u6EA2\u51FA\uFF08\u2265 0x8000\uFF09");
            at += 1;
          }
        }
      }
      let v = m;
      at += 14;
      while ((m >>= 1) !== 0) {
        if (dec(ac, at) !== 0) v |= m;
      }
      v += 1;
      c.coefs[bo + ZIGZAG[k]] = sign !== 0 ? -v : v;
    }
  };
  const decodeDcFirst = (c, bo) => {
    const st = dcStatsOf(c);
    const r = decodeDiff(c, st, dcContext.get(c));
    dcContext.set(c, r.ctx);
    lastDc.set(c, lastDc.get(c) + r.diff);
    c.coefs[bo] = lastDc.get(c) << 16 >> 16 << al;
  };
  const decodeDcRefine = (c, bo) => {
    if (dec(fixed, 0) !== 0) c.coefs[bo] = c.coefs[bo] | 1 << al;
  };
  const decodeAcFirst = (c, bo) => {
    const ac = acStatsOf(c);
    const K = frame.acCond[c.ta] ?? 5;
    for (let k = ss; k <= se; k++) {
      let at = 3 * (k - 1);
      if (dec(ac, at) !== 0) break;
      while (dec(ac, at + 1) === 0) {
        at += 3;
        k++;
        if (k > se) fail("ASSET.BAD_JPEG", `\u7B97\u672F\u6E10\u8FDB AC \u8D8A\u8FC7\u8C31\u6BB5\u672B\u7AEF\uFF08k>Se=${se}\uFF09`);
      }
      const sign = dec(fixed, 0);
      at += 2;
      let m = dec(ac, at);
      if (m !== 0) {
        if (dec(ac, at) !== 0) {
          m <<= 1;
          at = k <= K ? 189 : 217;
          while (dec(ac, at) !== 0) {
            m <<= 1;
            if (m === 32768) fail("ASSET.BAD_JPEG", "\u7B97\u672F\u7F16\u7801\u7684 AC \u5E45\u5EA6\u7C7B\u522B\u6EA2\u51FA\uFF08\u2265 0x8000\uFF09");
            at += 1;
          }
        }
      }
      let v = m;
      at += 14;
      while ((m >>= 1) !== 0) {
        if (dec(ac, at) !== 0) v |= m;
      }
      v += 1;
      c.coefs[bo + ZIGZAG[k]] = (sign !== 0 ? -v : v) << al;
    }
  };
  const decodeAcRefine = (c, bo) => {
    const ac = acStatsOf(c);
    const p1 = 1 << al;
    const m1 = -p1;
    let kex = se;
    while (kex > 0 && c.coefs[bo + ZIGZAG[kex]] === 0) kex--;
    for (let k = ss; k <= se; k++) {
      let at = 3 * (k - 1);
      if (k > kex && dec(ac, at) !== 0) break;
      for (; ; ) {
        const pos = bo + ZIGZAG[k];
        const cur = c.coefs[pos];
        if (cur !== 0) {
          if (dec(ac, at + 2) !== 0) c.coefs[pos] = cur + (cur < 0 ? m1 : p1);
          break;
        }
        if (dec(ac, at + 1) !== 0) {
          c.coefs[pos] = dec(fixed, 0) !== 0 ? m1 : p1;
          break;
        }
        at += 3;
        k++;
        if (k > se) fail("ASSET.BAD_JPEG", `\u7B97\u672F AC \u7CBE\u4FEE\u8D8A\u8FC7\u8C31\u6BB5\u672B\u7AEF\uFF08k>Se=${se}\uFF09`);
      }
    }
  };
  for (let mcu = 0; mcu < geo.totalMcus; mcu++) {
    const intervalIdx = restartInterval > 0 ? Math.floor(mcu / restartInterval) : 0;
    if (reader === null || intervalIdx !== currentInterval) {
      currentInterval = intervalIdx;
      beginInterval(intervalIdx);
    }
    if (lossless) {
      if (interleaved) {
        const mcuX = mcu % geo.mcusX;
        const mcuY = Math.floor(mcu / geo.mcusX);
        for (const c of head.comps) {
          for (let vy = 0; vy < c.v; vy++) {
            const y = mcuY * c.v + vy;
            if (y >= c.compH) continue;
            for (let hx = 0; hx < c.h; hx++) {
              const x = mcuX * c.h + hx;
              if (x >= c.compW) continue;
              const st = dcStatsOf(c);
              const r = decodeDiff(c, st, dcContext.get(c));
              dcContext.set(c, r.ctx);
              writer.write(c, x, y, r.diff);
            }
          }
        }
      } else {
        const c = head.comps[0];
        const st = dcStatsOf(c);
        const r = decodeDiff(c, st, dcContext.get(c));
        dcContext.set(c, r.ctx);
        writer.write(c, mcu % c.compW, Math.floor(mcu / c.compW), r.diff);
      }
      continue;
    }
    const blockAt = (c, blockX, blockY) => (blockY * c.strideBlocksW + blockX) * 64;
    const decodeBlock = (c, bo) => {
      if (!progressive) decodeSequentialBlock(c, bo);
      else if (ss === 0) {
        if (ah === 0) decodeDcFirst(c, bo);
        else decodeDcRefine(c, bo);
      } else if (ah === 0) decodeAcFirst(c, bo);
      else decodeAcRefine(c, bo);
    };
    if (interleaved) {
      const mcuX = mcu % geo.mcusX;
      const mcuY = Math.floor(mcu / geo.mcusX);
      for (const c of head.comps) {
        for (let by = 0; by < c.v; by++) {
          for (let bx = 0; bx < c.h; bx++) {
            decodeBlock(c, blockAt(c, mcuX * c.h + bx, mcuY * c.v + by));
          }
        }
      }
    } else {
      const c = head.comps[0];
      decodeBlock(c, blockAt(c, mcu % c.blocksW, Math.floor(mcu / c.blocksW)));
    }
  }
  return split.next;
}

// src/extensions/asset-import/decode/jpeg/scan-lossless.ts
function decodeLosslessScan(bytes, dataStart, dataLen, frame, dcTables, restartInterval) {
  const head = readScanHeader(bytes, dataStart, dataLen, frame);
  const psv = head.ss;
  if (psv < 1 || psv > 7) {
    fail("ASSET.BAD_JPEG", `\u65E0\u635F\u626B\u63CF\u7684\u9884\u6D4B\u5668\u9009\u62E9\u503C\u5FC5\u987B\u662F 1..7\uFF08Ss\uFF09\uFF0C\u5B9E\u9645 ${psv}`);
  }
  if (head.se !== 0) fail("ASSET.BAD_JPEG", `\u65E0\u635F\u626B\u63CF\u7684 Se \u5FC5\u987B\u662F 0\uFF0C\u5B9E\u9645 ${head.se}`);
  if (head.ah !== 0) fail("ASSET.BAD_JPEG", `\u65E0\u635F\u626B\u63CF\u7684 Ah \u5FC5\u987B\u662F 0\uFF0C\u5B9E\u9645 ${head.ah}`);
  const al = head.al;
  if (al >= frame.precision) {
    fail("ASSET.BAD_JPEG", `\u65E0\u635F\u626B\u63CF\u7684\u70B9\u53D8\u6362 Pt=${al} \u5FC5\u987B\u5C0F\u4E8E\u7CBE\u5EA6 ${frame.precision}`);
  }
  frame.pt = al;
  const interleaved = head.comps.length > 1;
  const geo = scanGeometry(frame, head.comps, interleaved);
  const split = splitEntropy(bytes, head.entropyStart);
  expectIntervals(split.ranges.length, restartInterval, geo.totalMcus);
  const writer = new LosslessSampleWriter(frame.precision, al, psv, head.comps);
  let reader = null;
  let currentInterval = -1;
  const beginInterval = (idx) => {
    const r = split.ranges[idx];
    reader = new BitReader(bytes, r[0], r[1]);
    writer.beginInterval();
  };
  const dcTable = (c) => {
    const t = dcTables[c.td] ?? null;
    if (t === null) fail("ASSET.BAD_JPEG", `\u5206\u91CF ${c.id} \u9700\u8981 DC \u54C8\u592B\u66FC\u8868 ${c.td}\uFF0C\u4F46\u6587\u4EF6\u91CC\u6CA1\u6709\u5B9A\u4E49\uFF08DHT \u7F3A\u5931\uFF09`);
    return t;
  };
  const writeSample = (c, x, y) => {
    const r = reader;
    const s = dcTable(c).decode(r);
    if (s > 16) fail("ASSET.BAD_JPEG", `\u65E0\u635F\u5DEE\u5206\u7684\u7C7B\u522B\u4F4D\u6570 ${s} \u8D85\u8FC7 16`);
    writer.write(c, x, y, extend(r.receive(s), s));
  };
  for (let mcu = 0; mcu < geo.totalMcus; mcu++) {
    const intervalIdx = restartInterval > 0 ? Math.floor(mcu / restartInterval) : 0;
    if (reader === null || intervalIdx !== currentInterval) {
      currentInterval = intervalIdx;
      beginInterval(intervalIdx);
    }
    if (interleaved) {
      const mcuX = mcu % geo.mcusX;
      const mcuY = Math.floor(mcu / geo.mcusX);
      for (const c of head.comps) {
        for (let vy = 0; vy < c.v; vy++) {
          const y = mcuY * c.v + vy;
          if (y >= c.compH) continue;
          for (let hx = 0; hx < c.h; hx++) {
            const x = mcuX * c.h + hx;
            if (x >= c.compW) continue;
            writeSample(c, x, y);
          }
        }
      }
    } else {
      const c = head.comps[0];
      writeSample(c, mcu % c.compW, Math.floor(mcu / c.compW));
    }
  }
  return split.next;
}

// src/extensions/asset-import/decode/jpeg/scan-huffman.ts
function decodeScan(bytes, dataStart, dataLen, frame, dcTables, acTables, restartInterval) {
  const head = readScanHeader(bytes, dataStart, dataLen, frame);
  const scanComps = head.comps;
  const { ss, se, ah, al } = head;
  const progressive = frame.progressive;
  if (!progressive) {
    if (ss !== 0 || se !== 63) {
      fail("ASSET.BAD_JPEG", `\u987A\u5E8F\u5F0F\u626B\u63CF\u7684 Ss/Se \u5FC5\u987B\u662F 0/63\uFF0C\u5B9E\u9645 ${ss}/${se}`);
    }
    if (ah !== 0 || al !== 0) {
      fail("ASSET.BAD_JPEG", `\u987A\u5E8F\u5F0F\u626B\u63CF\u7684 Ah/Al \u5FC5\u987B\u662F 0/0\uFF0C\u5B9E\u9645 ${ah}/${al}`);
    }
  } else {
    if (ss > se || se > 63) fail("ASSET.BAD_JPEG", `\u6E10\u8FDB\u5F0F\u626B\u63CF\u7684\u8C31\u6BB5\u975E\u6CD5\uFF1ASs=${ss} Se=${se}`);
    if (ss === 0 && se !== 0) fail("ASSET.BAD_JPEG", "DC \u626B\u63CF\uFF08Ss=0\uFF09\u5FC5\u987B Se=0");
    if (ss > 0 && scanComps.length !== 1) fail("ASSET.BAD_JPEG", "AC \u626B\u63CF\uFF08Ss>0\uFF09\u5FC5\u987B\u662F\u5355\u5206\u91CF\u626B\u63CF");
    if (al > 13 || ah > 13) fail("ASSET.BAD_JPEG", `\u6E10\u8FDB\u5F0F\u9010\u6B21\u903C\u8FD1\u4F4D\u6570\u975E\u6CD5\uFF1AAl=${al} Ah=${ah}`);
    if (ah !== 0 && ah !== al + 1) {
      fail("ASSET.BAD_JPEG", `\u6E10\u8FDB\u5F0F\u903C\u8FD1\u53C2\u6570\u4E0D\u8FDE\u7EED\uFF1AAh=${ah} Al=${al}\uFF08\u8981\u6C42 Ah = Al+1\uFF09`);
    }
  }
  const interleaved = scanComps.length > 1;
  const geo = scanGeometry(frame, scanComps, interleaved);
  const split = splitEntropy(bytes, head.entropyStart);
  expectIntervals(split.ranges.length, restartInterval, geo.totalMcus);
  const maxDcCategory = frame.precision > 8 ? 15 : 11;
  let reader = null;
  let currentInterval = -1;
  const state = { eobrun: 0 };
  const refine = { state: 0, next: 0, eobrun: 0 };
  const beginInterval = (idx) => {
    const r = split.ranges[idx];
    reader = new BitReader(bytes, r[0], r[1]);
    state.eobrun = 0;
    refine.state = 0;
    refine.next = 0;
    refine.eobrun = 0;
    for (const c of scanComps) c.pred = 0;
  };
  const huff = (table, kind, compId) => {
    if (table === null) {
      fail("ASSET.BAD_JPEG", `\u5206\u91CF ${compId} \u9700\u8981 ${kind} \u54C8\u592B\u66FC\u8868\uFF0C\u4F46\u6587\u4EF6\u91CC\u6CA1\u6709\u5B9A\u4E49\uFF08DHT \u7F3A\u5931\uFF09`);
    }
    return table;
  };
  const decodeSequentialBlock = (c, bo) => {
    const r = reader;
    const dc = huff(dcTables[c.td] ?? null, "DC", c.id);
    const ac = huff(acTables[c.ta] ?? null, "AC", c.id);
    const s = dc.decode(r);
    if (s > maxDcCategory) {
      fail("ASSET.BAD_JPEG", `DC \u5DEE\u5206\u4F4D\u6570 ${s} \u8D85\u8FC7 ${maxDcCategory}\uFF08${frame.precision} \u4F4D\u6837\u672C\u7684\u4E0A\u9650\uFF09`);
    }
    c.pred += extend(r.receive(s), s);
    c.coefs[bo] = c.pred;
    let k = 1;
    while (k < 64) {
      const rs = ac.decode(r);
      const run = rs >> 4;
      const size = rs & 15;
      if (size === 0) {
        if (run === 15) {
          k += 16;
          continue;
        }
        break;
      }
      k += run;
      if (k > 63) fail("ASSET.BAD_JPEG", `AC \u7CFB\u6570\u8D8A\u8FC7\u5757\u5C3E\uFF1Ak=${k}\uFF08run=${run}\uFF09`);
      c.coefs[bo + ZIGZAG[k]] = extend(r.receive(size), size);
      k++;
    }
  };
  const decodeProgressiveDc = (c, bo) => {
    const r = reader;
    if (ah === 0) {
      const dc = huff(dcTables[c.td] ?? null, "DC", c.id);
      const s = dc.decode(r);
      if (s > maxDcCategory) {
        fail("ASSET.BAD_JPEG", `DC \u5DEE\u5206\u4F4D\u6570 ${s} \u8D85\u8FC7 ${maxDcCategory}\uFF08${frame.precision} \u4F4D\u6837\u672C\u7684\u4E0A\u9650\uFF09`);
      }
      c.pred += extend(r.receive(s), s);
      c.coefs[bo] = c.pred << al;
    } else {
      if (r.readBit() === 1) c.coefs[bo] = c.coefs[bo] | 1 << al;
    }
  };
  const decodeProgressiveAcFirst = (c, bo) => {
    const r = reader;
    if (state.eobrun > 0) {
      state.eobrun--;
      return;
    }
    const ac = huff(acTables[c.ta] ?? null, "AC", c.id);
    let k = ss;
    while (k <= se) {
      const rs = ac.decode(r);
      const run = rs >> 4;
      const size = rs & 15;
      if (size === 0) {
        if (run < 15) {
          state.eobrun = (1 << run) - 1;
          if (run > 0) state.eobrun += r.receive(run);
          break;
        }
        k += 16;
        continue;
      }
      k += run;
      if (k > 63) fail("ASSET.BAD_JPEG", `\u6E10\u8FDB AC \u7CFB\u6570\u8D8A\u8FC7\u5757\u5C3E\uFF1Ak=${k}`);
      c.coefs[bo + ZIGZAG[k]] = extend(r.receive(size), size) << al;
      k++;
    }
  };
  const decodeProgressiveAcRefine = (c, bo) => {
    const r = reader;
    const p1 = 1 << al;
    const st = refine;
    let k = ss;
    let run = 0;
    while (k <= se) {
      const pos = bo + ZIGZAG[k];
      const cur = c.coefs[pos];
      const dir = cur < 0 ? -1 : 1;
      switch (st.state) {
        case 0: {
          const rs = huff(acTables[c.ta] ?? null, "AC", c.id).decode(r);
          const size = rs & 15;
          run = rs >> 4;
          if (size === 0) {
            if (run < 15) {
              st.eobrun = (1 << run) + (run > 0 ? r.receive(run) : 0);
              st.state = 4;
            } else {
              run = 16;
              st.state = 1;
            }
          } else {
            if (size !== 1) fail("ASSET.BAD_JPEG", `\u6E10\u8FDB AC \u7CBE\u4FEE\u91CC\u51FA\u73B0\u4E86 size=${size}\uFF08\u89C4\u8303\u53EA\u5141\u8BB8 1\uFF09`);
            st.next = r.readBit() === 1 ? 1 : -1;
            st.state = run > 0 ? 2 : 3;
          }
          continue;
        }
        case 1:
        case 2:
          if (cur !== 0) {
            if (r.readBit() === 1 && (cur & p1) === 0) c.coefs[pos] = cur + p1 * dir;
          } else {
            run--;
            if (run === 0) st.state = st.state === 2 ? 3 : 0;
          }
          break;
        case 3:
          if (cur !== 0) {
            if (r.readBit() === 1 && (cur & p1) === 0) c.coefs[pos] = cur + p1 * dir;
          } else {
            c.coefs[pos] = st.next * p1;
            st.state = 0;
          }
          break;
        default:
          if (cur !== 0 && r.readBit() === 1 && (cur & p1) === 0) c.coefs[pos] = cur + p1 * dir;
          break;
      }
      k++;
    }
    if (st.state === 4) {
      st.eobrun--;
      if (st.eobrun <= 0) st.state = 0;
    }
  };
  for (let mcu = 0; mcu < geo.totalMcus; mcu++) {
    const intervalIdx = restartInterval > 0 ? Math.floor(mcu / restartInterval) : 0;
    if (intervalIdx !== currentInterval) {
      currentInterval = intervalIdx;
      beginInterval(intervalIdx);
    }
    if (interleaved) {
      const mcuX = mcu % geo.mcusX;
      const mcuY = Math.floor(mcu / geo.mcusX);
      for (const c of scanComps) {
        for (let by = 0; by < c.v; by++) {
          for (let bx = 0; bx < c.h; bx++) {
            const blockX = mcuX * c.h + bx;
            const blockY = mcuY * c.v + by;
            const bo = (blockY * c.strideBlocksW + blockX) * 64;
            if (progressive) {
              if (ss === 0) decodeProgressiveDc(c, bo);
              else if (ah === 0) decodeProgressiveAcFirst(c, bo);
              else decodeProgressiveAcRefine(c, bo);
            } else {
              decodeSequentialBlock(c, bo);
            }
          }
        }
      }
    } else {
      const c = scanComps[0];
      const bx = mcu % c.blocksW;
      const by = Math.floor(mcu / c.blocksW);
      const bo = (by * c.strideBlocksW + bx) * 64;
      if (progressive) {
        if (ss === 0) decodeProgressiveDc(c, bo);
        else if (ah === 0) decodeProgressiveAcFirst(c, bo);
        else decodeProgressiveAcRefine(c, bo);
      } else {
        decodeSequentialBlock(c, bo);
      }
    }
  }
  return split.next;
}

// src/extensions/asset-import/decode/jpeg/parse.ts
var MARKER_DHT = 196;
var MARKER_SOI = 216;
var MARKER_EOI = 217;
var MARKER_SOS = 218;
var MARKER_DQT = 219;
var MARKER_DRI = 221;
var MARKER_DHP = 222;
var MARKER_EXP = 223;
var MARKER_APP0 = 224;
var MARKER_APP1 = 225;
var MARKER_APP14 = 238;
var MARKER_DAC = 204;
function parse(bytes, maxPixels) {
  if (bytes.length < 2 || bytes[0] !== 255 || bytes[1] !== MARKER_SOI) {
    fail("ASSET.BAD_JPEG", `\u7F3A\u5C11 SOI\uFF08FF D8\uFF09\uFF0C\u5B9E\u9645\u5F00\u5934 ${hex(bytes, 0, Math.min(4, bytes.length))}`);
  }
  const frames = [];
  let current = null;
  const qt = [null, null, null, null];
  const dcTables = [null, null, null, null];
  const acTables = [null, null, null, null];
  const dcCond = [
    { l: 0, u: 1 },
    { l: 0, u: 1 },
    { l: 0, u: 1 },
    { l: 0, u: 1 }
  ];
  const acCond = [5, 5, 5, 5];
  let restartInterval = 0;
  let adobeTransform = null;
  let orientation = 1;
  let scanCount = 0;
  let sawEoi = false;
  let hierarchical = false;
  let pendingExp = /* @__PURE__ */ new Map();
  let sequenceHeader = null;
  const finishFrame = () => {
    if (current === null) return;
    if (current.scanCount === 0) {
      fail("ASSET.BAD_JPEG", `\u7B2C ${current.index + 1} \u5E27\u6CA1\u6709\u4EFB\u4F55\u626B\u63CF\uFF08\u53EA\u6709 SOF \u6CA1\u6709 SOS\uFF09`);
    }
    current.restartInterval = restartInterval;
    current.adobeTransform = adobeTransform;
    const prev = frames.length > 0 ? frames[frames.length - 1] : null;
    if (current.differential && prev === null) {
      fail("ASSET.BAD_JPEG", `\u7B2C 1 \u5E27\u5C31\u662F\u5DEE\u5206\u5E27\uFF08SOF0x${current.sof.toString(16)}\uFF09\uFF0C\u6CA1\u6709\u53C2\u8003\u5E27\u53EF\u4EE5\u76F8\u51CF`);
    }
    const cur = current;
    if (cur.differential && prev !== null && cur.expansions.size > 0) {
      if (!expansionMatchesGeometry(prev, cur)) {
        const detail = [...cur.expansions].map(([id, e]) => {
          const c = cur.components.find((x) => x.id === id);
          const p = prev.components.find((x) => x.id === id) ?? prev.components[0];
          const rw = c === void 0 ? 0 : c.compW / p.compW;
          const rh = c === void 0 ? 0 : c.compH / p.compH;
          return `${id}: EXP ${e.eh}\xD7${e.ev} vs \u51E0\u4F55 ${rw.toFixed(2)}\xD7${rh.toFixed(2)}`;
        }).join("\uFF0C");
        fail(
          "ASSET.BAD_JPEG",
          `\u5206\u5C42 JPEG \u7684 EXP \u653E\u5927\u56E0\u5B50\u4E0E\u5B9E\u9645\u51E0\u4F55\u4E0D\u4E00\u81F4\uFF08${detail}\uFF09\uFF1A\u6309 T.81 B.3.3\uFF0CEh/Ev \u5FC5\u987B\u7B49\u4E8E\u53C2\u8003\u5E27\u5230\u672C\u5E27\u7684\u5C3A\u5BF8\u6BD4`
        );
      }
    }
    buildFramePlanes(current);
    if (current.differential && prev !== null) {
      addReferencePlanes(current, prev);
    }
    frames.push(current);
    current = null;
  };
  let pos = 2;
  while (pos + 1 < bytes.length) {
    if (bytes[pos] !== 255) {
      pos++;
      continue;
    }
    const marker = bytes[pos + 1];
    if (marker === 255) {
      pos++;
      continue;
    }
    if (marker === MARKER_EOI) {
      sawEoi = true;
      break;
    }
    if (marker === 1 || marker >= 208 && marker <= 216) {
      pos += 2;
      continue;
    }
    if (pos + 4 > bytes.length) {
      fail("ASSET.BAD_JPEG", `\u6BB5 0x${marker.toString(16)} \u7684\u5934\u88AB\u622A\u65AD\uFF08\u504F\u79FB ${pos}\uFF09`);
    }
    const segLen = u16be(bytes, pos + 2);
    if (segLen < 2) fail("ASSET.BAD_JPEG", `\u6BB5 0x${marker.toString(16)} \u957F\u5EA6\u975E\u6CD5\uFF1A${segLen}`);
    const dataStart = pos + 4;
    const dataLen = segLen - 2;
    if (dataStart + dataLen > bytes.length) {
      fail(
        "ASSET.BAD_JPEG",
        `\u6BB5 0x${marker.toString(16)} \u58F0\u660E ${dataLen} \u5B57\u8282\u6570\u636E\uFF0C\u4F46\u6587\u4EF6\u53EA\u5269 ${bytes.length - dataStart} \u5B57\u8282`
      );
    }
    const seg = bytes.subarray(dataStart, dataStart + dataLen);
    if (marker >= 192 && marker <= 207 && marker !== MARKER_DHT && marker !== 200 && marker !== MARKER_DAC) {
      finishFrame();
      current = parseSof(seg, marker, frames.length, maxPixels);
      if (pendingExp.size > 0) {
        current.expansions = pendingExp;
        const first = pendingExp.values().next();
        if (!first.done) {
          current.expandH = first.value.eh;
          current.expandV = first.value.ev;
        }
        pendingExp = /* @__PURE__ */ new Map();
      }
      if (sequenceHeader !== null) {
        if (current.precision !== sequenceHeader.precision) {
          fail(
            "ASSET.BAD_JPEG",
            `\u5206\u5C42\u5E8F\u5217\u7684\u7CBE\u5EA6\u4E0D\u4E00\u81F4\uFF1ADHP \u58F0\u660E ${sequenceHeader.precision} \u4F4D\uFF0C\u7B2C ${frames.length + 1} \u5E27\u662F ${current.precision} \u4F4D\uFF08T.81 B.3.1 \u8981\u6C42\u6240\u6709\u5E27\u7684\u7CBE\u5EA6\u4E0E DHP \u76F8\u540C\uFF09`
          );
        }
        if (current.width > sequenceHeader.width || current.height > sequenceHeader.height) {
          fail(
            "ASSET.BAD_JPEG",
            `\u7B2C ${frames.length + 1} \u5E27\u5C3A\u5BF8 ${current.width}x${current.height} \u8D85\u8FC7 DHP \u58F0\u660E\u7684 ${sequenceHeader.width}x${sequenceHeader.height}\uFF08DHP \u662F\u5B8C\u6210\u6001\u56FE\u50CF\u5C3A\u5BF8\uFF0C\u5404\u5E27\u4E0D\u5F97\u8D85\u51FA\uFF09`
          );
        }
      }
      current.qt = qt;
      current.dcTables = dcTables;
      current.acTables = acTables;
      current.dcCond = dcCond;
      current.acCond = acCond;
      pos = dataStart + dataLen;
      continue;
    }
    switch (marker) {
      case MARKER_DQT:
        parseDqt(seg, qt);
        break;
      case MARKER_DHT:
        parseDht(seg, dcTables, acTables);
        break;
      case MARKER_DAC:
        parseDac(seg, dcCond, acCond);
        break;
      case MARKER_DRI:
        if (seg.length < 2) fail("ASSET.BAD_JPEG", "DRI \u6BB5\u957F\u5EA6\u4E0D\u8DB3");
        restartInterval = u16be(seg, 0);
        break;
      case MARKER_DHP: {
        if (seg.length < 6) fail("ASSET.BAD_JPEG", "DHP \u6BB5\u957F\u5EA6\u4E0D\u8DB3\uFF08\u81F3\u5C11 6 \u5B57\u8282\uFF1AP/Y/X/Nf\uFF09");
        const nf = seg[5];
        if (nf < 1 || nf > 4) fail("ASSET.BAD_JPEG", `DHP \u58F0\u660E\u4E86 ${nf} \u4E2A\u5206\u91CF\uFF081..4\uFF09`);
        if (seg.length < 6 + nf * 3) fail("ASSET.BAD_JPEG", "DHP \u6BB5\u88AB\u622A\u65AD\uFF08\u5206\u91CF\u5217\u8868\u4E0D\u5B8C\u6574\uFF09");
        for (let i = 0; i < nf; i++) {
          const tq = seg[6 + i * 3 + 2];
          if (tq !== 0) fail("ASSET.BAD_JPEG", `DHP \u7B2C ${i + 1} \u4E2A\u5206\u91CF\u7684\u91CF\u5316\u8868\u9009\u62E9\u5668\u5E94\u4E3A 0\uFF0C\u5B9E\u9645 ${tq}`);
        }
        sequenceHeader = { precision: seg[0], width: u16be(seg, 3), height: u16be(seg, 1) };
        hierarchical = true;
        if (frames.length > 0 || current !== null) {
          fail("ASSET.BAD_JPEG", "DHP \u53EA\u80FD\u51FA\u73B0\u5728\u7B2C\u4E00\u5E27\u4E4B\u524D\uFF08T.81 B.3.2 \u8981\u6C42\u5355\u4E2A DHP \u4E14\u5728\u6700\u524D\uFF09");
        }
        break;
      }
      case MARKER_EXP: {
        if (seg.length < 2) fail("ASSET.BAD_JPEG", "EXP \u6BB5\u957F\u5EA6\u4E0D\u8DB3\uFF08\u81F3\u5C11\u8981 Ci \u4E0E Eh/Ev \u4E24\u4E2A\u5B57\u8282\uFF09");
        if (seg.length % 2 !== 0) {
          fail("ASSET.BAD_JPEG", `EXP \u6BB5\u4F53\u5FC5\u987B\u662F (\u5206\u91CF id, Eh/Ev) \u7684\u6574\u7EC4\uFF0C\u5B9E\u9645 ${seg.length} \u5B57\u8282`);
        }
        if (sequenceHeader === null) {
          fail("ASSET.BAD_JPEG", "EXP \u51FA\u73B0\u5728 DHP \u4E4B\u524D\uFF1AEXP \u53EA\u5BF9\u5206\u5C42\u5E8F\u5217\u7684\u4E0B\u4E00\u5E27\u751F\u6548\uFF0C\u6CA1\u6709 DHP \u5C31\u65E0\u4ECE\u653E\u5927");
        }
        for (let i = 0; i + 1 < seg.length; i += 2) {
          const ci = seg[i];
          const eh = seg[i + 1] >> 4;
          const ev = seg[i + 1] & 15;
          if (eh < 1 || ev < 1 || eh > 4 || ev > 4) {
            fail("ASSET.BAD_JPEG", `\u5206\u91CF ${ci} \u7684 EXP \u653E\u5927\u56E0\u5B50\u975E\u6CD5\uFF1A${eh}\xD7${ev}\uFF08\u89C4\u8303\u8303\u56F4 1..4\uFF09`);
          }
          pendingExp.set(ci, { eh, ev });
        }
        break;
      }
      case MARKER_APP0:
        break;
      case MARKER_APP1:
        orientation = readExifOrientation(seg);
        break;
      case MARKER_APP14:
        if (seg.length >= 12 && seg[0] === 65 && seg[1] === 100 && seg[2] === 111 && seg[3] === 98) {
          adobeTransform = seg[11];
        }
        break;
      case MARKER_SOS: {
        if (current === null) fail("ASSET.BAD_JPEG", "SOS \u51FA\u73B0\u5728 SOF \u4E4B\u524D\uFF08\u6CA1\u6709\u5E27\u5934\u5C31\u65E0\u4ECE\u89E3\u7801\uFF09");
        for (const c of current.components) {
          if (!current.lossless) c.qtTable = qt[c.tq] ?? null;
        }
        const next = decodeScanByMode(bytes, dataStart, dataLen, current, dcTables, acTables, restartInterval);
        current.scanCount++;
        scanCount++;
        pos = next;
        continue;
      }
      default:
        break;
    }
    pos = dataStart + dataLen;
  }
  finishFrame();
  if (frames.length === 0) fail("ASSET.BAD_JPEG", "\u6CA1\u6709\u627E\u5230 SOF \u5E27\u5934");
  if (scanCount === 0) fail("ASSET.BAD_JPEG", "\u6CA1\u6709\u627E\u5230 SOS \u626B\u63CF\uFF08\u6587\u4EF6\u53EA\u6709\u5934\u3001\u6CA1\u6709\u50CF\u7D20\u6570\u636E\uFF09");
  if (pendingExp.size > 0) {
    fail("ASSET.BAD_JPEG", "EXP \u6BB5\u4E4B\u540E\u6CA1\u6709\u5E27\u5934\uFF1A\u653E\u5927\u56E0\u5B50\u65E0\u5904\u751F\u6548\uFF08EXP \u53EA\u5BF9\u4E0B\u4E00\u4E2A\u5E27\u5934\u751F\u6548\uFF09");
  }
  const last = frames[frames.length - 1];
  return {
    frames,
    width: last.width,
    height: last.height,
    precision: last.precision,
    adobeTransform,
    orientation,
    sawEoi,
    scanCount,
    hierarchical: hierarchical || frames.length > 1
  };
}
function decodeScanByMode(bytes, dataStart, dataLen, frame, dcTables, acTables, restartInterval) {
  if (frame.arithmetic) return decodeArithScan(bytes, dataStart, dataLen, frame, restartInterval);
  if (frame.lossless) return decodeLosslessScan(bytes, dataStart, dataLen, frame, dcTables, restartInterval);
  return decodeScan(bytes, dataStart, dataLen, frame, dcTables, acTables, restartInterval);
}
function hex(b, from, to) {
  return Array.from(b.subarray(from, to), (x) => x.toString(16).padStart(2, "0")).join(" ");
}

// src/extensions/asset-import/decode/jpeg/index.ts
function decodeJpeg(bytes, opts) {
  const o = opts ?? {};
  try {
    const file = parse(bytes, o.maxPixels ?? DEFAULT_MAX_PIXELS);
    if (o.strict === true && !file.sawEoi) {
      return err(
        engineError(
          "ASSET.BAD_JPEG",
          `JPEG \u4E0D\u5B8C\u6574\uFF1A\u71B5\u6570\u636E\u5728\u504F\u79FB ${bytes.length} \u5904\u5C31\u7ED3\u675F\u4E86\uFF0C\u6CA1\u6709 EOI\uFF08FF D9\uFF09\u3002\u5DF2\u89E3\u7801\u7684\u50CF\u7D20\u6765\u81EA\u8865 0 \u7684\u6570\u636E\uFF0Cstrict \u6A21\u5F0F\u4E0B\u4E0D\u8FD4\u56DE`,
          { byteLength: bytes.length }
        )
      );
    }
    const last = file.frames[file.frames.length - 1];
    return ok(
      toDecodedJpeg(
        last,
        {
          orientation: file.orientation,
          truncated: !file.sawEoi,
          frames: file.frames.length,
          hierarchical: file.hierarchical
        },
        o
      )
    );
  } catch (e) {
    if (e instanceof JpegFailure) {
      return err(engineError(e.code, e.message, e.detail));
    }
    return err(
      engineError("ASSET.BAD_JPEG", `JPEG \u89E3\u7801\u5185\u90E8\u9519\u8BEF\uFF1A${e instanceof Error ? e.message : String(e)}`)
    );
  }
}
function isJpeg(bytes) {
  return bytes.length >= 3 && bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255;
}

// src/extensions/asset-import/decode/image.ts
var PNG_SIGNATURE2 = [137, 80, 78, 71, 13, 10, 26, 10];
function isPng(bytes) {
  if (bytes.length < PNG_SIGNATURE2.length) return false;
  for (let i = 0; i < PNG_SIGNATURE2.length; i++) {
    if (bytes[i] !== PNG_SIGNATURE2[i]) return false;
  }
  return true;
}
function sniffImageFormat(bytes) {
  if (isPng(bytes)) return "png";
  if (isJpeg(bytes)) return "jpeg";
  return null;
}
function decodeImage(bytes, opts) {
  const fmt2 = sniffImageFormat(bytes);
  if (fmt2 === "png") return decodePng(bytes, opts?.png);
  if (fmt2 === "jpeg") return decodeJpeg(bytes, opts?.jpeg);
  const head = Array.from(bytes.subarray(0, Math.min(4, bytes.length)), (x) => x.toString(16).padStart(2, "0"));
  return err(
    engineError(
      "ASSET.UNKNOWN_FORMAT",
      `\u65E0\u6CD5\u8BC6\u522B\u7684\u56FE\u7247\u683C\u5F0F\uFF1A\u5F00\u5934\u5B57\u8282 ${head.join(" ") || "(\u7A7A)"}\uFF08\u652F\u6301 PNG 89 50 4e 47 / JPEG ff d8 ff\uFF09`,
      { head: head.join(" "), byteLength: bytes.length }
    )
  );
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
  const precision = opts?.precision ?? "auto";
  if (!Number.isInteger(padding) || padding < 0) {
    return err(errAtlas("ASSET.BAD_ATLAS_OPTIONS", `padding \u5FC5\u987B\u662F\u975E\u8D1F\u6574\u6570\uFF0C\u6536\u5230 ${padding}`));
  }
  if (!Number.isInteger(maxSize) || maxSize < 1) {
    return err(errAtlas("ASSET.BAD_ATLAS_OPTIONS", `maxSize \u5FC5\u987B\u662F \u22651 \u7684\u6574\u6570\uFF0C\u6536\u5230 ${maxSize}`));
  }
  if (precision !== "auto" && precision !== 8 && precision !== 16) {
    return err(
      errAtlas(
        "ASSET.BAD_ATLAS_OPTIONS",
        `precision \u53EA\u80FD\u662F "auto" | 8 | 16\uFF0C\u6536\u5230 ${JSON.stringify(precision)}`
      )
    );
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
  const use16 = precision === 16 || precision === "auto" && sources.some((s) => s.png.pixels16 !== void 0);
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
    return ok(
      use16 ? {
        width: 1,
        height: 1,
        pixels: new Uint8Array(4),
        format: PixelFormat.RGBA16,
        pixels16: new Uint16Array(4),
        frames: /* @__PURE__ */ new Map()
      } : { width: 1, height: 1, pixels: new Uint8Array(4), frames: /* @__PURE__ */ new Map() }
    );
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
  const pixels16 = use16 ? new Uint16Array(width * height * 4) : void 0;
  const byNameSource = /* @__PURE__ */ new Map();
  for (const s of sources) byNameSource.set(s.name, s.png);
  for (const p of placements) {
    const src = byNameSource.get(p.name);
    for (let row = 0; row < p.h; row++) {
      const from = row * p.w * 4;
      const to = ((p.y + row) * width + p.x) * 4;
      if (pixels16 !== void 0) {
        if (src.pixels16 !== void 0) {
          pixels16.set(src.pixels16.subarray(from, from + p.w * 4), to);
        } else {
          for (let i = 0; i < p.w * 4; i++) pixels16[to + i] = src.pixels[from + i] * 257;
        }
      } else if (src.pixels16 !== void 0) {
        for (let i = 0; i < p.w * 4; i++) pixels[to + i] = Math.round(src.pixels16[from + i] / 257);
      } else {
        pixels.set(src.pixels.subarray(from, from + p.w * 4), to);
      }
    }
  }
  if (pixels16 !== void 0) {
    for (let i = 0; i < pixels.length; i++) pixels[i] = Math.round(pixels16[i] / 257);
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
  return ok(
    pixels16 === void 0 ? { width, height, pixels, frames } : (
      // 16 位时**同时**给 8 位视图（见 atlas.ts 的不变量说明）
      { width, height, pixels, format: PixelFormat.RGBA16, pixels16, frames }
    )
  );
}

// src/extensions/inventory/inventory.ts
var ITEM_TYPE = "game.item";
var INVENTORY_TYPE = "game.inventory";
var INVENTORY_NO_OWNER = "INVENTORY.NO_OWNER";
var INVENTORY_FULL = "INVENTORY.FULL";
var INVENTORY_BAD_COUNT = "INVENTORY.BAD_COUNT";
var INVENTORY_NOT_ENOUGH = "INVENTORY.NOT_ENOUGH";
var ItemStack = class extends Component {
  /** 物品种类（与 `SiteKind` 同名，但不强绑：背包不认识"世界"）。 */
  kind = "";
  count = 0;
  schema = {
    type: ITEM_TYPE,
    fields: { kind: FieldType.String, count: FieldType.Int }
  };
};
var Inventory = class extends Component {
  /** 最多几堆（不是"最多几个"）。到上限再加"新种类"就报 `INVENTORY.FULL`。 */
  maxStacks = 8;
  /**
   * 单堆上限（饥荒默认 40）。**不是**"最多几个"：到顶会自动开新堆（有名额时），
   * 没有名额才报 `INVENTORY.FULL`。
   *
   * ★ 为什么需要它：`maxStacks` 管的是**格子数**，单堆无上限时"1 堆 × 9999"与
   *   "250 堆 × 40"都合法 —— 前者让背包面板一行写不下，后者让 `maxStacks` 形同虚设。
   *   两者都管，才是"几格、每格多少"的完整形状。
   */
  maxStack = 40;
  schema = {
    type: INVENTORY_TYPE,
    fields: { maxStacks: FieldType.Int, maxStack: FieldType.Int }
  };
};
function registerInventoryComponents(registry) {
  if (!registry.has(ITEM_TYPE)) registry.register(ITEM_SCHEMA, () => new ItemStack());
  if (!registry.has(INVENTORY_TYPE)) registry.register(INVENTORY_SCHEMA, () => new Inventory());
}
var ITEM_SCHEMA = { type: ITEM_TYPE, fields: { kind: FieldType.String, count: FieldType.Int } };
var INVENTORY_SCHEMA = {
  type: INVENTORY_TYPE,
  fields: { maxStacks: FieldType.Int, maxStack: FieldType.Int }
};
function makeInventory(scene, ownerId, maxStacks = 8, maxStack = 40) {
  const owner = scene.find(ownerId);
  if (owner === void 0) return err(engineError(INVENTORY_NO_OWNER, `\u8282\u70B9 ${String(ownerId)} \u4E0D\u5728\u573A\u666F\u91CC`));
  const existing = owner.get(INVENTORY_TYPE);
  if (existing !== void 0) return ok(existing);
  const made = scene.attach(ownerId, () => {
    const inv2 = new Inventory();
    inv2.maxStacks = maxStacks;
    inv2.maxStack = maxStack;
    return inv2;
  });
  if (!made.ok) return made;
  scene.flush();
  const inv = owner.get(INVENTORY_TYPE);
  if (inv === void 0) return err(engineError(INVENTORY_NO_OWNER, "\u80CC\u5305\u7EC4\u4EF6\u6302\u4E0A\u4E4B\u540E\u53C8\u8BFB\u4E0D\u5230"));
  return ok(inv);
}
function stacksOf(scene, ownerId) {
  const owner = scene.find(ownerId);
  if (owner === void 0) return [];
  const out = [];
  owner.walk((n) => {
    if (n.id === ownerId) return;
    const it = n.get(ITEM_TYPE);
    if (it !== void 0) out.push(it);
  });
  out.sort((a, b) => (a.node?.id ?? 0) - (b.node?.id ?? 0));
  return out;
}
function countItem(scene, ownerId, kind) {
  let n = 0;
  for (const s of stacksOf(scene, ownerId)) if (s.kind === kind) n += s.count;
  return n;
}
function isPositiveInt(v) {
  return Number.isInteger(v) && v > 0;
}
function stackCapOf(inv) {
  const v = inv.maxStack;
  if (!Number.isInteger(v) || v < 1) return 1;
  return v;
}
function stacksNeeded(total, cap) {
  return Math.max(1, Math.ceil(total / cap));
}
function addItem(scene, ownerId, kind, n) {
  if (!isPositiveInt(n)) {
    return err(engineError(INVENTORY_BAD_COUNT, `\u6570\u91CF\u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF0C\u6536\u5230 ${String(n)}`));
  }
  const owner = scene.find(ownerId);
  if (owner === void 0) return err(engineError(INVENTORY_NO_OWNER, `\u8282\u70B9 ${String(ownerId)} \u4E0D\u5728\u573A\u666F\u91CC`));
  const inv = owner.get(INVENTORY_TYPE);
  if (inv === void 0) return err(engineError(INVENTORY_NO_OWNER, `\u8282\u70B9 ${String(ownerId)} \u6CA1\u6709\u80CC\u5305\u7EC4\u4EF6`));
  const cap = stackCapOf(inv);
  const stacks = stacksOf(scene, ownerId);
  const free = Math.max(0, inv.maxStacks - stacks.length);
  const same = stacks.filter((s) => s.kind === kind);
  const total = n + same.reduce((a, s) => a + s.count, 0);
  const needNew = Math.max(0, stacksNeeded(total, cap) - same.length);
  if (needNew > free) {
    return err(
      engineError(
        INVENTORY_FULL,
        `\u80CC\u5305\u5DF2\u6EE1\uFF08${String(inv.maxStacks)} \u5806 \xD7 ${String(cap)}\uFF09\uFF0C${kind} \u6EA2\u51FA ${String(needNew - free)} \u5806\u653E\u4E0D\u4E0B`
      )
    );
  }
  let left = n;
  for (const s of same) {
    if (left === 0) break;
    const put2 = Math.min(cap - s.count, left);
    s.count += put2;
    left -= put2;
  }
  while (left > 0) {
    const put2 = Math.min(cap, left);
    const spawned = scene.spawn(`item/${kind}`, ownerId);
    if (!spawned.ok) return spawned;
    scene.flush();
    const nodeId = spawned.value.id;
    const made = scene.attach(nodeId, () => {
      const s = new ItemStack();
      s.kind = kind;
      s.count = put2;
      return s;
    });
    if (!made.ok) {
      scene.destroy(nodeId);
      scene.flush();
      return made;
    }
    left -= put2;
  }
  scene.flush();
  return ok(countItem(scene, ownerId, kind));
}
function takeItem(scene, ownerId, kind, n) {
  if (!isPositiveInt(n)) {
    return err(engineError(INVENTORY_BAD_COUNT, `\u6570\u91CF\u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF0C\u6536\u5230 ${String(n)}`));
  }
  const has = countItem(scene, ownerId, kind);
  if (has < n) {
    return err(engineError(INVENTORY_NOT_ENOUGH, `\u53EA\u6709 ${String(has)} \u4E2A ${kind}\uFF0C\u8981\u53D6 ${String(n)} \u4E2A`));
  }
  let left = n;
  for (const s of stacksOf(scene, ownerId)) {
    if (left === 0) break;
    if (s.kind !== kind) continue;
    const take = Math.min(s.count, left);
    s.count -= take;
    left -= take;
    if (s.count === 0) {
      const id = s.node?.id;
      if (id !== void 0) scene.destroy(id);
    }
  }
  scene.flush();
  return ok(n);
}

// src/foundation/canonical.ts
var CANON_NOT_INTEGER = "CANON.NOT_INTEGER";
var CANON_NOT_FINITE = "CANON.NOT_FINITE";
var CANON_TOO_LARGE = "CANON.TOO_LARGE";
var CANON_NULL = "CANON.NULL";
var CANON_UNSUPPORTED = "CANON.UNSUPPORTED";
function bad2(code, path, extra) {
  return err({
    code,
    message: `${path} ${extra} \u2014\u2014 \u5185\u5BB9\u6307\u7EB9\u8981\u6C42"\u540C\u503C\u540C\u4E32"\uFF0C\u8FD9\u7C7B\u503C\u6CA1\u6CD5\u4FDD\u8BC1`,
    detail: { path }
  });
}
function canonicalize(value) {
  return canon(value, "$");
}
function canon(value, path) {
  if (value === null) {
    return bad2(CANON_NULL, path, "\u662F null\uFF08\u7F3A\u5B57\u6BB5\u5C31\u522B\u5199\u8FD9\u4E2A\u952E\uFF0C\u4E0D\u8981\u5199 null\uFF09");
  }
  if (value === void 0) {
    return bad2(CANON_UNSUPPORTED, path, "\u662F undefined\uFF08JSON \u4F1A\u628A\u5B83\u9759\u9ED8\u4E22\u6389\uFF0C\u6570\u7EC4\u91CC\u8FD8\u4F1A\u53D8 null\uFF09");
  }
  switch (typeof value) {
    case "string":
      return ok(JSON.stringify(value));
    case "boolean":
      return ok(value ? "true" : "false");
    case "number": {
      if (!Number.isFinite(value)) {
        return bad2(CANON_NOT_FINITE, path, `\u662F ${String(value)}`);
      }
      if (!Number.isInteger(value)) {
        return bad2(CANON_NOT_INTEGER, path, `\u662F\u5C0F\u6570 ${String(value)}\uFF08\u9700\u8981\u5C0F\u6570\u8BF7\u6539\u7528\u5B9A\u70B9\u6574\u6570\uFF09`);
      }
      if (Math.abs(value) > Number.MAX_SAFE_INTEGER) {
        return bad2(CANON_TOO_LARGE, path, `\u662F ${String(value)}\uFF0C\u8D85\u51FA\u5B89\u5168\u6574\u6570\u8303\u56F4\uFF08\u6574\u6570\u5DF2\u4E0D\u7CBE\u786E\uFF09`);
      }
      return ok(String(value));
    }
    case "bigint":
    case "function":
    case "symbol":
      return bad2(CANON_UNSUPPORTED, path, `\u662F ${typeof value}`);
    default:
      break;
  }
  if (Array.isArray(value)) {
    const parts2 = [];
    for (let i = 0; i < value.length; i++) {
      const r = canon(value[i], `${path}[${String(i)}]`);
      if (!r.ok) return r;
      parts2.push(r.value);
    }
    return ok(`[${parts2.join(",")}]`);
  }
  const proto = Object.getPrototypeOf(value);
  if (proto !== Object.prototype && proto !== null) {
    const name = proto?.constructor?.name;
    return bad2(CANON_UNSUPPORTED, path, `\u4E0D\u662F\u7EAF\u5BF9\u8C61\uFF08\u539F\u578B ${String(name)}\uFF09`);
  }
  const rec = value;
  const keys = Object.keys(rec).sort();
  const parts = [];
  for (const k of keys) {
    const r = canon(rec[k], `${path}.${k}`);
    if (!r.ok) return r;
    parts.push(`${JSON.stringify(k)}:${r.value}`);
  }
  return ok(`{${parts.join(",")}}`);
}
function fingerprintOf(value) {
  const c = canonicalize(value);
  if (!c.ok) return c;
  return ok(hashText(c.value));
}

// src/extensions/worldgen/worldgen.ts
var FIXED_UNITS = 256;
var WORLD_PLAN_SCHEMA = 1;
var SITE_KINDS = ["tree", "berry", "rock", "flint", "grass_tuft", "reed"];
function isSiteKind(k) {
  return SITE_KINDS.includes(k);
}
var BIOMES = {
  ocean: { passable: false, sites: [] },
  cliff: { passable: false, sites: [] },
  beach: { passable: true, sites: ["flint", "grass_tuft"] },
  grass: { passable: true, sites: ["tree", "berry", "grass_tuft"] },
  forest: { passable: true, sites: ["tree", "tree", "berry"] },
  savanna: { passable: true, sites: ["grass_tuft", "rock"] },
  marsh: { passable: true, sites: ["reed", "berry"] },
  rocky: { passable: true, sites: ["rock", "flint"] }
};
function isPassable(kind) {
  return BIOMES[kind].passable;
}
function isBiomeKind(value) {
  return typeof value === "string" && Object.prototype.hasOwnProperty.call(BIOMES, value);
}
var WORLD_BAD_PARAMS = "WORLD.BAD_PARAMS";
var NOISE_PERIOD = 8;
function mix32(a) {
  let x = a | 0;
  x = Math.imul(x ^ x >>> 16, 2246822507);
  x = Math.imul(x ^ x >>> 13, 3266489909);
  return (x ^ x >>> 16) >>> 0;
}
function latticeValue(seed, lx, lz, channel) {
  const h = mix32(
    (seed | 0) ^ Math.imul(lx, 668265261) ^ Math.imul(lz, 374761393) ^ Math.imul(channel, 2654435761)
  );
  return h % 1024;
}
function noise2(seed, x, z, channel) {
  const g = NOISE_PERIOD;
  const lx = Math.floor(x / g);
  const lz = Math.floor(z / g);
  const dx = x - lx * g;
  const dz = z - lz * g;
  const a = latticeValue(seed, lx, lz, channel);
  const b = latticeValue(seed, lx + 1, lz, channel);
  const c = latticeValue(seed, lx, lz + 1, channel);
  const d = latticeValue(seed, lx + 1, lz + 1, channel);
  const top = a * (g - dx) + b * dx;
  const bot = c * (g - dx) + d * dx;
  return Math.floor((top * (g - dz) + bot * dz) / (g * g));
}
function pickBiome(elevation, moisture) {
  if (elevation < 280) return "ocean";
  if (elevation < 340) return "beach";
  if (elevation >= 900) return "cliff";
  if (elevation >= 780) return "rocky";
  if (moisture < 300) return "savanna";
  if (moisture < 700) return "grass";
  if (moisture < 850) return "forest";
  return "marsh";
}
function cellSeed(seed, cellIndex) {
  return mix32((seed | 0) ^ Math.imul(cellIndex + 1, 2654435761));
}
var NEIGHBORS = [
  [1, 0],
  [-1, 0],
  [0, 1],
  [0, -1]
];
function findComponents(width, height, kinds) {
  const total = width * height;
  const regionOf = new Int32Array(total).fill(-1);
  const groups = [];
  const queue = [];
  for (let start = 0; start < total; start++) {
    if (regionOf[start] !== -1) continue;
    if (!isPassable(kinds[start])) continue;
    const id = groups.length;
    const group = [];
    regionOf[start] = id;
    queue.length = 0;
    queue.push(start);
    for (let head = 0; head < queue.length; head++) {
      const cur = queue[head];
      group.push(cur);
      const cx = cur % width;
      const cz = (cur - cx) / width;
      for (const [ox, oz] of NEIGHBORS) {
        const nx = cx + ox;
        const nz = cz + oz;
        if (nx < 0 || nz < 0 || nx >= width || nz >= height) continue;
        const ni = nz * width + nx;
        if (regionOf[ni] !== -1) continue;
        if (!isPassable(kinds[ni])) continue;
        regionOf[ni] = id;
        queue.push(ni);
      }
    }
    group.sort((p, q2) => p - q2);
    groups.push(group);
  }
  return { regionOf, groups };
}
function lineCells(width, x0, z0, x1, z1) {
  const out = [];
  const dx = Math.abs(x1 - x0);
  const dz = Math.abs(z1 - z0);
  const sx = x0 < x1 ? 1 : -1;
  const sz = z0 < z1 ? 1 : -1;
  let e = dx - dz;
  let x = x0;
  let z = z0;
  for (; ; ) {
    out.push(z * width + x);
    if (x === x1 && z === z1) break;
    const e2 = 2 * e;
    if (e2 > -dz) {
      e -= dz;
      x += sx;
    }
    if (e2 < dx) {
      e += dx;
      z += sz;
    }
  }
  return out;
}
function repairConnectivity(width, height, kinds, bridges) {
  let carved = 0;
  let rounds = 0;
  for (let round = 0; round < 4; round++) {
    const { groups } = findComponents(width, height, kinds);
    if (groups.length <= 1) break;
    rounds++;
    let mainIdx = 0;
    for (let i = 1; i < groups.length; i++) {
      if (groups[i].length > groups[mainIdx].length) mainIdx = i;
    }
    const main2 = groups[mainIdx];
    let carvedThisRound = 0;
    for (let gi = 0; gi < groups.length; gi++) {
      if (gi === mainIdx) continue;
      const group = groups[gi];
      const source = group[0];
      const sx = source % width;
      const sz = (source - sx) / width;
      let best = -1;
      let bestD = Number.POSITIVE_INFINITY;
      for (const target of main2) {
        const tx2 = target % width;
        const tz2 = (target - tx2) / width;
        const d = Math.abs(tx2 - sx) + Math.abs(tz2 - sz);
        if (d < bestD) {
          bestD = d;
          best = target;
        }
      }
      if (best < 0) continue;
      const tx = best % width;
      const tz = (best - tx) / width;
      let carvedHere = 0;
      for (const cell of lineCells(width, sx, sz, tx, tz)) {
        if (isPassable(kinds[cell])) continue;
        kinds[cell] = "beach";
        carvedHere++;
      }
      if (carvedHere > 0) {
        bridges.push({ fromCell: source, toCell: best });
        carvedThisRound += carvedHere;
      }
    }
    carved += carvedThisRound;
    if (carvedThisRound === 0) break;
  }
  return { carved, rounds };
}
function generateWorld(params) {
  const { seed, width, height } = params;
  if (!Number.isInteger(seed)) {
    return err({ code: WORLD_BAD_PARAMS, message: `seed \u5FC5\u987B\u662F\u6574\u6570\uFF0C\u5F97\u5230 ${String(seed)}` });
  }
  if (!Number.isInteger(width) || width < 8 || width > 128) {
    return err({ code: WORLD_BAD_PARAMS, message: `width \u5FC5\u987B\u662F 8..128 \u7684\u6574\u6570\uFF0C\u5F97\u5230 ${String(width)}` });
  }
  if (!Number.isInteger(height) || height < 8 || height > 128) {
    return err({ code: WORLD_BAD_PARAMS, message: `height \u5FC5\u987B\u662F 8..128 \u7684\u6574\u6570\uFF0C\u5F97\u5230 ${String(height)}` });
  }
  const maxSites = params.maxSitesPerCell ?? 2;
  if (!Number.isInteger(maxSites) || maxSites < 0 || maxSites > 8) {
    return err({ code: WORLD_BAD_PARAMS, message: `maxSitesPerCell \u5FC5\u987B\u662F 0..8 \u7684\u6574\u6570\uFF0C\u5F97\u5230 ${String(maxSites)}` });
  }
  const total = width * height;
  const kinds = new Array(total);
  for (let z = 0; z < height; z++) {
    for (let x = 0; x < width; x++) {
      const isBorder = x === 0 || z === 0 || x === width - 1 || z === height - 1;
      if (isBorder) {
        kinds[z * width + x] = "ocean";
        continue;
      }
      const elevation = noise2(seed, x, z, 1);
      const moisture = noise2(seed, x, z, 2);
      kinds[z * width + x] = pickBiome(elevation, moisture);
    }
  }
  const bridges = [];
  if (params.repair !== false) {
    repairConnectivity(width, height, kinds, bridges);
  }
  const sites = [];
  for (let cell = 0; cell < total; cell++) {
    const kind = kinds[cell];
    const def = BIOMES[kind];
    if (!def.passable || def.sites.length === 0 || maxSites === 0) continue;
    const rng = new XorShift128(cellSeed(seed, cell));
    const n = rng.int(1, maxSites + 1);
    const cx = cell % width;
    const cz = (cell - cx) / width;
    for (let k = 0; k < n; k++) {
      const siteKind = rng.pick(def.sites);
      if (siteKind === void 0) continue;
      sites.push({
        id: cell * maxSites + k,
        kind: siteKind,
        x: cx * FIXED_UNITS + rng.int(0, FIXED_UNITS),
        z: cz * FIXED_UNITS + rng.int(0, FIXED_UNITS),
        cell
      });
    }
  }
  const partial = {
    schema: WORLD_PLAN_SCHEMA,
    seed,
    width,
    height,
    kinds,
    sites,
    bridges
  };
  const fp = fingerprintOf(partial);
  if (!fp.ok) return fp;
  return ok({
    seed,
    width,
    height,
    kinds,
    sites,
    bridges,
    fingerprint: fp.value
  });
}
function planDigest(plan) {
  return fingerprintOf({
    schema: WORLD_PLAN_SCHEMA,
    seed: plan.seed,
    width: plan.width,
    height: plan.height,
    kinds: plan.kinds,
    sites: plan.sites,
    bridges: plan.bridges
  });
}
var WORLD_NO_SPAWN = "WORLD.NO_SPAWN";
function pickSpawn(plan) {
  const { width, height, kinds } = plan;
  const total = width * height;
  const { regionOf, groups } = findComponents(width, height, kinds);
  let mainIdx = -1;
  let largest = 0;
  for (let i = 0; i < groups.length; i++) {
    const n = groups[i].length;
    if (n > largest) {
      largest = n;
      mainIdx = i;
    }
  }
  if (mainIdx < 0) {
    return err({ code: WORLD_NO_SPAWN, message: "\u6574\u5F20\u56FE\u6CA1\u6709\u53EF\u901A\u884C\u7684\u9646\u5730\uFF08\u5168\u662F\u6D77/\u60AC\u5D16\uFF09\uFF0C\u65E0\u6CD5\u9009\u51FA\u751F\u70B9" });
  }
  const dist = new Int32Array(total).fill(-1);
  const queue = [];
  for (let i = 0; i < total; i++) {
    if (!isPassable(kinds[i])) {
      dist[i] = 0;
      queue.push(i);
    }
  }
  for (let z = 0; z < height; z++) {
    for (let x = 0; x < width; x++) {
      if (x !== 0 && z !== 0 && x !== width - 1 && z !== height - 1) continue;
      const i = z * width + x;
      if (dist[i] !== -1) continue;
      dist[i] = 1;
      queue.push(i);
    }
  }
  for (let head = 0; head < queue.length; head++) {
    const cur = queue[head];
    const cx = cur % width;
    const cz = (cur - cx) / width;
    const d = dist[cur];
    for (const [ox, oz] of NEIGHBORS) {
      const nx = cx + ox;
      const nz = cz + oz;
      if (nx < 0 || nz < 0 || nx >= width || nz >= height) continue;
      const ni = nz * width + nx;
      if (dist[ni] !== -1) continue;
      dist[ni] = d + 1;
      queue.push(ni);
    }
  }
  let best = -1;
  let bestDist = -1;
  for (let i = 0; i < total; i++) {
    if (regionOf[i] !== mainIdx) continue;
    const d = dist[i];
    if (d > bestDist) {
      bestDist = d;
      best = i;
    }
  }
  if (best < 0) {
    return err({ code: WORLD_NO_SPAWN, message: `\u4E3B\u5206\u91CF\uFF08${largest} \u683C\uFF09\u91CC\u6CA1\u6709\u53EF\u901A\u884C\u683C` });
  }
  const bx = best % width;
  const bz = (best - bx) / width;
  return ok({
    cell: best,
    x: bx * FIXED_UNITS + FIXED_UNITS / 2,
    z: bz * FIXED_UNITS + FIXED_UNITS / 2,
    clearance: bestDist
  });
}

// src/extensions/worldgen/assemble.ts
var WORLD_BAD_PLAN = "WORLD.BAD_PLAN";
var WORLD_SCENE_NOT_EMPTY = "WORLD.SCENE_NOT_EMPTY";
var WORLD_COMPONENTS_UNREGISTERED = "WORLD.COMPONENTS_UNREGISTERED";
var TERRAIN_TYPE = "world.terrain";
var SITE_TYPE = "world.site";
var TERRAIN_SCHEMA = {
  type: TERRAIN_TYPE,
  fields: {
    kind: FieldType.String,
    /** 矩形左上角格子坐标与尺寸 —— 存的是**格子**，不是世界单位（不引入浮点）。 */
    cx: FieldType.Int,
    cz: FieldType.Int,
    w: FieldType.Int,
    h: FieldType.Int,
    /** 冗余但必要：`passable` 是"能不能走"的**运行时事实**，不只由 kind 推。 */
    passable: FieldType.Bool
  }
};
var SITE_SCHEMA = {
  type: SITE_TYPE,
  fields: {
    siteId: FieldType.Int,
    kind: FieldType.String,
    cell: FieldType.Int
  }
};
var TerrainArea = class extends Component {
  schema = TERRAIN_SCHEMA;
  kind = "ocean";
  cx = 0;
  cz = 0;
  w = 0;
  h = 0;
  passable = false;
};
var SiteMarker = class extends Component {
  schema = SITE_SCHEMA;
  siteId = 0;
  kind = "tree";
  cell = 0;
};
function registerWorldComponents(registry) {
  if (!registry.has(TERRAIN_TYPE)) registry.register(TERRAIN_SCHEMA, () => new TerrainArea());
  if (!registry.has(SITE_TYPE)) registry.register(SITE_SCHEMA, () => new SiteMarker());
}
function mergeTerrain(width, height, kinds) {
  const visited = new Uint8Array(width * height);
  const rects = [];
  for (let cz = 0; cz < height; cz++) {
    for (let cx = 0; cx < width; cx++) {
      const start = cz * width + cx;
      if (visited[start] === 1) continue;
      const kind = kinds[start];
      let w = 1;
      while (cx + w < width) {
        const i = start + w;
        if (visited[i] === 1 || kinds[i] !== kind) break;
        w++;
      }
      let h = 1;
      while (cz + h < height) {
        let sameRow = true;
        for (let dx = 0; dx < w; dx++) {
          const i = (cz + h) * width + cx + dx;
          if (visited[i] === 1 || kinds[i] !== kind) {
            sameRow = false;
            break;
          }
        }
        if (!sameRow) break;
        h++;
      }
      for (let dz = 0; dz < h; dz++) {
        for (let dx = 0; dx < w; dx++) visited[(cz + dz) * width + cx + dx] = 1;
      }
      rects.push({ cx, cz, w, h, kind });
    }
  }
  return rects;
}
function assembleWorld(plan, scene) {
  const { width, height, kinds } = plan;
  if (!Number.isInteger(width) || !Number.isInteger(height) || width < 1 || height < 1) {
    return err({ code: WORLD_BAD_PLAN, message: `\u5C3A\u5BF8\u4E0D\u5408\u6CD5\uFF1A${String(width)}x${String(height)}` });
  }
  if (kinds.length !== width * height) {
    return err({
      code: WORLD_BAD_PLAN,
      message: `kinds \u957F\u5EA6 ${kinds.length} \u4E0E\u5C3A\u5BF8 ${width}x${height}\uFF08${width * height}\uFF09\u4E0D\u7B26`
    });
  }
  for (let i = 0; i < kinds.length; i++) {
    if (!isBiomeKind(kinds[i])) {
      return err({
        code: WORLD_BAD_PLAN,
        message: `\u7B2C ${i} \u683C\u7684\u7FA4\u7CFB\u540D\u672A\u77E5\uFF1A${String(kinds[i])}\uFF08\u53EF\u80FD\u662F\u65E7 schema \u6216\u624B\u6539\u7684\u8BA1\u5212\uFF09`
      });
    }
  }
  const digest = planDigest(plan);
  if (!digest.ok) return digest;
  if (digest.value !== plan.fingerprint) {
    return err({
      code: WORLD_BAD_PLAN,
      message: `\u8BA1\u5212\u6307\u7EB9\u4E0E\u5185\u5BB9\u4E0D\u7B26\uFF08\u8BA1\u5212\u91CC\u5B58 ${plan.fingerprint}\uFF0C\u91CD\u7B97\u5F97 ${digest.value}\uFF09\u2014\u2014 \u5185\u5BB9\u88AB\u6539\u8FC7\u6216\u6765\u81EA\u65E7 schema`
    });
  }
  if (scene.stats().nodes !== 1) {
    return err({
      code: WORLD_SCENE_NOT_EMPTY,
      message: `\u76EE\u6807\u573A\u666F\u5DF2\u6709 ${scene.stats().nodes - 1} \u4E2A\u8282\u70B9\uFF08\u88C5\u914D\u8981\u6C42\u7A7A\u573A\u666F\uFF0C\u5148 scene.clear()\uFF09`
    });
  }
  const missing = [TERRAIN_TYPE, SITE_TYPE].filter((t) => !scene.components.has(t));
  if (missing.length > 0) {
    return err({
      code: WORLD_COMPONENTS_UNREGISTERED,
      message: `\u7EC4\u4EF6\u7C7B\u578B\u672A\u6CE8\u518C\uFF1A${missing.join(", ")} \u2014\u2014 \u5148 registerWorldComponents(scene.components)`
    });
  }
  const rects = mergeTerrain(width, height, kinds);
  const terrainRoot = scene.spawnImmediate("terrain");
  const siteRoot = scene.spawnImmediate("sites");
  for (const r of rects) {
    const node = scene.spawnImmediate(`terrain/${r.kind}`, terrainRoot.id);
    node.setLocalPosition(r.cx, r.cz);
    const made = scene.attach(node.id, () => new TerrainArea());
    if (!made.ok) return made;
    made.value.kind = r.kind;
    made.value.cx = r.cx;
    made.value.cz = r.cz;
    made.value.w = r.w;
    made.value.h = r.h;
    made.value.passable = isPassable(r.kind);
  }
  for (const s of plan.sites) {
    const node = scene.spawnImmediate(`site/${s.kind}`, siteRoot.id);
    node.setLocalPosition(s.x / FIXED_UNITS, s.z / FIXED_UNITS);
    const made = scene.attach(node.id, () => new SiteMarker());
    if (!made.ok) return made;
    made.value.siteId = s.id;
    made.value.kind = s.kind;
    made.value.cell = s.cell;
  }
  scene.flush();
  return ok({
    terrainNodes: rects.length,
    siteNodes: plan.sites.length,
    sceneNodes: scene.stats().nodes,
    cells: width * height,
    rects: rects.length,
    fingerprint: plan.fingerprint
  });
}

// src/extensions/worldgen/tasks.ts
var WORLD_TASK_SCHEMA = 1;
var TASK_BAD_TABLE = "TASK.BAD_TABLE";
var TASK_BAD_TICK = "TASK.BAD_TICK";
function hashString(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}
function dueRange(period, phase, from, to) {
  if (to <= from) return { first: -1, count: 0 };
  const rem = ((phase - from % period) % period + period) % period;
  const first = from + (rem === 0 ? period : rem);
  if (first > to) return { first: -1, count: 0 };
  return { first, count: Math.floor((to - first) / period) + 1 };
}
function validateTaskTable(table) {
  if (table.schema !== WORLD_TASK_SCHEMA) {
    return err({
      code: TASK_BAD_TABLE,
      message: `\u8868\u7ED3\u6784\u7248\u672C ${String(table.schema)} \u4E0D\u662F ${WORLD_TASK_SCHEMA}\uFF08\u65E7\u8868\u5FC5\u987B\u88AB\u62D2\u7EDD\uFF0C\u800C\u4E0D\u662F\u52C9\u5F3A\u80FD\u7528\uFF09`
    });
  }
  const seen = /* @__PURE__ */ new Set();
  const out = [];
  for (let i = 0; i < table.tasks.length; i++) {
    const t = table.tasks[i];
    if (typeof t.id !== "string" || t.id.length === 0) {
      return err({ code: TASK_BAD_TABLE, message: `\u7B2C ${i} \u6761\u4EFB\u52A1\u6CA1\u6709 id` });
    }
    if (seen.has(t.id)) {
      return err({ code: TASK_BAD_TABLE, message: `\u4EFB\u52A1 id \u91CD\u590D\uFF1A${t.id}` });
    }
    seen.add(t.id);
    if (!Number.isInteger(t.periodTicks) || t.periodTicks < 1) {
      return err({
        code: TASK_BAD_TABLE,
        message: `\u4EFB\u52A1 ${t.id} \u7684 periodTicks \u5FC5\u987B\u662F \u22651 \u7684\u6574\u6570\uFF0C\u5F97\u5230 ${String(t.periodTicks)}`
      });
    }
    const phase = t.phase ?? 0;
    if (!Number.isInteger(phase) || phase < 0 || phase >= t.periodTicks) {
      return err({
        code: TASK_BAD_TABLE,
        message: `\u4EFB\u52A1 ${t.id} \u7684 phase \u5FC5\u987B\u843D\u5728 [0, ${t.periodTicks})\uFF0C\u5F97\u5230 ${String(phase)} \u2014\u2014 \u8D8A\u754C\u4F1A\u8BA9\u5B83\u6C38\u4E0D\u89E6\u53D1`
      });
    }
    const picks = t.picksPerRun ?? 0;
    if (!Number.isInteger(picks) || picks < 0 || picks > 64) {
      return err({
        code: TASK_BAD_TABLE,
        message: `\u4EFB\u52A1 ${t.id} \u7684 picksPerRun \u5FC5\u987B\u662F 0..64 \u7684\u6574\u6570\uFF0C\u5F97\u5230 ${String(picks)}`
      });
    }
    if (t.biomes !== void 0) {
      for (const b of t.biomes) {
        if (!isBiomeKind(b)) {
          return err({ code: TASK_BAD_TABLE, message: `\u4EFB\u52A1 ${t.id} \u7684\u7FA4\u7CFB\u540D\u672A\u77E5\uFF1A${String(b)}` });
        }
      }
    }
    out.push(t);
  }
  return ok(out);
}
var WorldTasks = class _WorldTasks {
  states;
  plan;
  _lastTick = 0;
  _runs = 0;
  _missed = 0;
  constructor(states, plan) {
    this.states = states;
    this.plan = plan;
  }
  static create(table, plan) {
    const valid = validateTaskTable(table);
    if (!valid.ok) return valid;
    const needsPlan = valid.value.some((t) => (t.picksPerRun ?? 0) > 0 && (t.biomes?.length ?? 0) > 0);
    if (needsPlan && plan === void 0) {
      return err({
        code: TASK_BAD_TABLE,
        message: "\u8868\u91CC\u6709\u4EFB\u52A1\u8981\u6309\u7FA4\u7CFB\u9009\u683C\uFF0C\u4F46\u6CA1\u6709\u7ED9 WorldPlan \u2014\u2014 \u9759\u9ED8\u8FD4\u56DE\u7A7A\u6570\u7EC4\u4F1A\u8BA9\u300C\u6CA1\u5237\u51FA\u6765\u300D\u770B\u8D77\u6765\u50CF\u300C\u6CA1\u8DD1\u5230\u300D"
      });
    }
    return ok(
      new _WorldTasks(
        valid.value.map((task) => ({ task, runs: 0, missed: 0 })),
        plan
      )
    );
  }
  get lastTick() {
    return this._lastTick;
  }
  /**
   * 推进到 `tick`（含），返回本次推进触发的执行。
   *
   * ★ 只能前进：倒退会让同一个 tick 被执行两次（读档回档时的经典坑），必须报错。
   * ★ 顺序：先按 `tick` 升序（区间内各任务的首次命中），再按表内声明顺序 ——
   *   "按 tick 再按声明序"是确定的；只按声明序会让同一 tick 内多任务的先后
   *   依赖表里谁写在前，而这个顺序会进 seed 之外的副作用（日志、事件）。
   */
  advanceTo(tick) {
    if (!Number.isInteger(tick)) {
      return err({ code: TASK_BAD_TICK, message: `tick \u5FC5\u987B\u662F\u6574\u6570\uFF0C\u5F97\u5230 ${String(tick)}` });
    }
    if (tick < this._lastTick) {
      return err({
        code: TASK_BAD_TICK,
        message: `\u65F6\u95F4\u4E0D\u80FD\u5012\u9000\uFF1A\u4E0A\u6B21 ${this._lastTick}\uFF0C\u8FD9\u6B21 ${tick}\uFF08\u56DE\u6863\u8BF7\u91CD\u5EFA\u4EFB\u52A1\u8868\uFF09`
      });
    }
    const due = [];
    for (let i = 0; i < this.states.length; i++) {
      const st = this.states[i];
      const period = st.task.periodTicks;
      const phase = st.task.phase ?? 0;
      const { first, count } = dueRange(period, phase, this._lastTick, tick);
      if (first < 0) continue;
      st.runs += 1;
      st.missed += count - 1;
      this._runs += 1;
      this._missed += count - 1;
      due.push({
        order: i,
        fire: {
          taskId: st.task.id,
          tick: first,
          run: st.runs,
          missed: count - 1,
          cells: this.pickCells(st.task, first, st.runs)
        }
      });
    }
    this._lastTick = tick;
    due.sort((a, b) => a.fire.tick !== b.fire.tick ? a.fire.tick - b.fire.tick : a.order - b.order);
    return ok(due.map((d) => d.fire));
  }
  /**
   * 按群系确定性选格：候选 = 计划里"群系属于 biomes 且可通行"的格子（升序）。
   *
   * ★★ seed 只由 **(任务 id, 首次到期 tick)** 决定，**不含 `run`**。
   *   第一版把 `run` 也混了进去，写变异时才发现两个问题：
   *   ① 它让"同一 tick 的产出"依赖**执行历史** —— 读档后重建实例、推进到同一个 tick，
   *      会得到另一批格子（`run` 从 1 重新数），可重放性当场失效；
   *   ② `firstTick` 严格单调递增，`run` 在它之外不带来任何新信息 ——
   *      删掉 `run` 也无法被任何判据抓住。**一条抓不住对应变异的判据等于没写**，
   *      反过来说：一个无法被区分的设计元素也不该留在关键路径上。
   *   所以 `run` 降级为纯诊断字段（`runCounts()` 用）。
   */
  pickCells(task, firstTick, _run) {
    const want = task.picksPerRun ?? 0;
    const biomes = task.biomes ?? [];
    if (want === 0 || biomes.length === 0 || this.plan === void 0) return [];
    const allow = new Set(biomes);
    const candidates = [];
    for (let i = 0; i < this.plan.kinds.length; i++) {
      const k = this.plan.kinds[i];
      if (!allow.has(k)) continue;
      if (!isPassable(k)) continue;
      candidates.push(i);
    }
    if (candidates.length === 0) return [];
    const seed = hashString(task.id) ^ Math.imul(firstTick, 2654435761) | 0;
    const rng = new XorShift128(seed);
    rng.shuffle(candidates);
    return candidates.slice(0, Math.min(want, candidates.length)).sort((a, b) => a - b);
  }
  stats() {
    return {
      tasks: this.states.length,
      runs: this._runs,
      missed: this._missed,
      lastTick: this._lastTick
    };
  }
  /** 每条任务跑了多少次（诊断/编辑器面板用）。 */
  runCounts() {
    const out = /* @__PURE__ */ new Map();
    for (const st of this.states) out.set(st.task.id, st.runs);
    return out;
  }
};

// src/extensions/worldgen/task-module.ts
var RESOURCE_TYPE = "world.resource";
var TASK_NO_SCENE = "TASK.NO_SCENE";
var TASK_BAD_CELL = "TASK.BAD_CELL";
var TASK_BAD_TERRAIN = "TASK.BAD_TERRAIN";
var TASK_CELL_TAKEN = "TASK.CELL_TAKEN";
var TASK_CAP = "TASK.CAP";
var RESOURCE_SCHEMA = {
  type: RESOURCE_TYPE,
  fields: {
    cell: FieldType.Int,
    kind: FieldType.String,
    /** 哪一次触发刷出来的（= `TaskFire.tick`）。诊断用，也用来验"重复触发没被合并"。 */
    bornTick: FieldType.Int
  }
};
var ResourceMarker = class extends Component {
  schema = RESOURCE_SCHEMA;
  cell = 0;
  kind = "tree";
  bornTick = 0;
};
function registerResourceComponent(registry) {
  if (!registry.has(RESOURCE_TYPE)) registry.register(RESOURCE_SCHEMA, () => new ResourceMarker());
}
var DEFAULT_MAX_RESOURCES = 4096;
function createWorldTaskModule(opts) {
  const maxResources = opts.maxResources ?? DEFAULT_MAX_RESOURCES;
  let scene = opts.scene ?? null;
  let ctxRef = null;
  let started = false;
  const tasks = (() => {
    const r = WorldTasks.create(opts.tasks, opts.plan);
    if (!r.ok) {
      throw new Error(`\u4E16\u754C\u4EFB\u52A1\u8868\u4E0D\u5408\u6CD5\uFF1A${r.error.code} ${r.error.message}`);
    }
    return r.value;
  })();
  let occupied = null;
  let fires = 0;
  let spawned = 0;
  let alive = 0;
  let released = 0;
  let skippedExisting = 0;
  let skippedCap = 0;
  let lastFires = [];
  function ensureIndex(s) {
    if (occupied !== null) return occupied;
    const set = /* @__PURE__ */ new Set();
    for (const marker of s.componentsOf(SITE_TYPE)) set.add(marker.cell);
    for (const res of s.componentsOf(RESOURCE_TYPE)) set.add(res.cell);
    occupied = set;
    return set;
  }
  const mod = {
    id: "world.tasks",
    deps: [],
    tasks,
    init(ctx) {
      ctxRef = ctx;
      if (scene === null) {
        const got = ctx.services.get(Services.Scene);
        if (got === void 0) {
          return err(
            engineError(
              TASK_NO_SCENE,
              "\u4E16\u754C\u4EFB\u52A1\u6A21\u5757\u9700\u8981\u4E00\u4E2A Scene\uFF1A\u8981\u4E48\u5728 options \u91CC\u4F20\uFF0C\u8981\u4E48\u5148\u7531\u5BBF\u4E3B\u6CE8\u518C Services.Scene"
            )
          );
        }
        scene = got;
      }
      if (!scene.components.has(RESOURCE_TYPE)) {
        return err(
          engineError(
            TASK_NO_SCENE,
            `\u573A\u666F\u7684\u7EC4\u4EF6\u6CE8\u518C\u8868\u91CC\u6CA1\u6709 ${RESOURCE_TYPE} \u2014\u2014 \u5148 registerResourceComponent(scene.components)`
          )
        );
      }
      return ok(void 0);
    },
    start() {
      started = true;
    },
    stop() {
      started = false;
    },
    update(tick, dt) {
      const s = scene;
      if (s === null || !started) return;
      const advanced = tasks.advanceTo(tick);
      if (!advanced.ok) {
        ctxRef?.log.channel("world").warn(`\u4E16\u754C\u4EFB\u52A1\u63A8\u8FDB\u5931\u8D25\uFF1A${advanced.error.code} ${advanced.error.message}`);
        lastFires = [];
        return;
      }
      lastFires = advanced.value;
      if (advanced.value.length === 0) return;
      const taken = ensureIndex(s);
      let touched = false;
      for (const fire of advanced.value) {
        fires++;
        for (const cell of fire.cells) {
          if (taken.has(cell)) {
            skippedExisting++;
            continue;
          }
          if (alive >= maxResources) {
            skippedCap++;
            continue;
          }
          const width = opts.plan.width;
          const cx = cell % width;
          const cz = (cell - cx) / width;
          const node = s.spawn(`resource/${kindOf(fire, opts.plan, cell)}`, null);
          if (!node.ok) {
            ctxRef?.log.channel("world").warn(`\u8D44\u6E90\u8282\u70B9\u521B\u5EFA\u5931\u8D25\uFF1A${node.error.code}`);
            continue;
          }
          node.value.setLocalPosition(cx + 0.5, cz + 0.5);
          const made = s.attach(node.value.id, () => new ResourceMarker());
          if (!made.ok) continue;
          made.value.cell = cell;
          made.value.kind = kindOf(fire, opts.plan, cell);
          made.value.bornTick = fire.tick;
          taken.add(cell);
          spawned++;
          alive++;
          touched = true;
        }
      }
      if (touched) s.flush();
    },
    stats() {
      return {
        fires,
        spawned,
        alive,
        released,
        skippedExisting,
        skippedCap,
        occupied: occupied === null ? 0 : occupied.size,
        lastTick: tasks.lastTick
      };
    },
    releaseCell(cell) {
      const s = scene;
      if (s === null) return false;
      const taken = ensureIndex(s);
      if (!taken.delete(cell)) return false;
      if (alive > 0) alive--;
      released++;
      return true;
    },
    isOccupied(cell) {
      const s = scene;
      if (s === null) return false;
      return ensureIndex(s).has(cell);
    },
    placeResource(cell, kind, bornTick) {
      const s = scene;
      if (s === null) {
        return err(engineError(TASK_NO_SCENE, "\u4E16\u754C\u4EFB\u52A1\u6A21\u5757\u6CA1\u6709\u573A\u666F\uFF0C\u653E\u4E0D\u4E86\u8D44\u6E90"));
      }
      const width = opts.plan.width;
      const size = width * opts.plan.height;
      if (!Number.isInteger(cell) || cell < 0 || cell >= size) {
        return err(engineError(TASK_BAD_CELL, `\u683C\u5B50 ${String(cell)} \u8D8A\u754C\uFF08\u4E16\u754C\u662F ${String(width)}\xD7${String(opts.plan.height)}\uFF09`));
      }
      if (!isPassable(opts.plan.kinds[cell])) {
        return err(engineError(TASK_BAD_TERRAIN, `\u683C\u5B50 ${String(cell)} \u662F\u4E0D\u53EF\u901A\u884C\u5730\u5F62\uFF0C\u4E0D\u80FD\u653E\u8D44\u6E90`));
      }
      const taken = ensureIndex(s);
      if (taken.has(cell)) {
        return err(engineError(TASK_CELL_TAKEN, `\u683C\u5B50 ${String(cell)} \u4E0A\u5DF2\u7ECF\u6709\u8D44\u6E90\u4E86`));
      }
      if (alive >= maxResources) {
        return err(engineError(TASK_CAP, `\u4E16\u754C\u8D44\u6E90\u5DF2\u5230\u5168\u5C40\u4E0A\u9650\uFF08${String(maxResources)}\uFF09\uFF0C\u653E\u4E0D\u4E0B\u66F4\u591A`));
      }
      const cx = cell % width;
      const cz = (cell - cx) / width;
      const node = s.spawn(`resource/${kind}`, null);
      if (!node.ok) return node;
      node.value.setLocalPosition(cx + 0.5, cz + 0.5);
      const made = s.attach(node.value.id, () => new ResourceMarker());
      if (!made.ok) {
        s.destroy(node.value.id);
        s.flush();
        return made;
      }
      made.value.cell = cell;
      made.value.kind = kind;
      made.value.bornTick = bornTick;
      taken.add(cell);
      spawned++;
      alive++;
      s.flush();
      return ok(node.value.id);
    },
    lastFires() {
      return lastFires;
    },
    describe() {
      return `world.tasks\uFF1A${String(tasks.stats().tasks)} \u6761\u4EFB\u52A1 / \u5DF2\u5237 ${String(spawned)} / \u8DF3\u8FC7\u53BB\u91CD ${String(skippedExisting)} / \u4E0A\u9650 ${String(skippedCap)}`;
    }
  };
  return mod;
}
function kindOf(fire, plan, cell) {
  const kind = plan.kinds[cell];
  if (!isPassable(kind)) return "grass_tuft";
  switch (kind) {
    case "forest":
      return "tree";
    case "grass":
      return "berry";
    case "beach":
      return "flint";
    case "rocky":
      return "rock";
    case "savanna":
      return "grass_tuft";
    case "marsh":
      return "reed";
    default:
      return "grass_tuft";
  }
}

// src/extensions/worldgen/harvest.ts
var HARVEST_NOTHING = "HARVEST.NOTHING";
var HARVEST_BAD_CELL = "HARVEST.BAD_CELL";
function isCellIndex(v) {
  return Number.isInteger(v) && v >= 0;
}
function peekResourceAt(scene, cell) {
  for (const r of scene.componentsOf(RESOURCE_TYPE)) {
    if (r.cell === cell && r.node !== null) return { kind: r.kind, source: "resource" };
  }
  for (const m of scene.componentsOf(SITE_TYPE)) {
    if (m.cell === cell && m.node !== null) return { kind: m.kind, source: "site" };
  }
  return null;
}
function harvestAt(scene, cell, opts = {}) {
  if (!isCellIndex(cell)) {
    return err(engineError(HARVEST_BAD_CELL, `\u683C\u5B50\u4E0B\u6807\u5FC5\u987B\u662F \u2265 0 \u7684\u6574\u6570\uFF0C\u6536\u5230 ${String(cell)}`));
  }
  for (const r of scene.componentsOf(RESOURCE_TYPE)) {
    if (r.cell !== cell || r.node === null) continue;
    const nodeId = r.node.id;
    const kind = r.kind;
    scene.destroy(nodeId);
    scene.flush();
    opts.onRelease?.(cell);
    return ok({ cell, kind, nodeId, source: "resource" });
  }
  for (const m of scene.componentsOf(SITE_TYPE)) {
    if (m.cell !== cell || m.node === null) continue;
    const nodeId = m.node.id;
    const kind = m.kind;
    scene.destroy(nodeId);
    scene.flush();
    opts.onRelease?.(cell);
    return ok({ cell, kind, nodeId, source: "site" });
  }
  return err(
    engineError(
      HARVEST_NOTHING,
      `\u683C\u5B50 ${String(cell)} \u4E0A\u6CA1\u6709\u8D44\u6E90\uFF08\u518D\u751F ${String(scene.countOf(RESOURCE_TYPE))} \u4E2A / \u6295\u653E\u70B9 ${String(scene.countOf(SITE_TYPE))} \u4E2A\uFF09`
    )
  );
}

// src/extensions/inventory/harvest-into.ts
function harvestInto(scene, cell, ownerId, opts = {}) {
  const amount = opts.amount ?? 1;
  const peek = peekResourceAt(scene, cell);
  if (peek === null) {
    return err(engineError(HARVEST_NOTHING, `\u683C\u5B50 ${String(cell)} \u4E0A\u6CA1\u6709\u8D44\u6E90`));
  }
  const added = addItem(scene, ownerId, peek.kind, amount);
  if (!added.ok) return added;
  const took = harvestAt(scene, cell, { onRelease: opts.onRelease });
  if (!took.ok) {
    return took;
  }
  return ok({ cell, kind: peek.kind, total: added.value });
}

// src/extensions/inventory/pickup.ts
var DEFAULT_MAX = 8;
function pickupNearby(scene, x, z, radius, ownerId, opts = {}) {
  if (!(radius >= 0)) return err(engineError("PICKUP.BAD_RADIUS", `\u62FE\u53D6\u534A\u5F84\u5FC5\u987B \u2265 0\uFF0C\u6536\u5230 ${radius}`));
  const max = Math.max(1, Math.floor(opts.max ?? DEFAULT_MAX));
  const amountOpt = opts.amount;
  const amountOf = typeof amountOpt === "function" ? amountOpt : () => amountOpt ?? 1;
  const cand = [];
  for (const m of scene.componentsOf(RESOURCE_TYPE)) {
    const node = m.node;
    if (node === null) continue;
    const p = node.worldPosition;
    const dx = p.x - x;
    const dz = p.y - z;
    const d2 = dx * dx + dz * dz;
    if (d2 > radius * radius) continue;
    const peek = peekResourceAt(scene, m.cell);
    if (peek === null) continue;
    cand.push({ nodeId: node.id, cell: m.cell, d2, kind: peek.kind });
  }
  cand.sort((a, b) => a.d2 !== b.d2 ? a.d2 - b.d2 : a.nodeId - b.nodeId);
  const seenCell = /* @__PURE__ */ new Set();
  const picked = [];
  let failed = null;
  let skippedSameCell = 0;
  for (const c of cand) {
    if (picked.length >= max) break;
    if (seenCell.has(c.cell)) {
      skippedSameCell++;
      continue;
    }
    seenCell.add(c.cell);
    const r = harvestInto(scene, c.cell, ownerId, { amount: amountOf(c.kind), onRelease: opts.onRelease });
    if (!r.ok) {
      if (r.error.code === HARVEST_NOTHING) continue;
      failed = { cell: c.cell, code: r.error.code, message: r.error.message };
      break;
    }
    picked.push({ cell: r.value.cell, kind: r.value.kind, total: r.value.total });
  }
  return ok({
    picked,
    failed,
    remaining: Math.max(0, cand.length - picked.length),
    inRange: cand.length
  });
}

// src/extensions/inventory/drop-to-world.ts
var DROP_NO_SPACE = "DROP.NO_SPACE";
var DROP_UNKNOWN_KIND = "DROP.UNKNOWN_KIND";
function findFreeCells(plan, tasks, x, z, n, searchCells = 3) {
  if (n <= 0) return [];
  const width = plan.width;
  const height = plan.height;
  const cx = Math.floor(x);
  const cz = Math.floor(z);
  const base = Math.max(0, Math.floor(searchCells));
  const out = [];
  for (let r = 0; r <= base + 2 && out.length < n; r++) {
    for (let dz = -r; dz <= r && out.length < n; dz++) {
      for (let dx = -r; dx <= r && out.length < n; dx++) {
        if (r > 0 && Math.abs(dx) !== r && Math.abs(dz) !== r) continue;
        const gx = cx + dx;
        const gz = cz + dz;
        if (gx < 0 || gx >= width || gz < 0 || gz >= height) continue;
        const cell = gz * width + gx;
        if (!isPassable(plan.kinds[cell])) continue;
        if (tasks.isOccupied(cell)) continue;
        out.push(cell);
      }
    }
  }
  return out.length >= n ? out : null;
}
function dropIntoWorld(scene, ownerId, kind, n, opts) {
  if (!Number.isInteger(n) || n <= 0) {
    return err(engineError("INVENTORY.BAD_COUNT", `\u4E22\u5F03\u6570\u91CF\u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF0C\u6536\u5230 ${String(n)}`));
  }
  if (!isSiteKind(kind)) {
    return err(engineError(DROP_UNKNOWN_KIND, `\u8FD9\u4E2A\u4E16\u754C\u4E0D\u8BA4\u8BC6\u300C${kind}\u300D\uFF0C\u653E\u4E0D\u4E0B\u53BB`));
  }
  const owner = scene.find(ownerId);
  if (owner === void 0) {
    return err(engineError("INVENTORY.NO_OWNER", `\u8282\u70B9 ${String(ownerId)} \u4E0D\u5728\u573A\u666F\u91CC`));
  }
  if (owner.get(INVENTORY_TYPE) === void 0) {
    return err(engineError("INVENTORY.NO_OWNER", `\u8282\u70B9 ${String(ownerId)} \u6CA1\u6709\u80CC\u5305\u7EC4\u4EF6`));
  }
  const has = countItem(scene, ownerId, kind);
  if (has < n) {
    return err(engineError("INVENTORY.NOT_ENOUGH", `\u53EA\u6709 ${String(has)} \u4E2A ${kind}\uFF0C\u8981\u4E22 ${String(n)} \u4E2A`));
  }
  const cells = findFreeCells(opts.plan, opts.tasks, opts.x, opts.z, n, opts.searchCells);
  if (cells === null) {
    return err(
      engineError(
        DROP_NO_SPACE,
        `\u9644\u8FD1\u6CA1\u6709\u8DB3\u591F\u591A\u7684\u7A7A\u5730\u653E\u4E0B ${String(n)} \u4E2A${kind}\uFF08\u5DF2\u5916\u6269\u5230 ${String(Math.max(0, Math.floor(opts.searchCells ?? 3)) + 2)} \u683C\uFF09`
      )
    );
  }
  const nodeIds = [];
  for (const cell of cells) {
    const placed = opts.tasks.placeResource(cell, kind, opts.bornTick);
    if (!placed.ok) {
      for (let i = 0; i < nodeIds.length; i++) {
        scene.destroy(nodeIds[i]);
        opts.tasks.releaseCell(cells[i]);
      }
      scene.flush();
      return placed;
    }
    nodeIds.push(placed.value);
  }
  const took = takeItem(scene, ownerId, kind, n);
  if (!took.ok) return took;
  return ok({ cells, nodeIds, dropped: n });
}

// src/extensions/ui/font.ts
function kerningKey(first, second) {
  return first * 2097152 + second;
}
var FONT_ERR = {
  NO_COMMON: "UI.FONT_NO_COMMON",
  BAD_SCALE: "UI.FONT_BAD_SCALE",
  BAD_LINE_HEIGHT: "UI.FONT_BAD_LINE_HEIGHT",
  BAD_BASE: "UI.FONT_BAD_BASE",
  NO_GLYPHS: "UI.FONT_NO_GLYPHS",
  DUP_GLYPH: "UI.FONT_DUP_GLYPH",
  GLYPH_OOB: "UI.FONT_GLYPH_OOB",
  BAD_ADVANCE: "UI.FONT_BAD_ADVANCE",
  BAD_NUMBER: "UI.FONT_BAD_NUMBER",
  UNSUPPORTED_FORMAT: "UI.FONT_UNSUPPORTED_FORMAT"
};
function parseBmFont(text, opts = {}) {
  const id = opts.id ?? "font";
  const pageBase = opts.pageBase ?? 0;
  if (!Number.isInteger(pageBase) || pageBase < 0) {
    return err(engineError(FONT_ERR.BAD_NUMBER, `pageBase \u5FC5\u987B\u662F\u975E\u8D1F\u6574\u6570\uFF1A${String(pageBase)}`));
  }
  const head = text.slice(0, 4);
  if (head.startsWith("BMF")) {
    return err(
      engineError(FONT_ERR.UNSUPPORTED_FORMAT, "\u8FD9\u662F BMFont \u4E8C\u8FDB\u5236\u683C\u5F0F\uFF0C\u5F53\u524D\u53EA\u652F\u6301\u6587\u672C\u683C\u5F0F\uFF08.fnt\uFF09")
    );
  }
  if (head.trimStart().startsWith("<")) {
    return err(engineError(FONT_ERR.UNSUPPORTED_FORMAT, "\u8FD9\u662F BMFont XML \u683C\u5F0F\uFF0C\u5F53\u524D\u53EA\u652F\u6301\u6587\u672C\u683C\u5F0F\uFF08.fnt\uFF09"));
  }
  let size = 0;
  let lineHeight = 0;
  let base = 0;
  let scaleW = 0;
  let scaleH = 0;
  let sawCommon = false;
  const pages = [];
  const rawChars = [];
  const kernings = /* @__PURE__ */ new Map();
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line === "") continue;
    const sp = line.indexOf(" ");
    const tag = sp < 0 ? line : line.slice(0, sp);
    const rest = sp < 0 ? "" : line.slice(sp + 1);
    if (tag === "info") {
      const kv = parseKeyValues(rest);
      const s = num(kv, "size");
      if (s === void 0) return err(engineError(FONT_ERR.BAD_NUMBER, `info \u884C\u7F3A\u5C11 size\uFF1A${line}`));
      size = s;
    } else if (tag === "common") {
      const kv = parseKeyValues(rest);
      const lh = num(kv, "lineHeight");
      const bs = num(kv, "base");
      const sw = num(kv, "scaleW");
      const sh = num(kv, "scaleH");
      if (lh === void 0 || bs === void 0 || sw === void 0 || sh === void 0) {
        return err(engineError(FONT_ERR.BAD_NUMBER, `common \u884C\u7F3A\u5B57\u6BB5\uFF1A${line}`));
      }
      lineHeight = lh;
      base = bs;
      scaleW = sw;
      scaleH = sh;
      sawCommon = true;
    } else if (tag === "page") {
      const kv = parseKeyValues(rest);
      const pid = num(kv, "id");
      if (pid === void 0) return err(engineError(FONT_ERR.BAD_NUMBER, `page \u884C\u7F3A\u5C11 id\uFF1A${line}`));
      pages.push({ id: pid, file: kv.get("file") ?? "" });
    } else if (tag === "char") {
      const kv = parseKeyValues(rest);
      const code = num(kv, "id");
      const x = num(kv, "x");
      const y = num(kv, "y");
      const w = num(kv, "width");
      const h = num(kv, "height");
      const xa = num(kv, "xadvance");
      if (code === void 0 || x === void 0 || y === void 0 || w === void 0 || h === void 0 || xa === void 0) {
        return err(engineError(FONT_ERR.BAD_NUMBER, `char \u884C\u7F3A\u5B57\u6BB5\uFF1A${line}`));
      }
      rawChars.push({
        code,
        x,
        y,
        w,
        h,
        xo: num(kv, "xoffset") ?? 0,
        yo: num(kv, "yoffset") ?? 0,
        xa,
        pg: num(kv, "page") ?? 0
      });
    } else if (tag === "kerning") {
      const kv = parseKeyValues(rest);
      const first = num(kv, "first");
      const second = num(kv, "second");
      const amount = num(kv, "amount");
      if (first === void 0 || second === void 0 || amount === void 0) {
        return err(engineError(FONT_ERR.BAD_NUMBER, `kerning \u884C\u7F3A\u5B57\u6BB5\uFF1A${line}`));
      }
      kernings.set(kerningKey(first, second), amount);
    }
  }
  if (!sawCommon) {
    return err(engineError(FONT_ERR.NO_COMMON, "\u7F3A\u5C11 common \u884C\uFF08\u62FF\u4E0D\u5230 lineHeight / scaleW / scaleH\uFF09"));
  }
  if (!(scaleW > 0) || !(scaleH > 0)) {
    return err(engineError(FONT_ERR.BAD_SCALE, `\u7EB9\u7406\u9875\u5C3A\u5BF8\u5FC5\u987B > 0\uFF1A${scaleW}x${scaleH}`, { scaleW, scaleH }));
  }
  if (!(lineHeight > 0)) {
    return err(engineError(FONT_ERR.BAD_LINE_HEIGHT, `lineHeight \u5FC5\u987B > 0\uFF1A${lineHeight}`));
  }
  if (!Number.isFinite(base) || base < 0) {
    return err(engineError(FONT_ERR.BAD_BASE, `base \u5FC5\u987B \u2265 0\uFF1A${base}`));
  }
  if (rawChars.length === 0) return err(engineError(FONT_ERR.NO_GLYPHS, "\u6CA1\u6709\u4EFB\u4F55 char \u884C"));
  if (pages.length === 0) pages.push({ id: 0, file: "" });
  const glyphs = /* @__PURE__ */ new Map();
  for (const c of rawChars) {
    if (glyphs.has(c.code)) {
      return err(engineError(FONT_ERR.DUP_GLYPH, `\u5B57\u7B26 ${c.code} \u91CD\u590D\u5B9A\u4E49`, { code: c.code }));
    }
    if (!Number.isFinite(c.xa) || c.xa < 0) {
      return err(engineError(FONT_ERR.BAD_ADVANCE, `\u5B57\u7B26 ${c.code} \u7684 xadvance \u975E\u6CD5\uFF1A${c.xa}`, { code: c.code }));
    }
    if (c.x < 0 || c.y < 0 || c.w < 0 || c.h < 0 || c.x + c.w > scaleW || c.y + c.h > scaleH) {
      return err(
        engineError(
          FONT_ERR.GLYPH_OOB,
          `\u5B57\u7B26 ${c.code} \u7684\u77E9\u5F62\u8D85\u51FA\u7EB9\u7406\u9875 ${scaleW}x${scaleH}\uFF1Ax=${c.x} y=${c.y} w=${c.w} h=${c.h}`,
          { code: c.code }
        )
      );
    }
    if (c.pg < 0 || c.pg >= pages.length) {
      return err(
        engineError(FONT_ERR.BAD_NUMBER, `\u5B57\u7B26 ${c.code} \u5F15\u7528\u4E0D\u5B58\u5728\u7684\u9875 ${c.pg}\uFF08\u5171 ${pages.length} \u9875\uFF09`, {
          code: c.code
        })
      );
    }
    const w = c.w;
    const h = c.h;
    glyphs.set(c.code, {
      code: c.code,
      // 校验用局部页号（`c.pg`），落表用全局页号（`c.pg + pageBase`）——
      // 这两个数在单页字体里恰好相等，于是"忘了换算"在 5×7 上完全看不出来。
      page: c.pg + pageBase,
      // ★ 恒等映射，理由见文件头。
      u0: c.x / scaleW,
      v0: c.y / scaleH,
      u1: (c.x + w) / scaleW,
      v1: (c.y + h) / scaleH,
      width: w,
      height: h,
      xoffset: c.xo,
      yoffset: c.yo,
      xadvance: c.xa
    });
  }
  return ok({
    id,
    size,
    lineHeight,
    base,
    scaleW,
    scaleH,
    pages,
    glyphs,
    kernings,
    // 缺字占位：半个字号是"看得见有个东西缺了、但不会把行撑开"的折中。
    missingAdvance: size > 0 ? size / 2 : lineHeight / 2
  });
}
function kerningOf(font, first, second) {
  return font.kernings.get(kerningKey(first, second)) ?? 0;
}
var FontRegistry = class {
  fonts = /* @__PURE__ */ new Map();
  listeners = /* @__PURE__ */ new Set();
  /**
   * 订阅"字体表变了"。
   *
   * ★★ 为什么必须有这个通知，而不是让调用方记得手动清缓存：
   *   文本排版结果里**烘进了字形来源**（`page` 下标、UV、`xadvance`、kerning）。
   *   热重载一个字体（同 id、不同图集或不同字号）之后，旧缓存里的四边形
   *   指向的是**旧图集的坐标** —— 画面上字会变成另一堆乱码/空白，
   *   而布局量出来的宽高还是旧的。
   *   让"谁改字体"顺手记得"谁清缓存"是不可靠的：注册点可能有三处
   *   （启动、编辑器导入、热重载），漏一处就复现一次。
   *   所以通知由**表自己**发：改了表就等于旧缓存作废，这条因果关系写在源头。
   *
   * 返回退订函数（dispose 时调用，避免模块销毁后还被通知）。
   */
  onRegister(cb) {
    this.listeners.add(cb);
    return () => {
      this.listeners.delete(cb);
    };
  }
  register(font) {
    if (this.fonts.has(font.id)) {
      this.fonts.delete(font.id);
    }
    this.fonts.set(font.id, font);
    for (const cb of this.listeners) cb();
  }
  get(id) {
    return this.fonts.get(id);
  }
  require(id) {
    const f = this.fonts.get(id);
    if (f === void 0) {
      throw new Error(`\u5B57\u4F53\u672A\u6CE8\u518C\uFF1A${id}\uFF08\u5DF2\u6CE8\u518C\uFF1A${Array.from(this.fonts.keys()).sort().join(", ") || "\u65E0"}\uFF09`);
    }
    return f;
  }
  ids() {
    return Array.from(this.fonts.keys()).sort();
  }
};
function parseKeyValues(rest) {
  const out = /* @__PURE__ */ new Map();
  let i = 0;
  const n = rest.length;
  while (i < n) {
    while (i < n && rest[i] === " ") i++;
    const eq = rest.indexOf("=", i);
    if (eq < 0) break;
    const key = rest.slice(i, eq).trim();
    i = eq + 1;
    let value;
    if (rest[i] === '"') {
      const close = rest.indexOf('"', i + 1);
      if (close < 0) {
        value = rest.slice(i + 1);
        i = n;
      } else {
        value = rest.slice(i + 1, close);
        i = close + 1;
      }
    } else {
      const next = rest.indexOf(" ", i);
      if (next < 0) {
        value = rest.slice(i);
        i = n;
      } else {
        value = rest.slice(i, next);
        i = next;
      }
    }
    if (key !== "") out.set(key, value);
  }
  return out;
}
function num(kv, key) {
  const raw = kv.get(key);
  if (raw === void 0) return void 0;
  const v = Number(raw);
  return Number.isFinite(v) ? v : void 0;
}

// src/extensions/ui/viewport.ts
var UiScaleMode = { Fit: "fit", Fill: "fill", Expand: "expand" };
var ZERO_INSETS = { top: 0, right: 0, bottom: 0, left: 0 };
var UiViewport = class {
  designWidth;
  designHeight;
  scaleMode;
  cssW = 1;
  cssH = 1;
  dpr = 1;
  scaleValue = 1;
  safe = ZERO_INSETS;
  /** 复用同一个相机实例：每帧 new 一个会白白产生垃圾，而且外部持有的引用会失效。 */
  cam;
  constructor(cfg) {
    if (!(cfg.designWidth > 0) || !(cfg.designHeight > 0)) {
      throw new RangeError(`\u8BBE\u8BA1\u5206\u8FA8\u7387\u5FC5\u987B > 0\uFF1A${cfg.designWidth}x${cfg.designHeight}`);
    }
    this.designWidth = cfg.designWidth;
    this.designHeight = cfg.designHeight;
    this.scaleMode = cfg.scaleMode ?? UiScaleMode.Expand;
    this.safe = cfg.safeArea ?? ZERO_INSETS;
    this.cam = new Camera2D({
      viewportWidth: 1,
      viewportHeight: 1,
      zoom: 1,
      // ★ 1 = 无俯视压缩。UI 是纯 2D，任何 tiltY 都会把字压扁。
      tiltY: 1,
      x: cfg.designWidth / 2,
      z: cfg.designHeight / 2
    });
    this.apply();
  }
  /** 宿主每帧（或窗口变化时）推进来。尺寸非正时忽略（与 Camera2D.setViewport 一致）。 */
  setScreen(cssWidth, cssHeight, dpr = 1) {
    if (!(cssWidth > 0) || !(cssHeight > 0)) return;
    if (!(dpr > 0) || !Number.isFinite(dpr)) return;
    this.cssW = cssWidth;
    this.cssH = cssHeight;
    this.dpr = dpr;
    this.apply();
  }
  setScaleMode(m) {
    this.scaleMode = m;
    this.apply();
  }
  setSafeArea(insets) {
    this.safe = insets;
  }
  /** 绘制像素尺寸（= CSS 像素 × dpr）。`makeCamera` 用它设 viewport。 */
  get pixelWidth() {
    return this.cssW * this.dpr;
  }
  get pixelHeight() {
    return this.cssH * this.dpr;
  }
  /** 一个设计像素对应多少**绘制**像素。 */
  get scale() {
    return this.scaleValue;
  }
  /** 设计框本身（恒为原点起始）。 */
  get designRect() {
    return new Rect(0, 0, this.designWidth, this.designHeight);
  }
  /**
   * 屏幕在设计坐标系里覆盖的范围。
   * `fit` 时比设计框**大**（每边留黑边），`fill`/`expand` 时可能比设计框小（裁边）。
   */
  get screenRect() {
    const w = this.cssW / this.scaleValue;
    const h = this.cssH / this.scaleValue;
    return new Rect((this.designWidth - w) / 2, (this.designHeight - h) / 2, w, h);
  }
  /**
   * **锚点参考矩形**：`anchor` 为 0/0.5/1 时贴的是这条边。
   *
   * · `fit` / `fill` 贴**设计框**（内容不越界，这是"设计分辨率"的语义）
   * · `expand`       贴**屏幕范围**（多出来的区域也算可用，HUD 贴屏幕边）
   *
   * ★ 只有 `expand` 的参考区比设计框**大**（因为它用 min 缩放，另一个轴必然多出来），
   *   所以"贴屏幕左上的血条在超宽屏上不会被裁出屏幕"这条只有它成立。
   */
  get anchorRect() {
    if (this.scaleMode === UiScaleMode.Expand) return this.screenRect;
    return this.designRect;
  }
  /** 锚点参考矩形扣掉安全区。刘海屏上的可点区域用它。 */
  get safeRect() {
    const r = this.anchorRect;
    const top = Math.min(this.safe.top, r.height / 2);
    const bottom = Math.min(this.safe.bottom, r.height / 2 - top);
    const left = Math.min(this.safe.left, r.width / 2);
    const right = Math.min(this.safe.right, r.width / 2 - left);
    return new Rect(r.x + left, r.y + top, r.width - left - right, r.height - top - bottom);
  }
  /** CSS 像素 → 设计坐标。 */
  screenToDesign(px, py) {
    return {
      x: this.designWidth / 2 + (px - this.cssW / 2) / this.scaleValue,
      y: this.designHeight / 2 + (py - this.cssH / 2) / this.scaleValue
    };
  }
  /** 设计坐标 → CSS 像素。 */
  designToScreen(x, y) {
    return {
      x: this.cssW / 2 + (x - this.designWidth / 2) * this.scaleValue,
      y: this.cssH / 2 + (y - this.designHeight / 2) * this.scaleValue
    };
  }
  /**
   * 与 2.5D 场景**共用**的相机对象（`Camera2D` 只是一条投影函数，谁都能拿一个）。
   * UI 相机的世界单位 = 设计像素，所以 `zoom = scale`、`tiltY = 1`。
   */
  get camera() {
    return this.cam;
  }
  apply() {
    const pw = this.pixelWidth;
    const ph = this.pixelHeight;
    const sx = pw / this.designWidth;
    const sy = ph / this.designHeight;
    this.scaleValue = this.scaleMode === UiScaleMode.Fill ? Math.max(sx, sy) : Math.min(sx, sy);
    if (!(this.scaleValue > 0) || !Number.isFinite(this.scaleValue)) this.scaleValue = 1;
    this.cam.setViewport(pw, ph);
    this.cam.zoom = this.scaleValue;
    this.cam.tiltY = 1;
    this.cam.moveTo(this.designWidth / 2, this.designHeight / 2);
  }
};

// src/extensions/ui/layout.ts
var UiLayoutKind = { Free: "free", Row: "row", Column: "column", Grid: "grid" };
var UiWidget = {
  Group: "group",
  Panel: "panel",
  Image: "image",
  Label: "label",
  Button: "button",
  Progress: "progress",
  Spacer: "spacer"
};
var ANCHOR_TOP_LEFT = { x: 0, y: 0 };
var ANCHOR_CENTER = { x: 0.5, y: 0.5 };
var nextNodeId = 1;
var UiNode = class _UiNode {
  uid;
  id;
  widget;
  kind;
  anchor;
  pivot;
  offset;
  size;
  percent;
  grow;
  padding;
  margin;
  gap;
  columns;
  cell;
  visible;
  /**
   * 自身不透明度 0..1（默认 1）。
   *
   * ★ 为什么是"自身"而不是"最终"：过渡动画（批76 `tween.player`）要能把父节点淡到 0.5、
   *   子节点淡到 0.5 而得到 0.25。若这里存的是最终值，动画一改父节点就得遍历子树重算 ——
   *   而"遍历子树"与"每帧"叠在一起就是 O(节点数) 的隐式成本，且父子谁覆盖谁说不清。
   *   最终值在**画的时候**乘出来（`widgets.ts` 的 `alphaOf`），是纯粹的读取。
   *
   * ★ 语义边界：`opacity` **不参与布局**（不透明的东西和透明的占一样的位置）。
   *   要"不占位"用 `visible=false` —— 两者是两件事（见文件头 ★）。
   */
  opacity;
  /**
   * 自身缩放 1 = 原尺寸，绕 `pivot` 缩放。
   *
   * ★ **不改 `measured`**：改 measured 会让父容器的流式布局把"放大到 1.2 倍"算进尺寸，
   *   于是弹一下的按钮会把它后面的按钮挤开。过渡要的是"原地变大"，不是"重新排版"。
   * ★ **沿父链组合**（见 `arrange` 的注释）：父 2 倍、子再 2 倍 ⇒ 子看到的是 4 倍，
   *   位置也一起放大 —— 一组 UI 弹出时是整体放大，不是各自从自己的左上角长。
   */
  scale;
  interactive;
  opaque;
  contentSize;
  props;
  children = [];
  parent = null;
  /** 布局结果（设计坐标，绝对值）。 */
  rect = Rect.zero;
  /** 测量阶段的自然尺寸。 */
  measured = { w: 0, h: 0 };
  constructor(cfg = {}) {
    this.uid = nextNodeId++;
    this.id = cfg.id ?? `#${this.uid}`;
    this.widget = cfg.widget ?? UiWidget.Group;
    this.kind = cfg.kind ?? UiLayoutKind.Free;
    this.anchor = cfg.anchor ?? ANCHOR_TOP_LEFT;
    this.pivot = cfg.pivot ?? ANCHOR_TOP_LEFT;
    this.offset = cfg.offset ?? { x: 0, y: 0 };
    this.size = { ...cfg.size ?? {} };
    this.percent = { ...cfg.percent ?? {} };
    this.grow = cfg.grow ?? 0;
    this.padding = {
      top: cfg.padding?.top ?? 0,
      right: cfg.padding?.right ?? 0,
      bottom: cfg.padding?.bottom ?? 0,
      left: cfg.padding?.left ?? 0
    };
    this.margin = {
      top: cfg.margin?.top ?? 0,
      right: cfg.margin?.right ?? 0,
      bottom: cfg.margin?.bottom ?? 0,
      left: cfg.margin?.left ?? 0
    };
    this.gap = cfg.gap ?? 0;
    this.columns = Math.max(1, Math.floor(cfg.columns ?? 1));
    this.cell = cfg.cell === void 0 ? null : { w: cfg.cell.w, h: cfg.cell.h };
    this.visible = cfg.visible ?? true;
    this.opacity = clampOpacity(cfg.opacity ?? 1);
    this.scale = clampScale(cfg.scale ?? 1);
    this.interactive = cfg.interactive ?? false;
    this.opaque = cfg.opaque ?? false;
    this.contentSize = { w: cfg.contentSize?.w ?? 0, h: cfg.contentSize?.h ?? 0 };
    this.props = cfg.props ?? {};
    for (const c of cfg.children ?? []) this.add(new _UiNode(c));
  }
  add(child) {
    child.parent = this;
    this.children.push(child);
  }
  /** 从前序（绘制顺序）里取所有节点。 */
  *walk() {
    yield this;
    for (const c of this.children) yield* c.walk();
  }
  find(id) {
    for (const n of this.walk()) if (n.id === id) return n;
    return void 0;
  }
  /**
   * 内区（只扣 padding）。流式布局摆放子节点用它。
   * ★ 这里**不扣 margin**：margin 是"节点相对父容器"的外边距，作用于自身被摆放的位置，
   *   扣进内区会让它同时影响"自己占多大"和"子节点从哪开始"——两处都少一点，叠加起来偏得很隐蔽。
   */
  inner(rect) {
    const l = this.padding.left;
    const t = this.padding.top;
    const r = this.padding.right;
    const b = this.padding.bottom;
    return new Rect(
      rect.x + l,
      rect.y + t,
      Math.max(0, rect.width - l - r),
      Math.max(0, rect.height - t - b)
    );
  }
};
function layoutTree(root, bounds, opts = {}) {
  root.rect = bounds;
  measure(root, bounds.width, bounds.height, opts);
  arrange(root, bounds, 1, 0, 0);
  const out = /* @__PURE__ */ new Map();
  for (const n of root.walk()) {
    if (n === root) continue;
    if (!n.visible) continue;
    if (out.has(n.id)) {
      throw new Error(`UI \u8282\u70B9 id \u91CD\u590D\uFF1A${n.id}\uFF08\u540C\u4E00\u68F5\u6811\u91CC id \u5FC5\u987B\u552F\u4E00\uFF0C\u5426\u5219\u547D\u4E2D\u6D4B\u8BD5\u4F1A\u6253\u5230\u9519\u7684\u90A3\u4E2A\uFF09`);
    }
    out.set(n.id, n.rect);
  }
  return out;
}
function measure(node, availW, availH, opts) {
  if (!node.visible) {
    node.measured = { w: 0, h: 0 };
    return;
  }
  const fixedW = node.size.w;
  const fixedH = node.size.h;
  const pctW = node.percent.w;
  const pctH = node.percent.h;
  const innerW = fixedW ?? (pctW !== void 0 ? availW * pctW : availW);
  const innerH = fixedH ?? (pctH !== void 0 ? availH * pctH : availH);
  const padW = Math.max(0, innerW - node.padding.left - node.padding.right);
  const padH = Math.max(0, innerH - node.padding.top - node.padding.bottom);
  const nat = opts.intrinsic?.(node, padW, padH) ?? null;
  if (nat !== null) node.contentSize = { w: nat.w, h: nat.h };
  let contentW = 0;
  let contentH = 0;
  if (node.kind === UiLayoutKind.Row || node.kind === UiLayoutKind.Column) {
    let mainTotal = 0;
    let crossMax = 0;
    let count = 0;
    for (const c of node.children) {
      if (!c.visible) continue;
      measure(c, padW, padH, opts);
      count++;
      const w2 = c.measured.w + c.margin.left + c.margin.right;
      const h2 = c.measured.h + c.margin.top + c.margin.bottom;
      if (node.kind === UiLayoutKind.Row) {
        mainTotal += w2;
        crossMax = Math.max(crossMax, h2);
      } else {
        mainTotal += h2;
        crossMax = Math.max(crossMax, w2);
      }
    }
    if (count > 0) mainTotal += node.gap * (count - 1);
    if (node.kind === UiLayoutKind.Row) {
      contentW = mainTotal;
      contentH = crossMax;
    } else {
      contentW = crossMax;
      contentH = mainTotal;
    }
  } else if (node.kind === UiLayoutKind.Grid) {
    const cols = node.columns;
    let cw = node.cell?.w ?? 0;
    let ch = node.cell?.h ?? 0;
    let maxCellW = 0;
    let maxCellH = 0;
    let n = 0;
    for (const c of node.children) {
      if (!c.visible) continue;
      measure(c, padW, padH, opts);
      maxCellW = Math.max(maxCellW, c.measured.w + c.margin.left + c.margin.right);
      maxCellH = Math.max(maxCellH, c.measured.h + c.margin.top + c.margin.bottom);
      n++;
    }
    if (cw === 0) cw = maxCellW;
    if (ch === 0) ch = maxCellH;
    const rows = Math.ceil(n / cols);
    contentW = rows === 0 ? 0 : cols * cw + node.gap * (cols - 1);
    contentH = rows === 0 ? 0 : rows * ch + node.gap * (rows - 1);
    node.cell = { w: cw, h: ch };
  } else {
    for (const c of node.children) {
      if (!c.visible) continue;
      measure(c, padW, padH, opts);
    }
    contentW = 0;
    contentH = 0;
  }
  const w = fixedW ?? (pctW !== void 0 ? availW * pctW : Math.max(contentW, node.contentSize.w));
  const h = fixedH ?? (pctH !== void 0 ? availH * pctH : Math.max(contentH, node.contentSize.h));
  node.measured = { w: clampSize(w), h: clampSize(h) };
}
function clampSize(v) {
  if (!Number.isFinite(v) || v < 0) return 0;
  return v;
}
function clampOpacity(v) {
  if (!Number.isFinite(v)) return 1;
  return v < 0 ? 0 : v > 1 ? 1 : v;
}
function clampScale(v) {
  if (!Number.isFinite(v)) return 1;
  return v < 0 ? 0 : v;
}
function anchoredPos(node, parentInner) {
  const w = node.measured.w;
  const h = node.measured.h;
  const x = parentInner.x + node.margin.left + node.anchor.x * parentInner.width - node.pivot.x * w + node.offset.x;
  const y = parentInner.y + node.margin.top + node.anchor.y * parentInner.height - node.pivot.y * h + node.offset.y;
  return { x, y };
}
function arrange(node, slot, sIn, oxIn, oyIn) {
  if (!node.visible) return;
  let s = sIn;
  let ox = oxIn;
  let oy = oyIn;
  if (node.scale !== 1) {
    const px = slot.x + node.pivot.x * slot.width;
    const py = slot.y + node.pivot.y * slot.height;
    const offX = px * (1 - node.scale);
    const offY = py * (1 - node.scale);
    s = sIn * node.scale;
    ox = sIn * offX + oxIn;
    oy = sIn * offY + oyIn;
  }
  node.rect = s === 1 ? slot : new Rect(s * slot.x + ox, s * slot.y + oy, slot.width * s, slot.height * s);
  const inner = node.inner(slot);
  if (node.kind === UiLayoutKind.Free) {
    for (const c of node.children) {
      if (!c.visible) continue;
      const p = anchoredPos(c, inner);
      arrange(c, new Rect(p.x, p.y, c.measured.w, c.measured.h), s, ox, oy);
    }
    return;
  }
  if (node.kind === UiLayoutKind.Row || node.kind === UiLayoutKind.Column) {
    const isRow = node.kind === UiLayoutKind.Row;
    const mainLen = isRow ? inner.width : inner.height;
    const visibles = node.children.filter((c) => c.visible);
    const gaps = node.gap * Math.max(0, visibles.length - 1);
    let used = 0;
    let growTotal = 0;
    for (const c of visibles) {
      const m = isRow ? c.measured.w + c.margin.left + c.margin.right : c.measured.h + c.margin.top + c.margin.bottom;
      used += m;
      growTotal += Math.max(0, c.grow);
    }
    const remain = Math.max(0, mainLen - used - gaps);
    let cursor = 0;
    for (const c of visibles) {
      const baseMain = isRow ? c.measured.w + c.margin.left + c.margin.right : c.measured.h + c.margin.top + c.margin.bottom;
      const extra = growTotal > 0 ? remain * Math.max(0, c.grow) / growTotal : 0;
      const mainSize = baseMain + extra;
      const crossSize = isRow ? c.measured.h + c.margin.top + c.margin.bottom : c.measured.w + c.margin.left + c.margin.right;
      const x = isRow ? inner.x + cursor + c.margin.left : inner.x + c.margin.left;
      const y = isRow ? inner.y + c.margin.top : inner.y + cursor + c.margin.top;
      const w = isRow ? Math.max(0, mainSize - c.margin.left - c.margin.right) : Math.max(0, crossSize - c.margin.left - c.margin.right);
      const h = isRow ? Math.max(0, crossSize - c.margin.top - c.margin.bottom) : Math.max(0, mainSize - c.margin.top - c.margin.bottom);
      arrange(c, new Rect(x, y, w, h), s, ox, oy);
      cursor += mainSize + node.gap;
    }
    return;
  }
  const cols = Math.max(1, node.columns);
  const cw = node.cell?.w ?? 0;
  const ch = node.cell?.h ?? 0;
  let i = 0;
  for (const c of node.children) {
    if (!c.visible) continue;
    const col = i % cols;
    const row = Math.floor(i / cols);
    const x = inner.x + col * (cw + node.gap) + c.margin.left;
    const y = inner.y + row * (ch + node.gap) + c.margin.top;
    arrange(c, new Rect(x, y, Math.max(0, cw - c.margin.left - c.margin.right), Math.max(0, ch - c.margin.top - c.margin.bottom)), s, ox, oy);
    i++;
  }
}
function hitTest(root, x, y) {
  const stack = [];
  for (const n of root.walk()) if (n.visible) stack.push(n);
  for (let i = stack.length - 1; i >= 0; i--) {
    const n = stack[i];
    const r = n.rect;
    if (x < r.x || x > r.xMax || y < r.y || y > r.yMax) continue;
    if (n.interactive) return n;
    if (n.opaque) return null;
  }
  return null;
}
function hitChain(node) {
  const chain = [];
  let cur = node;
  while (cur !== null) {
    chain.push(cur);
    cur = cur.parent;
  }
  return chain;
}

// src/extensions/ui/intrinsic.ts
var BUTTON_TEXT_INSET = 4;
function textInsetOf(widget) {
  if (widget === UiWidget.Button) return BUTTON_TEXT_INSET;
  if (widget === UiWidget.Label) return 0;
  return -1;
}
function defaultFontId(fonts) {
  const ids = fonts.ids();
  return ids.length === 0 ? "" : ids[0];
}
function textStyleFor(node, boxWidth) {
  const p = node.props;
  const explicit = p.style?.maxWidth;
  const maxWidth = explicit !== void 0 && explicit > 0 ? explicit : boxWidth;
  return {
    ...p.style,
    maxWidth,
    align: p.style?.align ?? (node.widget === UiWidget.Button ? "center" : "left"),
    color: p.textColor ?? p.style?.color
  };
}
function textBoxOf(node, rect) {
  const inset = textInsetOf(node.widget);
  if (inset <= 0) return rect;
  const w = Math.max(0, rect.width - inset * 2);
  return new Rect(rect.x + inset, rect.y, w, rect.height);
}
function hasExplicitWidth(node) {
  return node.size.w !== void 0 || node.percent.w !== void 0;
}
function createIntrinsicMeasure(fonts, store) {
  return (node, innerW) => {
    const inset = textInsetOf(node.widget);
    if (inset < 0) return null;
    const text = node.props.text ?? "";
    if (text === "") return null;
    const pad = node.padding;
    const boxW = Math.max(0, innerW + pad.left + pad.right);
    const explicit = hasExplicitWidth(node);
    const wrap = explicit ? Math.max(0, boxW - inset * 2) : 0;
    const fontId = node.props.fontId ?? defaultFontId(fonts);
    const layout = store.text(node.uid, fonts, fontId, text, textStyleFor(node, wrap));
    if (layout === null) return null;
    if (explicit) {
      return { w: boxW, h: layout.height + pad.top + pad.bottom };
    }
    return {
      w: layout.width + inset * 2 + pad.left + pad.right,
      h: layout.height + pad.top + pad.bottom
    };
  };
}

// src/extensions/ui/text-layout.ts
var DEFAULT_ELLIPSIS = "\u2026";
function normalizeCodes(text) {
  const paragraphs = [];
  let cur = [];
  for (const ch of Array.from(text)) {
    const code = ch.codePointAt(0) ?? 0;
    if (ch === "\n") {
      paragraphs.push(cur);
      cur = [];
      continue;
    }
    if (ch === "\r") continue;
    if (ch === "	") {
      cur.push(32);
      continue;
    }
    if (code < 32 || code === 127) continue;
    cur.push(code);
  }
  paragraphs.push(cur);
  return paragraphs;
}
function breakAfter(code) {
  return code >= 11904 && code <= 40959 || code >= 63744 && code <= 64255 || code >= 12288 && code <= 12351 || code >= 65280 && code <= 65519;
}
function advanceOf(font, code, scale, letterSpacing) {
  const g = font.glyphs.get(code);
  const base = g === void 0 ? font.missingAdvance : g.xadvance;
  return base * scale + letterSpacing;
}
function tokenize(font, codes, scale, letterSpacing) {
  const out = [];
  let buf = [];
  let bufW = 0;
  const flush = (isSpace) => {
    if (buf.length === 0) return;
    out.push({ codes: buf, width: bufW + (isSpace ? 0 : 0), isSpace });
    buf = [];
    bufW = 0;
  };
  for (let i = 0; i < codes.length; i++) {
    const code = codes[i];
    if (code === 32) {
      flush(false);
      out.push({ codes: [code], width: advanceOf(font, code, scale, letterSpacing), isSpace: true });
      continue;
    }
    buf.push(code);
    bufW += advanceOf(font, code, scale, letterSpacing);
    const prev = codes[i - 1];
    if (prev !== void 0) bufW += kerningOf(font, prev, code) * scale;
    if (breakAfter(code)) flush(false);
  }
  flush(false);
  return out;
}
function lineWidthOf(font, codes, scale, letterSpacing) {
  let w = 0;
  for (let i = 0; i < codes.length; i++) {
    const code = codes[i];
    w += advanceOf(font, code, scale, letterSpacing);
    const prev = codes[i - 1];
    if (prev !== void 0) w += kerningOf(font, prev, code) * scale;
  }
  return w;
}
function trimTrailingSpaces(codes) {
  let end = codes.length;
  while (end > 0 && codes[end - 1] === 32) end--;
  return codes.slice(0, end);
}
function breakParagraph(font, codes, scale, letterSpacing, maxWidth) {
  if (maxWidth <= 0) return [trimTrailingSpaces(codes.slice())];
  const lines = [];
  let cur = [];
  let curW = 0;
  const pushLine = () => {
    lines.push(trimTrailingSpaces(cur));
    cur = [];
    curW = 0;
  };
  for (const tk of tokenize(font, codes, scale, letterSpacing)) {
    if (tk.isSpace) {
      if (cur.length === 0) continue;
      cur.push(...tk.codes);
      curW += tk.width;
      continue;
    }
    if (curW + tk.width <= maxWidth) {
      cur.push(...tk.codes);
      curW += tk.width;
      continue;
    }
    if (cur.length > 0) pushLine();
    if (tk.width <= maxWidth) {
      cur.push(...tk.codes);
      curW = tk.width;
      continue;
    }
    for (const code of tk.codes) {
      const cw = advanceOf(font, code, scale, letterSpacing);
      if (curW + cw > maxWidth && cur.length > 0) pushLine();
      cur.push(code);
      curW += cw;
    }
  }
  if (cur.length > 0 || lines.length === 0) lines.push(trimTrailingSpaces(cur));
  return lines;
}
function layoutText(font, text, style = {}) {
  const scale = style.scale ?? 1;
  const ls = style.letterSpacing ?? 0;
  const maxWidth = style.maxWidth ?? 0;
  const maxLines = style.maxLines ?? 0;
  const ellipsis = style.ellipsis ?? DEFAULT_ELLIPSIS;
  const align = style.align ?? "left";
  if (!(scale > 0)) throw new RangeError(`\u6587\u672C scale \u5FC5\u987B > 0\uFF1A${scale}`);
  const lineHeightPx = font.lineHeight * scale + (style.lineSpacing ?? 0);
  const paragraphs = normalizeCodes(text);
  const lines = [];
  for (const p of paragraphs) {
    const broken = breakParagraph(font, p, scale, ls, maxWidth);
    for (const l of broken) lines.push(l);
  }
  if (lines.length === 1 && lines[0].length === 0 && text.trim() === "") {
    lines.length = 0;
  }
  let truncated = false;
  if (maxLines > 0 && lines.length > maxLines) {
    lines.length = maxLines;
    truncated = true;
    if (lines.length === 0) lines.push([]);
    const last = lines[lines.length - 1];
    const ellCodes = Array.from(ellipsis).map((c) => c.codePointAt(0) ?? 0);
    if (maxWidth > 0) {
      const ellW = lineWidthOf(font, ellCodes, scale, ls);
      while (last.length > 0 && lineWidthOf(font, last, scale, ls) + ellW > maxWidth) last.pop();
      if (last.length === 0 && ellW > maxWidth) {
        lines[lines.length - 1] = [];
      } else {
        last.push(...ellCodes);
      }
    } else {
      last.push(...ellCodes);
    }
  }
  const lineWidths = lines.map((l) => lineWidthOf(font, l, scale, ls));
  const naturalWidth = lineWidths.reduce((m, w) => w > m ? w : m, 0);
  const boxWidth = maxWidth > 0 ? maxWidth : naturalWidth;
  const color = style.color;
  const quads = [];
  const missingSet = /* @__PURE__ */ new Set();
  for (let li = 0; li < lines.length; li++) {
    const codes = lines[li];
    const lw = lineWidths[li];
    let penX = 0;
    if (align === "center") penX = (boxWidth - lw) / 2;
    else if (align === "right") penX = boxWidth - lw;
    const lineTop = li * lineHeightPx;
    const baseline = lineTop + font.base * scale;
    for (let i = 0; i < codes.length; i++) {
      const code = codes[i];
      const g = font.glyphs.get(code);
      if (g === void 0) {
        missingSet.add(code);
        penX += font.missingAdvance * scale + ls;
        continue;
      }
      if (g.width > 0 && g.height > 0) {
        quads.push({
          page: g.page,
          x: penX + g.xoffset * scale,
          y: baseline + g.yoffset * scale,
          w: g.width * scale,
          h: g.height * scale,
          u0: g.u0,
          v0: g.v0,
          u1: g.u1,
          v1: g.v1,
          r: color?.r ?? 1,
          g: color?.g ?? 1,
          b: color?.b ?? 1,
          a: color?.a ?? 1
        });
      }
      penX += g.xadvance * scale + ls;
      const prev = codes[i - 1];
      if (prev !== void 0) penX += kerningOf(font, prev, code) * scale;
    }
  }
  return {
    quads,
    width: boxWidth,
    height: lines.length === 0 ? 0 : lines.length * lineHeightPx,
    lineCount: lines.length,
    truncated,
    missing: Array.from(missingSet).sort((a, b) => a - b)
  };
}

// src/extensions/ui/state.ts
var MAX_LAYOUT_ENTRIES = 1024;
var UiStateStore = class {
  layouts = /* @__PURE__ */ new Map();
  scrolls = /* @__PURE__ */ new Map();
  version = 1;
  hits = 0;
  misses = 0;
  evictions = 0;
  /** 当前失效代次。诊断用：两次报错之间没变过，说明不是缓存导致的。 */
  get epoch() {
    return this.version;
  }
  get stats() {
    return {
      epoch: this.version,
      layouts: this.layouts.size,
      scrolls: this.scrolls.size,
      hits: this.hits,
      misses: this.misses,
      evictions: this.evictions
    };
  }
  /**
   * 取一段文本的排版结果（派生缓存）。
   *
   * ★ 返回 `null` 表示**字体不存在**，而不是"空排版"：
   *   空排版会让调用方以为"这段文本就是 0 宽"，于是标签静默塌成 0×0；
   *   返回 null 时调用方必须自己决定是跳过还是回退 —— 那是一个明确的决定。
   *
   * ★ 键里**必须**含字体 id、文本、样式三样（原有的 `cacheKey` 规则）：
   *   只按节点缓存 ⇒ 改了文案没换节点会显示旧文本；
   *   只按文本缓存 ⇒ 两种字号互相污染。
   */
  text(uid, fonts, fontId, text, style) {
    const font = fonts.get(fontId);
    if (font === void 0) return null;
    const key = layoutCacheKey(fontId, text, style);
    const hit = this.layouts.get(uid);
    if (hit !== void 0 && hit.key === key) {
      this.hits++;
      return hit.layout;
    }
    this.misses++;
    const layout = layoutText(font, text, style);
    if (this.layouts.size >= MAX_LAYOUT_ENTRIES) {
      this.evictions += this.layouts.size;
      this.layouts.clear();
    }
    this.layouts.set(uid, { key, layout });
    return layout;
  }
  /** 丢掉一个节点的派生缓存（改了一个节点的文案后想立刻重算时用）。 */
  forget(uid) {
    if (this.layouts.delete(uid)) this.evictions++;
  }
  /**
   * 只丢派生缓存（字体热重载、UI 图集换页）。
   * ★ **不动滚动位置**：换一张字体不该让用户正在看的列表回顶。
   */
  invalidateDerived() {
    this.layouts.clear();
    this.version++;
  }
  /**
   * 全丢（换界面、回滚、dispose）。
   * ★ 回滚必须走这里：上一份世界里的滚动位置与文本量算都不该被这一份世界读到。
   *   `epoch` +1 让**任何持有旧代次的东西**（哪怕它绕过了本表）能自查出过期。
   */
  reset() {
    this.layouts.clear();
    this.scrolls.clear();
    this.version++;
  }
  /** 滚动偏移（设计像素，正值向下）。未滚过 = 0。 */
  scrollOf(uid) {
    return this.scrolls.get(uid) ?? 0;
  }
  /**
   * 写滚动偏移。
   *
   * ★ 非有限数**拒绝写入**（保持原值）而不是夹成 0：夹成 0 会把"算出来是 NaN"
   *   表现成"滚回顶部"，而那是最容易被当成"用户手滑"的症状。
   * ★ 负值夹到 0；上界由调用方按内容高度算（那一层才知道内容多高）。
   */
  setScroll(uid, value) {
    if (!Number.isFinite(value)) return;
    this.scrolls.set(uid, value < 0 ? 0 : value);
  }
  /** 丢一个节点的全部状态（节点被移除时）。 */
  drop(uid) {
    this.layouts.delete(uid);
    this.scrolls.delete(uid);
  }
};
function layoutCacheKey(fontId, text, style) {
  const c = style.color;
  return [
    fontId,
    text,
    style.scale ?? 1,
    style.align ?? "left",
    style.lineSpacing ?? 0,
    style.letterSpacing ?? 0,
    style.maxWidth ?? 0,
    style.maxLines ?? 0,
    style.ellipsis ?? "",
    c === void 0 ? "-" : `${c.r},${c.g},${c.b},${c.a}`
  ].join("");
}

// src/extensions/ui/widgets.ts
var UI_LAYER = 2;
function alphaOf(node) {
  let a = 1;
  for (let cur = node; cur !== null; cur = cur.parent) {
    a *= cur.opacity;
  }
  return a;
}
function buildUiQuads(root, fonts, skin, store) {
  const quads = [];
  let order = 0;
  let glyphs = 0;
  let labels = 0;
  const missingGlyphs = /* @__PURE__ */ new Set();
  const missingFrames = /* @__PURE__ */ new Set();
  const emit = (rect, page, uv, tint, ord, alpha = 1) => {
    if (rect.width <= 0 || rect.height <= 0) return;
    const a = (tint?.a ?? 1) * alpha;
    if (a <= 0) return;
    quads.push({
      nodeId: order,
      // ★ UI 用 z=0 恒定：排序第一键 layer 恒为 UI_LAYER，绘制顺序全靠 order。
      //   给 UI 编假的 z 会让"同 order 的兄弟"按 z 乱序 —— 那是最难查的一类重叠。
      x: rect.x,
      z: rect.y,
      w: rect.width,
      h: rect.height,
      u0: uv.u0,
      v0: uv.v0,
      u1: uv.u1,
      v1: uv.v1,
      r: tint?.r ?? 1,
      g: tint?.g ?? 1,
      b: tint?.b ?? 1,
      a,
      order: ord,
      layer: UI_LAYER,
      pivotX: 0,
      pivotY: 0,
      atlas: page
    });
  };
  const drawFrame = (rect, frameName, slice, tint, ord, alpha) => {
    if (frameName === void 0) return;
    const f = skin.frames.get(frameName);
    if (f === void 0) {
      missingFrames.add(frameName);
      return;
    }
    if (slice > 0) {
      for (const q2 of nineSlice(rect, f, slice)) emit(q2.rect, f.page, q2.uv, tint, ord, alpha);
    } else {
      emit(rect, f.page, { u0: f.u0, v0: f.v0, u1: f.u1, v1: f.v1 }, tint, ord, alpha);
    }
  };
  const emitText = (node, p, box, style, ord, alpha) => {
    const text = p.text ?? "";
    if (text === "") return;
    const layout = store.text(node.uid, fonts, p.fontId ?? defaultFontId(fonts), text, style);
    if (layout === null) return;
    labels++;
    const y = box.y + (box.height - layout.height) / 2;
    for (const g of layout.quads) {
      glyphs++;
      emit(new Rect(box.x + g.x, y + g.y, g.w, g.h), g.page, g, { r: g.r, g: g.g, b: g.b, a: g.a }, ord, alpha);
    }
    for (const m of layout.missing) missingGlyphs.add(m);
  };
  for (const node of root.walk()) {
    if (!node.visible) continue;
    if (node.widget === UiWidget.Group || node.widget === UiWidget.Spacer) continue;
    const ord = order++;
    const p = node.props;
    const alpha = alphaOf(node);
    if (node.widget === UiWidget.Panel) {
      drawFrame(node.rect, p.frame, p.slice ?? 0, p.tint, ord, alpha);
      continue;
    }
    if (node.widget === UiWidget.Image) {
      drawFrame(node.rect, p.frame, 0, p.tint, ord, alpha);
      continue;
    }
    if (node.widget === UiWidget.Button) {
      drawFrame(node.rect, p.frame, p.slice ?? 0, p.tint, ord, alpha);
      const inner = textBoxOf(node, node.rect);
      emitText(node, p, inner, textStyleFor(node, inner.width), ord, alpha);
      continue;
    }
    if (node.widget === UiWidget.Progress) {
      drawFrame(node.rect, p.frame, p.slice ?? 0, p.tint, ord, alpha);
      const v = Math.max(0, Math.min(1, p.value ?? 0));
      const f = p.frame === void 0 ? void 0 : skin.frames.get(p.frame);
      if (v > 0 && f !== void 0) {
        const r = new Rect(node.rect.x, node.rect.y, node.rect.width * v, node.rect.height);
        const u1 = f.u0 + (f.u1 - f.u0) * v;
        emit(r, f.page, { u0: f.u0, v0: f.v0, u1, v1: f.v1 }, p.activeTint ?? { r: 0.5, g: 0.85, b: 0.4, a: 1 }, ord, alpha);
      }
      continue;
    }
    if (node.widget === UiWidget.Label) {
      emitText(node, p, node.rect, textStyleFor(node, node.rect.width), ord, alpha);
    }
  }
  return {
    quads,
    stats: {
      quads: quads.length,
      glyphs,
      labels,
      cacheHits: store.hits,
      missingGlyphs: Array.from(missingGlyphs).sort((a, b) => a - b),
      missingFrames: Array.from(missingFrames).sort()
    }
  };
}
function nineSlice(rect, f, slice) {
  const b = Math.max(0, Math.min(slice, f.width / 2, f.height / 2, rect.width / 2, rect.height / 2));
  if (b <= 0) {
    return [{ rect, uv: { u0: f.u0, v0: f.v0, u1: f.u1, v1: f.v1 } }];
  }
  const sv = b / f.height * (f.v1 - f.v0);
  const su = b / f.width * (f.u1 - f.u0);
  const ux = [f.u0, f.u0 + su, f.u1 - su, f.u1];
  const vy = [f.v0, f.v0 + sv, f.v1 - sv, f.v1];
  const dx = [rect.x, rect.x + b, rect.xMax - b, rect.xMax];
  const dy = [rect.y, rect.y + b, rect.yMax - b, rect.yMax];
  const out = [];
  for (let r = 0; r < 3; r++) {
    for (let c = 0; c < 3; c++) {
      const w = dx[c + 1] - dx[c];
      const h = dy[r + 1] - dy[r];
      if (w <= 0 || h <= 0) continue;
      out.push({
        rect: new Rect(dx[c], dy[r], w, h),
        uv: { u0: ux[c], v0: vy[r], u1: ux[c + 1], v1: vy[r + 1] }
      });
    }
  }
  return out;
}

// src/extensions/ui/events.ts
var UiEvent = class {
  type;
  /** 事件产生的原始目标（不随冒泡变化）。 */
  target;
  /** 当前冒泡到的节点（投递时才有意义）。 */
  currentTarget;
  x;
  y;
  stopped = false;
  constructor(type, target, x, y) {
    this.type = type;
    this.target = target;
    this.currentTarget = target;
    this.x = x;
    this.y = y;
  }
  stopPropagation() {
    this.stopped = true;
  }
  get propagationStopped() {
    return this.stopped;
  }
};
var UiInputRouter = class {
  root;
  dragThreshold;
  lastDown = false;
  lastX = Number.NaN;
  lastY = Number.NaN;
  downTarget = null;
  downX = 0;
  downY = 0;
  hover = null;
  /** 最近一次命中的节点（诊断与测试用）。 */
  hit = null;
  constructor(root, opts = {}) {
    this.root = root;
    this.dragThreshold = opts.dragThreshold ?? 8;
  }
  get hovered() {
    return this.hover;
  }
  /** 正在被捕获的目标（按下未抬起）。 */
  get captured() {
    return this.downTarget;
  }
  /**
   * 推进一帧。返回本帧产生的事件（已冒泡投递到 `sink`，若提供）。
   * ★ 返回值是给判据用的：断言"这一刻产生了 click"不需要监听器。
   */
  update(p, sink) {
    const events = [];
    const hit = hitTest(this.root, p.x, p.y);
    this.hit = hit;
    const push = (type, target) => {
      events.push(new UiEvent(type, target, p.x, p.y));
    };
    if (hit !== this.hover) {
      const prev = this.hover;
      this.hover = hit;
      if (prev !== null) push("pointerleave", prev);
      if (hit !== null) push("pointerenter", hit);
    }
    const moved = !(p.x === this.lastX && p.y === this.lastY);
    if (moved && hit !== null) push("pointermove", hit);
    if (p.down && !this.lastDown) {
      this.downTarget = hit;
      this.downX = p.x;
      this.downY = p.y;
      if (hit !== null) push("pointerdown", hit);
    }
    if (!p.down && this.lastDown) {
      const target = this.downTarget;
      if (target !== null) {
        push("pointerup", target);
        const chain = hit === null ? [] : hitChain(hit);
        const sameTarget = chain.includes(target);
        const dx = p.x - this.downX;
        const dy = p.y - this.downY;
        const dist = Math.sqrt(dx * dx + dy * dy);
        if (sameTarget && dist <= this.dragThreshold) push("click", target);
      }
      this.downTarget = null;
    }
    this.lastDown = p.down;
    this.lastX = p.x;
    this.lastY = p.y;
    if (sink !== void 0) {
      for (const ev of events) bubble(ev, sink);
    }
    return events;
  }
  /** 强制释放捕获（例如页面失焦）。不发事件 —— 失焦不是用户的点击意图。 */
  release() {
    this.downTarget = null;
    this.lastDown = false;
  }
};
function bubble(ev, sink) {
  let cur = ev.target;
  while (cur !== null) {
    if (ev.propagationStopped) return;
    ev.currentTarget = cur;
    sink(ev);
    cur = cur.parent;
  }
}

// src/extensions/ui/ui-module.ts
var RENDER_MODULE_ID = "render.batch2d";
function createUiModule(opts) {
  const dpr = opts.dpr ?? 1;
  const viewport = new UiViewport(opts.viewport);
  const fonts = new FontRegistry();
  for (const f of opts.fonts) fonts.register(f);
  const store = new UiStateStore();
  const intrinsic = createIntrinsicMeasure(fonts, store);
  const offFonts = fonts.onRegister(() => {
    store.invalidateDerived();
    dirty = true;
  });
  const skin = opts.skin;
  const hostPages = opts.pages;
  const pageSources = opts.pageSources;
  let ownPages = [];
  let pages = hostPages ?? [];
  let root = opts.root ?? new UiNode({ id: "ui.root" });
  let router = new UiInputRouter(root, { dragThreshold: opts.dragThreshold });
  let dev = null;
  let ctxRef = null;
  let shader = null;
  let pipeline = null;
  let batch = null;
  let vbo = null;
  let ibo = null;
  let offRender = null;
  let dirty = true;
  let lastPw = -1;
  let lastPh = -1;
  let quads = [];
  let drawStats = {
    quads: 0,
    glyphs: 0,
    labels: 0,
    cacheHits: 0,
    missingGlyphs: [],
    missingFrames: []
  };
  let layoutResult = /* @__PURE__ */ new Map();
  let lastFrame = {
    quads: 0,
    drawCalls: 0,
    glyphs: 0,
    labels: 0,
    cacheHits: 0,
    missingGlyphs: [],
    missingFrames: [],
    relaid: false
  };
  function sync() {
    const d = dev;
    if (d === null) return;
    const pw = d.size.width;
    const ph = d.size.height;
    if (pw > 0 && ph > 0) viewport.setScreen(pw / dpr, ph / dpr, dpr);
    if (!dirty && pw === lastPw && ph === lastPh) {
      lastFrame = { ...lastFrame, relaid: false };
      return;
    }
    layoutResult = layoutTree(root, viewport.safeRect, { intrinsic });
    const res = buildUiQuads(root, fonts, skin, store);
    quads = res.quads;
    drawStats = res.stats;
    dirty = false;
    lastPw = pw;
    lastPh = ph;
    lastFrame = {
      ...lastFrame,
      quads: quads.length,
      glyphs: drawStats.glyphs,
      labels: drawStats.labels,
      cacheHits: drawStats.cacheHits,
      missingGlyphs: drawStats.missingGlyphs,
      missingFrames: drawStats.missingFrames,
      relaid: true
    };
  }
  function drawOverlay(cmd) {
    sync();
    const d = dev;
    const b = batch;
    if (d === null || b === null || pipeline === null || vbo === null || ibo === null) return;
    if (quads.length === 0) {
      lastFrame = { ...lastFrame, quads: 0, drawCalls: 0 };
      return;
    }
    const built = b.build(quads, viewport.camera);
    const up = d.updateBuffer(vbo, b.vertexView(built.quadCount));
    if (!up.ok) {
      ctxRef?.log.channel("ui").error(`UI \u9876\u70B9\u4E0A\u4F20\u5931\u8D25\uFF1A${up.error.message}`, void 0, null);
      return;
    }
    cmd.setPipeline(pipeline);
    for (const run of built.runs) {
      const page = pages[run.atlas];
      if (page === void 0) {
        ctxRef?.log.channel("ui").warn(`UI \u7EB9\u7406\u9875 ${run.atlas} \u4E0D\u5B58\u5728\uFF08\u8BE5\u6BB5\u88AB\u8DF3\u8FC7\uFF09`, void 0, null);
        continue;
      }
      cmd.bindTexture(0, page);
      cmd.setUniform("u_useTexture", 1, "int");
      cmd.draw({
        vertices: vbo,
        indices: ibo,
        vertexCount: (run.start + run.count) * 4,
        indexCount: run.count * 6,
        firstIndex: run.start * 6
      });
    }
    lastFrame = { ...lastFrame, quads: built.quadCount, drawCalls: built.drawCalls };
  }
  const mod = {
    id: opts.id ?? "ui",
    deps: [RENDER_MODULE_ID],
    init(ctx) {
      ctxRef = ctx;
      dev = ctx.platform.gfx;
      const d = dev;
      if (opts.fonts.length === 0) {
        return err(engineError("UI.NO_FONT", "UI \u6A21\u5757\u81F3\u5C11\u9700\u8981\u4E00\u4E2A\u4F4D\u56FE\u5B57\u4F53"));
      }
      if (hostPages !== void 0 && pageSources !== void 0) {
        return err(engineError("UI.PAGE_AMBIGUOUS", "pages \u4E0E pageSources \u53EA\u80FD\u7ED9\u4E00\u4E2A\uFF08\u7EB9\u7406\u6240\u6709\u6743\u5FC5\u987B\u552F\u4E00\uFF09"));
      }
      if (hostPages === void 0 && pageSources === void 0) {
        return err(engineError("UI.NO_PAGE", "UI \u6A21\u5757\u81F3\u5C11\u9700\u8981\u4E00\u4E2A\u7EB9\u7406\u9875\uFF08pages \u6216 pageSources\uFF09"));
      }
      if (pageSources !== void 0) {
        if (pageSources.length === 0) return err(engineError("UI.NO_PAGE", "UI \u6A21\u5757\u81F3\u5C11\u9700\u8981\u4E00\u4E2A\u7EB9\u7406\u9875"));
        const made = [];
        for (const [i, src] of pageSources.entries()) {
          const t = d.createTexture(
            {
              width: src.width,
              height: src.height,
              filter: TextureFilter.Nearest,
              wrap: TextureWrap.Clamp,
              label: `engine.ui.page[${String(i)}]:${src.name}`
            },
            src.pixels
          );
          if (!t.ok) {
            for (const h of made) d.destroyTexture(h);
            return t;
          }
          made.push(t.value);
        }
        ownPages = made;
        pages = made;
      }
      if (pages.length === 0) {
        return err(engineError("UI.NO_PAGE", "UI \u6A21\u5757\u81F3\u5C11\u9700\u8981\u4E00\u4E2A\u7EB9\u7406\u9875"));
      }
      const bail = (e) => {
        for (const h of ownPages) d.destroyTexture(h);
        ownPages = [];
        return e;
      };
      const sh = d.createShader({ vertex: SPRITE_VS, fragment: SPRITE_FS, label: "engine.ui" });
      if (!sh.ok) return bail(sh);
      const pl = d.createPipeline({
        shader: sh.value,
        layout: SPRITE_VERTEX_LAYOUT,
        blend: BlendMode.Alpha,
        label: "engine.ui"
      });
      if (!pl.ok) {
        d.destroyShader(sh.value);
        return bail(pl);
      }
      const b = new SpriteBatch(opts.maxQuads ?? 2048);
      const vb = d.createBuffer({
        usage: BufferUsage.Vertex,
        byteLength: b.vertices.byteLength,
        dynamic: true,
        label: "engine.ui.vbo"
      });
      if (!vb.ok) {
        d.destroyPipeline(pl.value);
        d.destroyShader(sh.value);
        return bail(vb);
      }
      const ib = d.createBuffer({
        usage: BufferUsage.Index,
        byteLength: b.indices.byteLength,
        dynamic: false,
        label: "engine.ui.ibo"
      });
      if (!ib.ok) {
        d.destroyBuffer(vb.value);
        d.destroyPipeline(pl.value);
        d.destroyShader(sh.value);
        return bail(ib);
      }
      const up = d.updateBuffer(ib.value, b.indices);
      if (!up.ok) {
        d.destroyBuffer(ib.value);
        d.destroyBuffer(vb.value);
        d.destroyPipeline(pl.value);
        d.destroyShader(sh.value);
        return bail(up);
      }
      shader = sh.value;
      pipeline = pl.value;
      batch = b;
      vbo = vb.value;
      ibo = ib.value;
      ctx.log.channel("ui").info(
        `UI \u6A21\u5757\u5C31\u7EEA\uFF1A${opts.fonts.length} \u4E2A\u5B57\u4F53 \xB7 ${skin.frames.size} \u4E2A\u76AE\u80A4\u5E27 \xB7 ${pages.length} \u9875 \xB7 \u8BBE\u8BA1\u5206\u8FA8\u7387 ${viewport.designWidth}x${viewport.designHeight}\uFF08${viewport.scaleMode}\uFF09`
      );
      return ok(void 0);
    },
    start() {
      const ctx = ctxRef;
      if (ctx === null) return err(engineError("UI.NOT_INIT", "start \u4E4B\u524D\u6CA1\u6709 init"));
      const render = ctx.module(RENDER_MODULE_ID);
      if (render === void 0) {
        return err(
          engineError("UI.NO_RENDER", `\u627E\u4E0D\u5230\u6E32\u67D3\u6A21\u5757 ${RENDER_MODULE_ID}\uFF08UI \u5FC5\u987B\u6302\u5728\u5B83\u7684 pass \u5C3E\u90E8\uFF09`)
        );
      }
      render.setOverlay(drawOverlay);
      offRender = () => render.setOverlay(null);
      return ok(void 0);
    },
    stop() {
      offRender?.();
      offRender = null;
    },
    dispose() {
      const d = dev;
      if (d !== null) {
        for (const h of ownPages) d.destroyTexture(h);
        if (ibo !== null) d.destroyBuffer(ibo);
        if (vbo !== null) d.destroyBuffer(vbo);
        if (pipeline !== null) d.destroyPipeline(pipeline);
        if (shader !== null) d.destroyShader(shader);
      }
      ownPages = [];
      pages = hostPages ?? [];
      ibo = null;
      vbo = null;
      pipeline = null;
      shader = null;
      batch = null;
      dev = null;
      quads = [];
      offFonts();
      store.reset();
      dirty = true;
    },
    describe() {
      return `UI\uFF1A${lastFrame.quads} quad / ${lastFrame.drawCalls} draw / ${lastFrame.glyphs} \u5B57\u5F62 / ${lastFrame.labels} \u6807\u7B7E`;
    },
    get viewport() {
      return viewport;
    },
    get fonts() {
      return fonts;
    },
    get root() {
      return root;
    },
    setRoot(node) {
      root = node;
      router = new UiInputRouter(root, { dragThreshold: opts.dragThreshold });
      store.reset();
      dirty = true;
    },
    pointer(p) {
      sync();
      return router.update(p, opts.onEvent);
    },
    invalidate() {
      dirty = true;
    },
    relayout() {
      dirty = true;
      sync();
    },
    get lastFrame() {
      return lastFrame;
    },
    get layout() {
      return layoutResult;
    },
    get state() {
      return store;
    }
  };
  return mod;
}

// src/host/hud-model.ts
function hudRows(f) {
  const r = (n) => String(Math.round(n));
  const world = f.world === null ? "world -" : `world ${r(f.world.terrain)}/${r(f.world.sites)}`;
  const script = f.script === null ? "script off" : `script ${r(f.script.calls)}c/${r(f.script.errors)}e${f.script.timeouts > 0 ? `/${r(f.script.timeouts)}to` : ""}`;
  const hunger = f.hunger === null ? "fed -" : `fed ${r(f.hunger.value)}/${r(f.hunger.max)}`;
  return [
    [
      `fps ${r(f.fps)}`,
      `tick ${r(f.tick)}`,
      `quad ${r(f.quads)}`,
      `draw ${r(f.drawCalls)}`,
      `cull ${r(f.culled)}`,
      `nodes ${r(f.nodes)}`,
      `bodies ${r(f.bodies)}`
    ].join(" | "),
    [
      `atlas:${f.atlas}`,
      world,
      `res ${r(f.resources.alive)}/${r(f.resources.spawned)}/${r(f.resources.released)}`,
      `bag ${r(f.bagStacks)}`,
      hunger
    ].join(" | "),
    [
      `${f.backends.gfx}/${f.backends.audio}/${f.backends.input}/${f.backends.script ?? "-"}`,
      script,
      `drop ${r(f.droppedSteps)}`
    ].join(" | ")
  ];
}
function hudLine(f) {
  return hudRows(f).join(" | ");
}
function bagRows(stacks, selected, labelOf) {
  const sel = stacks.length === 0 ? 0 : Math.min(Math.max(0, selected), stacks.length - 1);
  const label = labelOf ?? ((kind) => kind.replace(/_/g, " "));
  return stacks.map((s, i) => ({
    index: i + 1,
    // 下划线换空格：`grass_tuft` 读作 "grass tuft"，比原文更好看，且不需要第二张表
    text: `${String(i + 1)}. ${label(s.kind)} x${String(s.count)}`,
    selected: i === sel
  }));
}
function bagFooter(hints) {
  return `click row to select | ${hints.drop} drop 1 | shift+${hints.drop} drop all | ${hints.bag} close`;
}
function bagEmptyLine(pickKey) {
  return `empty - press ${pickKey} to pick something up`;
}

// src/host/hud-ui.ts
function buildSkin(json, page = 1) {
  if (json.width <= 0 || json.height <= 0) {
    return err(engineError("UI.SKIN_BAD_SIZE", `\u76AE\u80A4\u56FE\u5C3A\u5BF8\u975E\u6CD5\uFF1A${String(json.width)}x${String(json.height)}`));
  }
  if (json.frames.length === 0) {
    return err(engineError("UI.SKIN_NO_FRAME", "\u76AE\u80A4\u91CC\u4E00\u5E27\u90FD\u6CA1\u6709\uFF08\u9762\u677F/\u6309\u94AE\u5168\u90FD\u4F1A\u53D8\u6210\u7A7A\u767D\uFF09"));
  }
  const frames = /* @__PURE__ */ new Map();
  const slice = /* @__PURE__ */ new Map();
  const W = json.width;
  const H = json.height;
  for (const f of json.frames) {
    if (f.w <= 0 || f.h <= 0) {
      return err(engineError("UI.SKIN_BAD_FRAME", `\u5E27 ${f.name} \u7684\u5C3A\u5BF8\u975E\u6CD5\uFF1A${String(f.w)}x${String(f.h)}`));
    }
    if (f.x < 0 || f.y < 0 || f.x + f.w > W || f.y + f.h > H) {
      return err(
        engineError(
          "UI.SKIN_FRAME_OOB",
          `\u5E27 ${f.name} \u8D85\u51FA\u76AE\u80A4\u56FE\uFF08${String(f.x)},${String(f.y)} ${String(f.w)}x${String(f.h)} \u4E0D\u5728 ${String(W)}x${String(H)} \u5185\uFF09`
        )
      );
    }
    if (frames.has(f.name)) {
      return err(engineError("UI.SKIN_DUP_FRAME", `\u5E27\u540D\u91CD\u590D\uFF1A${f.name}`));
    }
    frames.set(f.name, {
      page,
      u0: f.x / W,
      v0: f.y / H,
      u1: (f.x + f.w) / W,
      v1: (f.y + f.h) / H,
      width: f.w,
      height: f.h
    });
    slice.set(f.name, Math.max(0, f.slice));
  }
  return ok({ skin: { frames }, slice });
}
var DEFAULT_MAX_ROWS = 8;
var HUD_LAYOUT = {
  /** 面板总宽（设计 px）。960 设计宽下留出两侧各 160 给世界。 */
  width: 640,
  /** 内边距（四边）。 */
  pad: 6,
  /** 行间距。 */
  gap: 2,
  /** 饱食度条高度。 */
  bar: 6
};
function createHudUi(opts) {
  const builtR = buildSkin(opts.skinJson, 1);
  if (!builtR.ok) return builtR;
  const built = builtR.value;
  const font = opts.font;
  const lineH = Math.max(1, font.lineHeight);
  const pad = HUD_LAYOUT.pad;
  const gap = HUD_LAYOUT.gap;
  const rowH = lineH + 4;
  const cjk = opts.cjkFont;
  const cjkRowH = cjk === void 0 ? rowH : Math.max(1, cjk.lineHeight) + 4;
  const bagRowFontId = cjk?.id;
  const maxRows = Math.max(1, opts.maxRows ?? DEFAULT_MAX_ROWS);
  const hudW = HUD_LAYOUT.width;
  const bagW = 268;
  const innerW = bagW - pad * 2;
  const bagH = pad * 2 + lineH + gap + maxRows * cjkRowH + (maxRows - 1) * gap + gap + lineH * 2;
  const hudH = pad * 2 + lineH * 3 + gap * 3 + HUD_LAYOUT.bar;
  const white = new Color(1, 1, 1, 1);
  const dim = new Color(0.72, 0.76, 0.82, 1);
  const selTint = new Color(0.42, 0.38, 0.22, 1);
  const rowTint = new Color(0.26, 0.28, 0.34, 0.85);
  const barTint = new Color(0.55, 0.86, 0.45, 1);
  const sliceOf = (name) => built.slice.get(name) ?? 0;
  const hudRowNodes = [0, 1, 2].map(
    (i) => new UiNode({
      id: `hud.row${String(i)}`,
      widget: UiWidget.Label,
      size: { w: hudW - pad * 2, h: lineH },
      props: { text: "", style: { color: dim } }
    })
  );
  const fedBar = new UiNode({
    id: "hud.fed",
    widget: UiWidget.Progress,
    size: { w: hudW - pad * 2, h: HUD_LAYOUT.bar },
    props: { frame: "bar", slice: 0, value: 1, activeTint: barTint },
    visible: false
  });
  const hudPanel = new UiNode({
    id: "hud.panel",
    widget: UiWidget.Panel,
    kind: UiLayoutKind.Column,
    anchor: ANCHOR_TOP_LEFT,
    offset: { x: 8, y: 8 },
    size: { w: hudW, h: hudH },
    padding: { top: pad, right: pad, bottom: pad, left: pad },
    gap,
    props: { frame: "panel", slice: sliceOf("panel"), tint: new Color(1, 1, 1, 0.55) }
  });
  for (const c of [...hudRowNodes, fedBar]) hudPanel.add(c);
  const bagRowsNodes = Array.from({ length: maxRows }, (_, i) => {
    const n = new UiNode({
      id: `bag.row${String(i)}`,
      widget: UiWidget.Button,
      size: { w: innerW, h: cjkRowH },
      interactive: true,
      opaque: true,
      visible: false,
      props: {
        frame: "slot",
        slice: sliceOf("slot"),
        text: "",
        tint: rowTint,
        style: { align: "left", color: white },
        // 行数按行高算出来之后，字体的选择就只剩这一处：没有中文字体时不写这个键，
        // 落到"注册表里第一个字体"（= 5×7），与这批之前完全一样。
        ...bagRowFontId === void 0 ? {} : { fontId: bagRowFontId }
      }
    });
    return n;
  });
  const bagEmpty = new UiNode({
    id: "bag.empty",
    widget: UiWidget.Label,
    size: { w: innerW, h: rowH },
    visible: false,
    props: { text: bagEmptyLine(opts.hints.pick), style: { color: dim } }
  });
  const bagFoot = new UiNode({
    id: "bag.foot",
    widget: UiWidget.Label,
    size: { w: innerW, h: lineH * 2 },
    props: { text: bagFooter(opts.hints), style: { color: dim } }
  });
  const bagPanel = new UiNode({
    id: "bag.panel",
    widget: UiWidget.Panel,
    kind: UiLayoutKind.Column,
    anchor: ANCHOR_CENTER,
    pivot: ANCHOR_CENTER,
    size: { w: bagW, h: bagH },
    padding: { top: pad, right: pad, bottom: pad, left: pad },
    gap,
    visible: false,
    // ★ `opaque`：面板底色上的一次点击**不该**穿透到背后的东西。
    //   现在面板后面没有可点的节点（HUD 是显示层），但这条语义必须现在就对 ——
    //   等哪天世界里有了"点地面移动"，漏掉它就会变成"点背包面板把角色派出去了"。
    opaque: true,
    props: { frame: "panel", slice: sliceOf("panel"), tint: new Color(1, 1, 1, 0.92) }
  });
  bagPanel.add(bagEmpty);
  for (const n of bagRowsNodes) bagPanel.add(n);
  bagPanel.add(bagFoot);
  const root = new UiNode({ id: "ui.root" });
  root.add(hudPanel);
  root.add(bagPanel);
  const onEvent = (ev) => {
    if (ev.type !== "click") return;
    if (ev.currentTarget !== ev.target) return;
    const m = /^bag\.row(\d+)$/.exec(ev.target.id);
    if (m === null) return;
    opts.onSelectRow(Number(m[1]));
  };
  const module = createUiModule({
    id: "ui.hud",
    viewport: opts.viewport,
    skin: built.skin,
    // 页号是**全局下标**：0=5×7 字形、1=皮肤、2=中文字形（`.fnt` 里写的就是这三个号）
    pageSources: cjk === void 0 ? [opts.fontPage, opts.skinPage] : [opts.fontPage, opts.skinPage, opts.cjkPage],
    fonts: cjk === void 0 ? [font] : [font, cjk],
    root,
    dpr: opts.dpr ?? 1,
    onEvent
  });
  let hudSig = "";
  let bagSig = "";
  let bagOpenState = false;
  let bagTexts = [];
  const api = {
    module,
    built,
    hudRowIds: hudRowNodes.map((n) => n.id),
    get bagRowTexts() {
      return bagTexts;
    },
    get bagOpen() {
      return bagOpenState;
    },
    setHud(rows, hunger) {
      const text0 = rows[0] ?? "";
      const text1 = rows[1] ?? "";
      const text2 = rows[2] ?? "";
      const sig = `${text0}${text1}${text2}${hunger === null ? "-" : hunger.toFixed(2)}`;
      if (sig === hudSig) return;
      hudSig = sig;
      const texts = [text0, text1, text2];
      hudRowNodes.forEach((n, i) => {
        n.props = { ...n.props, text: texts[i] ?? "" };
      });
      fedBar.visible = hunger !== null;
      fedBar.props = { ...fedBar.props, value: hunger === null ? 0 : Math.max(0, Math.min(1, hunger)) };
      module.invalidate();
    },
    setBag(stacks, selected) {
      const open = stacks !== null;
      const list = stacks ?? [];
      const rows = bagRows(list, selected, opts.labelOf);
      const sig = open ? `${rows.map((r) => `${r.text}#${r.selected ? 1 : 0}`).join("|")}` : "#closed";
      if (sig === bagSig) return;
      bagSig = sig;
      bagOpenState = open;
      bagPanel.visible = open;
      if (!open) {
        bagTexts = [];
        module.invalidate();
        return;
      }
      const shown = Math.min(rows.length, maxRows);
      for (let i = 0; i < maxRows; i++) {
        const n = bagRowsNodes[i];
        const r = i < shown ? rows[i] : void 0;
        n.visible = r !== void 0;
        if (r === void 0) continue;
        n.props = {
          ...n.props,
          text: r.text,
          tint: r.selected ? selTint : rowTint,
          textColor: white
        };
      }
      bagEmpty.visible = rows.length === 0;
      bagTexts = rows.map((r) => r.text);
      module.invalidate();
    },
    pointer(cssX, cssY, down) {
      const p = module.viewport.screenToDesign(cssX, cssY);
      const ptr = { x: p.x, y: p.y, down };
      return module.pointer(ptr);
    }
  };
  return ok(api);
}
function rectOfId(handle, id) {
  return handle.module.layout.get(id);
}

// src/extensions/tween/easing.ts
var EASING_ERR = {
  UNKNOWN: "TWEEN.UNKNOWN_EASING"
};
function quadIn(t) {
  return t * t;
}
function quadOut(t) {
  return t * (2 - t);
}
function quadInOut(t) {
  return t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t;
}
function cubicIn(t) {
  return t * t * t;
}
function cubicOut(t) {
  const u = t - 1;
  return u * u * u + 1;
}
function cubicInOut(t) {
  return t < 0.5 ? 4 * t * t * t : (t - 1) * (2 * t - 2) * (2 * t - 2) + 1;
}
function quartIn(t) {
  return t * t * t * t;
}
function quartOut(t) {
  const u = t - 1;
  return 1 - u * u * u * u;
}
function quartInOut(t) {
  return t < 0.5 ? 8 * t * t * t * t : 1 - 8 * (t - 1) * (t - 1) * (t - 1) * (t - 1);
}
function quintIn(t) {
  return t * t * t * t * t;
}
function quintOut(t) {
  const u = t - 1;
  return 1 + u * u * u * u * u;
}
function quintInOut(t) {
  return t < 0.5 ? 16 * t * t * t * t * t : 1 + 16 * (t - 1) * (t - 1) * (t - 1) * (t - 1) * (t - 1);
}
function sineIn(t) {
  if (t === 1) return 1;
  return 1 - Math.cos(t * Math.PI / 2);
}
function sineOut(t) {
  return Math.sin(t * Math.PI / 2);
}
function sineInOut(t) {
  return 0.5 * (1 - Math.cos(Math.PI * t));
}
function expoIn(t) {
  return t === 0 ? 0 : Math.pow(2, 10 * (t - 1));
}
function expoOut(t) {
  return t === 1 ? 1 : 1 - Math.pow(2, -10 * t);
}
function expoInOut(t) {
  if (t === 0) return 0;
  if (t === 1) return 1;
  return t < 0.5 ? 0.5 * Math.pow(2, 10 * (2 * t - 1)) : 1 - 0.5 * Math.pow(2, -10 * (2 * t - 1));
}
function circIn(t) {
  return 1 - Math.sqrt(1 - t * t);
}
function circOut(t) {
  const u = t - 1;
  return Math.sqrt(1 - u * u);
}
function circInOut(t) {
  return t < 0.5 ? 0.5 * (1 - Math.sqrt(1 - 4 * t * t)) : 0.5 * (Math.sqrt(1 - (2 * t - 2) * (2 * t - 2)) + 1);
}
var BACK_S = 1.70158;
function backIn(t) {
  if (t === 0) return 0;
  if (t === 1) return 1;
  return t * t * ((BACK_S + 1) * t - BACK_S);
}
function backOut(t) {
  if (t === 0) return 0;
  const u = t - 1;
  return u * u * ((BACK_S + 1) * u + BACK_S) + 1;
}
function backInOut(t) {
  if (t === 0) return 0;
  const s = BACK_S * 1.525;
  if (t < 0.5) {
    const u2 = 2 * t;
    return 0.5 * (u2 * u2 * ((s + 1) * u2 - s));
  }
  const u = 2 * t - 2;
  return 0.5 * (u * u * ((s + 1) * u + s) + 2);
}
var ELASTIC_P = 0.3;
var ELASTIC_S = ELASTIC_P / 4;
function elasticIn(t) {
  if (t === 0) return 0;
  if (t === 1) return 1;
  return -Math.pow(2, 10 * (t - 1)) * Math.sin((t - 1 - ELASTIC_S) * 2 * Math.PI / ELASTIC_P);
}
function elasticOut(t) {
  if (t === 0) return 0;
  if (t === 1) return 1;
  return Math.pow(2, -10 * t) * Math.sin((t - ELASTIC_S) * 2 * Math.PI / ELASTIC_P) + 1;
}
function elasticInOut(t) {
  if (t === 0) return 0;
  if (t === 1) return 1;
  return t < 0.5 ? elasticIn(2 * t) / 2 : elasticOut(2 * t - 1) / 2 + 0.5;
}
var BOUNCE_N = 7.5625;
var BOUNCE_D = 2.75;
function bounceOut(t) {
  if (t < 1 / BOUNCE_D) return BOUNCE_N * t * t;
  if (t < 2 / BOUNCE_D) {
    const u2 = t - 1.5 / BOUNCE_D;
    return BOUNCE_N * u2 * u2 + 0.75;
  }
  if (t < 2.5 / BOUNCE_D) {
    const u2 = t - 2.25 / BOUNCE_D;
    return BOUNCE_N * u2 * u2 + 0.9375;
  }
  const u = t - 2.625 / BOUNCE_D;
  return BOUNCE_N * u * u + 0.984375;
}
function bounceIn(t) {
  return 1 - bounceOut(1 - t);
}
function bounceInOut(t) {
  return t < 0.5 ? 0.5 * (1 - bounceOut(1 - 2 * t)) : 0.5 * bounceOut(2 * t - 1) + 0.5;
}
function step(t) {
  return t < 1 ? 0 : 1;
}
var EASINGS = Object.freeze({
  linear: (t) => t,
  quadIn,
  quadOut,
  quadInOut,
  cubicIn,
  cubicOut,
  cubicInOut,
  quartIn,
  quartOut,
  quartInOut,
  quintIn,
  quintOut,
  quintInOut,
  sineIn,
  sineOut,
  sineInOut,
  expoIn,
  expoOut,
  expoInOut,
  circIn,
  circOut,
  circInOut,
  backIn,
  backOut,
  backInOut,
  elasticIn,
  elasticOut,
  elasticInOut,
  bounceIn,
  bounceOut,
  bounceInOut,
  step
});
var EASING_NAMES = Object.freeze(Object.keys(EASINGS));
function getEasing(name) {
  const fn = EASINGS[name];
  if (fn === void 0) {
    return err(
      engineError(
        EASING_ERR.UNKNOWN,
        `\u672A\u77E5\u7F13\u52A8 ${JSON.stringify(name)}\uFF1B\u53EF\u7528\uFF1A${EASING_NAMES.join(", ")}`,
        { name }
      )
    );
  }
  return ok(fn);
}

// src/extensions/tween/tween.ts
var TWEEN_ERR = {
  BAD_DURATION: "TWEEN.BAD_DURATION",
  BAD_DELAY: "TWEEN.BAD_DELAY",
  BAD_SPEED: "TWEEN.BAD_SPEED",
  BAD_LOOP: "TWEEN.BAD_LOOP",
  BAD_ENDPOINT: "TWEEN.BAD_ENDPOINT",
  UNKNOWN_EASING: "TWEEN.UNKNOWN_EASING",
  NON_FINITE_TIME: "TWEEN.NON_FINITE_TIME"
};
function makeTween(input) {
  if (!Number.isFinite(input.from) || !Number.isFinite(input.to)) {
    return err(
      engineError(TWEEN_ERR.BAD_ENDPOINT, `\u8865\u95F4\u4E24\u7AEF\u5FC5\u987B\u662F\u6709\u9650\u6570\uFF1Afrom=${String(input.from)} to=${String(input.to)}`, {
        id: input.id
      })
    );
  }
  if (!Number.isFinite(input.durationMs) || input.durationMs <= 0) {
    return err(
      engineError(TWEEN_ERR.BAD_DURATION, `durationMs \u5FC5\u987B\u662F > 0 \u7684\u6709\u9650\u6570\uFF1A${String(input.durationMs)}`, {
        id: input.id
      })
    );
  }
  const delayMs = input.delayMs ?? 0;
  if (!Number.isFinite(delayMs) || delayMs < 0) {
    return err(engineError(TWEEN_ERR.BAD_DELAY, `delayMs \u5FC5\u987B\u662F\u975E\u8D1F\u6709\u9650\u6570\uFF1A${String(delayMs)}`, { id: input.id }));
  }
  const speed = input.speed ?? 1;
  if (!Number.isFinite(speed)) {
    return err(engineError(TWEEN_ERR.BAD_SPEED, `speed \u5FC5\u987B\u662F\u6709\u9650\u6570\uFF1A${String(speed)}`, { id: input.id }));
  }
  const loopCount = input.loopCount ?? 0;
  if (!Number.isInteger(loopCount) || loopCount < 0) {
    return err(
      engineError(TWEEN_ERR.BAD_LOOP, `loopCount \u5FC5\u987B\u662F\u975E\u8D1F\u6574\u6570\uFF1A${String(loopCount)}\uFF080 = \u65E0\u9650\u5FAA\u73AF\uFF09`, {
        id: input.id
      })
    );
  }
  const easing = input.easing ?? "quadInOut";
  const e = getEasing(easing);
  if (!e.ok) {
    return err(engineError(TWEEN_ERR.UNKNOWN_EASING, e.error.message, { id: input.id, easing }));
  }
  return ok(
    Object.freeze({
      id: input.id,
      from: input.from,
      to: input.to,
      durationMs: input.durationMs,
      easing,
      delayMs,
      speed,
      loopCount,
      yoyo: input.yoyo ?? false
    })
  );
}
function effectiveDuration(spec) {
  const s = Math.abs(spec.speed);
  return spec.durationMs / (s === 0 ? 1 : s);
}
function sampleTween(spec, timeMs) {
  if (!Number.isFinite(timeMs)) {
    throw new TypeError(`sampleTween \u7684 timeMs \u5FC5\u987B\u662F\u6709\u9650\u6570\uFF08\u6536\u5230 ${String(timeMs)}\uFF09`);
  }
  const t = timeMs < 0 ? 0 : timeMs;
  if (t < spec.delayMs) {
    return { value: spec.from, progress: 0, loop: 0, done: false, waiting: true };
  }
  const local0 = t - spec.delayMs;
  const perLoop = effectiveDuration(spec);
  if (spec.loopCount > 0 && local0 >= perLoop * spec.loopCount) {
    const lastIsReverse = spec.yoyo && (spec.loopCount - 1) % 2 === 1;
    return {
      value: lastIsReverse ? spec.from : spec.to,
      progress: 1,
      loop: spec.loopCount - 1,
      done: true,
      waiting: false
    };
  }
  const loop = spec.loopCount === 0 ? Math.floor(local0 / perLoop) : Math.min(Math.floor(local0 / perLoop), spec.loopCount - 1);
  const local = local0 - loop * perLoop;
  const atLoopStart = local === 0 && loop > 0;
  const effectiveLoop = atLoopStart ? loop - 1 : loop;
  const p = atLoopStart ? 1 : local / perLoop;
  const reversed = spec.speed < 0 !== (spec.yoyo && effectiveLoop % 2 === 1);
  const progress = reversed ? 1 - p : p;
  const ease = EASINGS[spec.easing];
  const value = spec.from + (spec.to - spec.from) * ease(progress);
  return { value, progress: p, loop, done: false, waiting: false };
}

// src/extensions/tween/keyframes.ts
var KEYFRAME_ERR = {
  /** 少于 2 个关键帧（一个点构不成"轨道"）。 */
  TOO_FEW: "TWEEN.TOO_FEW_KEYS",
  /** 时间轴没有从 0 起步（见文件头 ★★）。 */
  NO_ORIGIN: "TWEEN.TRACK_NO_ORIGIN",
  /** `atMs` 没有严格递增（相等也不行：同一时刻两个值没有定义）。 */
  UNSORTED: "TWEEN.TRACK_UNSORTED",
  /** `atMs` 非有限或为负。 */
  BAD_AT: "TWEEN.TRACK_BAD_AT",
  /** 关键帧的值非有限。 */
  BAD_VALUE: "TWEEN.TRACK_BAD_VALUE",
  /** 引用了不存在的 easing 名。 */
  UNKNOWN_EASING: "TWEEN.UNKNOWN_EASING"
};
function easingOf(name) {
  if (name === void 0) return EASINGS.linear;
  const fn = EASINGS[name];
  if (fn === void 0) throw new Error(`\u672A\u77E5\u7F13\u52A8\uFF1A${name}`);
  return fn;
}
function makeTrack(input) {
  const keys = input.keys;
  if (keys.length < 2) {
    return err(
      engineError(KEYFRAME_ERR.TOO_FEW, `\u5173\u952E\u5E27\u81F3\u5C11\u8981\u6709 2 \u4E2A\uFF08\u6536\u5230 ${String(keys.length)} \u4E2A\uFF09`, { id: input.id })
    );
  }
  const first = keys[0];
  if (!Number.isFinite(first.atMs) || first.atMs < 0) {
    return err(engineError(KEYFRAME_ERR.BAD_AT, `\u7B2C\u4E00\u4E2A\u5173\u952E\u5E27\u7684 atMs \u975E\u6CD5\uFF1A${String(first.atMs)}`, { id: input.id }));
  }
  if (first.atMs !== 0) {
    return err(
      engineError(KEYFRAME_ERR.NO_ORIGIN, `\u7B2C\u4E00\u4E2A\u5173\u952E\u5E27\u5FC5\u987B\u5728 0ms\uFF08\u6536\u5230 ${String(first.atMs)}ms\uFF09`, {
        id: input.id,
        atMs: first.atMs
      })
    );
  }
  let prev = first.atMs;
  for (const [i, k] of keys.entries()) {
    if (!Number.isFinite(k.atMs) || k.atMs < 0) {
      return err(
        engineError(KEYFRAME_ERR.BAD_AT, `\u7B2C ${String(i)} \u4E2A\u5173\u952E\u5E27\u7684 atMs \u975E\u6CD5\uFF1A${String(k.atMs)}`, { id: input.id })
      );
    }
    if (i > 0 && !(k.atMs > prev)) {
      return err(
        engineError(
          KEYFRAME_ERR.UNSORTED,
          `\u7B2C ${String(i)} \u4E2A\u5173\u952E\u5E27\u7684 atMs=${String(k.atMs)} \u5FC5\u987B\u4E25\u683C\u5927\u4E8E\u524D\u4E00\u4E2A ${String(prev)}`,
          { id: input.id }
        )
      );
    }
    if (!Number.isFinite(k.value)) {
      return err(
        engineError(KEYFRAME_ERR.BAD_VALUE, `\u7B2C ${String(i)} \u4E2A\u5173\u952E\u5E27\u7684\u503C\u975E\u6709\u9650\uFF1A${String(k.value)}`, { id: input.id })
      );
    }
    if (i > 0 && k.easing !== void 0 && EASINGS[k.easing] === void 0) {
      return err(
        engineError(KEYFRAME_ERR.UNKNOWN_EASING, `\u7B2C ${String(i)} \u4E2A\u5173\u952E\u5E27\u5F15\u7528\u4E86\u672A\u77E5\u7F13\u52A8\uFF1A${k.easing}`, {
          id: input.id
        })
      );
    }
    prev = k.atMs;
  }
  const frozen = keys.map(
    (k) => k.easing === void 0 ? { atMs: k.atMs, value: k.value } : { atMs: k.atMs, value: k.value, easing: k.easing }
  );
  return ok({ id: input.id, keys: Object.freeze(frozen), durationMs: prev });
}
function sampleTrack(spec, ms) {
  if (!Number.isFinite(ms)) {
    throw new TypeError(`sampleTrack \u7684 ms \u5FC5\u987B\u662F\u6709\u9650\u6570\uFF08\u6536\u5230 ${String(ms)}\uFF09`);
  }
  const keys = spec.keys;
  const n = keys.length;
  if (ms <= 0) return { value: keys[0].value, segment: 0, progress: 0, done: false };
  if (ms >= spec.durationMs) {
    return { value: keys[n - 1].value, segment: n - 2, progress: 1, done: true };
  }
  let i = 0;
  while (i < n - 2 && keys[i + 1].atMs <= ms) i++;
  const a = keys[i];
  const b = keys[i + 1];
  const span = b.atMs - a.atMs;
  const t = span <= 0 ? 1 : (ms - a.atMs) / span;
  const eased = easingOf(b.easing)(t < 0 ? 0 : t > 1 ? 1 : t);
  return { value: a.value + (b.value - a.value) * eased, segment: i, progress: t, done: false };
}
var KeyTrack = class {
  id;
  targetId;
  prop;
  spec;
  timeMs = 0;
  playing;
  autoplay;
  /** 上一次采样值（判断"这一步真的变了吗"）。`NaN` = 还没采过。 */
  lastValue = Number.NaN;
  constructor(id, targetId, prop, spec, playing, autoplay) {
    this.id = id;
    this.targetId = targetId;
    this.prop = prop;
    this.spec = spec;
    this.playing = playing;
    this.autoplay = autoplay;
  }
  reset() {
    this.timeMs = 0;
    this.lastValue = Number.NaN;
    this.playing = this.autoplay;
  }
  seek(ms) {
    if (!Number.isFinite(ms)) {
      throw new TypeError(`KeyTrack.seek \u7684 ms \u5FC5\u987B\u662F\u6709\u9650\u6570\uFF08\u6536\u5230 ${String(ms)}\uFF09`);
    }
    this.timeMs = ms < 0 ? 0 : ms;
  }
  sample() {
    return sampleTrack(this.spec, this.timeMs);
  }
};

// src/extensions/tween/tween-player.ts
var TWEEN_PLAYER_TYPE = "tween.player";
var TWEEN_PLAYER_ERR = {
  /** 同一 player 里轨道 id 重复（后加的那条永远不会被单独找到）。 */
  DUPLICATE_TRACK: "TWEEN.DUPLICATE_TRACK",
  /** 轨道不存在。 */
  NO_TRACK: "TWEEN.NO_TRACK"
};
var TweenTrack = class {
  id;
  targetId;
  prop;
  spec;
  /** 本轨道自己的进度（毫秒，可被 `seek` 直接改）。 */
  timeMs = 0;
  /** 是否推进时间。false 时仍可按当前 `timeMs` 采样（`seek` 之后能立刻看到结果）。 */
  playing;
  autoplay;
  /** 上一次采样出来的值（判断"这一步真的变了吗"）。`NaN` = 还没采过。 */
  lastValue = Number.NaN;
  constructor(id, targetId, prop, spec, playing, autoplay) {
    this.id = id;
    this.targetId = targetId;
    this.prop = prop;
    this.spec = spec;
    this.playing = playing;
    this.autoplay = autoplay;
  }
  /** 回到起点，并按 `autoplay` 决定是否继续播。 */
  reset() {
    this.timeMs = 0;
    this.lastValue = Number.NaN;
    this.playing = this.autoplay;
  }
  /**
   * 跳到指定毫秒。
   * ★ 负数夹到 0（与 `sampleTween` 的"负时间 = 还没开始"一致）；
   *   非有限数直接抛 —— 那是调用方的编程错误，不是可配置字段。
   */
  seek(ms) {
    if (!Number.isFinite(ms)) {
      throw new TypeError(`TweenTrack.seek \u7684 ms \u5FC5\u987B\u662F\u6709\u9650\u6570\uFF08\u6536\u5230 ${String(ms)}\uFF09`);
    }
    this.timeMs = ms < 0 ? 0 : ms;
  }
};
var TweenPlayer = class extends Component {
  /**
   * 整组开关。
   * ★ 它单独存在于 schema 里，是为了让存档能表达"这组过渡停在暂停态"——
   *   而轨道本身不进 schema（见文件头 ★★）。
   */
  playing = true;
  /** 运行时轨道（顺序 = 添加顺序，推进也按这个序）。 */
  tracks = [];
  /**
   * 关键帧轨道（ADR-0010 缺口①）。
   *
   * ★★ 为什么与 `tracks` **分成两个数组**，而不是让 `TweenTrack.spec` 变成可空：
   *   分段轨道的 `spec` 在十几处被直接读（`speed`、`loopCount`、`durationMs`），
   *   变成可空之后每个读点都要判空 —— 而漏判的地方**不会报错**，只会静默按关键帧
   *   轨道处理（`speed` 当成 0 ⇒ 永不推进）。两个类型不同的数组让"这是哪种轨道"
   *   在类型层面就成立，推进器里一个 `for` 循环各管一种。
   */
  keyTracks = [];
  schema = {
    type: TWEEN_PLAYER_TYPE,
    fields: {
      playing: FieldType.Bool
    },
    defaults: {
      playing: true
    }
  };
  /**
   * 加一条轨道。构造期就把 spec 校验掉（坏配置不许留到采样期）。
   *
   * ★ 重复 id 直接拒绝：`track(id)` 只能返回第一条，第二条就成了
   *   "加进去了但永远停不下来"的幽灵 —— 而它的症状是"关掉界面后还有东西在动"。
   */
  addTrack(input) {
    if (this.tracks.some((t) => t.id === input.id)) {
      return err(
        engineError(TWEEN_PLAYER_ERR.DUPLICATE_TRACK, `\u8F68\u9053 id \u91CD\u590D\uFF1A${input.id}\uFF08\u540C\u4E00 player \u5185\u5FC5\u987B\u552F\u4E00\uFF09`, {
          id: input.id
        })
      );
    }
    const made = makeTween(input.spec);
    if (!made.ok) return made;
    const track = new TweenTrack(
      input.id,
      input.targetId,
      input.prop,
      made.value,
      input.playing ?? true,
      input.autoplay ?? true
    );
    this.tracks.push(track);
    return ok(track);
  }
  track(id) {
    return this.tracks.find((t) => t.id === id);
  }
  /**
   * 加一条关键帧轨道。
   * ★ id 在**两种轨道之间**也必须唯一：`pause(id)`/`play(id)` 是按 id 找的，
   *   同名会让"停下的那条"与"以为停下的那条"不是同一条。
   */
  addKeyTrack(input) {
    if (this.track(input.id) !== void 0 || this.keyTrack(input.id) !== void 0) {
      return err(
        engineError(TWEEN_PLAYER_ERR.DUPLICATE_TRACK, `\u8F68\u9053 id \u91CD\u590D\uFF1A${input.id}\uFF08\u540C\u4E00 player \u5185\u5FC5\u987B\u552F\u4E00\uFF09`, {
          id: input.id
        })
      );
    }
    const made = makeTrack({ id: input.id, keys: input.keys });
    if (!made.ok) return made;
    const spec = made.value;
    const track = new KeyTrack(
      input.id,
      input.targetId,
      input.prop,
      spec,
      input.playing ?? true,
      input.autoplay ?? true
    );
    this.keyTracks.push(track);
    return ok(track);
  }
  keyTrack(id) {
    return this.keyTracks.find((t) => t.id === id);
  }
  /** 按 id 停一条轨道（界面收起时用：进度留着，只是不再推进）。 */
  pause(id) {
    const t = this.track(id) ?? this.keyTrack(id);
    if (t === void 0) return err(engineError(TWEEN_PLAYER_ERR.NO_TRACK, `\u6CA1\u6709\u8F68\u9053 ${id}`));
    t.playing = false;
    return ok(void 0);
  }
  play(id) {
    const t = this.track(id) ?? this.keyTrack(id);
    if (t === void 0) return err(engineError(TWEEN_PLAYER_ERR.NO_TRACK, `\u6CA1\u6709\u8F68\u9053 ${id}`));
    t.playing = true;
    return ok(void 0);
  }
  /** 清空所有轨道（换界面时用）。 */
  clear() {
    this.tracks.length = 0;
    this.keyTracks.length = 0;
  }
  /** 所有轨道回到起点。 */
  reset() {
    for (const t of this.tracks) t.reset();
    for (const t of this.keyTracks) t.reset();
  }
  /** 是否还有轨道在推进（诊断/性能用：全静止就不必每帧走一遍）。 */
  get moving() {
    if (!this.playing) return false;
    if (this.tracks.some((t) => t.playing && !sampleTween(t.spec, t.timeMs).done)) return true;
    return this.keyTracks.some((t) => t.playing && !t.sample().done);
  }
};
function ticksToMs(ticks, fixedDtMs) {
  if (!Number.isInteger(ticks) || ticks <= 0) {
    throw new TypeError(`ticksToMs \u7684 ticks \u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF08\u6536\u5230 ${String(ticks)}\uFF09`);
  }
  if (!Number.isFinite(fixedDtMs) || fixedDtMs <= 0) {
    throw new TypeError(`ticksToMs \u7684 fixedDtMs \u5FC5\u987B\u662F\u6B63\u7684\u6709\u9650\u6570\uFF08\u6536\u5230 ${String(fixedDtMs)}\uFF09`);
  }
  return ticks * fixedDtMs;
}
function advancePlayer(player, dtMs) {
  if (!Number.isFinite(dtMs) || dtMs < 0) {
    throw new TypeError(`advancePlayer \u7684 dtMs \u5FC5\u987B\u662F\u975E\u8D1F\u6709\u9650\u6570\uFF08\u6536\u5230 ${String(dtMs)}\uFF09`);
  }
  const out = [];
  for (const t of player.tracks) {
    const wasDone = sampleTween(t.spec, t.timeMs).done;
    if (player.playing && t.playing && !wasDone && t.spec.speed !== 0) {
      t.timeMs += dtMs;
      if (t.timeMs < 0) t.timeMs = 0;
    }
    const s = sampleTween(t.spec, t.timeMs);
    const changed = Number.isNaN(t.lastValue) || s.value !== t.lastValue;
    t.lastValue = s.value;
    out.push({ id: t.id, targetId: t.targetId, prop: t.prop, value: s.value, done: s.done, changed });
  }
  for (const t of player.keyTracks) {
    const wasDone = t.sample().done;
    if (player.playing && t.playing && !wasDone) {
      t.timeMs += dtMs;
      if (t.timeMs < 0) t.timeMs = 0;
    }
    const s = t.sample();
    const changed = Number.isNaN(t.lastValue) || s.value !== t.lastValue;
    t.lastValue = s.value;
    out.push({ id: t.id, targetId: t.targetId, prop: t.prop, value: s.value, done: s.done, changed });
  }
  return out;
}

// src/extensions/ui/ui-transition.ts
var UI_TWEEN_PROP = {
  Opacity: "opacity",
  Scale: "scale",
  OffsetX: "offsetX",
  OffsetY: "offsetY"
};
var KNOWN = new Set(Object.values(UI_TWEEN_PROP));
function applyUiTween(node, prop, value) {
  if (!Number.isFinite(value)) return false;
  switch (prop) {
    case UI_TWEEN_PROP.Opacity:
      node.opacity = value < 0 ? 0 : value > 1 ? 1 : value;
      return true;
    case UI_TWEEN_PROP.Scale:
      node.scale = value < 0 ? 0 : value;
      return true;
    case UI_TWEEN_PROP.OffsetX:
      node.offset = { x: value, y: node.offset.y };
      return true;
    case UI_TWEEN_PROP.OffsetY:
      node.offset = { x: node.offset.x, y: value };
      return true;
    default:
      return false;
  }
}
function applyUiSamples(samples, index) {
  let applied = 0;
  let changed = 0;
  let unknownProp = 0;
  let missingNode = 0;
  for (const s of samples) {
    const node = index(s.targetId);
    if (node === void 0) {
      missingNode++;
      continue;
    }
    if (!applyUiTween(node, s.prop, s.value)) {
      unknownProp++;
      continue;
    }
    applied++;
    if (s.changed) changed++;
  }
  return { applied, changed, unknownProp, missingNode };
}

// src/host/hitstop-policy.ts
var HITSTOP_HIT_TICKS = 3;
var HITSTOP_KILL_TICKS = 12;
function demoHitstopPolicy(info, heroId) {
  if (info.attackerId !== heroId) return 0;
  return info.dead ? HITSTOP_KILL_TICKS : HITSTOP_HIT_TICKS;
}

// src/extensions/input/input-map.ts
var INPUT_MAP_VERSION = 1;
var DEFAULT_GROUP = "default";
function badMap(message, detail) {
  return detail === void 0 ? engineError("INPUT.BAD_MAP", message) : engineError("INPUT.BAD_MAP", message, detail);
}
function createInputMap(data) {
  if (typeof data !== "object" || data === null) return err(badMap(`\u6620\u5C04\u8868\u5FC5\u987B\u662F\u5BF9\u8C61\uFF0C\u6536\u5230 ${typeof data}`));
  const d = data;
  if (d.version !== INPUT_MAP_VERSION) {
    return err(
      badMap(`\u6620\u5C04\u8868\u7248\u672C\u5FC5\u987B\u662F ${INPUT_MAP_VERSION}\uFF0C\u6536\u5230 ${JSON.stringify(d.version)}\uFF08\u4E0D\u505A"\u731C\u683C\u5F0F"\u7684\u517C\u5BB9\uFF09`, {
        version: d.version
      })
    );
  }
  if (typeof d.actions !== "object" || d.actions === null || Array.isArray(d.actions)) {
    return err(badMap("actions \u5FC5\u987B\u662F\u300C\u52A8\u4F5C\u540D \u2192 \u7ED1\u5B9A\u300D\u7684\u5BF9\u8C61"));
  }
  const actions = /* @__PURE__ */ new Map();
  for (const [name, rawSpec] of Object.entries(d.actions)) {
    if (name.trim() === "") return err(badMap("\u52A8\u4F5C\u540D\u4E0D\u80FD\u4E3A\u7A7A\u5B57\u7B26\u4E32"));
    if (typeof rawSpec !== "object" || rawSpec === null) {
      return err(badMap(`\u52A8\u4F5C "${name}" \u7684\u7ED1\u5B9A\u5FC5\u987B\u662F\u5BF9\u8C61`, { action: name }));
    }
    const spec = rawSpec;
    if (!Array.isArray(spec.keys)) {
      return err(badMap(`\u52A8\u4F5C "${name}" \u7684 keys \u5FC5\u987B\u662F\u5B57\u7B26\u4E32\u6570\u7EC4`, { action: name }));
    }
    if (spec.group !== void 0 && (typeof spec.group !== "string" || spec.group.trim() === "")) {
      return err(badMap(`\u52A8\u4F5C "${name}" \u7684 group \u5FC5\u987B\u662F\u975E\u7A7A\u5B57\u7B26\u4E32`, { action: name }));
    }
    const seen = /* @__PURE__ */ new Set();
    const keys = [];
    for (const k of spec.keys) {
      if (typeof k !== "string" || k.trim() === "") {
        return err(badMap(`\u52A8\u4F5C "${name}" \u91CC\u6709\u975E\u5B57\u7B26\u4E32\u6216\u7A7A\u7684\u952E\u7801\uFF1A${JSON.stringify(k)}`, { action: name }));
      }
      if (seen.has(k)) {
        return err(
          engineError("INPUT.DUPLICATE_KEY", `\u52A8\u4F5C "${name}" \u91CC\u952E\u7801 "${k}" \u51FA\u73B0\u4E86\u4E24\u6B21`, { action: name, key: k })
        );
      }
      seen.add(k);
      keys.push(k);
    }
    actions.set(name, { keys, group: spec.group ?? DEFAULT_GROUP });
  }
  const owner = /* @__PURE__ */ new Map();
  for (const [name, spec] of actions) {
    for (const k of spec.keys) {
      const prev = owner.get(k);
      if (prev === void 0) {
        owner.set(k, { group: spec.group, action: name });
        continue;
      }
      if (prev.group !== spec.group) continue;
      return err(
        engineError(
          "INPUT.KEY_CONFLICT",
          `\u952E "${k}" \u540C\u65F6\u7ED1\u5728 "${prev.action}" \u4E0E "${name}" \u4E0A\uFF08\u4E24\u8005\u90FD\u5728\u4E92\u65A5\u7EC4 "${prev.group}" \u91CC\uFF09 \u2014\u2014 \u8981\u4E48\u5220\u6389\u4E00\u4E2A\uFF0C\u8981\u4E48\u628A\u5B83\u4EEC\u58F0\u660E\u663E\u5F0F\u5206\u5230\u4E0D\u540C\u7EC4`,
          { key: k, a: prev.action, b: name, group: prev.group }
        )
      );
    }
  }
  const names = [...actions.keys()].sort();
  const require2 = (action, who) => {
    const a = actions.get(action);
    if (a === void 0) {
      throw new Error(
        `${who}\uFF1A\u6620\u5C04\u8868\u91CC\u6CA1\u6709\u52A8\u4F5C "${action}"\uFF08\u73B0\u6709\uFF1A${names.join(", ")}\uFF09\u2014\u2014 \u62FC\u9519\u4E86\uFF1F`
      );
    }
    return a;
  };
  const anyDown = (snap, action) => {
    for (const k of require2(action, "isDown").keys) if (snap.keysDown.has(k)) return true;
    return false;
  };
  return ok({
    names,
    keysOf(action) {
      return require2(action, "keysOf").keys;
    },
    isDown(snap, action) {
      return anyDown(snap, action);
    },
    justPressed(snap, action) {
      for (const k of require2(action, "justPressed").keys) if (snap.keysPressed.has(k)) return true;
      return false;
    },
    axis(snap, neg, pos) {
      const lo = neg === null ? 0 : anyDown(snap, neg) ? 1 : 0;
      const hi = pos === null ? 0 : anyDown(snap, pos) ? 1 : 0;
      return hi - lo;
    },
    toData() {
      const out = {};
      for (const [name, spec] of actions) out[name] = { keys: [...spec.keys], group: spec.group };
      return { version: INPUT_MAP_VERSION, actions: out };
    }
  });
}
var DEFAULT_INPUT_MAP_DATA = {
  version: INPUT_MAP_VERSION,
  actions: {
    move_left: { keys: ["KeyA", "ArrowLeft", "Gamepad0.LStickLeft", "Gamepad0.DPadLeft"], group: "move" },
    move_right: { keys: ["KeyD", "ArrowRight", "Gamepad0.LStickRight", "Gamepad0.DPadRight"], group: "move" },
    move_forward: { keys: ["KeyW", "ArrowUp", "Gamepad0.LStickUp", "Gamepad0.DPadUp"], group: "move" },
    move_back: { keys: ["KeyS", "ArrowDown", "Gamepad0.LStickDown", "Gamepad0.DPadDown"], group: "move" },
    // 下面这些动作同属一个组：它们的键**互相不能共用**，否则"按一下砍树也存了档"
    harvest: { keys: ["KeyG", "Gamepad0.A"], group: "action" },
    chop: { keys: ["KeyH", "Gamepad0.B"], group: "action" },
    /**
     * 打一下（批66）。`Space` 在这个组里是空的；手柄用 RT ——
     * `Gamepad0.RT` 由输入后端合成（映射表不知道 getGamepads 长什么样）。
     */
    attack: { keys: ["Space", "Gamepad0.RT"], group: "action" },
    /**
     * 吃一口（批67）。**自动挑最有营养的那一种** —— 不为"吃哪个"再开一个面板：
     * 背包里能吃的东西通常只有一两样，而"先选再吃"会把一次按键变成三步操作。
     */
    eat: { keys: ["KeyE", "Gamepad0.LT"], group: "action" },
    /**
     * 做一件（批68）。做**表里第一条现在就能做的** —— 不弹面板，理由见
     * `craftSomething`：能否做完全由背包决定，一次按键 + 一句提示就够。
     */
    craft: { keys: ["KeyC", "Gamepad0.RB"], group: "action" },
    // 背包面板开关（饥荒同款键位）与丢弃选中堆。Tab 由宿主 preventDefault
    // （否则焦点会跳到浏览器 UI 上，"打开背包"变成"跳出页面"）
    bag: { keys: ["Tab", "Gamepad0.Y"], group: "action" },
    drop: { keys: ["KeyQ", "Gamepad0.X"], group: "action" },
    save: { keys: ["F5", "Gamepad0.Start"], group: "system" },
    load: { keys: ["F9", "Gamepad0.Select"], group: "system" },
    restart: { keys: ["KeyR"], group: "system" }
  }
};
var DEFAULT_INPUT_MAP = (() => {
  const r = createInputMap(DEFAULT_INPUT_MAP_DATA);
  if (!r.ok) throw new Error(`\u9ED8\u8BA4\u6620\u5C04\u8868\u672C\u8EAB\u4E0D\u5408\u6CD5\uFF1A${r.error.message}`);
  return r.value;
})();

// src/extensions/input/player-controller.ts
var CONTROLLER_TYPE = "game.controller";
var PlayerController = class extends Component {
  /** 每秒移动多少个世界单位。 */
  speed = 4.5;
  /** 去重用的"上次 poll 是哪个 tick"（不进 schema：它是运行期状态，不该进存档）。 */
  lastTick = -1;
  snapshot = null;
  schema = {
    type: CONTROLLER_TYPE,
    fields: { speed: FieldType.Float }
  };
};
function registerControllerComponent(registry) {
  if (!registry.has(CONTROLLER_TYPE)) registry.register(SCHEMA, () => new PlayerController());
}
var SCHEMA = { type: CONTROLLER_TYPE, fields: { speed: FieldType.Float } };
function directionFromMap(map, snap) {
  return {
    dx: map.axis(snap, "move_left", "move_right"),
    dz: map.axis(snap, "move_back", "move_forward")
  };
}
var EMPTY_KEYS = /* @__PURE__ */ new Set();
function stepOf(snap, speed, dt, map = DEFAULT_INPUT_MAP) {
  const d = directionFromMap(map, snap);
  const len = Math.hypot(d.dx, d.dz);
  if (len === 0) return { dx: 0, dz: 0 };
  return { dx: d.dx / len * speed * dt, dz: d.dz / len * speed * dt };
}
function createControllerModule(opts) {
  let scene = null;
  let driven = 0;
  let lastTick = -1;
  const map = opts.map ?? DEFAULT_INPUT_MAP;
  let snapshot = {
    keysDown: EMPTY_KEYS,
    keysPressed: EMPTY_KEYS,
    keysReleased: EMPTY_KEYS,
    pointer: { x: 0, y: 0, down: false, pressed: false, released: false, button: 0 },
    wheel: { dx: 0, dy: 0 },
    text: ""
  };
  const mod = {
    id: opts.id ?? "game.controller",
    get driven() {
      return driven;
    },
    get snapshot() {
      return snapshot;
    },
    get map() {
      return map;
    },
    init(ctx) {
      const got = ctx.services.get(Services.Scene);
      if (got === void 0) {
        return err(engineError("CONTROLLER.NO_SCENE", "\u63A7\u5236\u5668\u6A21\u5757\u9700\u8981\u4E00\u4E2A Scene\uFF08\u5148\u6CE8\u518C Services.Scene\uFF09"));
      }
      scene = got;
      return ok(void 0);
    },
    update(tick, dt) {
      const s = scene;
      if (s === null) return;
      if (tick === lastTick) return;
      lastTick = tick;
      snapshot = opts.poll();
      let n = 0;
      for (const c of s.componentsOf(CONTROLLER_TYPE)) {
        const node = c.node;
        if (node === null) continue;
        const step2 = stepOf(snapshot, c.speed, dt, map);
        if (step2.dx !== 0 || step2.dz !== 0) {
          node.setLocalPosition(node.localPosition.x + step2.dx, node.localPosition.y + step2.dz);
        }
        n++;
      }
      driven = n;
    },
    describe() {
      return `\u63A7\u5236\u5668\uFF1A\u6BCF tick \u9A71\u52A8 ${String(driven)} \u4E2A\u73A9\u5BB6`;
    }
  };
  return mod;
}

// src/extensions/worldgen/spawn.ts
var PLAYER_TYPE = "world.player";
var PLAYER_FRAME = "player";
var SPAWN_NO_SPRITE_COMPONENT = "SPAWN.NO_SPRITE_COMPONENT";
var SPAWN_NO_CONTROLLER_COMPONENT = "SPAWN.NO_CONTROLLER_COMPONENT";
var SPAWN_ALREADY_SPAWNED = "SPAWN.ALREADY_SPAWNED";
var PLAYER_SCHEMA = {
  type: PLAYER_TYPE,
  fields: {
    /** 出生格（升序下标）。玩家走开之后这个字段仍然是"他是从哪开始的"。 */
    cell: FieldType.Int
  }
};
var PlayerSpawn = class extends Component {
  schema = PLAYER_SCHEMA;
  cell = 0;
};
function registerPlayerComponents(registry) {
  if (!registry.has(PLAYER_TYPE)) registry.register(PLAYER_SCHEMA, () => new PlayerSpawn());
  registerControllerComponent(registry);
}
function spawnPlayer(scene, plan) {
  if (!scene.components.has(SPRITE_TYPE)) {
    return err(
      engineError(
        SPAWN_NO_SPRITE_COMPONENT,
        "\u7EC4\u4EF6\u7C7B\u578B render.sprite \u672A\u6CE8\u518C \u2014\u2014 \u73A9\u5BB6\u4F1A\u6CA1\u6709\u8EAB\u4F53\uFF08\u6E32\u67D3\u6A21\u5757\u542F\u52A8\u65F6\u4F1A\u6CE8\u518C\uFF09"
      )
    );
  }
  if (!scene.components.has(PLAYER_TYPE)) {
    return err(
      engineError(SPAWN_NO_SPRITE_COMPONENT, "\u7EC4\u4EF6\u7C7B\u578B world.player \u672A\u6CE8\u518C \u2014\u2014 \u5148 registerPlayerComponents(...)")
    );
  }
  if (!scene.components.has(CONTROLLER_TYPE)) {
    return err(
      engineError(
        SPAWN_NO_CONTROLLER_COMPONENT,
        "\u7EC4\u4EF6\u7C7B\u578B game.controller \u672A\u6CE8\u518C \u2014\u2014 \u73A9\u5BB6\u4F1A\u7AD9\u7740\u4E0D\u52A8\uFF08\u5148 registerPlayerComponents(...)\uFF09"
      )
    );
  }
  const existing = [...scene.componentsOf(PLAYER_TYPE)];
  if (existing.length > 0) {
    return err(
      engineError(SPAWN_ALREADY_SPAWNED, "\u573A\u666F\u91CC\u5DF2\u7ECF\u6709\u73A9\u5BB6\u4E86 \u2014\u2014 \u91CD\u590D\u51FA\u751F\u4F1A\u8BA9\u4E24\u4E2A\u63A7\u5236\u5668\u62A2\u540C\u4E00\u4E2A\u4F4D\u7F6E")
    );
  }
  const pick = pickSpawn(plan);
  if (!pick.ok) return pick;
  const sp = pick.value;
  const made = scene.spawnAt("player", sp.x / FIXED_UNITS, sp.z / FIXED_UNITS);
  if (!made.ok) return made;
  const nodeId = made.value.id;
  scene.attach(nodeId, () => {
    const s = new Sprite();
    s.frame = PLAYER_FRAME;
    s.width = 1;
    s.height = 1;
    s.pivotY = 0;
    return s;
  });
  scene.attach(nodeId, () => {
    const marker = new PlayerSpawn();
    marker.cell = sp.cell;
    return marker;
  });
  scene.attach(nodeId, () => new PlayerController());
  scene.flush();
  return ok({ nodeId, cell: sp.cell, x: sp.x, z: sp.z });
}

// src/extensions/render/world-visuals.ts
var VISUAL_MISSING_FRAME = "VISUAL.MISSING_FRAME";
var VISUAL_NO_SPRITE_COMPONENT = "VISUAL.NO_SPRITE_COMPONENT";
var UNMAPPED_LABEL = "\uFF08\u672A\u6620\u5C04\u7684\u79CD\u7C7B\uFF09";
var SITE_FRAMES = {
  tree: "tree",
  rock: "rock",
  berry: "berry",
  flint: "rock",
  grass_tuft: "berry",
  reed: "berry"
};
var TERRAIN_FRAME = "terrain";
var TERRAIN_TILE_PAGE = "terrain.tile";
var BIOME_TINT = {
  ocean: [0.16, 0.32, 0.55],
  beach: [0.85, 0.78, 0.55],
  grass: [0.42, 0.62, 0.3],
  forest: [0.24, 0.46, 0.26],
  rocky: [0.52, 0.5, 0.48],
  cliff: [0.38, 0.36, 0.4],
  savanna: [0.72, 0.66, 0.36],
  marsh: [0.36, 0.44, 0.38]
};
function hasSprite(s, nodeId) {
  const node = s.find(nodeId);
  return node?.get(SPRITE_TYPE) !== void 0;
}
function attachWorldVisuals(scene, availableFrames) {
  const plans = [];
  for (const area of scene.componentsOf(TERRAIN_TYPE)) {
    if (area.node === null) continue;
    const tint = BIOME_TINT[area.kind];
    plans.push({
      nodeId: area.node.id,
      frame: TERRAIN_FRAME,
      atlasId: TERRAIN_TILE_PAGE,
      kind: `terrain:${area.kind}`,
      width: area.w,
      height: area.h,
      // ★ 背景层：地面永远先画、永远被实体盖住。地形的 z 是矩形左上角的格子坐标，
      //   与实体（格子中心）必然交错 —— 不分层会被一块地形盖住站在它上面的角色，
      //   而且 draw 会被 z 序打散成几十段（T288 之后实测 29 段）。
      layer: 0,
      // ★ T288：按格平铺 —— 一块 w×h 的地形铺 w×h 张噪点，颗粒不随块变大。
      //   必须是整数：0.5 次平铺在 GPU 上就是"半张被裁掉的贴图"，
      //   而矩形格数天生是整数（`TerrainArea` 的 w/h 是格子数）。
      tileX: Math.max(1, Math.floor(area.w)),
      tileY: Math.max(1, Math.floor(area.h)),
      // ★ (0,0)：矩形左上角 = 节点位置。用 0.5 会让整块地形右移半块、上移半块 ——
      //   相邻块之间于是出现缝隙，而"缝隙"在 2.5D 斜视角下看起来像地表裂开了。
      pivotX: 0,
      pivotY: 0,
      r: tint[0],
      g: tint[1],
      b: tint[2]
    });
  }
  for (const m of scene.componentsOf(SITE_TYPE)) {
    if (m.node === null) continue;
    plans.push({
      nodeId: m.node.id,
      frame: SITE_FRAMES[m.kind] ?? null,
      atlasId: "",
      kind: `site:${m.kind}`,
      tileX: 1,
      tileY: 1,
      width: 1,
      height: 1,
      layer: 1,
      pivotX: 0.5,
      // 脚踩地面：2.5D 里精灵的底边贴住它所在的格
      pivotY: 0,
      r: 1,
      g: 1,
      b: 1
    });
  }
  for (const res of scene.componentsOf(RESOURCE_TYPE)) {
    if (res.node === null) continue;
    plans.push({
      nodeId: res.node.id,
      frame: SITE_FRAMES[res.kind] ?? null,
      atlasId: "",
      kind: `resource:${res.kind}`,
      tileX: 1,
      tileY: 1,
      width: 1,
      height: 1,
      layer: 1,
      pivotX: 0.5,
      pivotY: 0,
      r: 1,
      g: 1,
      b: 1
    });
  }
  const available = new Set(availableFrames);
  const missing = /* @__PURE__ */ new Map();
  for (const p of plans) {
    if (p.frame !== null && available.has(p.frame)) continue;
    const key = p.frame ?? UNMAPPED_LABEL;
    const set = missing.get(key) ?? /* @__PURE__ */ new Set();
    set.add(p.kind);
    missing.set(key, set);
  }
  if (missing.size > 0) {
    const detail = [...missing.entries()].sort((a, b) => a[0] < b[0] ? -1 : 1).map(([frame, kinds]) => `${frame}\uFF08\u88AB ${[...kinds].sort().join(", ")} \u7528\u5230\uFF09`).join("\uFF1B");
    return err(
      engineError(
        VISUAL_MISSING_FRAME,
        `\u56FE\u96C6\u91CC\u6CA1\u6709\u8FD9\u4E9B\u5E27\uFF1A${detail} \u2014\u2014 \u7F3A\u5E27\u7684\u8D44\u6E90\u4F1A**\u9759\u9ED8\u4E0D\u663E\u793A**\uFF08\u6E32\u67D3\u6A21\u5757\u53EA warn \u4E00\u6B21\uFF09\uFF0C\u6240\u4EE5\u5728\u8FD9\u91CC\u62A5\u9519`
      )
    );
  }
  if (!scene.components.has(SPRITE_TYPE)) {
    return err(
      engineError(
        VISUAL_NO_SPRITE_COMPONENT,
        "\u7EC4\u4EF6\u7C7B\u578B render.sprite \u672A\u6CE8\u518C \u2014\u2014 \u5148 components.register(...)\uFF08\u6E32\u67D3\u6A21\u5757\u542F\u52A8\u65F6\u4F1A\u6CE8\u518C\uFF09"
      )
    );
  }
  let terrain = 0;
  let sites = 0;
  let resources = 0;
  let skipped = 0;
  const used = /* @__PURE__ */ new Set();
  for (const p of plans) {
    if (hasSprite(scene, p.nodeId)) {
      skipped++;
      continue;
    }
    const frame = p.frame;
    if (frame === null) throw new Error(`world-visuals \u5185\u90E8\u9519\u8BEF\uFF1A${p.kind} \u7684\u5E27\u6620\u5C04\u5728\u68C0\u67E5\u4E4B\u540E\u53D8\u6210\u4E86 null`);
    const made = scene.attach(p.nodeId, () => {
      const sp = new Sprite();
      sp.frame = frame;
      sp.atlasId = p.atlasId;
      sp.tileX = p.tileX;
      sp.tileY = p.tileY;
      sp.layer = p.layer;
      sp.width = p.width;
      sp.height = p.height;
      sp.pivotX = p.pivotX;
      sp.pivotY = p.pivotY;
      sp.r = p.r;
      sp.g = p.g;
      sp.b = p.b;
      return sp;
    });
    if (!made.ok) return made;
    used.add(frame);
    if (p.kind.startsWith("terrain:")) terrain++;
    else if (p.kind.startsWith("site:")) sites++;
    else resources++;
  }
  scene.flush();
  return ok({
    terrain,
    sites,
    resources,
    frames: [...used].sort(),
    skipped
  });
}

// src/extensions/nav/nav-grid.ts
var NAV_BAD_GRID = "NAV.BAD_GRID";
var NAV_OUT_OF_RANGE = "NAV.OUT_OF_RANGE";
var NAV_BLOCKED = "NAV.BLOCKED";
var NAV_NO_PATH = "NAV.NO_PATH";
var NAV_TOO_COMPLEX = "NAV.TOO_COMPLEX";
var STRAIGHT_COST = 10;
var DIAGONAL_COST = 14;
var DIRS = [
  [1, 0, STRAIGHT_COST],
  [-1, 0, STRAIGHT_COST],
  [0, 1, STRAIGHT_COST],
  [0, -1, STRAIGHT_COST],
  [1, 1, DIAGONAL_COST],
  [1, -1, DIAGONAL_COST],
  [-1, 1, DIAGONAL_COST],
  [-1, -1, DIAGONAL_COST]
];
var OpenHeap = class {
  f = [];
  h = [];
  c = [];
  get size() {
    return this.c.length;
  }
  push(f, h, c) {
    this.f.push(f);
    this.h.push(h);
    this.c.push(c);
    let i = this.c.length - 1;
    while (i > 0) {
      const p = i - 1 >> 1;
      if (!this.less(i, p)) break;
      this.swap(i, p);
      i = p;
    }
  }
  pop() {
    const top = this.c[0];
    const lastIdx = this.c.length - 1;
    this.swap(0, lastIdx);
    this.f.pop();
    this.h.pop();
    this.c.pop();
    let i = 0;
    for (; ; ) {
      const l = i * 2 + 1;
      const r = l + 1;
      let best = i;
      if (l < this.c.length && this.less(l, best)) best = l;
      if (r < this.c.length && this.less(r, best)) best = r;
      if (best === i) break;
      this.swap(i, best);
      i = best;
    }
    return top;
  }
  less(i, j) {
    const fi = this.f[i];
    const fj = this.f[j];
    if (fi !== fj) return fi < fj;
    const hi = this.h[i];
    const hj = this.h[j];
    if (hi !== hj) return hi < hj;
    return this.c[i] < this.c[j];
  }
  swap(i, j) {
    const f = this.f[i];
    this.f[i] = this.f[j];
    this.f[j] = f;
    const h = this.h[i];
    this.h[i] = this.h[j];
    this.h[j] = h;
    const c = this.c[i];
    this.c[i] = this.c[j];
    this.c[j] = c;
  }
};
var NavGrid = class _NavGrid {
  width;
  height;
  mask;
  /** 连通分量标号；-1 = 未标。惰性填充，见 `componentOf`。 */
  labels;
  labelCount = 0;
  /** ★ 单独一个布尔：全图不可站时 `labelCount` 也是 0，用它区分"没算过"和"算出来是 0 个"。 */
  labeled = false;
  constructor(width, height, walkable) {
    if (!Number.isInteger(width) || !Number.isInteger(height) || width <= 0 || height <= 0) {
      throw new RangeError(`\u5BFC\u822A\u7F51\u683C\u5C3A\u5BF8\u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF0C\u5F97\u5230 ${String(width)}x${String(height)}`);
    }
    if (walkable.length !== width * height) {
      throw new RangeError(`\u63A9\u7801\u957F\u5EA6 ${String(walkable.length)} \u4E0E ${String(width)}x${String(height)} \u4E0D\u7B26`);
    }
    this.width = width;
    this.height = height;
    this.mask = walkable;
    this.labels = new Int32Array(width * height).fill(-1);
  }
  /** 由生成计划构造（`kinds` 走群系表）。 */
  static fromPlan(plan) {
    const total = plan.width * plan.height;
    if (plan.kinds.length !== total) {
      return err(
        engineError(
          NAV_BAD_GRID,
          `\u8BA1\u5212\u7684 kinds \u957F\u5EA6 ${String(plan.kinds.length)} \u4E0E ${String(plan.width)}x${String(plan.height)} \u4E0D\u7B26`
        )
      );
    }
    const mask = new Uint8Array(total);
    for (let i = 0; i < total; i++) mask[i] = isPassable(plan.kinds[i]) ? 1 : 0;
    return ok(new _NavGrid(plan.width, plan.height, mask));
  }
  /**
   * 由**装配后的场景**构造。
   *
   * ★ 只读组件里的 `passable` 字段，不再查群系表。
   *   这正是 `assemble.ts` 里 `sceneComponents` 踩过的坑：两条输入源混在一起时，
   *   "某块地形的 passable 写错了"会被另一条源抹平，判据全绿而地图是错的。
   *   漏格（没有任何地形覆盖）直接报错 —— 缺失不等于"不能走"。
   */
  static fromScene(scene, width, height) {
    const total = width * height;
    const mask = new Int8Array(total).fill(-1);
    for (const area of scene.componentsOf(TERRAIN_TYPE)) {
      for (let dz = 0; dz < area.h; dz++) {
        for (let dx = 0; dx < area.w; dx++) {
          const x = area.cx + dx;
          const z = area.cz + dz;
          if (x < 0 || z < 0 || x >= width || z >= height) {
            return err(
              engineError(
                NAV_BAD_GRID,
                `\u5730\u5F62\u8282\u70B9\u8D8A\u754C\uFF1A(${String(x)}, ${String(z)}) \u8D85\u51FA ${String(width)}x${String(height)}`
              )
            );
          }
          mask[z * width + x] = area.passable ? 1 : 0;
        }
      }
    }
    for (let i = 0; i < total; i++) {
      if (mask[i] === -1) {
        return err(engineError(NAV_BAD_GRID, `\u7B2C ${String(i)} \u683C\u6CA1\u6709\u5730\u5F62\u8986\u76D6\uFF0C\u65E0\u6CD5\u5EFA\u5BFC\u822A\u7F51\u683C`));
      }
    }
    const out = new Uint8Array(total);
    for (let i = 0; i < total; i++) out[i] = mask[i] === 1 ? 1 : 0;
    return ok(new _NavGrid(width, height, out));
  }
  get total() {
    return this.width * this.height;
  }
  /** 格子坐标 → 下标；越界返回 -1。 */
  indexOf(cx, cz) {
    if (!Number.isInteger(cx) || !Number.isInteger(cz)) return -1;
    if (cx < 0 || cz < 0 || cx >= this.width || cz >= this.height) return -1;
    return cz * this.width + cx;
  }
  cellX(index) {
    return index % this.width;
  }
  cellZ(index) {
    return (index - index % this.width) / this.width;
  }
  /** 格子中心的世界坐标（`+0.5` 与 `spawn.ts` 的出生点同源）。 */
  centerOf(index) {
    return { x: this.cellX(index) + 0.5, z: this.cellZ(index) + 0.5 };
  }
  /** 世界坐标 → 格子下标。1 世界单位 = 1 格（`FIXED_UNITS` 除下来正好）。 */
  cellAt(x, z) {
    return this.indexOf(Math.floor(x), Math.floor(z));
  }
  isWalkableIndex(index) {
    return index >= 0 && index < this.mask.length && this.mask[index] === 1;
  }
  isWalkable(cx, cz) {
    return this.isWalkableIndex(this.indexOf(cx, cz));
  }
  /**
   * 找离 `(cx, cz)` 最近的可站立格；找不到返回 -1。
   *
   * ★ 同一圈内取**距离平方最小**、平手取**下标最小**，不是"环上第一个遇到的"。
   *   后者取决于扫描方向，于是"被推到海里的怪该回到哪块岸"取决于遍历序 ——
   *   回放里就是另一条路。
   */
  nearestWalkable(cx, cz, maxRadius = 6) {
    if (this.isWalkable(cx, cz)) return this.indexOf(cx, cz);
    for (let r = 1; r <= maxRadius; r++) {
      let best = -1;
      let bestD2 = Infinity;
      for (let dz = -r; dz <= r; dz++) {
        for (let dx = -r; dx <= r; dx++) {
          if (Math.max(Math.abs(dx), Math.abs(dz)) !== r) continue;
          const x = cx + dx;
          const z = cz + dz;
          const i = this.indexOf(x, z);
          if (i < 0 || this.mask[i] !== 1) continue;
          const d2 = dx * dx + dz * dz;
          if (d2 < bestD2 || d2 === bestD2 && i < best) {
            best = i;
            bestD2 = d2;
          }
        }
      }
      if (best >= 0) return best;
    }
    return -1;
  }
  /**
   * 连通分量标号（惰性全图标注一次）。
   *
   * ★ 与 A* 共用同一套邻居规则（见文件头 ④），否则会出现
   *   "分量说是通的、寻路说没路"这种自相矛盾的报告。
   */
  componentOf(index) {
    if (index < 0 || index >= this.mask.length) return -1;
    if (this.labels[index] >= 0) return this.labels[index];
    if (this.mask[index] !== 1) return -1;
    this.labelAll();
    return this.labels[index];
  }
  get componentCount() {
    if (!this.labeled) this.labelAll();
    return this.labelCount;
  }
  labelAll() {
    if (this.labeled) return;
    this.labeled = true;
    const labels = this.labels;
    const stack = [];
    let next = 0;
    for (let start = 0; start < this.mask.length; start++) {
      if (this.mask[start] !== 1 || labels[start] >= 0) continue;
      labels[start] = next;
      stack.push(start);
      while (stack.length > 0) {
        const cur = stack.pop();
        const cx = this.cellX(cur);
        const cz = this.cellZ(cur);
        for (const [dx, dz] of DIRS) {
          const n = this.neighborOf(cx, cz, dx, dz);
          if (n < 0 || labels[n] >= 0) continue;
          labels[n] = next;
          stack.push(n);
        }
      }
      next++;
    }
    this.labelCount = next;
  }
  /**
   * 邻居判定：越界/不可走/切角 → -1。
   *
   * ★ 这是全类唯一一处定义"相邻"的地方，`labelAll` 与 `findPath` 都走它。
   *   抄两份的后果是"分量连通但寻不到路"，而两边的判据各自都绿。
   */
  neighborOf(cx, cz, dx, dz) {
    const n = this.indexOf(cx + dx, cz + dz);
    if (n < 0 || this.mask[n] !== 1) return -1;
    if (dx !== 0 && dz !== 0) {
      if (!this.isWalkable(cx + dx, cz) || !this.isWalkable(cx, cz + dz)) return -1;
    }
    return n;
  }
  /**
   * A*。`from` / `to` 是格子下标。
   *
   * 起点或终点不可站时先吸附到附近空格（`snapped: true` 会写在结果里）——
   * 静默吸附是危险的，调用方需要知道"它其实走不到你指的那一格"。
   */
  findPath(from, to, opts = {}) {
    if (from < 0 || from >= this.total || to < 0 || to >= this.total) {
      return err(
        engineError(
          NAV_OUT_OF_RANGE,
          `\u5BFB\u8DEF\u4E0B\u6807\u8D8A\u754C\uFF1A${String(from)} \u2192 ${String(to)}\uFF08\u5171 ${String(this.total)} \u683C\uFF09`
        )
      );
    }
    const maxExpanded = opts.maxExpanded ?? 2e5;
    const snapRadius = opts.snapRadius ?? 6;
    let start = from;
    let goal = to;
    let snapped = false;
    if (this.mask[start] !== 1) {
      const s = this.nearestWalkable(this.cellX(from), this.cellZ(from), snapRadius);
      if (s < 0) {
        return err(engineError(NAV_BLOCKED, `\u8D77\u70B9 ${String(from)} \u4E0D\u53EF\u7AD9\uFF0C\u9644\u8FD1 ${String(snapRadius)} \u683C\u5185\u6CA1\u6709\u843D\u811A\u70B9`));
      }
      start = s;
      snapped = true;
    }
    if (this.mask[goal] !== 1) {
      const g = this.nearestWalkable(this.cellX(to), this.cellZ(to), snapRadius);
      if (g < 0) {
        return err(engineError(NAV_BLOCKED, `\u7EC8\u70B9 ${String(to)} \u4E0D\u53EF\u7AD9\uFF0C\u9644\u8FD1 ${String(snapRadius)} \u683C\u5185\u6CA1\u6709\u843D\u811A\u70B9`));
      }
      goal = g;
      snapped = true;
    }
    if (start === goal) {
      return ok({ cells: [start], cost: 0, expanded: 0, snapped, from: start, to: goal });
    }
    const total = this.total;
    const width = this.width;
    const gScore = new Int32Array(total).fill(-1);
    const back = new Int32Array(total).fill(-1);
    const closed = new Uint8Array(total);
    const heap = new OpenHeap();
    const gx = this.cellX(goal);
    const gz = this.cellZ(goal);
    const guess = (cell) => {
      const dx = Math.abs(this.cellX(cell) - gx);
      const dz = Math.abs(this.cellZ(cell) - gz);
      return STRAIGHT_COST * (dx + dz) + (DIAGONAL_COST - 2 * STRAIGHT_COST) * Math.min(dx, dz);
    };
    gScore[start] = 0;
    heap.push(guess(start), guess(start), start);
    let expanded = 0;
    let reached = false;
    while (heap.size > 0) {
      const cur = heap.pop();
      if (closed[cur] === 1) continue;
      closed[cur] = 1;
      expanded++;
      if (cur === goal) {
        reached = true;
        break;
      }
      if (expanded > maxExpanded) {
        return err(
          engineError(
            NAV_TOO_COMPLEX,
            `A* \u5C55\u5F00\u8D85\u8FC7 ${String(maxExpanded)} \u4E2A\u8282\u70B9\u4ECD\u672A\u5230\u8FBE ${String(goal)}\uFF08\u8D77\u70B9 ${String(start)}\uFF09`
          )
        );
      }
      const cx = cur % width;
      const cz = (cur - cx) / width;
      for (const [dx, dz, stepCost] of DIRS) {
        const n = this.neighborOf(cx, cz, dx, dz);
        if (n < 0 || closed[n] === 1) continue;
        const ng = gScore[cur] + stepCost;
        const old = gScore[n];
        if (old >= 0 && ng >= old) continue;
        gScore[n] = ng;
        back[n] = cur;
        const h = guess(n);
        heap.push(ng + h, h, n);
      }
    }
    if (!reached) {
      return err(
        engineError(
          NAV_NO_PATH,
          `\u4ECE ${String(start)} \u5230 ${String(goal)} \u6CA1\u6709\u53EF\u8D70\u7684\u8DEF\uFF08\u5C55\u5F00 ${String(expanded)} \u683C\uFF1B\u68C0\u67E5\u662F\u5426\u88AB\u6C34/\u60AC\u5D16\u9694\u65AD\uFF09`
        )
      );
    }
    const cells = [];
    let walk = goal;
    while (walk !== -1) {
      cells.push(walk);
      if (walk === start) break;
      walk = back[walk];
    }
    cells.reverse();
    return ok({ cells, cost: gScore[goal], expanded, snapped, from: start, to: goal });
  }
  stats() {
    let walkable = 0;
    for (let i = 0; i < this.mask.length; i++) if (this.mask[i] === 1) walkable++;
    return {
      width: this.width,
      height: this.height,
      walkable,
      blocked: this.total - walkable,
      components: this.labeled ? this.labelCount : -1
    };
  }
  /** 导出掩码副本（存档/诊断用）。改动返回值不影响网格。 */
  toMask() {
    return this.mask.slice();
  }
};

// src/extensions/combat/health.ts
var HEALTH_TYPE = "combat.health";
var COMBAT_NO_TARGET = "COMBAT.NO_TARGET";
var COMBAT_NO_HEALTH = "COMBAT.NO_HEALTH";
var COMBAT_BAD_AMOUNT = "COMBAT.BAD_AMOUNT";
var COMBAT_TARGET_DEAD = "COMBAT.TARGET_DEAD";
var COMBAT_INVULNERABLE = "COMBAT.INVULNERABLE";
var Health = class extends Component {
  /** 当前血量（整数，>= 0）。 */
  hp = 10;
  /** 上限（整数，> 0）。 */
  maxHp = 10;
  schema = {
    type: HEALTH_TYPE,
    fields: { hp: FieldType.Int, maxHp: FieldType.Int }
  };
  /**
   * 无敌截止 tick（运行期，见文件头 ④）：`tick < invulnUntil` 时不受伤害。
   * `-1` = 从来不无敌。
   */
  invulnUntil = -1;
};
function registerHealthComponent(registry) {
  if (!registry.has(HEALTH_TYPE)) registry.register(new Health().schema, () => new Health());
}
function isDead(h) {
  return h.hp <= 0;
}
function damage(scene, targetId, amount, opts = {}) {
  if (!Number.isInteger(amount) || amount <= 0) {
    return err(
      engineError(COMBAT_BAD_AMOUNT, `\u4F24\u5BB3\u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF0C\u6536\u5230 ${String(amount)}\uFF08\u5C0F\u6570\u4F1A\u8BA9"\u6B7B\u4E86\u6CA1\u6709"\u53D6\u51B3\u4E8E\u7D2F\u52A0\u6B21\u5E8F\uFF09`)
    );
  }
  const node = scene.find(targetId);
  if (node === void 0 || node === null) {
    return err(engineError(COMBAT_NO_TARGET, `\u8282\u70B9 ${String(targetId)} \u4E0D\u5728\u573A\u666F\u91CC`));
  }
  const h = node.get(HEALTH_TYPE);
  if (h === void 0) {
    return err(engineError(COMBAT_NO_HEALTH, `\u8282\u70B9 ${String(targetId)} \u6CA1\u6709 ${HEALTH_TYPE}\uFF08\u5148 attach \u4E00\u4E2A Health\uFF09`));
  }
  if (isDead(h)) {
    return err(
      engineError(COMBAT_TARGET_DEAD, `\u8282\u70B9 ${String(targetId)} \u5DF2\u7ECF\u5F52\u96F6\uFF08hp=${String(h.hp)}\uFF09\u2014\u2014 \u6253\u5C38\u4F53\u901A\u5E38\u662F\u76EE\u6807\u9009\u62E9\u51FA\u9519`)
    );
  }
  if (opts.tick !== void 0 && Number.isInteger(opts.tick) && opts.tick < h.invulnUntil) {
    return err(
      engineError(
        COMBAT_INVULNERABLE,
        `\u8282\u70B9 ${String(targetId)} \u8FD8\u5728\u65E0\u654C\u5E27\u91CC\uFF08tick ${String(opts.tick)} < ${String(h.invulnUntil)}\uFF09`
      )
    );
  }
  const before = h.hp;
  const after = Math.max(0, before - amount);
  h.hp = after;
  if (opts.invulnTicks !== void 0 && opts.invulnTicks > 0 && opts.tick !== void 0) {
    h.invulnUntil = opts.tick + opts.invulnTicks;
  }
  return ok({
    nodeId: targetId,
    before,
    after,
    applied: before - after,
    overkill: Math.max(0, amount - before),
    dead: after === 0
  });
}
function heal(scene, targetId, amount) {
  if (!Number.isInteger(amount) || amount <= 0) {
    return err(engineError(COMBAT_BAD_AMOUNT, `\u56DE\u8840\u91CF\u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF0C\u6536\u5230 ${String(amount)}`));
  }
  const node = scene.find(targetId);
  if (node === void 0 || node === null) {
    return err(engineError(COMBAT_NO_TARGET, `\u8282\u70B9 ${String(targetId)} \u4E0D\u5728\u573A\u666F\u91CC`));
  }
  const h = node.get(HEALTH_TYPE);
  if (h === void 0) {
    return err(engineError(COMBAT_NO_HEALTH, `\u8282\u70B9 ${String(targetId)} \u6CA1\u6709 ${HEALTH_TYPE}`));
  }
  if (isDead(h)) {
    return err(engineError(COMBAT_TARGET_DEAD, `\u8282\u70B9 ${String(targetId)} \u5DF2\u7ECF\u5F52\u96F6 \u2014\u2014 \u56DE\u8840\u4E0D\u590D\u6D3B\uFF08\u590D\u6D3B\u8981\u6709\u5355\u72EC\u7684\u8BED\u4E49\uFF09`));
  }
  const before = h.hp;
  h.hp = Math.min(h.maxHp, before + amount);
  return ok(h.hp - before);
}

// src/extensions/combat/faction.ts
var FACTION_TYPE = "combat.faction";
var FACTION_BAD_INPUT = "FACTION.BAD_INPUT";
var STANCES = ["ally", "foe", "neutral"];
function isStance(v) {
  return STANCES.includes(v);
}
var FactionMember = class extends Component {
  /** 阵营名。**空串 = 中立**（在场但没编队）。 */
  team = "";
  schema = {
    type: FACTION_TYPE,
    fields: { team: FieldType.String }
  };
};
function registerFactionComponent(registry) {
  if (!registry.has(FACTION_TYPE)) registry.register(new FactionMember().schema, () => new FactionMember());
}
function teamOf(scene, nodeId) {
  const node = scene.find(nodeId);
  if (node === void 0 || node === null) return { team: "", hasComponent: false };
  const m = node.get(FACTION_TYPE);
  if (m === void 0) return { team: "", hasComponent: false };
  return { team: m.team, hasComponent: true };
}
var Factions = class {
  /** a → (b → stance)，**恒定对称**写入，见文件头 ③。 */
  table = /* @__PURE__ */ new Map();
  /**
   * 设置两个阵营的关系（**双向**）。
   *
   * 报错而非覆盖的三种情况（见文件头 ②④）：
   *  · `a`/`b` 为空串 —— 中立不是一个能用关系表编址的组（否则一次调用
   *    就把"世界上所有中立单位"变成某人的敌人，而调用方以为自己只设了一对）；
   *  · `a === b` —— 同队关系是不变量；
   *  · `stance` 不在 `STANCES` 里 —— 拼错的 `"foe "` 会被当成未知关系。
   */
  setStance(a, b, stance) {
    if (a.length === 0 || b.length === 0) {
      return err(engineError(FACTION_BAD_INPUT, `\u9635\u8425\u540D\u4E0D\u80FD\u4E3A\u7A7A\u4E32\uFF08\u7A7A\u4E32 = \u4E2D\u7ACB\uFF0C\u4E2D\u7ACB\u4E0D\u53C2\u4E0E\u5173\u7CFB\u8868\uFF09\uFF1A\u6536\u5230\u300C${a}\u300D/\u300C${b}\u300D`));
    }
    if (a === b) {
      return err(
        engineError(FACTION_BAD_INPUT, `\u4E0D\u80FD\u7ED9\u300C${a}\u300D\u548C\u5B83\u81EA\u5DF1\u8BBE\u5173\u7CFB \u2014\u2014 \u540C\u961F\u6052\u4E3A ally\uFF08\u8981\u961F\u53CB\u4E92\u780D\u8BF7\u7528 attack({friendlyFire:true})\uFF09`)
      );
    }
    if (!isStance(stance)) {
      return err(engineError(FACTION_BAD_INPUT, `\u672A\u77E5\u5173\u7CFB\u300C${String(stance)}\u300D\uFF08\u53EA\u63A5\u53D7 ${STANCES.join(" / ")}\uFF09`));
    }
    this.put(a, b, stance);
    this.put(b, a, stance);
    return ok(true);
  }
  put(a, b, stance) {
    let row = this.table.get(a);
    if (row === void 0) {
      row = /* @__PURE__ */ new Map();
      this.table.set(a, row);
    }
    row.set(b, stance);
  }
  /**
   * 判两方的立场。
   *
   * 顺序（判据按这个顺序写）：
   *  1. 同名且非空 → `ally`（不查表）；
   *  2. 表里有 → 表里的值；
   *  3. 其余（含任一方为空串、含两方都空串）→ `neutral`。
   */
  stanceOf(a, b) {
    if (a.length > 0 && a === b) return "ally";
    const got = this.table.get(a)?.get(b);
    return got ?? "neutral";
  }
  /** 是不是盟友（`attack()` 默认只拦这个）。 */
  isAlly(a, b) {
    return this.stanceOf(a, b) === "ally";
  }
  /** 关系的只读快照（按 `a` 再按 `b` 升序）—— 日志与判据读它不会因插入序而变。 */
  pairs() {
    const out = [];
    for (const [a, row] of this.table) {
      for (const [b, stance] of row) out.push({ a, b, stance });
    }
    out.sort((x, y) => x.a !== y.a ? x.a < y.a ? -1 : 1 : x.b < y.b ? -1 : x.b > y.b ? 1 : 0);
    return out;
  }
};
function createFactions() {
  return new Factions();
}

// src/extensions/combat/attack.ts
var ATTACKER_TYPE = "combat.attacker";
var COMBAT_NO_ATTACKER = "COMBAT.NO_ATTACKER";
var COMBAT_SELF = "COMBAT.SELF";
var COMBAT_OUT_OF_RANGE = "COMBAT.OUT_OF_RANGE";
var COMBAT_COOLDOWN = "COMBAT.COOLDOWN";
var COMBAT_FRIENDLY_FIRE = "COMBAT.FRIENDLY_FIRE";
var Attacker = class extends Component {
  /** 每下多少伤害（整数，见 `health.ts` 文件头 ①）。 */
  damage = 1;
  /** 射程（世界单位）。 */
  range = 1.6;
  /** 两下之间至少隔多少 tick（0 = 每 tick 都能打）。 */
  cooldownTicks = 20;
  schema = {
    type: ATTACKER_TYPE,
    fields: { damage: FieldType.Int, range: FieldType.Float, cooldownTicks: FieldType.Int }
  };
  /** 上次成功命中的 tick（运行期，不进存档 —— 读档后的第一下不该"欠一次冷却"）。 */
  lastHitTick = Number.NEGATIVE_INFINITY;
};
function registerAttackerComponent(registry) {
  if (!registry.has(ATTACKER_TYPE)) registry.register(new Attacker().schema, () => new Attacker());
}
function attack(scene, attackerId, targetId, opts = {}) {
  if (attackerId === targetId) {
    return err(engineError(COMBAT_SELF, `\u8282\u70B9 ${String(attackerId)} \u60F3\u6253\u81EA\u5DF1 \u2014\u2014 \u901A\u5E38\u662F\u76EE\u6807\u9009\u62E9\u586B\u9519\u4E86`));
  }
  const attackerNode = scene.find(attackerId);
  if (attackerNode === void 0 || attackerNode === null) {
    return err(engineError(COMBAT_NO_ATTACKER, `\u653B\u51FB\u8005 ${String(attackerId)} \u4E0D\u5728\u573A\u666F\u91CC`));
  }
  const atk = attackerNode.get(ATTACKER_TYPE);
  if (atk === void 0) {
    return err(engineError(COMBAT_NO_ATTACKER, `\u8282\u70B9 ${String(attackerId)} \u6CA1\u6709 ${ATTACKER_TYPE}`));
  }
  if (!Number.isInteger(atk.damage) || atk.damage <= 0) {
    return err(
      engineError(COMBAT_NO_ATTACKER, `\u8282\u70B9 ${String(attackerId)} \u7684\u4F24\u5BB3\u914D\u7F6E\u4E0D\u5408\u6CD5\uFF1A${String(atk.damage)}\uFF08\u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF09`)
    );
  }
  if (!(atk.range > 0) || !Number.isFinite(atk.range)) {
    return err(
      engineError(COMBAT_NO_ATTACKER, `\u8282\u70B9 ${String(attackerId)} \u7684\u5C04\u7A0B\u914D\u7F6E\u4E0D\u5408\u6CD5\uFF1A${String(atk.range)}`)
    );
  }
  if (!Number.isInteger(atk.cooldownTicks) || atk.cooldownTicks < 0) {
    return err(
      engineError(COMBAT_NO_ATTACKER, `\u8282\u70B9 ${String(attackerId)} \u7684\u51B7\u5374\u914D\u7F6E\u4E0D\u5408\u6CD5\uFF1A${String(atk.cooldownTicks)}`)
    );
  }
  const targetNode = scene.find(targetId);
  if (targetNode === void 0 || targetNode === null) {
    return err(engineError(COMBAT_NO_TARGET, `\u76EE\u6807 ${String(targetId)} \u4E0D\u5728\u573A\u666F\u91CC`));
  }
  const hp = targetNode.get(HEALTH_TYPE);
  if (hp === void 0) {
    return err(engineError(COMBAT_NO_HEALTH, `\u76EE\u6807 ${String(targetId)} \u6CA1\u6709 ${HEALTH_TYPE}`));
  }
  if (isDead(hp)) {
    return err(engineError(COMBAT_TARGET_DEAD, `\u76EE\u6807 ${String(targetId)} \u5DF2\u7ECF\u5F52\u96F6\uFF08hp=${String(hp.hp)}\uFF09`));
  }
  const factions = opts.factions;
  let stance = "neutral";
  if (factions !== void 0) {
    const mine = teamOf(scene, attackerId).team;
    const theirs = teamOf(scene, targetId).team;
    stance = factions.stanceOf(mine, theirs);
    if (stance === "ally" && opts.friendlyFire !== true) {
      return err(
        engineError(
          COMBAT_FRIENDLY_FIRE,
          `\u76EE\u6807 ${String(targetId)} \u662F\u53CB\u519B\uFF08\u9635\u8425\u300C${mine}\u300D\uFF09\u2014\u2014 \u8981\u5141\u8BB8\u53CB\u4F24\u8BF7\u663E\u5F0F\u4F20 friendlyFire: true`
        )
      );
    }
  }
  const a = attackerNode.worldPosition;
  const t = targetNode.worldPosition;
  const dx = t.x - a.x;
  const dz = t.y - a.y;
  const dist2 = dx * dx + dz * dz;
  if (dist2 > atk.range * atk.range) {
    return err(
      engineError(
        COMBAT_OUT_OF_RANGE,
        `\u76EE\u6807 ${String(targetId)} \u8DDD\u79BB ${Math.sqrt(dist2).toFixed(3)} \u8D85\u51FA\u5C04\u7A0B ${String(atk.range)}`
      )
    );
  }
  const tick = opts.tick;
  const checkCd = tick !== void 0 && Number.isInteger(tick);
  if (checkCd && tick - atk.lastHitTick < atk.cooldownTicks) {
    return err(
      engineError(
        COMBAT_COOLDOWN,
        `\u51B7\u5374\u672A\u597D\uFF1Atick ${String(tick)} \u8DDD\u4E0A\u6B21\u547D\u4E2D ${String(atk.lastHitTick)} \u53EA\u9694 ${String(tick - atk.lastHitTick)}\uFF08\u9700\u8981 ${String(atk.cooldownTicks)}\uFF09`
      )
    );
  }
  const dmg = damage(scene, targetId, atk.damage, {
    tick: checkCd ? tick : void 0,
    invulnTicks: opts.invulnTicks
  });
  if (!dmg.ok) return dmg;
  if (checkCd) atk.lastHitTick = tick;
  return ok({
    attackerId,
    targetId,
    distance: Math.sqrt(dist2),
    cooldownChecked: checkCd,
    stance,
    stanceChecked: factions !== void 0,
    report: dmg.value
  });
}

// src/extensions/combat/hitstop.ts
var HITSTOP_BAD_MODULE = "HITSTOP.BAD_MODULE";
var HITSTOP_BAD_TICKS = "HITSTOP.BAD_TICKS";
function createHitstopModule(opts) {
  let sched = null;
  let triggers = 0;
  let extended = 0;
  let skipped = 0;
  let rejected = 0;
  let lastTicks = 0;
  const handle = {
    id: opts.id ?? "combat.hitstop",
    deps: [],
    get stats() {
      return {
        triggers,
        extended,
        skipped,
        rejected,
        lastTicks,
        frozen: sched === null ? false : sched.frozen,
        freezeTicks: sched === null ? 0 : sched.freezeTicks
      };
    },
    init(ctx) {
      const got = ctx.services.get(Services.Scheduler);
      if (got === void 0) {
        return err(engineError(HITSTOP_BAD_MODULE, "\u987F\u5E27\u6A21\u5757\u9700\u8981\u4E00\u4E2A\u8C03\u5EA6\u5668\uFF08\u5148\u63D0\u4F9B Services.Scheduler\uFF09"));
      }
      sched = got;
      return ok(void 0);
    },
    stop() {
    },
    describe() {
      return `\u987F\u5E27\uFF1A\u89E6\u53D1 ${String(triggers)} / \u5EF6\u957F ${String(extended)} / \u8DF3\u8FC7 ${String(skipped)} / \u62D2\u7EDD ${String(rejected)}`;
    },
    trigger(info) {
      const s = sched;
      if (s === null) {
        return err(engineError(HITSTOP_BAD_MODULE, "\u987F\u5E27\u6A21\u5757\u8FD8\u6CA1 init\uFF08\u62FF\u4E0D\u5230\u8C03\u5EA6\u5668\uFF09\u5C31\u6536\u5230\u4E86\u547D\u4E2D"));
      }
      const ticks = opts.policy(info);
      if (!Number.isInteger(ticks) || ticks < 0) {
        rejected++;
        return err(
          engineError(
            HITSTOP_BAD_TICKS,
            `\u987F\u5E27\u7B56\u7565\u8FD4\u56DE\u4E86 ${String(ticks)}\uFF08\u5FC5\u987B\u662F \u22650 \u7684\u6574\u6570\uFF1B0 = \u4E0D\u51BB\uFF09`
          )
        );
      }
      if (ticks === 0) {
        skipped++;
        lastTicks = 0;
        return ok({ ticks: 0, remaining: s.freezeTicks, extended: false });
      }
      const wasFrozen = s.frozen;
      s.freeze(ticks);
      triggers++;
      if (wasFrozen) extended++;
      lastTicks = ticks;
      return ok({ ticks, remaining: s.freezeTicks, extended: wasFrozen });
    }
  };
  return handle;
}

// src/extensions/nav/move-along.ts
var ARRIVE_EPS = 1e-6;
function stepAlong(grid, path, cursor, x, z, speed, dt) {
  let i = Math.max(0, Math.min(cursor, path.length));
  let px = x;
  let pz = z;
  let moved = 0;
  let budget = speed * dt;
  if (!Number.isFinite(px) || !Number.isFinite(pz)) {
    return { x, z, cursor: i, done: i >= path.length, moved: 0 };
  }
  if (!(budget > 0) || !Number.isFinite(budget)) {
    return { x: px, z: pz, cursor: i, done: i >= path.length, moved: 0 };
  }
  while (budget > 0 && i < path.length) {
    const c = grid.centerOf(path[i]);
    const dx = c.x - px;
    const dz = c.z - pz;
    const d = Math.hypot(dx, dz);
    if (d <= ARRIVE_EPS) {
      px = c.x;
      pz = c.z;
      i++;
      continue;
    }
    if (d <= budget) {
      px = c.x;
      pz = c.z;
      moved += d;
      budget -= d;
      i++;
      continue;
    }
    px += dx / d * budget;
    pz += dz / d * budget;
    moved += budget;
    budget = 0;
  }
  return { x: px, z: pz, cursor: i, done: i >= path.length, moved };
}

// src/extensions/ai/move.ts
var MOVER_TYPE = "ai.mover";
var AI_BAD_MOVE = "AI.BAD_MOVE";
var SWEEP_SKIN = 1e-3;
var Mover = class extends Component {
  /** 每秒走多少世界单位。 */
  speed = 2.2;
  schema = {
    type: MOVER_TYPE,
    fields: { speed: FieldType.Float }
  };
  // ---- 以下全部是**运行期状态**，不进 schema、不进存档、不进指纹。
  //      理由：路径是"从当前局面推出来的"，存档再读回来时局面已经变了；
  //      把它存进去反而会让读档后的第一 tick 沿一条过期的路走。
  /** 当前路径（格子下标序列）。 */
  path = [];
  /** 下一个要去的路点下标。 */
  cursor = 0;
  /** 当前路径对应的目标格；-1 = 没有目标。 */
  goalCell = -1;
  /** 已经走到目标上了（等目标变化再重算）。 */
  arrived = false;
  /** 上次算路失败的目标格与退避截止 tick（见文件头 ①）。 */
  failCell = -1;
  retryTick = 0;
  /** 连续没挪动的 tick 数（见文件头 ③）。 */
  stuckTicks = 0;
};
function registerMoverComponent(registry) {
  if (!registry.has(MOVER_TYPE)) registry.register(new Mover().schema, () => new Mover());
}
function createMoveModule(opts) {
  const { grid } = opts;
  const stuckLimit = opts.stuckTicks ?? 12;
  const stuckEps = opts.stuckEps ?? 1e-3;
  const retryTicks = opts.retryTicks ?? 30;
  let scene = null;
  let paths = 0;
  let unreachable = 0;
  let stuck = 0;
  let blocked = 0;
  let moving = 0;
  let arrived = 0;
  let idle = 0;
  function clampToContact(nodeId, fromX, fromZ, toX, toZ) {
    const sweep = opts.sweep;
    if (sweep === void 0) return { x: toX, z: toZ, hit: null };
    const dx = toX - fromX;
    const dz = toZ - fromZ;
    const len = Math.hypot(dx, dz);
    if (!(len > 0)) return { x: toX, z: toZ, hit: null };
    const hit = sweep(nodeId, dx, dz);
    if (hit === null) return { x: toX, z: toZ, hit: null };
    const back = Math.max(0, hit.t - SWEEP_SKIN / len);
    return { x: fromX + dx * back, z: fromZ + dz * back, hit };
  }
  const handle = {
    id: opts.id ?? "ai.move",
    get stats() {
      const s = scene;
      return {
        agents: s === null ? 0 : [...s.componentsOf(MOVER_TYPE)].length,
        moving,
        arrived,
        idle,
        paths,
        unreachable,
        stuck,
        blocked
      };
    },
    pathOf(nodeId) {
      const s = scene;
      if (s === null) return [];
      for (const m of s.componentsOf(MOVER_TYPE)) {
        if (m.node?.id === nodeId) return m.path.slice();
      }
      return [];
    },
    init(ctx) {
      const got = ctx.services.get(Services.Scene);
      if (got === void 0) {
        return err(engineError(AI_BAD_MOVE, "\u79FB\u52A8\u6A21\u5757\u9700\u8981\u4E00\u4E2A Scene\uFF08\u5148\u6CE8\u518C Services.Scene\uFF09"));
      }
      scene = got;
      return ok(void 0);
    },
    update(tick, dt) {
      const s = scene;
      if (s === null) return;
      moving = 0;
      arrived = 0;
      idle = 0;
      const agents = [...s.componentsOf(MOVER_TYPE)];
      agents.sort((a, b) => (a.node?.id ?? -1) - (b.node?.id ?? -1));
      for (const m of agents) {
        const node = m.node;
        if (node === null || !node.activeInHierarchy) continue;
        if (!(m.speed > 0) || !Number.isFinite(m.speed)) {
          idle++;
          continue;
        }
        const goal = opts.decide(node.id, tick);
        if (goal === null) {
          m.path.length = 0;
          m.cursor = 0;
          m.goalCell = -1;
          m.arrived = false;
          idle++;
          continue;
        }
        if (m.arrived && goal === m.goalCell) {
          idle++;
          continue;
        }
        if (goal === m.failCell && tick < m.retryTick) {
          idle++;
          continue;
        }
        if (goal !== m.goalCell || m.path.length === 0) {
          if (!plan(m, node, goal, tick)) {
            idle++;
            continue;
          }
        }
        const wp = node.worldPosition;
        const cursorBefore = m.cursor;
        const r = stepAlong(grid, m.path, m.cursor, wp.x, wp.y, m.speed, dt);
        m.cursor = r.cursor;
        const aim = clampToContact(node.id, wp.x, wp.y, r.x, r.z);
        if (aim.hit !== null) {
          m.cursor = cursorBefore;
          blocked++;
        }
        const stepX = aim.x - wp.x;
        const stepZ = aim.z - wp.y;
        const movedNow = Math.hypot(stepX, stepZ);
        if (movedNow > 0) {
          const lp = node.localPosition;
          node.setLocalPosition(lp.x + stepX, lp.y + stepZ);
          moving++;
        }
        if (aim.hit === null && r.done) {
          m.arrived = true;
          m.stuckTicks = 0;
          arrived++;
          continue;
        }
        if (movedNow <= stuckEps) {
          m.stuckTicks++;
          if (m.stuckTicks >= stuckLimit) {
            m.path.length = 0;
            m.cursor = 0;
            m.goalCell = -1;
            m.arrived = false;
            m.stuckTicks = 0;
            stuck++;
          }
        } else {
          m.stuckTicks = 0;
        }
      }
    },
    describe() {
      return `AI \u79FB\u52A8\uFF1A${String(moving)} \u4E2A\u4EE3\u7406\u5728\u8D70\uFF0C\u7D2F\u8BA1\u7B97\u8DEF ${String(paths)} \u6B21 / \u4E0D\u53EF\u8FBE ${String(unreachable)} \u6B21 / \u88AB\u7269\u7406\u6321\u4F4F ${String(blocked)} \u6B21`;
    }
  };
  function plan(m, node, goal, tick) {
    const wp = node.worldPosition;
    const from = grid.cellAt(wp.x, wp.y);
    if (from < 0) {
      m.failCell = goal;
      m.retryTick = tick + retryTicks;
      unreachable++;
      return false;
    }
    const res = grid.findPath(from, goal);
    if (!res.ok) {
      m.failCell = goal;
      m.retryTick = tick + retryTicks;
      m.path.length = 0;
      m.cursor = 0;
      m.goalCell = -1;
      m.arrived = false;
      unreachable++;
      return false;
    }
    const p = res.value;
    m.path = p.cells.slice();
    m.cursor = p.cells.length > 0 && p.cells[0] === from ? 1 : 0;
    m.goalCell = goal;
    m.arrived = false;
    m.stuckTicks = 0;
    m.failCell = -1;
    m.retryTick = 0;
    paths++;
    return true;
  }
  return handle;
}

// src/extensions/combat/combat-module.ts
var COMBAT_BAD_MODULE = "COMBAT.BAD_MODULE";
function createCombatModule(opts) {
  const destroyOnKill = opts.destroyOnKill ?? true;
  let scene = null;
  let hits = 0;
  let kills = 0;
  let outOfRange = 0;
  let cooldown = 0;
  let friendlyFire = 0;
  let errors = 0;
  let lastError = "";
  const handle = {
    id: opts.id ?? "combat",
    get stats() {
      const s = scene;
      return {
        attackers: s === null ? 0 : [...s.componentsOf(ATTACKER_TYPE)].length,
        hits,
        kills,
        outOfRange,
        cooldown,
        friendlyFire,
        errors,
        lastError
      };
    },
    init(ctx) {
      const got = ctx.services.get(Services.Scene);
      if (got === void 0) {
        return err(engineError(COMBAT_BAD_MODULE, "\u6218\u6597\u6A21\u5757\u9700\u8981\u4E00\u4E2A Scene\uFF08\u5148\u6CE8\u518C Services.Scene\uFF09"));
      }
      scene = got;
      return ok(void 0);
    },
    update(tick) {
      const s = scene;
      if (s === null) return;
      const attackers = [...s.componentsOf(ATTACKER_TYPE)];
      attackers.sort((a, b) => (a.node?.id ?? -1) - (b.node?.id ?? -1));
      for (const atk of attackers) {
        const node = atk.node;
        if (node === null || !node.activeInHierarchy) continue;
        const target = opts.decide(node.id, tick);
        if (target === null) continue;
        const r = attack(s, node.id, target, { tick, factions: opts.factions, friendlyFire: opts.friendlyFire });
        if (!r.ok) {
          switch (r.error.code) {
            case "COMBAT.OUT_OF_RANGE":
              outOfRange++;
              break;
            case "COMBAT.COOLDOWN":
              cooldown++;
              break;
            case "COMBAT.FRIENDLY_FIRE":
              friendlyFire++;
              break;
            default:
              errors++;
              lastError = r.error.code;
              break;
          }
          continue;
        }
        hits++;
        opts.onHit?.({
          attackerId: node.id,
          targetId: target,
          before: r.value.report.before,
          after: r.value.report.after,
          applied: r.value.report.applied,
          overkill: r.value.report.overkill,
          dead: r.value.report.dead,
          tick
        });
        if (!r.value.report.dead) continue;
        kills++;
        opts.onKill?.(target, node.id, tick);
        if (destroyOnKill) {
          s.destroy(target);
          s.flush();
        }
      }
    },
    describe() {
      return `\u6218\u6597\uFF1A\u547D\u4E2D ${String(hits)} / \u51FB\u6740 ${String(kills)}`;
    }
  };
  return handle;
}

// src/extensions/combat/threat.ts
var THREAT_BAD_OPTIONS = "THREAT.BAD_OPTIONS";
var THREAT_BAD_AMOUNT = "THREAT.BAD_AMOUNT";
var ThreatTable = class {
  decayTicks;
  maxPerTarget;
  /** `目标 → (攻击者 → 记录)`。用嵌套 Map 而不是"扁平 key 字符串"：键是数字，不该被拼成字符串。 */
  table = /* @__PURE__ */ new Map();
  expired = 0;
  evicted = 0;
  constructor(options) {
    const d = options.decayTicks;
    if (!Number.isInteger(d) || d <= 0) {
      throw new RangeError(`${THREAT_BAD_OPTIONS}: decayTicks \u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF0C\u5F97\u5230 ${String(d)}`);
    }
    const m = options.maxPerTarget ?? 8;
    if (!Number.isInteger(m) || m <= 0) {
      throw new RangeError(`${THREAT_BAD_OPTIONS}: maxPerTarget \u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF0C\u5F97\u5230 ${String(m)}`);
    }
    this.decayTicks = d;
    this.maxPerTarget = m;
  }
  get decay() {
    return this.decayTicks;
  }
  /**
   * 记一笔：`attackerId` 在 `tick` 这一刻对 `targetId` 造成了 `amount` 点伤害。
   *
   * 校验顺序：数量 → 自己打自己。**都失败在"一点状态都不动"之前**。
   */
  add(targetId, attackerId, amount, tick) {
    if (!Number.isFinite(amount) || amount <= 0) {
      return { ok: false, code: THREAT_BAD_AMOUNT };
    }
    if (targetId === attackerId) {
      return { ok: false, code: THREAT_BAD_AMOUNT };
    }
    let row = this.table.get(targetId);
    if (row === void 0) {
      row = /* @__PURE__ */ new Map();
      this.table.set(targetId, row);
    }
    const prev = row.get(attackerId);
    if (prev === void 0) {
      if (row.size >= this.maxPerTarget) this.evictWeakest(row);
    }
    row.set(attackerId, { amount: (prev?.amount ?? 0) + amount, since: tick });
    return { ok: true };
  }
  /**
   * 最恨谁（`null` = 谁也不恨）。顺手剔除过期的（见文件头 ③）。
   *
   * `alive` 是**可选的过滤器**：传进来时，被它否掉的人不算 ——
   * 但**不会**因此删除记录（"暂时打不到"与"已经不恨了"是两件事）。
   */
  best(targetId, tick, alive) {
    const row = this.table.get(targetId);
    if (row === void 0) return null;
    this.sweep(targetId, row, tick);
    let bestId = null;
    let bestAmount = -1;
    for (const [attackerId, r] of row) {
      if (alive !== void 0 && !alive(attackerId)) continue;
      if (r.amount > bestAmount || r.amount === bestAmount && bestId !== null && attackerId < bestId) {
        bestAmount = r.amount;
        bestId = attackerId;
      }
    }
    return bestId;
  }
  /** 某人对某目标的仇恨值（过期即 0）。 */
  amountOf(targetId, attackerId, tick) {
    const row = this.table.get(targetId);
    if (row === void 0) return 0;
    this.sweep(targetId, row, tick);
    return row.get(attackerId)?.amount ?? 0;
  }
  /** 这个目标记了几条（自检/判据用）。 */
  sizeOf(targetId, tick) {
    const row = this.table.get(targetId);
    if (row === void 0) return 0;
    this.sweep(targetId, row, tick);
    return row.size;
  }
  /** 忘掉某个攻击者（他死了 / 离开世界了）。返回真的删掉了几条。 */
  forget(attackerId) {
    let n = 0;
    for (const [targetId, row] of [...this.table]) {
      if (row.delete(attackerId)) n++;
      if (row.size === 0) this.table.delete(targetId);
    }
    return n;
  }
  /** 只忘掉"某人对某目标"这一条。 */
  forgetOne(targetId, attackerId) {
    const row = this.table.get(targetId);
    if (row === void 0) return false;
    const had = row.delete(attackerId);
    if (row.size === 0) this.table.delete(targetId);
    return had;
  }
  stats() {
    let entries = 0;
    for (const row of this.table.values()) entries += row.size;
    return { targets: this.table.size, entries, expired: this.expired, evicted: this.evicted };
  }
  /** 剔除过期项；顺手把空的目标删掉（否则 `targets` 会只涨不跌）。 */
  sweep(targetId, row, tick) {
    for (const [attackerId, r] of [...row]) {
      if (tick - r.since >= this.decayTicks) {
        row.delete(attackerId);
        this.expired++;
      }
    }
    if (row.size === 0) this.table.delete(targetId);
  }
  /** 丢掉最不恨的那一条（平手丢 id 最大的：让结果只取决于数值与 id）。 */
  evictWeakest(row) {
    let weakId = null;
    let weakAmount = Number.POSITIVE_INFINITY;
    for (const [attackerId, r] of row) {
      if (r.amount < weakAmount || r.amount === weakAmount && weakId !== null && attackerId > weakId) {
        weakAmount = r.amount;
        weakId = attackerId;
      }
    }
    if (weakId !== null) {
      row.delete(weakId);
      this.evicted++;
    }
  }
};
function createThreatTable(options) {
  return new ThreatTable(options);
}

// src/extensions/combat/loot.ts
var LOOT_BAD_TABLE = "LOOT.BAD_TABLE";
var LOOT_NO_OWNER = "LOOT.NO_OWNER";
function isPositiveInt2(n) {
  return typeof n === "number" && Number.isInteger(n) && n > 0;
}
function normalizeLoot(table) {
  if (!Array.isArray(table)) {
    return err(engineError(LOOT_BAD_TABLE, `\u6218\u5229\u54C1\u8868\u5FC5\u987B\u662F\u6570\u7EC4\uFF0C\u6536\u5230 ${typeof table}`));
  }
  const merged = /* @__PURE__ */ new Map();
  for (let i = 0; i < table.length; i++) {
    const e = table[i];
    if (e === void 0 || typeof e !== "object") {
      return err(engineError(LOOT_BAD_TABLE, `\u7B2C ${String(i)} \u9879\u4E0D\u662F\u5BF9\u8C61`));
    }
    if (typeof e.kind !== "string" || e.kind.length === 0) {
      return err(engineError(LOOT_BAD_TABLE, `\u7B2C ${String(i)} \u9879\u7684 kind \u5FC5\u987B\u662F\u975E\u7A7A\u5B57\u7B26\u4E32\uFF0C\u6536\u5230 ${JSON.stringify(e.kind)}`));
    }
    if (!isPositiveInt2(e.count)) {
      return err(
        engineError(LOOT_BAD_TABLE, `\u7B2C ${String(i)} \u9879\u300C${e.kind}\u300D\u7684 count \u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF0C\u6536\u5230 ${String(e.count)}`)
      );
    }
    merged.set(e.kind, (merged.get(e.kind) ?? 0) + e.count);
  }
  const out = [...merged.entries()].map(([kind, count]) => ({ kind, count }));
  out.sort((x, y) => x.kind < y.kind ? -1 : x.kind > y.kind ? 1 : 0);
  return ok(out);
}
function lootTotal(table) {
  let n = 0;
  for (const e of table) n += e.count;
  return n;
}
function grantLoot(scene, ownerId, table) {
  const norm2 = normalizeLoot(table);
  if (!norm2.ok) return norm2;
  const entries = norm2.value;
  const owner = scene.find(ownerId);
  if (owner === void 0 || owner === null) {
    return err(engineError(LOOT_NO_OWNER, `\u51FB\u6740\u8005 ${String(ownerId)} \u4E0D\u5728\u573A\u666F\u91CC\uFF08\u6218\u5229\u54C1\u6CA1\u6709\u53BB\u5904\uFF09`));
  }
  if (owner.get(INVENTORY_TYPE) === void 0) {
    return err(engineError(LOOT_NO_OWNER, `\u51FB\u6740\u8005 ${String(ownerId)} \u6CA1\u6709\u80CC\u5305\u7EC4\u4EF6 \u2014\u2014 \u5148 makeInventory()`));
  }
  const granted = [];
  const lost = [];
  let stoppedAt = null;
  for (let i = 0; i < entries.length; i++) {
    const e = entries[i];
    if (stoppedAt !== null) {
      lost.push({ kind: e.kind, count: e.count, code: "LOOT.SKIPPED" });
      continue;
    }
    const r = addItem(scene, ownerId, e.kind, e.count);
    if (r.ok) {
      granted.push({ kind: e.kind, count: e.count });
      continue;
    }
    stoppedAt = e.kind;
    lost.push({ kind: e.kind, count: e.count, code: r.error.code });
  }
  return ok({
    granted,
    grantedCount: lootTotal(granted),
    lost,
    lostCount: lootTotal(lost),
    stoppedAt
  });
}

// src/extensions/mobs/mob-template.ts
var MOB_BAD_TEMPLATE = "MOB.BAD_TEMPLATE";
function bad3(field, message) {
  return err(engineError(MOB_BAD_TEMPLATE, message, { field }));
}
function isPosInt(v) {
  return typeof v === "number" && Number.isInteger(v) && v > 0;
}
function isPosFinite(v) {
  return typeof v === "number" && Number.isFinite(v) && v > 0;
}
function validateTemplate(raw) {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    return bad3("", `\u751F\u7269\u6A21\u677F\u5FC5\u987B\u662F\u5BF9\u8C61\uFF0C\u6536\u5230 ${Array.isArray(raw) ? "\u6570\u7EC4" : typeof raw}`);
  }
  const t = raw;
  if (typeof t.kind !== "string" || t.kind.length === 0) {
    return bad3("kind", `kind \u5FC5\u987B\u662F\u975E\u7A7A\u5B57\u7B26\u4E32\uFF0C\u6536\u5230 ${JSON.stringify(t.kind)}`);
  }
  if (typeof t.frame !== "string" || t.frame.length === 0) {
    return bad3("frame", `\u300C${t.kind}\u300D\u7684 frame \u5FC5\u987B\u662F\u975E\u7A7A\u5B57\u7B26\u4E32\uFF08\u7F3A\u5E27 \u21D2 \u751F\u7269\u80FD\u8D70\u4F46\u770B\u4E0D\u89C1\uFF09`);
  }
  if (!isPosFinite(t.width)) return bad3("width", `\u300C${t.kind}\u300D\u7684 width \u5FC5\u987B\u662F > 0 \u7684\u6709\u9650\u6570\uFF0C\u6536\u5230 ${String(t.width)}`);
  if (!isPosFinite(t.height)) {
    return bad3("height", `\u300C${t.kind}\u300D\u7684 height \u5FC5\u987B\u662F > 0 \u7684\u6709\u9650\u6570\uFF0C\u6536\u5230 ${String(t.height)}`);
  }
  if (!isPosFinite(t.radius)) return bad3("radius", `\u300C${t.kind}\u300D\u7684 radius \u5FC5\u987B\u662F > 0 \u7684\u6709\u9650\u6570\uFF0C\u6536\u5230 ${String(t.radius)}`);
  if (!isPosInt(t.maxHp)) return bad3("maxHp", `\u300C${t.kind}\u300D\u7684 maxHp \u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF0C\u6536\u5230 ${String(t.maxHp)}`);
  if (typeof t.damage !== "number" || !Number.isInteger(t.damage) || t.damage < 0) {
    return bad3("damage", `\u300C${t.kind}\u300D\u7684 damage \u5FC5\u987B\u662F >= 0 \u7684\u6574\u6570\uFF080 = \u548C\u5E73\u751F\u7269\uFF09\uFF0C\u6536\u5230 ${String(t.damage)}`);
  }
  if (!isPosFinite(t.range)) return bad3("range", `\u300C${t.kind}\u300D\u7684 range \u5FC5\u987B\u662F > 0 \u7684\u6709\u9650\u6570\uFF0C\u6536\u5230 ${String(t.range)}`);
  if (typeof t.cooldownTicks !== "number" || !Number.isInteger(t.cooldownTicks) || t.cooldownTicks < 0) {
    return bad3("cooldownTicks", `\u300C${t.kind}\u300D\u7684 cooldownTicks \u5FC5\u987B\u662F >= 0 \u7684\u6574\u6570\uFF0C\u6536\u5230 ${String(t.cooldownTicks)}`);
  }
  if (!isPosFinite(t.speed)) return bad3("speed", `\u300C${t.kind}\u300D\u7684 speed \u5FC5\u987B\u662F > 0 \u7684\u6709\u9650\u6570\uFF0C\u6536\u5230 ${String(t.speed)}`);
  if (typeof t.team !== "string") return bad3("team", `\u300C${t.kind}\u300D\u7684 team \u5FC5\u987B\u662F\u5B57\u7B26\u4E32\uFF0C\u6536\u5230 ${typeof t.team}`);
  if (t.team.length > 0 && t.team.trim().length === 0) {
    return bad3("team", `\u300C${t.kind}\u300D\u7684 team \u662F\u7EAF\u7A7A\u767D \u2014\u2014 \u7A7A\u4E32\u8868\u793A\u4E2D\u7ACB\uFF0C\u7EAF\u7A7A\u767D\u662F\u4E00\u4E2A\u770B\u4E0D\u89C1\u7684\u9635\u8425\u540D`);
  }
  const loot = normalizeLoot(t.loot ?? []);
  if (!loot.ok) return bad3("loot", `\u300C${t.kind}\u300D\u7684\u6218\u5229\u54C1\u8868\u4E0D\u5408\u6CD5\uFF1A${loot.error.message}`);
  return ok({
    kind: t.kind,
    frame: t.frame,
    width: t.width,
    height: t.height,
    radius: t.radius,
    maxHp: t.maxHp,
    damage: t.damage,
    range: t.range,
    cooldownTicks: t.cooldownTicks,
    speed: t.speed,
    team: t.team,
    loot: loot.value
  });
}

// src/extensions/mobs/spawn-mob.ts
var MOB_SPAWN_FAILED = "MOB.SPAWN_FAILED";
function spawnMob(scene, template, x, z, opts = {}) {
  const tplR = validateTemplate(template);
  if (!tplR.ok) return tplR;
  const tpl = tplR.value;
  const name = opts.name ?? tpl.kind;
  const spawned = scene.spawnAt(name, x, z);
  if (!spawned.ok) return spawned;
  const nodeId = spawned.value.id;
  const sprite = makeSprite(tpl.frame, tpl.width, tpl.height);
  sprite.pivotY = opts.pivotY ?? 0;
  const health = new Health();
  health.hp = tpl.maxHp;
  health.maxHp = tpl.maxHp;
  const attacker = new Attacker();
  attacker.damage = tpl.damage;
  attacker.range = tpl.range;
  attacker.cooldownTicks = tpl.cooldownTicks;
  const mover = new Mover();
  mover.speed = tpl.speed;
  const faction = new FactionMember();
  faction.team = tpl.team;
  const attached = [
    [SPRITE_TYPE, sprite],
    [HEALTH_TYPE, health],
    [MOVER_TYPE, mover],
    [FACTION_TYPE, faction]
  ];
  if (tpl.damage > 0) attached.push([ATTACKER_TYPE, attacker]);
  for (const [type, c] of attached) {
    const a = scene.attach(nodeId, () => c);
    if (!a.ok) {
      scene.destroy(nodeId);
      scene.flush();
      return err(
        engineError(MOB_SPAWN_FAILED, `\u300C${tpl.kind}\u300D\u9700\u8981 ${type}\uFF0C\u4F46\u5B83\u6CA1\u6CE8\u518C\uFF1A${a.error.message}`, {
          nodeId,
          type,
          cause: a.error.code
        })
      );
    }
  }
  scene.flush();
  const back = scene.find(nodeId);
  if (back === void 0) {
    return err(engineError(MOB_SPAWN_FAILED, `\u300C${tpl.kind}\u300D\u7684\u8282\u70B9 ${String(nodeId)} \u5EFA\u5B8C\u5C31\u627E\u4E0D\u5230\u4E86`));
  }
  for (const [type] of attached) {
    if (back.get(type) === void 0) {
      scene.destroy(nodeId);
      scene.flush();
      return err(
        engineError(MOB_SPAWN_FAILED, `\u300C${tpl.kind}\u300D\u7684 ${type} \u6302\u4E0A\u4E4B\u540E\u8BFB\u4E0D\u5230\uFF08\u7C7B\u578B\u540D\u4E0E\u6CE8\u518C\u540D\u4E0D\u4E00\u81F4\uFF1F\uFF09`, {
          nodeId,
          type
        })
      );
    }
  }
  return ok({ nodeId, template: tpl, sprite, health, attacker: tpl.damage > 0 ? attacker : null, mover });
}

// src/extensions/ai/perception.ts
var AI_NO_SELF = "AI.NO_SELF";
var AI_BAD_SENSE = "AI.BAD_SENSE";
var DEG = Math.PI / 180;
function byDistance(a, b) {
  if (a.dist2 !== b.dist2) return a.dist2 - b.dist2;
  return a.nodeId - b.nodeId;
}
var Perception = class {
  cfg;
  memory = /* @__PURE__ */ new Map();
  /** 上一轮真的看见的节点 id 集合（`stale` 判定用它，不用再扫一遍场景）。 */
  visibleNow = /* @__PURE__ */ new Set();
  constructor(config) {
    if (!(config.range > 0) || !Number.isFinite(config.range)) {
      throw new RangeError(`\u611F\u77E5\u534A\u5F84\u5FC5\u987B\u662F > 0 \u7684\u6709\u9650\u6570\uFF0C\u5F97\u5230 ${String(config.range)}`);
    }
    if (config.watch.length === 0) {
      throw new RangeError("watch \u4E0D\u80FD\u4E3A\u7A7A \u2014\u2014 \u4E00\u4E2A\u4EC0\u4E48\u90FD\u770B\u4E0D\u89C1\u7684\u611F\u77E5\u5668\u548C\u6CA1\u6709\u611F\u77E5\u662F\u4E00\u56DE\u4E8B");
    }
    if (config.halfAngleDeg !== void 0 && !(config.halfAngleDeg > 0 && config.halfAngleDeg <= 180)) {
      throw new RangeError(`halfAngleDeg \u5FC5\u987B\u5728 (0, 180] \u5185\uFF0C\u5F97\u5230 ${String(config.halfAngleDeg)}`);
    }
    if (config.memoryTicks !== void 0 && (!Number.isInteger(config.memoryTicks) || config.memoryTicks < 0)) {
      throw new RangeError(`memoryTicks \u5FC5\u987B\u662F >= 0 \u7684\u6574\u6570\uFF0C\u5F97\u5230 ${String(config.memoryTicks)}`);
    }
    this.cfg = {
      range: config.range,
      watch: [...config.watch],
      memoryTicks: config.memoryTicks ?? 0,
      halfAngleDeg: config.halfAngleDeg
    };
  }
  /** 当前记忆条数（判据用它证"会忘"，也用来兜"记忆无限增长"）。 */
  memorySize() {
    return this.memory.size;
  }
  forgetAll() {
    this.memory.clear();
    this.visibleNow.clear();
  }
  /**
   * 感知一次。
   *
   * @param facingRad 朝向（弧度）。给了 `halfAngleDeg` 就必须给朝向 ——
   *                  否则"前方"没有定义，只能报错，不能默默当全向。
   */
  sense(scene, selfId, tick, facingRad) {
    const self2 = scene.find(selfId);
    if (self2 === void 0) {
      return err(engineError(AI_NO_SELF, `\u611F\u77E5\u8005 ${String(selfId)} \u4E0D\u5728\u573A\u666F\u91CC`));
    }
    if (this.cfg.halfAngleDeg !== void 0 && (facingRad === void 0 || !Number.isFinite(facingRad))) {
      return err(
        engineError(AI_BAD_SENSE, "\u914D\u7F6E\u4E86\u89C6\u91CE\u534A\u89D2\uFF0C\u4F46\u6CA1\u7ED9\u671D\u5411 \u2014\u2014 \u300C\u524D\u65B9\u300D\u6CA1\u6709\u5B9A\u4E49\uFF0C\u4E0D\u80FD\u5F53\u5168\u5411\u5904\u7406", {
          selfId
        })
      );
    }
    const range2 = this.cfg.range * this.cfg.range;
    const halfDeg = this.cfg.halfAngleDeg;
    const sp = self2.worldPosition;
    const visibleNow = /* @__PURE__ */ new Set();
    const out = [];
    scene.root.walk((n) => {
      if (n.id === selfId) return;
      let type;
      for (const t of this.cfg.watch) {
        if (n.get(t) !== void 0) {
          type = t;
          break;
        }
      }
      if (type === void 0) return;
      const p = n.worldPosition;
      const dx = p.x - sp.x;
      const dz = p.y - sp.y;
      const d2 = dx * dx + dz * dz;
      if (d2 > range2) return;
      if (halfDeg !== void 0) {
        const angDeg = (Math.atan2(dz, dx) / DEG + 360) % 360;
        const faceDeg = (facingRad / DEG % 360 + 360) % 360;
        let diff = Math.abs(angDeg - faceDeg);
        if (diff > 180) diff = 360 - diff;
        if (diff > halfDeg) return;
      }
      visibleNow.add(n.id);
      out.push({ nodeId: n.id, type, x: p.x, z: p.y, dist2: d2, seenTick: tick, stale: false });
    });
    if (this.cfg.memoryTicks > 0) {
      for (const s of out) this.memory.set(s.nodeId, { x: s.x, z: s.z, type: s.type, seenTick: tick });
      for (const [id, m] of [...this.memory]) {
        if (visibleNow.has(id)) continue;
        if (tick - m.seenTick > this.cfg.memoryTicks) this.memory.delete(id);
      }
      for (const [id, m] of this.memory) {
        if (visibleNow.has(id)) continue;
        const p = scene.find(id)?.worldPosition;
        const x = p?.x ?? m.x;
        const z = p?.y ?? m.z;
        const dx = x - sp.x;
        const dz = z - sp.y;
        out.push({ nodeId: id, type: m.type, x, z, dist2: dx * dx + dz * dz, seenTick: m.seenTick, stale: true });
      }
    } else {
      this.memory.clear();
    }
    this.visibleNow = visibleNow;
    out.sort(byDistance);
    return ok(out);
  }
  /** 这一轮真的看见的节点 id（升序）。判据用它区分"看见"与"记得"。 */
  visibleIds() {
    return [...this.visibleNow].sort((a, b) => a - b);
  }
};

// src/extensions/mobs/mob-brain.ts
var MOB_BAD_BRAIN = "MOB.BAD_BRAIN";
function mix322(a, b, c) {
  let h = (a ^ 2654435769) >>> 0;
  h = Math.imul(h ^ b + 2246822507, 3432918353) >>> 0 ^ h >>> 13;
  h = Math.imul(h ^ c + 3266489909, 461845907) >>> 0 ^ h >>> 15;
  return h >>> 0;
}
var MobBrain = class {
  o;
  perception;
  /**
   * 见文件头 ④。**按 `id → 决定` 存一整张表**，不是只存"上一次"：
   * `move` 与 `combat` 是两个模块，它们各自遍历全部生物 ——
   * 只记最后一条的话，第二次遍历的第一只就已经把缓存冲掉了
   *（于是"缓存"实际只对同一只生物连续问两次才生效，而这几乎不发生）。
   */
  cacheTick = Number.NaN;
  cache = /* @__PURE__ */ new Map();
  senses = 0;
  constructor(options) {
    if (!(options.range > 0) || !Number.isFinite(options.range)) {
      throw new RangeError(`${MOB_BAD_BRAIN}: \u611F\u77E5\u534A\u5F84\u5FC5\u987B\u662F > 0 \u7684\u6709\u9650\u6570\uFF0C\u5F97\u5230 ${String(options.range)}`);
    }
    const wr = options.wanderRadiusCells ?? 4;
    if (!Number.isInteger(wr) || wr <= 0) {
      throw new RangeError(`${MOB_BAD_BRAIN}: wanderRadiusCells \u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF0C\u5F97\u5230 ${String(wr)}`);
    }
    const we = options.wanderEvery ?? 24;
    if (!Number.isInteger(we) || we <= 0) {
      throw new RangeError(`${MOB_BAD_BRAIN}: wanderEvery \u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF0C\u5F97\u5230 ${String(we)}`);
    }
    const leash = options.leashCells ?? 0;
    if (!Number.isInteger(leash) || leash < 0) {
      throw new RangeError(`${MOB_BAD_BRAIN}: leashCells \u5FC5\u987B\u662F >= 0 \u7684\u6574\u6570\uFF0C\u5F97\u5230 ${String(leash)}`);
    }
    const aggro = options.aggroCells ?? leash;
    if (!Number.isInteger(aggro) || aggro < 0) {
      throw new RangeError(`${MOB_BAD_BRAIN}: aggroCells \u5FC5\u987B\u662F >= 0 \u7684\u6574\u6570\uFF0C\u5F97\u5230 ${String(aggro)}`);
    }
    this.o = {
      factions: options.factions,
      range: options.range,
      wanderRadiusCells: wr,
      wanderEvery: we,
      leashCells: leash,
      aggroCells: aggro,
      threat: options.threat ?? null,
      watch: options.watch ?? [HEALTH_TYPE],
      seed: options.seed ?? 1
    };
    this.perception = new Perception({ range: this.o.range, watch: this.o.watch });
  }
  /** 感知调用次数（判据用它证"同一 tick 只算一次"）。 */
  get senseCount() {
    return this.senses;
  }
  /**
   * 决定这一 tick 干什么。
   *
   * @returns `null` = 什么都不用做（找不到自己 / 没有可走的漫游格）。
   */
  decide(scene, agentId, tick, grid) {
    if (this.cacheTick !== tick) {
      this.cacheTick = tick;
      this.cache.clear();
    }
    const hit = this.cache.get(agentId);
    if (hit !== void 0 || this.cache.has(agentId)) return hit ?? null;
    const self2 = scene.find(agentId);
    if (self2 === void 0) {
      this.remember(agentId, tick, null);
      return null;
    }
    const homeCell = grid.cellAt(self2.worldPosition.x, self2.worldPosition.y);
    const me = teamOf(scene, agentId).team;
    if (self2.get(ATTACKER_TYPE) !== void 0) {
      const grudge = this.avenge(scene, agentId, tick, grid, me);
      if (grudge !== null) {
        this.remember(agentId, tick, grudge);
        return grudge;
      }
      this.senses++;
      const sensed = this.perception.sense(scene, agentId, tick);
      if (sensed.ok) {
        for (const s of sensed.value) {
          const other = teamOf(scene, s.nodeId).team;
          if (this.o.factions.stanceOf(me, other) === "ally") continue;
          if (this.o.leashCells > 0 && s.dist2 > this.o.leashCells * this.o.leashCells) continue;
          const cell2 = grid.cellAt(s.x, s.z);
          if (cell2 < 0) continue;
          const d2 = { kind: "hunt", targetNodeId: s.nodeId, cell: cell2 };
          this.remember(agentId, tick, d2);
          return d2;
        }
      }
    }
    const cell = this.wanderCell(grid, agentId, tick, homeCell);
    const d = cell < 0 ? null : { kind: "wander", targetNodeId: -1, cell };
    this.remember(agentId, tick, d);
    return d;
  }
  /**
   * 从仇恨表里挑出"要追的那个人"（`null` = 没有人打过我 / 都忘了 / 都够不着）。
   *
   * ★ 三个过滤都必须有：
   *   · 已经没有血量组件（被销毁/从没活过）→ 不追。否则会朝一个不存在的 id 走一辈子；
   *   · 已经死了但节点还在（`hp === 0`）→ 不追。否则尸体会把一群生物钉在原地；
   *   · 友军 → 不追。否则"打错人"会让整队人内讧（批65 的阵营就白做了）。
   * ★ 距离用**格**（与 leash 同一套坐标），不是世界单位：
   *   记仇的追击半径是"跑出几个格子就放弃"，那是地图概念。
   */
  avenge(scene, agentId, tick, grid, me) {
    const t = this.o.threat;
    if (t === null) return null;
    const targetId = t.best(agentId, tick, (id) => {
      const n = scene.find(id);
      if (n === void 0 || n === null || !n.activeInHierarchy) return false;
      const hp = n.get(HEALTH_TYPE);
      if (hp === void 0 || isDead(hp)) return false;
      return this.o.factions.stanceOf(me, teamOf(scene, id).team) !== "ally";
    });
    if (targetId === null) return null;
    const target = scene.find(targetId);
    if (target === void 0 || target === null) return null;
    const cell = grid.cellAt(target.worldPosition.x, target.worldPosition.y);
    if (cell < 0) return null;
    if (this.o.aggroCells > 0) {
      const self2 = scene.find(agentId);
      if (self2 === void 0) return null;
      const dx = target.worldPosition.x - self2.worldPosition.x;
      const dz = target.worldPosition.y - self2.worldPosition.y;
      if (dx * dx + dz * dz > this.o.aggroCells * this.o.aggroCells) return null;
    }
    return { kind: "hunt", targetNodeId: targetId, cell };
  }
  /**
   * 漫游目标格（见文件头 ②：纯函数）。
   *
   * ★ 取**第一个可走**的候选而不是"取最近的/最远的"：后者会让所有生物
   *   挤向同一片空地（同一个 epoch 的候选序是同一个函数），画面上像一队人。
   */
  wanderCell(grid, agentId, tick, homeCell) {
    if (homeCell < 0) return -1;
    const cx = grid.cellX(homeCell);
    const cz = grid.cellZ(homeCell);
    const r = this.o.wanderRadiusCells;
    const epoch = Math.floor(tick / this.o.wanderEvery);
    let h = mix322(this.o.seed, agentId, epoch);
    for (let k = 0; k < 6; k++) {
      h = Math.imul(h, 1664525) + 1013904223 >>> 0;
      const span = 2 * r + 1;
      const dx = h % span - r;
      const dz = Math.floor(h / span) % span - r;
      if (dx === 0 && dz === 0) continue;
      if (grid.isWalkable(cx + dx, cz + dz)) return this.cellIndex(grid, cx + dx, cz + dz);
    }
    return -1;
  }
  /** 用 `cellAt` 反查下标（避免再引入一个 `indexOf` 依赖）。 */
  cellIndex(grid, cx, cz) {
    return grid.cellAt(cx + 0.5, cz + 0.5);
  }
  remember(agentId, tick, d) {
    if (this.cacheTick !== tick) {
      this.cacheTick = tick;
      this.cache.clear();
    }
    this.cache.set(agentId, d);
  }
};
function createMobBrain(options) {
  return new MobBrain(options);
}

// src/extensions/mobs/mob-world.ts
var MOB_WORLD_BAD_MODULE = "MOB_WORLD.BAD_MODULE";
function createMobWorldModule(options) {
  let scene = null;
  let brain = null;
  let threat = null;
  let moveMod = null;
  let combatMod = null;
  const lootOf = /* @__PURE__ */ new Map();
  const kindOf2 = /* @__PURE__ */ new Map();
  let ids = [];
  let mobs = 0;
  let hunting = 0;
  let wandering = 0;
  let idle = 0;
  let lootGranted = 0;
  let lootLost = 0;
  let lootNoRecipient = 0;
  let lastLootError = "";
  function prune() {
    const s = scene;
    if (s === null || ids.length === 0) {
      mobs = 0;
      return;
    }
    const alive = ids.filter((id) => s.find(id) !== void 0);
    if (alive.length !== ids.length) ids = alive;
    mobs = ids.length;
  }
  const handle = {
    id: options.id ?? "world.mobs",
    get stats() {
      return {
        mobs,
        hunting,
        wandering,
        idle,
        kills: combatMod?.stats.kills ?? 0,
        lootGranted,
        lootLost,
        lootNoRecipient,
        threatTargets: threat?.stats().targets ?? 0,
        threatEntries: threat?.stats().entries ?? 0,
        lastLootError
      };
    },
    get nodeIds() {
      return [...ids].sort((a, b) => a - b);
    },
    templateOf(nodeId) {
      return kindOf2.get(nodeId) ?? null;
    },
    noteHit(info) {
      if (threat === null) return false;
      return threat.add(info.targetId, info.attackerId, info.applied, info.tick).ok;
    },
    init(ctx) {
      const got = ctx.services.get(Services.Scene);
      if (got === void 0) {
        return err(engineError(MOB_WORLD_BAD_MODULE, "\u751F\u7269\u7FA4\u9700\u8981\u4E00\u4E2A Scene\uFF08\u5148\u6CE8\u518C Services.Scene\uFF09"));
      }
      scene = got;
      const grid = options.grid;
      const decay = options.threatDecayTicks ?? 150;
      if (!Number.isInteger(decay) || decay < 0) {
        return err(engineError(MOB_WORLD_BAD_MODULE, `threatDecayTicks \u5FC5\u987B\u662F >= 0 \u7684\u6574\u6570\uFF0C\u6536\u5230 ${String(decay)}`));
      }
      threat = decay === 0 ? null : createThreatTable({ decayTicks: decay });
      brain = createMobBrain({
        factions: options.factions,
        range: options.range,
        ...options.seed === void 0 ? {} : { seed: options.seed },
        ...options.wanderEvery === void 0 ? {} : { wanderEvery: options.wanderEvery },
        ...options.leashCells === void 0 ? {} : { leashCells: options.leashCells },
        ...options.aggroCells === void 0 ? {} : { aggroCells: options.aggroCells },
        ...threat === null ? {} : { threat }
      });
      const placed = [];
      for (let i = 0; i < options.spots.length; i++) {
        const spot = options.spots[i];
        const tpl = options.templates[spot.template];
        if (tpl === void 0) {
          return err(
            engineError(MOB_WORLD_BAD_MODULE, `\u7B2C ${String(i)} \u4E2A\u51FA\u751F\u70B9\u5F15\u7528\u4E86\u4E0D\u5B58\u5728\u7684\u6A21\u677F ${String(spot.template)}`, {
              index: i,
              template: spot.template
            })
          );
        }
        const c = grid.centerOf(spot.cell);
        const r = spawnMob(got, tpl, c.x, c.z, { name: `mob#${String(i)}` });
        if (!r.ok) return r;
        placed.push(r.value);
      }
      for (const m of placed) {
        ids.push(m.nodeId);
        lootOf.set(m.nodeId, m.template.loot);
        kindOf2.set(m.nodeId, m.template.kind);
      }
      mobs = ids.length;
      const b = brain;
      moveMod = createMoveModule({
        grid,
        decide: (agentId, tick) => b.decide(got, agentId, tick, grid)?.cell ?? null,
        id: "world.mobs.move"
      });
      combatMod = createCombatModule({
        // 表现层的输入：原样转发（见 `MobWorldOptions.onHit`）
        onHit: (info) => {
          threat?.add(info.targetId, info.attackerId, info.applied, info.tick);
          options.onHit?.(info);
        },
        decide: (agentId, tick) => {
          const d = b.decide(got, agentId, tick, grid);
          return d !== null && d.kind === "hunt" ? d.targetNodeId : null;
        },
        factions: options.factions,
        id: "world.mobs.combat",
        // ---- ③ 战利品：发给击杀者（见文件头 ②）
        onKill: (targetId, killerId) => {
          if (threat !== null) {
            threat.forgetOne(targetId, killerId);
            threat.forget(targetId);
          }
          const loot = lootOf.get(targetId);
          if (loot === void 0 || loot.length === 0) return;
          const g = grantLoot(got, killerId, loot);
          if (!g.ok) {
            lootNoRecipient++;
            lastLootError = g.error.code;
            return;
          }
          lootGranted += g.value.grantedCount;
          if (g.value.lostCount > 0) {
            lootLost += g.value.lostCount;
            lastLootError = g.value.stoppedAt === null ? "" : `INVENTORY.FULL@${g.value.stoppedAt}`;
          }
        }
      });
      const im = moveMod.init(ctx);
      if (im !== void 0 && !im.ok) return err(engineError(MOB_WORLD_BAD_MODULE, "\u79FB\u52A8\u5B50\u6A21\u5757\u521D\u59CB\u5316\u5931\u8D25"));
      const ic = combatMod.init(ctx);
      if (ic !== void 0 && !ic.ok) return err(engineError(MOB_WORLD_BAD_MODULE, "\u6218\u6597\u5B50\u6A21\u5757\u521D\u59CB\u5316\u5931\u8D25"));
      return ok(void 0);
    },
    update(tick, dt) {
      const s = scene;
      const b = brain;
      if (s === null || b === null || moveMod === null || combatMod === null) return;
      let h = 0;
      let w = 0;
      let i0 = 0;
      for (const id of ids) {
        const d = b.decide(s, id, tick, options.grid);
        if (d === null) i0++;
        else if (d.kind === "hunt") h++;
        else w++;
      }
      hunting = h;
      wandering = w;
      idle = i0;
      moveMod.update(tick, dt);
      combatMod.update(tick, dt);
      prune();
    },
    stop() {
      moveMod?.stop?.();
      combatMod?.stop?.();
    },
    describe() {
      return `\u751F\u7269\uFF1A${String(mobs)} \u53EA\uFF08\u8FFD ${String(hunting)} / \u6E38 ${String(wandering)}\uFF09\uFF0C\u51FB\u6740 ${String(
        combatMod?.stats.kills ?? 0
      )}`;
    }
  };
  return handle;
}

// src/extensions/render/feedback.ts
var FEEDBACK_TYPE = "render.feedback";
var FX_NO_NODE = "FX.NO_NODE";
var FX_NO_SPRITE = "FX.NO_SPRITE";
var FX_BAD_TICKS = "FX.BAD_TICKS";
var FX_BAD_MODULE = "FX.BAD_MODULE";
var FLASH_R = 1;
var FLASH_G = 0.35;
var FLASH_B = 0.4;
var PUNCH_W = 1.3;
var PUNCH_H = 0.72;
var Feedback = class extends Component {
  /** 还剩几 tick 闪（0 = 没在闪，见文件头 ②③）。 */
  flashTicks = 0;
  /** 这一段闪的总时长（诊断用，不参与判定）。 */
  flashTotal = 0;
  /** 受击**之前**的颜色（见文件头 ①②）。 */
  baseR = 1;
  baseG = 1;
  baseB = 1;
  baseA = 1;
  /** 还剩几 tick 挤压。 */
  punchTicks = 0;
  punchTotal = 0;
  /** 挤压**之前**的尺寸。 */
  baseW = 1;
  baseH = 1;
  schema = {
    type: FEEDBACK_TYPE,
    fields: {
      flashTicks: FieldType.Int,
      flashTotal: FieldType.Int,
      baseR: FieldType.Float,
      baseG: FieldType.Float,
      baseB: FieldType.Float,
      baseA: FieldType.Float,
      punchTicks: FieldType.Int,
      punchTotal: FieldType.Int,
      baseW: FieldType.Float,
      baseH: FieldType.Float
    }
  };
};
function registerFeedbackComponent(registry) {
  if (!registry.has(FEEDBACK_TYPE)) registry.register(new Feedback().schema, () => new Feedback());
}
function ensure(scene, nodeId) {
  const node = scene.find(nodeId);
  if (node === void 0 || node === null) {
    return engineError(FX_NO_NODE, `\u8282\u70B9 ${String(nodeId)} \u4E0D\u5728\u573A\u666F\u91CC`);
  }
  const existing = node.get(FEEDBACK_TYPE);
  if (existing !== void 0) return existing;
  const made = scene.attach(nodeId, () => new Feedback());
  if (!made.ok) return made.error;
  scene.flush();
  const got = node.get(FEEDBACK_TYPE);
  if (got === void 0) {
    return engineError(FEEDBACK_TYPE + ".ATTACH_LOST", `\u53CD\u9988\u7EC4\u4EF6\u6302\u4E0A\u4E4B\u540E\u53C8\u8BFB\u4E0D\u5230\uFF08\u8282\u70B9 ${String(nodeId)}\uFF09`);
  }
  return got;
}
function spriteOf(scene, nodeId) {
  const node = scene.find(nodeId);
  if (node === void 0 || node === null) {
    return engineError(FX_NO_NODE, `\u8282\u70B9 ${String(nodeId)} \u4E0D\u5728\u573A\u666F\u91CC`);
  }
  const sp = node.get(SPRITE_TYPE);
  if (sp === void 0) {
    return engineError(FX_NO_SPRITE, `\u8282\u70B9 ${String(nodeId)} \u6CA1\u6709 ${SPRITE_TYPE}\uFF08\u95EA\u4E00\u4E2A\u770B\u4E0D\u89C1\u7684\u4E1C\u897F\u6CA1\u6709\u610F\u4E49\uFF09`);
  }
  return sp;
}
function positiveTicks(ticks) {
  if (!Number.isInteger(ticks) || ticks <= 0) {
    return engineError(
      FX_BAD_TICKS,
      `\u65F6\u957F\u5FC5\u987B\u662F\u6B63\u6574\u6570 tick\uFF0C\u6536\u5230 ${String(ticks)}\uFF080 \u60F3\u8868\u8FBE"\u53D6\u6D88"\u7684\u8BDD\u8BF7\u7528 clear()\uFF09`
    );
  }
  return null;
}
function flash(scene, nodeId, ticks) {
  const bad4 = positiveTicks(ticks);
  if (bad4 !== null) return err(bad4);
  const sp = spriteOf(scene, nodeId);
  if ("code" in sp) return err(sp);
  const sprite = sp;
  const fb = ensure(scene, nodeId);
  if ("code" in fb) return err(fb);
  const feed2 = fb;
  const extended = feed2.flashTicks > 0;
  if (!extended) {
    feed2.baseR = sprite.r;
    feed2.baseG = sprite.g;
    feed2.baseB = sprite.b;
    feed2.baseA = sprite.a;
    feed2.flashTotal = ticks;
  } else if (ticks > feed2.flashTotal) {
    feed2.flashTotal = ticks;
  }
  feed2.flashTicks = Math.max(feed2.flashTicks, ticks);
  sprite.r = FLASH_R;
  sprite.g = FLASH_G;
  sprite.b = FLASH_B;
  return ok({ nodeId, ticks, remaining: feed2.flashTicks, extended });
}
function punch(scene, nodeId, ticks) {
  const bad4 = positiveTicks(ticks);
  if (bad4 !== null) return err(bad4);
  const sp = spriteOf(scene, nodeId);
  if ("code" in sp) return err(sp);
  const sprite = sp;
  const fb = ensure(scene, nodeId);
  if ("code" in fb) return err(fb);
  const feed2 = fb;
  const extended = feed2.punchTicks > 0;
  if (!extended) {
    feed2.baseW = sprite.width;
    feed2.baseH = sprite.height;
    feed2.punchTotal = ticks;
  } else if (ticks > feed2.punchTotal) {
    feed2.punchTotal = ticks;
  }
  feed2.punchTicks = Math.max(feed2.punchTicks, ticks);
  sprite.width = feed2.baseW * PUNCH_W;
  sprite.height = feed2.baseH * PUNCH_H;
  return ok({ nodeId, ticks, remaining: feed2.punchTicks, extended });
}
function restoreTint(scene, nodeId) {
  const node = scene.find(nodeId);
  if (node === void 0 || node === null) return false;
  const feed2 = node.get(FEEDBACK_TYPE);
  if (feed2 === void 0 || feed2.flashTicks > 0) return false;
  const sprite = node.get(SPRITE_TYPE);
  if (sprite === void 0) return false;
  if (sprite.r !== FLASH_R || sprite.g !== FLASH_G || sprite.b !== FLASH_B) return false;
  sprite.r = feed2.baseR;
  sprite.g = feed2.baseG;
  sprite.b = feed2.baseB;
  sprite.a = feed2.baseA;
  return true;
}
function restoreSize(scene, nodeId) {
  const node = scene.find(nodeId);
  if (node === void 0 || node === null) return false;
  const feed2 = node.get(FEEDBACK_TYPE);
  if (feed2 === void 0 || feed2.punchTicks > 0) return false;
  const sprite = node.get(SPRITE_TYPE);
  if (sprite === void 0) return false;
  if (sprite.width !== feed2.baseW * PUNCH_W || sprite.height !== feed2.baseH * PUNCH_H) return false;
  sprite.width = feed2.baseW;
  sprite.height = feed2.baseH;
  return true;
}
function createFeedbackModule(options = {}) {
  let scene = null;
  let flashing = 0;
  let punching = 0;
  let restored = 0;
  let orphaned = 0;
  let overridden = 0;
  const handle = {
    id: options.id ?? "render.feedback",
    deps: [],
    get stats() {
      return { flashing, punching, restored, orphaned, overridden };
    },
    init(ctx) {
      const got = ctx.services.get(Services.Scene);
      if (got === void 0) {
        return err(engineError(FX_BAD_MODULE, "\u53CD\u9988\u6A21\u5757\u9700\u8981\u4E00\u4E2A Scene\uFF08\u5148\u6CE8\u518C Services.Scene\uFF09"));
      }
      scene = got;
      return ok(void 0);
    },
    stop() {
    },
    describe() {
      return `\u53CD\u9988\uFF1A\u95EA ${String(flashing)} / \u6324 ${String(punching)} / \u8FD8\u539F ${String(restored)}`;
    },
    update() {
      const s = scene;
      if (s === null) return;
      flashing = 0;
      punching = 0;
      const list = [...s.componentsOf(FEEDBACK_TYPE)].sort(
        (a, b) => (a.node?.id ?? -1) - (b.node?.id ?? -1)
      );
      for (const fb of list) {
        const node = fb.node;
        if (node === null) continue;
        if (fb.flashTicks > 0) {
          fb.flashTicks--;
          if (fb.flashTicks === 0) {
            if (node.get(SPRITE_TYPE) === void 0) orphaned++;
            else if (restoreTint(s, node.id)) restored++;
            else overridden++;
          } else {
            flashing++;
          }
        }
        if (fb.punchTicks > 0) {
          fb.punchTicks--;
          if (fb.punchTicks === 0) {
            if (node.get(SPRITE_TYPE) === void 0) orphaned++;
            else if (restoreSize(s, node.id)) restored++;
            else overridden++;
          } else {
            punching++;
          }
        }
      }
    }
  };
  return handle;
}

// src/extensions/survival/hunger.ts
var HUNGER_TYPE = "game.hunger";
var HUNGER_NO_OWNER = "HUNGER.NO_OWNER";
var HUNGER_NO_COMPONENT = "HUNGER.NO_COMPONENT";
var HUNGER_BAD_AMOUNT = "HUNGER.BAD_AMOUNT";
var Hunger = class extends Component {
  /** 当前饱食度（整数，>= 0）。0 = 饿着（见文件头 ②）。 */
  value = 100;
  /** 上限（整数，> 0）。 */
  max = 100;
  schema = {
    type: HUNGER_TYPE,
    fields: { value: FieldType.Int, max: FieldType.Int }
  };
};
function registerHungerComponent(registry) {
  if (!registry.has(HUNGER_TYPE)) registry.register(new Hunger().schema, () => new Hunger());
}
function isStarving(h) {
  return h.value <= 0;
}
function feed(scene, ownerId, nutrition) {
  if (!Number.isInteger(nutrition) || nutrition <= 0) {
    return err(
      engineError(HUNGER_BAD_AMOUNT, `\u8425\u517B\u503C\u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF0C\u6536\u5230 ${String(nutrition)}\uFF08\u5C0F\u6570\u4F1A\u8BA9"\u997F\u4E86\u6CA1\u6709"\u53D6\u51B3\u4E8E\u7D2F\u52A0\u6B21\u5E8F\uFF09`)
    );
  }
  const node = scene.find(ownerId);
  if (node === void 0 || node === null) {
    return err(engineError(HUNGER_NO_OWNER, `\u8282\u70B9 ${String(ownerId)} \u4E0D\u5728\u573A\u666F\u91CC`));
  }
  const h = node.get(HUNGER_TYPE);
  if (h === void 0) {
    return err(
      engineError(HUNGER_NO_COMPONENT, `\u8282\u70B9 ${String(ownerId)} \u6CA1\u6709 ${HUNGER_TYPE}\uFF08\u5148 attach \u4E00\u4E2A Hunger\uFF09`)
    );
  }
  const before = h.value;
  const after = Math.min(h.max, before + nutrition);
  h.value = after;
  return ok({
    nodeId: ownerId,
    before,
    after,
    applied: after - before,
    wasted: nutrition - (after - before)
  });
}

// src/extensions/survival/food.ts
var FOOD_BAD_TABLE = "FOOD.BAD_TABLE";
var FOOD_UNKNOWN_KIND = "FOOD.UNKNOWN_KIND";
var FOOD_NOT_HELD = "FOOD.NOT_HELD";
var FOOD_FULL = "FOOD.FULL";
var FOOD_DEAD = "FOOD.DEAD";
function normalizeFoodTable(raw) {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    return err(engineError(FOOD_BAD_TABLE, "\u98DF\u7269\u8868\u5FC5\u987B\u662F\u5BF9\u8C61\uFF08kind \u2192 {nutrition, health?}\uFF09"));
  }
  const src = raw;
  const kinds = Object.keys(src).sort();
  if (kinds.length === 0) {
    return err(engineError(FOOD_BAD_TABLE, "\u98DF\u7269\u8868\u662F\u7A7A\u7684 \u2014\u2014 \u591A\u534A\u662F\u5FD8\u4E86\u586B\uFF0C\u800C\u4E0D\u662F\u771F\u7684\u60F3\u8BA9\u6240\u6709\u4E1C\u897F\u90FD\u4E0D\u80FD\u5403"));
  }
  const out = {};
  for (const kind of kinds) {
    if (kind === "") {
      return err(engineError(FOOD_BAD_TABLE, "\u98DF\u7269\u8868\u91CC\u6709\u4E00\u4E2A\u7A7A\u5B57\u7B26\u4E32 kind"));
    }
    const e = src[kind];
    if (typeof e !== "object" || e === null || Array.isArray(e)) {
      return err(engineError(FOOD_BAD_TABLE, `\u98DF\u7269\u8868\u9879 ${kind} \u5FC5\u987B\u662F\u5BF9\u8C61`, { field: kind, kind }));
    }
    const n = e.nutrition;
    if (!Number.isInteger(n) || n <= 0) {
      return err(
        engineError(FOOD_BAD_TABLE, `\u98DF\u7269\u8868\u9879 ${kind}.nutrition \u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF0C\u6536\u5230 ${String(n)}`, {
          field: `${kind}.nutrition`,
          kind
        })
      );
    }
    const hp = e.health;
    if (hp !== void 0 && (!Number.isInteger(hp) || hp <= 0)) {
      return err(
        engineError(FOOD_BAD_TABLE, `\u98DF\u7269\u8868\u9879 ${kind}.health \u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF0C\u6536\u5230 ${String(hp)}\uFF08\u7701\u7565 = \u4E0D\u56DE\u8840\uFF09`, {
          field: `${kind}.health`,
          kind
        })
      );
    }
    out[kind] = hp === void 0 ? { nutrition: n } : { nutrition: n, health: hp };
  }
  return ok(out);
}
function eat(scene, ownerId, kind, table) {
  const entry = table[kind];
  if (entry === void 0) {
    return err(
      engineError(FOOD_UNKNOWN_KIND, `"${kind}" \u4E0D\u5728\u98DF\u7269\u8868\u91CC\uFF08\u80FD\u5403\u7684\u53EA\u6709\uFF1A${Object.keys(table).sort().join(" / ")}\uFF09`)
    );
  }
  const node = scene.find(ownerId);
  if (node === void 0 || node === null) {
    return err(engineError(HUNGER_NO_OWNER, `\u8282\u70B9 ${String(ownerId)} \u4E0D\u5728\u573A\u666F\u91CC`));
  }
  const h = node.get(HUNGER_TYPE);
  if (h === void 0) {
    return err(engineError(HUNGER_NO_COMPONENT, `\u8282\u70B9 ${String(ownerId)} \u6CA1\u6709 ${HUNGER_TYPE}`));
  }
  const health = node.get(HEALTH_TYPE);
  if (health !== void 0 && isDead(health)) {
    return err(engineError(FOOD_DEAD, `\u8282\u70B9 ${String(ownerId)} \u5DF2\u7ECF\u6B7B\u4E86 \u2014\u2014 \u5C38\u4F53\u4E0D\u4F1A\u5403\u4E1C\u897F`));
  }
  if (h.value >= h.max) {
    return err(
      engineError(FOOD_FULL, `\u5DF2\u7ECF\u5403\u9971\u4E86\uFF08${String(h.value)}/${String(h.max)}\uFF09\u2014\u2014 \u4E0D\u8BE5\u5728\u8FD9\u65F6\u5019\u6D88\u8017\u4E00\u4E2A\u300C${kind}\u300D`)
    );
  }
  if (countItem(scene, ownerId, kind) < 1) {
    return err(engineError(FOOD_NOT_HELD, `\u8EAB\u4E0A\u6CA1\u6709\u300C${kind}\u300D\uFF08\u80CC\u5305\u91CC\u6709\uFF1A${Object.keys(table).sort().join(" / ")}\uFF09`));
  }
  const taken = takeItem(scene, ownerId, kind, 1);
  if (!taken.ok) return taken;
  const fed = feed(scene, ownerId, entry.nutrition);
  if (!fed.ok) {
    return fed;
  }
  let healed = 0;
  if (entry.health !== void 0 && health !== void 0) {
    const r = heal(scene, ownerId, entry.health);
    if (r.ok) healed = r.value;
  }
  return ok({
    nodeId: ownerId,
    kind,
    nutrition: entry.nutrition,
    hungerBefore: fed.value.before,
    hungerAfter: fed.value.after,
    healed
  });
}

// src/extensions/survival/survival-module.ts
var SURVIVAL_BAD_MODULE = "SURVIVAL.BAD_MODULE";
function positive(name, v, dflt) {
  const n = v ?? dflt;
  if (!Number.isInteger(n) || n <= 0) {
    throw new RangeError(`${name} \u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF0C\u6536\u5230 ${String(v)}`);
  }
  return n;
}
function createSurvivalModule(options = {}) {
  const decayEvery = positive("decayEveryTicks", options.decayEveryTicks, 30);
  const starveEvery = positive("starveEveryTicks", options.starveEveryTicks, 30);
  const starveDmg = positive("starveDamage", options.starveDamage, 1);
  let scene = null;
  let tracked = 0;
  let starving = 0;
  let starveTicks = 0;
  let starveDeaths = 0;
  let lastError = "";
  const handle = {
    id: options.id ?? "game.survival",
    deps: [],
    get stats() {
      return { tracked, starving, starveTicks, starveDeaths, lastError };
    },
    init(ctx) {
      const got = ctx.services.get(Services.Scene);
      if (got === void 0) {
        return err(engineError(SURVIVAL_BAD_MODULE, "\u751F\u5B58\u6A21\u5757\u9700\u8981\u4E00\u4E2A Scene\uFF08\u5148\u6CE8\u518C Services.Scene\uFF09"));
      }
      scene = got;
      return ok(void 0);
    },
    update(tick) {
      handle.tick(tick);
    },
    stop() {
    },
    describe() {
      return `\u751F\u5B58\uFF1A\u8FFD\u8E2A ${String(tracked)} / \u997F\u7740 ${String(starving)} / \u997F\u6B7B ${String(starveDeaths)}`;
    },
    tick(tick) {
      const s = scene;
      if (s === null) return;
      const list = [...s.componentsOf(HUNGER_TYPE)].sort(
        (a, b) => (a.node?.id ?? -1) - (b.node?.id ?? -1)
      );
      tracked = list.length;
      let stillStarving = 0;
      for (const h of list) {
        const node = h.node;
        if (node === null || !node.activeInHierarchy) continue;
        if (tick > 0 && tick % decayEvery === 0 && h.value > 0) {
          h.value--;
        }
        if (!isStarving(h)) continue;
        stillStarving++;
        if (tick <= 0 || tick % starveEvery !== 0) continue;
        const health = node.get(HEALTH_TYPE);
        if (health === void 0 || isDead(health)) continue;
        const r = damage(s, node.id, starveDmg, { tick });
        if (!r.ok) {
          lastError = r.error.code;
          continue;
        }
        starveTicks++;
        options.onStarve?.(node.id, tick);
        if (r.value.dead) {
          starveDeaths++;
          options.onStarveDeath?.(node.id, tick);
        }
      }
      starving = stillStarving;
    }
  };
  return handle;
}

// src/extensions/crafting/recipe.ts
var RECIPE_BAD_TABLE = "CRAFT.BAD_TABLE";
var RECIPE_MISSING = "CRAFT.MISSING";
var RECIPE_NO_SPACE = "CRAFT.NO_SPACE";
var RECIPE_NO_OWNER = "CRAFT.NO_OWNER";
function normalizeRecipes(raw) {
  if (!Array.isArray(raw)) {
    return err(engineError(RECIPE_BAD_TABLE, "\u914D\u65B9\u8868\u5FC5\u987B\u662F\u6570\u7EC4"));
  }
  if (raw.length === 0) {
    return err(engineError(RECIPE_BAD_TABLE, "\u914D\u65B9\u8868\u662F\u7A7A\u7684 \u2014\u2014 \u591A\u534A\u662F\u5FD8\u4E86\u586B\uFF0C\u800C\u4E0D\u662F\u771F\u7684\u4E0D\u60F3\u8BA9\u4EBA\u505A\u4E1C\u897F"));
  }
  const seen = /* @__PURE__ */ new Set();
  const out = [];
  for (const [i, item] of raw.entries()) {
    const at = `[${i}]`;
    if (typeof item !== "object" || item === null || Array.isArray(item)) {
      return err(engineError(RECIPE_BAD_TABLE, `\u914D\u65B9${at} \u5FC5\u987B\u662F\u5BF9\u8C61`, { field: at }));
    }
    const r = item;
    const id = r.id;
    if (typeof id !== "string" || id === "") {
      return err(engineError(RECIPE_BAD_TABLE, `\u914D\u65B9${at}.id \u5FC5\u987B\u662F\u975E\u7A7A\u5B57\u7B26\u4E32`, { field: `${at}.id` }));
    }
    if (seen.has(id)) {
      return err(engineError(RECIPE_BAD_TABLE, `\u914D\u65B9 id \u91CD\u590D\uFF1A"${id}"`, { field: `${at}.id`, id }));
    }
    seen.add(id);
    const name = r.name;
    if (typeof name !== "string" || name === "") {
      return err(engineError(RECIPE_BAD_TABLE, `\u914D\u65B9 ${id}.name \u5FC5\u987B\u662F\u975E\u7A7A\u5B57\u7B26\u4E32`, { field: `${id}.name`, id }));
    }
    const rawIn = r.inputs;
    if (!Array.isArray(rawIn) || rawIn.length === 0) {
      return err(
        engineError(RECIPE_BAD_TABLE, `\u914D\u65B9 ${id}.inputs \u5FC5\u987B\u662F\u975E\u7A7A\u6570\u7EC4\uFF08\u6CA1\u6709\u6750\u6599\u7684\u914D\u65B9\u7B49\u4E8E\u767D\u9001\uFF09`, {
          field: `${id}.inputs`,
          id
        })
      );
    }
    const inputs = [];
    for (const [k, c] of rawIn.entries()) {
      const cost = asCost(c);
      if (typeof cost === "string") {
        return err(
          engineError(RECIPE_BAD_TABLE, `\u914D\u65B9 ${id}.inputs[${k}] \u5199\u9519\u4E86\uFF1A${cost}`, {
            field: `${id}.inputs[${k}]`,
            id
          })
        );
      }
      inputs.push(cost);
    }
    const output = asCost(r.output);
    if (typeof output === "string") {
      return err(engineError(RECIPE_BAD_TABLE, `\u914D\u65B9 ${id}.output \u5199\u9519\u4E86\uFF1A${output}`, { field: `${id}.output`, id }));
    }
    out.push({ id, name, inputs, output });
  }
  return ok(out);
}
function asCost(v) {
  if (typeof v !== "object" || v === null || Array.isArray(v)) return "\u5FC5\u987B\u662F {kind, count} \u5BF9\u8C61";
  const o = v;
  if (typeof o.kind !== "string" || o.kind === "") return "kind \u5FC5\u987B\u662F\u975E\u7A7A\u5B57\u7B26\u4E32";
  if (!Number.isInteger(o.count) || o.count <= 0) {
    return `count \u5FC5\u987B\u662F\u6B63\u6574\u6570\uFF0C\u6536\u5230 ${String(o.count)}\uFF080 \u4F1A\u505A\u51FA"\u4E0D\u9700\u8981\u6750\u6599"\u7684\u914D\u65B9\uFF09`;
  }
  return { kind: o.kind, count: o.count };
}
function missingFor(scene, ownerId, recipe) {
  const out = [];
  for (const cost of recipe.inputs) {
    const have = countItem(scene, ownerId, cost.kind);
    if (have < cost.count) out.push({ kind: cost.kind, count: cost.count, have });
  }
  return out;
}
function craft(scene, ownerId, recipe) {
  const node = scene.find(ownerId);
  if (node === void 0 || node === null) {
    return err(engineError(RECIPE_NO_OWNER, `\u8282\u70B9 ${String(ownerId)} \u4E0D\u5728\u573A\u666F\u91CC`));
  }
  const missing = missingFor(scene, ownerId, recipe);
  if (missing.length > 0) {
    const desc = missing.map((m) => `${m.kind} ${String(m.have)}/${String(m.count)}`).join("\u3001");
    return err(
      engineError(RECIPE_MISSING, `\u6750\u6599\u4E0D\u8DB3\uFF1A${desc}`, {
        recipeId: recipe.id,
        missing: missing.map((m) => ({ kind: m.kind, need: m.count, have: m.have }))
      })
    );
  }
  const consumed = [];
  for (const cost of recipe.inputs) {
    const r = takeItem(scene, ownerId, cost.kind, cost.count);
    if (!r.ok) {
      for (const back of consumed) addItem(scene, ownerId, back.kind, back.count);
      return err(
        engineError(RECIPE_MISSING, `\u6263\u6750\u6599\u65F6 ${cost.kind} \u4E0D\u591F\uFF08${r.error.message}\uFF09\u2014\u2014 \u5DF2\u56DE\u6EDA`, {
          recipeId: recipe.id,
          rolledBack: consumed.map((c) => ({ kind: c.kind, count: c.count }))
        })
      );
    }
    consumed.push(cost);
  }
  const added = addItem(scene, ownerId, recipe.output.kind, recipe.output.count);
  if (!added.ok) {
    for (const back of consumed) addItem(scene, ownerId, back.kind, back.count);
    return err(
      engineError(
        RECIPE_NO_SPACE,
        `\u4EA7\u7269\u300C${recipe.output.kind}\xD7${String(recipe.output.count)}\u300D\u653E\u4E0D\u8FDB\u80CC\u5305\uFF08${added.error.code}\uFF09\u2014\u2014 \u6750\u6599\u5DF2\u9000\u56DE`,
        { recipeId: recipe.id, rolledBack: consumed.map((c) => ({ kind: c.kind, count: c.count })) }
      )
    );
  }
  return ok({
    recipeId: recipe.id,
    consumed,
    output: recipe.output,
    added: added.value
  });
}
function firstCraftable(scene, ownerId, recipes) {
  for (const r of recipes) {
    if (missingFor(scene, ownerId, r).length === 0) return r;
  }
  return void 0;
}

// src/browser-entry.ts
var EMPTY_INPUT = {
  keysDown: /* @__PURE__ */ new Set(),
  keysPressed: /* @__PURE__ */ new Set(),
  keysReleased: /* @__PURE__ */ new Set(),
  pointer: { x: 0, y: 0, dx: 0, dy: 0, buttonsDown: /* @__PURE__ */ new Set(), buttonsPressed: /* @__PURE__ */ new Set(), buttonsReleased: /* @__PURE__ */ new Set() },
  wheel: { dx: 0, dy: 0 },
  text: ""
};
var Workable = class extends Component {
  workleft = 3;
  schema = {
    type: "game.workable",
    fields: { workleft: FieldType.Int }
  };
};
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
var DEMO_FRAMES = [
  { name: "ground", file: "ground.png" },
  // ★ terrain 是**中性灰噪点**，不是草绿：地形块用「灰度帧 × 群系色」着色
  //   （一张灰度图 × 8 个群系色 = 8 种地貌）。底色若是草绿，海会变成墨绿。
  { name: "terrain", file: "terrain.png" },
  // 2×2 走向标尺（左上红/右上绿/左下蓝/右下白）：诊断 UV 与裁剪用，平时不挂
  { name: "ruler", file: "ruler.png" },
  { name: "tree", file: "tree.png" },
  { name: "rock", file: "rock.png" },
  { name: "berry", file: "berry.png" },
  { name: "player", file: "player.png" },
  // 批66：世界的活物。★ 名字要与 `MOB_TEMPLATES` 里的 `frame` 一致 ——
  //   两边写错一个字的症状是「生物在走但看不见」，而渲染模块只会 warn。
  { name: "rabbit", file: "rabbit.png" },
  { name: "hound", file: "hound.png" },
  { name: "photo", file: "photo.jpg" }
];
var ASSET_ROOT = "/assets";
var UI_FILES = ["ui-font.fnt", "ui-font.png", "ui-skin.png", "ui-skin.json"];
var UI_CJK_FILES = ["ui-font-cjk.fnt", "ui-font-cjk.png"];
var UI_FONT_ID = "ui5x7";
var UI_CJK_FONT_ID = "unifont-cjk-16-subset";
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
    const remote = new HttpFileSystem({ base: new URL("./assets/", location.href) });
    for (const { file } of DEMO_FRAMES) {
      const r = await remote.readBinary(file);
      if (!r.ok) {
        console.warn(`[asset] \u8BFB\u4E0D\u5230 ${file}\uFF1A${r.error.code} ${r.error.message}`);
        return null;
      }
      const w = await fs.writeBinary(`${ASSET_ROOT}/${file}`, r.value);
      if (!w.ok) return null;
    }
    let uiFilesOk = true;
    for (const file of UI_FILES) {
      const r = await remote.readBinary(file);
      if (!r.ok) {
        console.warn(`[ui] \u8BFB\u4E0D\u5230 ${file}\uFF1A${r.error.code} ${r.error.message}\uFF08HUD \u4F1A\u9000\u56DE DOM\uFF09`);
        uiFilesOk = false;
        continue;
      }
      const w = await fs.writeBinary(`${ASSET_ROOT}/${file}`, r.value);
      if (!w.ok) uiFilesOk = false;
    }
    for (const file of UI_CJK_FILES) {
      const r = await remote.readBinary(file);
      if (!r.ok) {
        console.warn(`[ui] \u8BFB\u4E0D\u5230 ${file}\uFF1A${r.error.code} ${r.error.message}\uFF08\u80CC\u5305\u884C\u4F1A\u7528\u82F1\u6587 kind\uFF09`);
        continue;
      }
      await fs.writeBinary(`${ASSET_ROOT}/${file}`, r.value);
    }
    const report = await pipeline.run(ASSET_ROOT);
    if (!report.ok) return null;
    const sources = [];
    for (const { name, file } of DEMO_FRAMES) {
      const id = db.idAtPath(`${ASSET_ROOT}/${file}`);
      if (id === void 0) continue;
      const h = await db.load(id);
      if (!h.ok) continue;
      const asset = h.value.asset;
      try {
        if (asset instanceof ImportedTexture) {
          const dec = decodeImage(asset.bytes);
          if (dec.ok) sources.push({ name, png: dec.value });
        }
      } finally {
        h.value.release();
      }
    }
    if (sources.length !== DEMO_FRAMES.length) return null;
    const built = buildAtlasFromSources(sources, { padding: 2 });
    if (!built.ok) return null;
    const ui = uiFilesOk ? await loadUiAssets(db, logger) : null;
    return { atlas: built.value, label: `assets*${String(sources.length)}`, ui };
  } catch {
    return null;
  }
}
async function loadText(db, file) {
  const id = db.idAtPath(`${ASSET_ROOT}/${file}`);
  if (id === void 0) return null;
  const h = await db.load(id);
  if (!h.ok) return null;
  try {
    return h.value.asset instanceof ImportedText ? h.value.asset.text : null;
  } finally {
    h.value.release();
  }
}
async function loadTextureBytes(db, file) {
  const id = db.idAtPath(`${ASSET_ROOT}/${file}`);
  if (id === void 0) return null;
  const h = await db.load(id);
  if (!h.ok) return null;
  try {
    return h.value.asset instanceof ImportedTexture ? h.value.asset.bytes : null;
  } finally {
    h.value.release();
  }
}
async function loadUiAssets(db, logger) {
  const [fnt, skin, fontPngBytes, skinPngBytes, cjkFnt, cjkPngBytes] = await Promise.all([
    loadText(db, "ui-font.fnt"),
    loadText(db, "ui-skin.json"),
    loadTextureBytes(db, "ui-font.png"),
    loadTextureBytes(db, "ui-skin.png"),
    loadText(db, "ui-font-cjk.fnt"),
    loadTextureBytes(db, "ui-font-cjk.png")
  ]);
  if (fnt === null || skin === null || fontPngBytes === null || skinPngBytes === null) {
    logger.channel("ui").warn("UI \u8D44\u4EA7\u4E0D\u9F50\uFF08.fnt/.json/\u4E24\u5F20 png\uFF09\uFF0CHUD \u4F1A\u9000\u56DE DOM");
    return null;
  }
  const fontR = parseBmFont(fnt, { id: UI_FONT_ID });
  if (!fontR.ok) {
    logger.channel("ui").warn(`\u5B57\u4F53\u89E3\u6790\u5931\u8D25\uFF1A${fontR.error.code} ${fontR.error.message}\uFF08HUD \u4F1A\u9000\u56DE DOM\uFF09`);
    return null;
  }
  const fontDec = decodeImage(fontPngBytes);
  const skinDec = decodeImage(skinPngBytes);
  if (!fontDec.ok || !skinDec.ok) {
    logger.channel("ui").warn("UI \u56FE\u89E3\u7801\u5931\u8D25\uFF08HUD \u4F1A\u9000\u56DE DOM\uFF09");
    return null;
  }
  let json;
  try {
    json = JSON.parse(skin);
  } catch {
    logger.channel("ui").warn("ui-skin.json \u4E0D\u662F\u5408\u6CD5 JSON\uFF08HUD \u4F1A\u9000\u56DE DOM\uFF09");
    return null;
  }
  const page = (name, w, h, pixels) => ({
    name,
    width: w,
    height: h,
    pixels
  });
  let cjkFont;
  let cjkPage;
  if (cjkFnt === null || cjkPngBytes === null) {
    logger.channel("ui").warn("\u6CA1\u6709\u4E2D\u6587\u5B57\u5F62\u8D44\u4EA7\uFF08\u80CC\u5305\u884C\u7528\u82F1\u6587 kind\uFF09");
  } else {
    const r = parseBmFont(cjkFnt, { id: UI_CJK_FONT_ID, pageBase: 2 });
    const dec = decodeImage(cjkPngBytes);
    if (!r.ok) logger.channel("ui").warn(`\u4E2D\u6587\u5B57\u4F53\u89E3\u6790\u5931\u8D25\uFF1A${r.error.code} ${r.error.message}\uFF08\u80CC\u5305\u884C\u7528\u82F1\u6587 kind\uFF09`);
    else if (!dec.ok) logger.channel("ui").warn(`\u4E2D\u6587\u5B57\u5F62\u56FE\u89E3\u7801\u5931\u8D25\uFF1A${dec.error.code}\uFF08\u80CC\u5305\u884C\u7528\u82F1\u6587 kind\uFF09`);
    else {
      cjkFont = r.value;
      cjkPage = page("ui-font-cjk.png", dec.value.width, dec.value.height, dec.value.pixels);
    }
  }
  return {
    font: fontR.value,
    ...cjkFont === void 0 || cjkPage === void 0 ? {} : { cjkFont, cjkPage },
    fontPage: page("ui-font.png", fontDec.value.width, fontDec.value.height, fontDec.value.pixels),
    skinPage: page("ui-skin.png", skinDec.value.width, skinDec.value.height, skinDec.value.pixels),
    skinJson: json
  };
}
var ITEM_LABEL = {
  tree: "\u6728\u5934",
  rock: "\u77F3\u5934",
  berry: "\u6D46\u679C",
  flint: "\u71E7\u77F3",
  grass_tuft: "\u8349",
  reed: "\u82A6\u82C7",
  // 批65 起战利品会进包；批67 起肉还能吃 —— 没有标签的话 HUD 里显示的是英文 kind
  meat: "\u8089",
  hide: "\u76AE",
  cooked_meat: "\u719F\u8089",
  rope: "\u7EF3\u5B50"
};
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
    // ★ 不写死 cellSize：格宽由引擎按实体尺寸定（`2 × 全场最大 range`，这里的世界是 1.4）。
    //   写死 4 的时候，0.45~0.7 半径的实体被塞进"每格能装几十个"的粗桶里，
    //   每次查询白扫上百个候选 —— 2000 体规模下实测差 2.3 倍（见 T338）。
    { maxIterations: 3 }
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
  const controllerMod = createControllerModule({
    poll: () => appRef === null ? EMPTY_INPUT : appRef.platform.input.poll()
  });
  const bakedUi = baked?.ui ?? null;
  let hudUi = null;
  if (bakedUi !== null) {
    const r = createHudUi({
      font: bakedUi.font,
      // 中文在才传：`labelOf` 与字体是**同一件事的两半** —— 传了中文标签却没有字形，
      // 行文本会变成一串空白（`missingAdvance` 还占着宽度），而日志里一个字都不会响。
      ...bakedUi.cjkFont === void 0 || bakedUi.cjkPage === void 0 ? {} : {
        cjkFont: bakedUi.cjkFont,
        cjkPage: bakedUi.cjkPage,
        labelOf: (kind) => ITEM_LABEL[kind] ?? kind
      },
      skinJson: bakedUi.skinJson,
      fontPage: bakedUi.fontPage,
      skinPage: bakedUi.skinPage,
      // 设计分辨率与画布默认尺寸一致（960×600）；`expand` 让 HUD 贴屏幕边而不是贴设计框，
      // 于是超宽屏上左上角的那块不会跑到黑边里。
      viewport: { designWidth: 960, designHeight: 600, scaleMode: UiScaleMode.Expand },
      dpr,
      hints: { drop: keyLabel("drop"), bag: keyLabel("bag"), pick: keyLabel("harvest") },
      // 点中背包行 = 选中（走的是**真实指针路径**：命中测试 → click 事件 → 这里）
      onSelectRow: (i) => {
        selectBagRow(i);
      }
    });
    if (r.ok) hudUi = r.value;
    else console.warn(`[ui] UI \u6A21\u5757\u6CA1\u5EFA\u8D77\u6765\uFF1A${r.error.code} ${r.error.message}\uFF08HUD \u9000\u56DE DOM\uFF09`);
  }
  hud.hidden = hudUi !== null;
  const BAG_FADE_TICKS = 6;
  const BAG_SLIDE_FROM = -8;
  let bagTween = null;
  const uiNodeById = (id) => hudUi?.module.root.find(id);
  function setBagOpen(next) {
    bagOpen = next;
    if (next) bagSel = 0;
    syncBagUi();
    const t = bagTween;
    if (t === null) return;
    if (next) {
      t.playing = true;
      t.reset();
      applyUiSamples(advancePlayer(t, 0), uiNodeById);
      hudUi?.module.invalidate();
    } else {
      t.playing = false;
    }
  }
  const worldMod = createWorldModule(physics, {
    onTick: (t) => hudTick = t,
    onStep: (tick, dt) => {
      if (bagTween !== null) {
        const applied = applyUiSamples(advancePlayer(bagTween, dt * 1e3), uiNodeById);
        if (applied.changed > 0) hudUi?.module.invalidate();
      }
      controllerMod.update(tick, dt);
      dispatchActions();
      worldState.tasks?.update(tick, dt);
      mobsHandle?.update(tick, dt);
      survivalMod.update(tick, dt);
      feedbackMod.update(tick);
      void scriptMod.update(tick, dt);
    }
  });
  const WORLD_SEED = 20261023;
  const WORLD_W = 32;
  const WORLD_H = 24;
  const planR = generateWorld({ seed: WORLD_SEED, width: WORLD_W, height: WORLD_H, maxSitesPerCell: 0 });
  const plan = planR.ok ? planR.value : null;
  if (!planR.ok) console.error(`[worldgen] \u751F\u6210\u5931\u8D25\uFF1A${planR.error.code} ${planR.error.message}`);
  const worldState = {
    plan,
    player: null,
    visual: null,
    tasks: null,
    /** 导航网格（批60）：从生成计划建一次，之后不再变（地图要变就整张重建）。 */
    nav: null,
    /** 生物群（批66）：世界里会走、会打、会掉东西的活物。 */
    mobs: null,
    assembled: false
  };
  const atlasFrames = baked === null ? [...buildProceduralAtlas().frames.keys()] : [...baked.atlas.frames.keys()];
  const worldgenMod = {
    id: "world.worldgen",
    init(ctx) {
      const scene2 = ctx.services.require(Services.Scene);
      const p = worldState.plan;
      if (p === null) {
        return err(engineError("WORLD.GEN_FAILED", "\u4E16\u754C\u8BA1\u5212\u6CA1\u6709\u751F\u6210\u51FA\u6765\uFF0C\u88C5\u914D\u65E0\u6CD5\u8FDB\u884C"));
      }
      registerWorldComponents(scene2.components);
      registerResourceComponent(scene2.components);
      registerPlayerComponents(scene2.components);
      registerInventoryComponents(scene2.components);
      registerHealthComponent(scene2.components);
      registerAttackerComponent(scene2.components);
      registerFactionComponent(scene2.components);
      registerMoverComponent(scene2.components);
      registerHungerComponent(scene2.components);
      registerFeedbackComponent(scene2.components);
      if (!scene2.components.has(SPRITE_TYPE)) {
        scene2.components.register(new Sprite().schema, () => new Sprite());
      }
      const a = assembleWorld(p, scene2);
      if (!a.ok) return a;
      worldState.assembled = true;
      const v = attachWorldVisuals(scene2, atlasFrames);
      if (!v.ok) return v;
      worldState.visual = v.value;
      const sp2 = spawnPlayer(scene2, p);
      if (!sp2.ok) return sp2;
      worldState.player = sp2.value;
      const nav = NavGrid.fromPlan(p);
      if (!nav.ok) return nav;
      worldState.nav = nav.value;
      return ok(void 0);
    },
    describe() {
      const v = worldState.visual;
      return v === null ? "\u4E16\u754C\uFF1A\u672A\u88C5\u914D" : `\u4E16\u754C\uFF1A${v.terrain} \u5757\u5730\u5F62 / ${v.sites} \u4E2A\u6295\u653E\u70B9`;
    }
  };
  const tasksHandle = plan === null ? null : createWorldTaskModule({
    tasks: {
      schema: WORLD_TASK_SCHEMA,
      tasks: [{ id: "regen", periodTicks: 30, phase: 0, picksPerRun: 2, biomes: ["grass", "forest"] }]
    },
    plan,
    maxResources: 96
  });
  const tasksMod = {
    id: "world.tasks",
    deps: [worldgenMod.id],
    init(ctx) {
      if (tasksHandle === null) return ok(void 0);
      const r = tasksHandle.init(ctx);
      if (r === void 0) return ok(void 0);
      if (!r.ok) return r;
      worldState.tasks = tasksHandle;
      return ok(void 0);
    },
    start() {
      tasksHandle?.start?.();
    },
    stop() {
      tasksHandle?.stop?.();
    },
    describe() {
      const s = worldState.tasks?.stats();
      return s === void 0 ? "\u4E16\u754C\u4EFB\u52A1\uFF1A\u672A\u542F\u52A8" : `\u4E16\u754C\u4EFB\u52A1\uFF1A\u6D3B ${s.alive} / \u7D2F\u8BA1 ${s.spawned}`;
    }
  };
  const MOB_TEMPLATES = [
    {
      kind: "rabbit",
      frame: "rabbit",
      width: 0.9,
      height: 0.9,
      radius: 0.28,
      maxHp: 4,
      damage: 0,
      range: 1.4,
      cooldownTicks: 20,
      speed: 1.1,
      team: "prey",
      loot: [{ kind: "meat", count: 2 }]
    },
    {
      kind: "hound",
      frame: "hound",
      width: 1.1,
      height: 1.1,
      radius: 0.34,
      maxHp: 8,
      damage: 2,
      range: 1.7,
      cooldownTicks: 15,
      speed: 2.3,
      team: "hunter",
      loot: [{ kind: "hide", count: 1 }]
    }
  ];
  const MOB_FACTIONS = createFactions();
  MOB_FACTIONS.setStance("hunter", "prey", "foe");
  function pickMobSpots(grid, hounds, rabbits, avoidCell) {
    const walk = [];
    const ax = grid.cellX(avoidCell);
    const az = grid.cellZ(avoidCell);
    for (let i = 0; i < grid.total; i++) {
      if (!grid.isWalkableIndex(i)) continue;
      const cx = grid.cellX(i);
      const cz = grid.cellZ(i);
      if (Math.abs(cx - ax) <= 2 && Math.abs(cz - az) <= 2) continue;
      walk.push(i);
    }
    const total = hounds + rabbits;
    const out = [];
    if (walk.length === 0) return out;
    const stride = Math.max(1, Math.floor(walk.length / total));
    for (let k = 0; k < total; k++) {
      const cell = walk[Math.min(walk.length - 1, k * stride)];
      if (cell === void 0) continue;
      out.push({ template: k < hounds ? 1 : 0, cell });
    }
    return out;
  }
  let mobsHandle = null;
  const feedbackMod = createFeedbackModule({ id: "render.feedback.demo" });
  const hitstopMod = createHitstopModule({
    id: "combat.hitstop.demo",
    policy: (info) => demoHitstopPolicy(info, heroId)
  });
  const HIT_FLASH_TICKS = 12;
  const HIT_PUNCH_TICKS = 6;
  const DMG_LIFE_MS = 900;
  const feedbackErrors = [];
  const damageNumbers = [];
  const fxLayer = document.createElement("div");
  fxLayer.id = "fx";
  fxLayer.style.cssText = "position:fixed;left:0;top:0;width:100%;height:100%;pointer-events:none;overflow:hidden;z-index:20;";
  document.body.appendChild(fxLayer);
  function spawnDamageNumber(x, z, text, dead, by) {
    const el = document.createElement("div");
    el.className = "dmg";
    el.dataset.dmg = text;
    el.dataset.dmgBy = String(by);
    el.textContent = text;
    el.style.cssText = `position:absolute;left:0;top:0;font:700 14px/1 ui-monospace,monospace;color:${dead ? "#ffd54a" : "#ff6b5a"};text-shadow:0 1px 2px rgba(0,0,0,.55);pointer-events:none;will-change:transform,opacity;`;
    fxLayer.appendChild(el);
    damageNumbers.push({ el, x, z, bornMs: performance.now(), lifeMs: DMG_LIFE_MS, text, dead, by });
  }
  function updateDamageNumbers(now) {
    if (damageNumbers.length === 0) return;
    if (canvas === null) return;
    const rect = canvas.getBoundingClientRect();
    const cam = renderMod.camera;
    for (let i = damageNumbers.length - 1; i >= 0; i--) {
      const d = damageNumbers[i];
      if (d === void 0) continue;
      const t = (now - d.bornMs) / d.lifeMs;
      if (t >= 1) {
        d.el.remove();
        damageNumbers.splice(i, 1);
        continue;
      }
      const c = cam.project(d.x, d.z);
      const px = rect.left + (c.x + 1) / 2 * rect.width;
      const py = rect.top + (1 - c.y) / 2 * rect.height - t * 28;
      const op = t < 0.7 ? 1 : 1 - (t - 0.7) / 0.3;
      d.el.style.transform = `translate(${px.toFixed(1)}px, ${py.toFixed(1)}px)`;
      d.el.style.opacity = op.toFixed(2);
    }
  }
  function showHit(info) {
    worldState.mobs?.noteHit({
      attackerId: info.attackerId,
      targetId: info.targetId,
      applied: info.applied,
      tick: hudTick
    });
    const hs = hitstopMod.trigger(info);
    if (!hs.ok) feedbackErrors.push(hs.error.code);
    const target = scene.find(info.targetId);
    if (target !== void 0) {
      const p = target.worldPosition;
      spawnDamageNumber(p.x, p.y, `-${String(info.applied)}`, info.dead, info.attackerId);
      const f = flash(scene, info.targetId, HIT_FLASH_TICKS);
      if (!f.ok) feedbackErrors.push(f.error.code);
    }
    const pn = punch(scene, info.attackerId, HIT_PUNCH_TICKS);
    if (!pn.ok) feedbackErrors.push(pn.error.code);
  }
  const mobsMod = {
    id: "world.mobs",
    deps: [worldgenMod.id],
    init(ctx) {
      const g = worldState.nav;
      const player = worldState.player;
      if (g === null || player === null) {
        return err(engineError("MOBS.NO_WORLD", "\u5BFC\u822A\u7F51\u683C\u6216\u73A9\u5BB6\u8FD8\u6CA1\u5EFA\u597D\uFF0C\u751F\u7269\u65E0\u5904\u843D\u811A"));
      }
      const spots = pickMobSpots(g, 3, 10, player.cell);
      if (spots.length === 0) {
        return err(engineError("MOBS.NO_SPOT", "\u4E16\u754C\u91CC\u627E\u4E0D\u5230\u53EF\u8D70\u7684\u51FA\u751F\u70B9\uFF08\u5730\u5F62\u5168\u662F\u6C34/\u5D16\uFF1F\uFF09"));
      }
      const h = createMobWorldModule({
        grid: g,
        factions: MOB_FACTIONS,
        templates: MOB_TEMPLATES,
        spots,
        range: 14,
        seed: WORLD_SEED,
        wanderEvery: 18,
        // 记仇：5 秒记忆、追 16 格（跑出 16 格才能甩掉）。这两个值是**玩法参数**，
        // 所以显式写在这里，而不是靠库里的默认值 —— 调平衡的人该在这里调。
        threatDecayTicks: 150,
        aggroCells: 16,
        // 生物打人：与玩家打怪走**同一个** showHit（否则会出现"我打的看得见、
        // 我挨打看不见"，而两边的代码都对）
        onHit: (info) => showHit(info)
      });
      const r = h.init(ctx);
      if (r !== void 0 && !r.ok) return r;
      mobsHandle = h;
      worldState.mobs = h;
      return ok(void 0);
    },
    describe() {
      const m = worldState.mobs;
      if (m === null) return "\u751F\u7269\uFF1A\u672A\u542F\u52A8";
      const st = m.stats;
      return `\u751F\u7269\uFF1A${String(st.mobs)} \u53EA\uFF08\u8FFD ${String(st.hunting)} / \u6E38 ${String(st.wandering)}\uFF09\uFF0C\u51FB\u6740 ${String(st.kills)}`;
    }
  };
  const survivalMod = createSurvivalModule({
    id: "game.survival.demo",
    // 60 tick（2 秒）掉 1 点 ⇒ 满值 100 点能撑 200 秒。演示里"看得见它在掉"，
    // 但不至于让人一直在吃东西。
    decayEveryTicks: 60,
    // 饿着之后每 30 tick（1 秒）掉 1 血：20 血能撑 20 秒才死 —— 够人反应。
    starveEveryTicks: 30,
    starveDamage: 1
  });
  const FOOD_TABLE_R = normalizeFoodTable({
    berry: { nutrition: 15 },
    meat: { nutrition: 25, health: 5 },
    // 批68：熟肉是"制作"的产物 —— 比生肉更顶饱、回血更多。
    // ★ 这条让「采草 + 打猎 → 做 → 吃」成为一个**有比价关系**的循环：
    //   生肉直接吃是 25/5，花一份草做成熟肉是 40/10。
    cooked_meat: { nutrition: 40, health: 10 }
  });
  if (!FOOD_TABLE_R.ok) throw new Error(`\u98DF\u7269\u8868\u4E0D\u5408\u6CD5\uFF1A${FOOD_TABLE_R.error.message}`);
  const FOOD_TABLE = FOOD_TABLE_R.value;
  const RECIPES_R = normalizeRecipes([
    { id: "cooked_meat", name: "\u719F\u8089", inputs: [{ kind: "meat", count: 1 }, { kind: "grass_tuft", count: 1 }], output: { kind: "cooked_meat", count: 1 } },
    { id: "rope", name: "\u7EF3\u5B50", inputs: [{ kind: "reed", count: 2 }], output: { kind: "rope", count: 1 } }
  ]);
  if (!RECIPES_R.ok) throw new Error(`\u914D\u65B9\u8868\u4E0D\u5408\u6CD5\uFF1A${RECIPES_R.error.message}`);
  const RECIPES = RECIPES_R.value;
  const modules = [
    worldMod,
    renderMod,
    scriptMod,
    worldgenMod,
    tasksMod,
    mobsMod,
    survivalMod,
    feedbackMod,
    hitstopMod,
    controllerMod
  ];
  if (hudUi !== null) modules.push(hudUi.module);
  const appR = await bootGameApp({
    platformId: "web",
    interactive: true,
    registry,
    modules,
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
  if (hudUi !== null) {
    const fadeMs = ticksToMs(BAG_FADE_TICKS, app.scheduler.fixedDt * 1e3);
    const player = new TweenPlayer();
    const fade = player.addTrack({
      id: "bag.fadeIn",
      targetId: "bag.panel",
      prop: UI_TWEEN_PROP.Opacity,
      spec: { id: "bag.fadeIn", from: 0, to: 1, durationMs: fadeMs, easing: "quadOut", loopCount: 1 }
    });
    const slide = player.addTrack({
      id: "bag.slideIn",
      targetId: "bag.panel",
      prop: UI_TWEEN_PROP.OffsetY,
      spec: { id: "bag.slideIn", from: BAG_SLIDE_FROM, to: 0, durationMs: fadeMs, easing: "quadOut", loopCount: 1 }
    });
    if (fade.ok && slide.ok) bagTween = player;
    else app.log.channel("host").warn("\u80CC\u5305\u8FC7\u6E21\u8F68\u9053\u6CA1\u5EFA\u8D77\u6765\uFF1A\u5C5E\u6027\u540D\u6216 spec \u5199\u9519\u4E86");
  }
  const scriptRuntime = scriptMod.runtime;
  if (scriptRuntime === null) {
    app.log.channel("host").warn("\u5E73\u53F0\u6CA1\u6709\u811A\u672C\u8FD0\u884C\u65F6\uFF1A\u6F14\u793A\u811A\u672C\u4E0D\u4F1A\u6267\u884C");
  } else {
    const lr = await scriptRuntime.loadModule("demo", LUA_DEMO);
    if (!lr.ok) app.log.channel("host").error(`\u6F14\u793A\u811A\u672C\u52A0\u8F7D\u5931\u8D25\uFF1A${lr.error.code} ${lr.error.message}`);
  }
  const reg = app.components;
  registerControllerComponent(reg);
  reg.register({ type: "game.workable", fields: { workleft: FieldType.Int } }, () => new Workable());
  const scene = app.scene;
  const rnd = app.random;
  const worldPlan = worldState.plan;
  const W = worldPlan?.width ?? WORLD_W;
  const H = worldPlan?.height ?? WORLD_H;
  function walkableSpot(margin = 1) {
    for (let tries = 0; tries < 64 && worldPlan !== null; tries++) {
      const cx = Math.floor(rnd.range(margin, W - margin));
      const cz = Math.floor(rnd.range(margin, H - margin));
      const kind = worldPlan.kinds[cz * W + cx];
      if (kind === void 0) continue;
      if (kind === "ocean" || kind === "cliff") continue;
      return { x: cx + 0.5, z: cz + 0.5 };
    }
    return { x: W / 2, z: H / 2 };
  }
  const obstacleIds = [];
  for (let i = 0; i < 70; i++) {
    const isTree = i % 3 !== 0;
    const spot = walkableSpot();
    const r = scene.spawnAt(isTree ? `tree${i}` : `rock${i}`, spot.x, spot.z);
    if (!r.ok) continue;
    const node = r.value;
    const s = makeSprite(isTree ? "tree" : "rock", isTree ? 2 : 1.6, isTree ? 3 : 1.4);
    s.pivotY = 0;
    scene.attach(node.id, () => s);
    if (isTree) scene.attach(node.id, () => new Workable());
    obstacleIds.push(node.id);
    scene.enqueue(() => physics.add({ nodeId: node.id, radius: isTree ? 0.55 : 0.7, isStatic: true }), "physics-add");
  }
  for (let i = 0; i < 14; i++) {
    const spot = walkableSpot();
    const r = scene.spawnAt(`berry${i}`, spot.x, spot.z);
    if (!r.ok) continue;
    const s = makeSprite("berry", 0.8, 0.8);
    s.pivotY = 0;
    scene.attach(r.value.id, () => s);
  }
  for (let i = 0; i < 4; i++) {
    const cellX = 6 + i * 5;
    const cx = Math.min(W - 2, cellX);
    const r = scene.spawnAt(`poster${i}`, cx + 0.5, 3.5);
    if (!r.ok) continue;
    const s = makeSprite("photo", 1.6, 1.6);
    s.pivotY = 0;
    s.order = -50;
    scene.attach(r.value.id, () => s);
    obstacleIds.push(r.value.id);
    scene.enqueue(() => physics.add({ nodeId: r.value.id, radius: 0.6, isStatic: true }), "physics-add");
  }
  const sp = worldState.player;
  if (sp === null) throw new Error("\u4E16\u754C\u6CA1\u6709\u7ED9\u51FA\u51FA\u751F\u70B9\uFF08worldgen \u6A21\u5757\u6CA1\u8DD1\u6210\uFF09");
  heroId = sp.nodeId;
  const heroNode = scene.find(heroId);
  if (heroNode === void 0) throw new Error(`\u51FA\u751F\u8282\u70B9 ${heroId} \u4E0D\u5728\u573A\u666F\u91CC`);
  scene.attach(heroId, () => new PlayerController());
  scene.attach(heroId, () => {
    const h = new Health();
    h.hp = 20;
    h.maxHp = 20;
    return h;
  });
  scene.attach(heroId, () => {
    const a = new Attacker();
    a.damage = 3;
    a.range = 1.8;
    a.cooldownTicks = 12;
    return a;
  });
  scene.attach(heroId, () => {
    const f = new FactionMember();
    f.team = "hunter";
    return f;
  });
  scene.attach(heroId, () => {
    const g = new Hunger();
    g.max = 100;
    g.value = 100;
    return g;
  });
  scene.attach(heroId, () => {
    const c = new ScriptComponent();
    c.module = "demo";
    c.entry = "onUpdate";
    return c;
  });
  scene.enqueue(() => physics.add({ nodeId: heroId, radius: 0.45, isStatic: false }), "physics-add");
  scene.flush();
  const bag = makeInventory(scene, heroId, 8);
  if (!bag.ok) toast(`\u80CC\u5305\u5EFA\u4E0D\u8D77\u6765\uFF1A${bag.error.code}`);
  const saves = new StorageFileSystem({ storage: window.localStorage, prefix: "engine08.fs." });
  const SAVE_PATH = "/saves/slot1.json";
  let toastTimer = 0;
  function toast(msg3) {
    toastEl.textContent = msg3;
    toastEl.style.opacity = "1";
    if (toastTimer !== 0) clearTimeout(toastTimer);
    toastTimer = window.setTimeout(() => {
      toastEl.style.opacity = "0";
    }, 2e3);
  }
  function attackNearest() {
    if (heroId < 0) return "\u8FD8\u6CA1\u6709\u73A9\u5BB6";
    const hero = scene.find(heroId);
    if (hero === void 0) return "\u73A9\u5BB6\u4E0D\u5728\u573A\u666F\u91CC";
    if (hero.get(ATTACKER_TYPE) === void 0) return `\u73A9\u5BB6\u6CA1\u6709 ${ATTACKER_TYPE}`;
    const me = hero.worldPosition;
    const myTeam = teamOf(scene, heroId).team;
    let bestId = -1;
    let bestD2 = Number.POSITIVE_INFINITY;
    for (const h of scene.componentsOf(HEALTH_TYPE)) {
      const n = h.node;
      if (n === null || n.id === heroId || !n.activeInHierarchy) continue;
      if (isDead(h)) continue;
      if (MOB_FACTIONS.stanceOf(myTeam, teamOf(scene, n.id).team) === "ally") continue;
      const p = n.worldPosition;
      const dx = p.x - me.x;
      const dz = p.y - me.y;
      const d2 = dx * dx + dz * dz;
      if (d2 < bestD2) {
        bestD2 = d2;
        bestId = n.id;
      }
    }
    if (bestId < 0) return "\u9644\u8FD1\u6CA1\u6709\u53EF\u6253\u7684";
    const r = attack(scene, heroId, bestId, { tick: hudTick, factions: MOB_FACTIONS });
    if (!r.ok) return `${r.error.code}\uFF1A${r.error.message}`;
    const rep = r.value.report;
    showHit({
      attackerId: heroId,
      targetId: bestId,
      before: rep.before,
      after: rep.after,
      applied: rep.applied,
      overkill: rep.overkill,
      dead: rep.dead,
      tick: hudTick
    });
    return rep.dead ? `\u51FB\u6740\uFF01` : `\u547D\u4E2D ${String(rep.applied)}\uFF0C\u5269 ${String(rep.after)}`;
  }
  function eatSomething() {
    if (heroId < 0) return "\u8FD8\u6CA1\u6709\u73A9\u5BB6";
    const held = stacksOf(scene, heroId).filter((s) => FOOD_TABLE[s.kind] !== void 0 && s.count > 0).sort((a, b) => {
      const na = FOOD_TABLE[a.kind]?.nutrition ?? 0;
      const nb = FOOD_TABLE[b.kind]?.nutrition ?? 0;
      if (na !== nb) return nb - na;
      return a.kind < b.kind ? -1 : a.kind > b.kind ? 1 : 0;
    });
    const best = held[0];
    if (best === void 0) {
      return `\u80CC\u5305\u91CC\u6CA1\u6709\u80FD\u5403\u7684\u4E1C\u897F\uFF08\u80FD\u5403\u7684\uFF1A${Object.keys(FOOD_TABLE).sort().join(" / ")}\uFF09`;
    }
    const r = eat(scene, heroId, best.kind, FOOD_TABLE);
    if (!r.ok) return `${r.error.code}\uFF1A${r.error.message}`;
    const rep = r.value;
    return `\u5403\u4E86\u300C${rep.kind}\u300D\uFF1A\u9971\u98DF ${String(rep.hungerBefore)}\u2192${String(rep.hungerAfter)}` + (rep.healed > 0 ? `\uFF0C\u56DE\u8840 ${String(rep.healed)}` : "");
  }
  function craftSomething() {
    if (heroId < 0) return "\u8FD8\u6CA1\u6709\u73A9\u5BB6";
    const pick = firstCraftable(scene, heroId, RECIPES);
    if (pick !== void 0) {
      const r = craft(scene, heroId, pick);
      if (!r.ok) return `${r.error.code}\uFF1A${r.error.message}`;
      return `\u505A\u597D\u4E86\u300C${pick.name}\u300D\uFF1A${pick.inputs.map((c) => `${ITEM_LABEL[c.kind] ?? c.kind}\xD7${String(c.count)}`).join(" + ")} \u2192 ${ITEM_LABEL[r.value.output.kind] ?? r.value.output.kind}\xD7${String(r.value.added)}`;
    }
    let best = null;
    for (const r of RECIPES) {
      const missing = missingFor(scene, heroId, r);
      if (missing.length === 0) continue;
      if (best === null || missing.length < best.missing.length) best = { id: r.id, name: r.name, missing };
    }
    if (best === null) return "\u6CA1\u6709\u53EF\u505A\u7684\u914D\u65B9";
    const desc = best.missing.map((m) => `${ITEM_LABEL[m.kind] ?? m.kind} ${String(m.have)}/${String(m.count)}`).join("\u3001");
    return `${best.id} \u7F3A\uFF1A${desc}`;
  }
  function dispatchActions() {
    const snap = controllerMod.snapshot;
    const map = controllerMod.map;
    if (map.justPressed(snap, "save")) void doSave();
    else if (map.justPressed(snap, "load")) void doLoad();
    else if (map.justPressed(snap, "restart")) location.reload();
    else if (map.justPressed(snap, "bag")) {
      setBagOpen(!bagOpen);
      toast(bagOpen ? "\u80CC\u5305\u5DF2\u6253\u5F00" : "\u80CC\u5305\u5DF2\u5173\u4E0A");
    } else if (map.justPressed(snap, "drop")) {
      const d = dropSelected(shiftDown);
      toast(d.ok ? d.value : `${d.error.code}\uFF1A${d.error.message}`);
    } else if (map.justPressed(snap, "attack")) toast(attackNearest());
    else if (map.justPressed(snap, "eat")) toast(eatSomething());
    else if (map.justPressed(snap, "craft")) toast(craftSomething());
    else if (map.justPressed(snap, "chop")) chopNearest();
    else if (map.justPressed(snap, "harvest")) {
      const h = pickupNearest();
      toast(h.ok ? h.value : `${h.error.code}\uFF1A${h.error.message}`);
    }
  }
  async function doSave() {
    const json = sceneToJson(saveScene(scene));
    const w = await saves.writeText(SAVE_PATH, json);
    toast(w.ok ? `\u5DF2\u5B58\u6863\uFF1A${json.length} \u5B57\u8282 \xB7 hash ${stableHash(json)}` : `\u5B58\u6863\u5931\u8D25\uFF1A${w.error.code} ${w.error.message}`);
    return w;
  }
  async function doLoad() {
    const res = await saves.readText(SAVE_PATH);
    if (!res.ok) {
      toast(res.error.code === "FS.NOT_FOUND" ? "\u8FD8\u6CA1\u6709\u5B58\u6863\uFF08\u5148\u6309 F5\uFF09" : `\u8BFB\u6863\u5931\u8D25\uFF1A${res.error.code}`);
      return res;
    }
    return applyLoad(res.value);
  }
  function applyLoad(json) {
    const snap = sceneFromJson(json);
    if (!snap.ok) {
      toast("\u5B58\u6863\u635F\u574F\uFF1A" + snap.error.message);
      return snap;
    }
    const r = loadScene(scene, snap.value, reg);
    if (!r.ok) {
      toast("\u8BFB\u6863\u5931\u8D25\uFF1A" + r.error.message);
      return r;
    }
    physics.clear();
    for (const id of obstacleIds) {
      if (scene.find(id) !== void 0) physics.add({ nodeId: id, radius: 0.6, isStatic: true });
    }
    if (scene.find(heroId) !== void 0) physics.add({ nodeId: heroId, radius: 0.45, isStatic: false });
    const extra = r.value.skipped.length > 0 ? `\uFF0C\u8DF3\u8FC7 ${r.value.skipped.length} \u9879` : "";
    toast(`\u5DF2\u8BFB\u6863\uFF1A${r.value.made} \u4E2A\u8282\u70B9${extra}`);
    return ok(r.value.made);
  }
  function pickupNearest(range = 3.2) {
    const heroNode2 = scene.find(heroId);
    if (heroNode2 === void 0) return err(engineError("HARVEST.NO_PLAYER", "\u73A9\u5BB6\u4E0D\u5728\u573A\u666F\u91CC"));
    const tasks = worldState.tasks;
    if (tasks === null) return err(engineError("HARVEST.NO_TASKS", "\u4E16\u754C\u4EFB\u52A1\u6A21\u5757\u6CA1\u8D77\u6765"));
    const hp = heroNode2.worldPosition;
    const r = pickupNearby(scene, hp.x, hp.y, range, heroId, {
      max: 4,
      // ★ 产出按种类走（T355 遗留的"amount 固定 1"）：芦苇成片长，一次攥一把；
      //   石头燧石一块是一块。**这是产品决定，留在宿主** —— 引擎只认"给几个"。
      amount: (kind) => RESOURCE_YIELD[kind] ?? 1,
      onRelease: (c) => tasks.releaseCell(c)
    });
    if (!r.ok) return r;
    const out = r.value;
    if (out.inRange === 0) {
      return err(engineError("HARVEST.FAR", "\u9644\u8FD1\u6CA1\u6709\u4E16\u754C\u8D44\u6E90\uFF08\u8D44\u6E90\u4F1A\u81EA\u5DF1\u957F\u51FA\u6765\uFF0C\u7B49\u51E0\u79D2\uFF09"));
    }
    if (out.picked.length === 0) {
      const f = out.failed;
      return err(
        engineError(
          f?.code ?? "PICKUP.NONE",
          `\u62FF\u5230\u4E86 0 \u4E2A\uFF08\u534A\u5F84\u5185 ${out.inRange} \u4E2A\uFF09\uFF1A${f === null ? "\u539F\u56E0\u4E0D\u660E" : f.message}`
        )
      );
    }
    const got = out.picked.map((p) => `${ITEM_LABEL[p.kind] ?? p.kind}\xD7${countItem(scene, heroId, p.kind)}`);
    const tail = out.failed === null ? "" : `\uFF1B\u80CC\u5305\u6EE1\u4E86\uFF0C\u8FD8\u5269 ${out.remaining} \u4E2A\u6CA1\u62FF`;
    return ok(`\u62FE\u53D6\uFF1A${got.join(" ")}${tail}`);
  }
  function chopNearest() {
    const heroNode2 = scene.find(heroId);
    if (heroNode2 === void 0) return;
    const hp = heroNode2.worldPosition;
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
  function helpText() {
    const m = controllerMod.map;
    const k = (a) => (m.keysOf(a)[0] ?? "?").replace(/^Key/, "");
    return `${k("move_forward")}${k("move_left")}${k("move_back")}${k("move_right")} \u79FB\u52A8 \xB7 ${k("harvest")} \u62FE\u53D6 \xB7 ${k("chop")} \u780D\u6811 \xB7 ${k("attack")} \u6253 \xB7 ${k("eat")} \u5403 \xB7 ${k("craft")} \u5236\u4F5C \xB7 ${k("bag")} \u80CC\u5305 \xB7 ${k("drop")} \u4E22\u5F03 \xB7 ${k("save")} \u5B58\u6863 \xB7 ${k("load")} \u8BFB\u6863 \xB7 ${k("restart")} \u91CD\u8F7D`;
  }
  const RESOURCE_YIELD = {
    berry: 1,
    reed: 2,
    tree: 1,
    rock: 1,
    flint: 1,
    grass_tuft: 1
  };
  function bagText() {
    if (heroId < 0) return "\u65E0\u4E3B";
    const stacks = stacksOf(scene, heroId);
    if (stacks.length === 0) return "\u7A7A";
    return stacks.map((s) => `${ITEM_LABEL[s.kind] ?? s.kind}\xD7${s.count}`).join(" ");
  }
  function hungerText() {
    if (heroId < 0) return "\u65E0\u4E3B";
    const h = scene.find(heroId)?.get(HUNGER_TYPE);
    if (h === void 0) return "\u65E0";
    return `${String(h.value)}/${String(h.max)}${h.value <= 0 ? " \u997F\uFF01" : ""}`;
  }
  let bagOpen = false;
  let bagSel = 0;
  let shiftDown = false;
  function keyLabel(a) {
    return (controllerMod.map.keysOf(a)[0] ?? "?").replace(/^Key/, "");
  }
  function syncBagUi(stacks) {
    if (hudUi === null) return;
    if (!bagOpen || heroId < 0) {
      hudUi.setBag(null, bagSel);
      return;
    }
    hudUi.setBag(stacks ?? stacksOf(scene, heroId), bagSel);
  }
  function selectBagRow(i) {
    const n = heroId < 0 ? 0 : stacksOf(scene, heroId).length;
    bagSel = n === 0 ? 0 : Math.min(Math.max(0, Math.floor(i)), n - 1);
    syncBagUi();
    return bagSel;
  }
  function dropSelected(whole) {
    if (heroId < 0) return err(engineError("BAG.NO_OWNER", "\u6CA1\u6709\u73A9\u5BB6"));
    if (!bagOpen) return err(engineError("BAG.CLOSED", `\u5148\u6309 ${keyLabel("bag")} \u6253\u5F00\u80CC\u5305`));
    const stacks = stacksOf(scene, heroId);
    if (stacks.length === 0) return err(engineError("BAG.EMPTY", "\u80CC\u5305\u662F\u7A7A\u7684\uFF0C\u6CA1\u4EC0\u4E48\u53EF\u4E22"));
    const plan2 = worldState.plan;
    const tasks = worldState.tasks;
    if (plan2 === null || tasks === null) return err(engineError("BAG.NO_WORLD", "\u4E16\u754C\u6CA1\u8D77\u6765\uFF0C\u6CA1\u5730\u65B9\u4E22"));
    const heroNode3 = scene.find(heroId);
    if (heroNode3 === void 0) return err(engineError("HARVEST.NO_PLAYER", "\u73A9\u5BB6\u4E0D\u5728\u573A\u666F\u91CC"));
    const sel = Math.min(Math.max(0, bagSel), stacks.length - 1);
    const s = stacks[sel];
    const n = whole ? s.count : 1;
    const hp = heroNode3.worldPosition;
    const r = dropIntoWorld(scene, heroId, s.kind, n, {
      x: hp.x,
      z: hp.y,
      plan: plan2,
      tasks,
      bornTick: app.snapshot().tick
    });
    if (!r.ok) return r;
    syncBagUi();
    const label = ITEM_LABEL[s.kind] ?? s.kind;
    return ok(`\u4E22\u4E0B ${label}\xD7${String(n)}\uFF08\u6563\u843D\u5728 ${String(r.value.cells.length)} \u683C\uFF0C\u6309 G \u8FD8\u80FD\u6361\u56DE\u6765\uFF09`);
  }
  let fps = 0;
  let frames = 0;
  let lastFpsAt = performance.now();
  let renderFrames = 0;
  let lastHudText = "";
  app.services.require(Services.Frame).onRender((info) => {
    frames++;
    renderFrames++;
    const now = performance.now();
    if (now - lastFpsAt > 500) {
      fps = frames / ((now - lastFpsAt) / 1e3);
      frames = 0;
      lastFpsAt = now;
    }
    updateDamageNumbers(now);
    const lf = renderMod.lastFrame;
    const st = app.snapshot();
    const sc = scriptMod.runtime?.stats();
    const ws = worldState.tasks?.stats();
    const wv = worldState.visual;
    const stacks = heroId < 0 ? [] : stacksOf(scene, heroId);
    const hungerC = heroId < 0 ? void 0 : scene.find(heroId)?.get(HUNGER_TYPE);
    const facts = {
      fps,
      tick: hudTick,
      quads: lf.quads,
      drawCalls: lf.drawCalls,
      culled: lf.culled,
      nodes: st.scene.nodes,
      bodies: physics.stats().bodies,
      atlas: atlasLabel,
      world: wv === null ? null : { terrain: wv.terrain, sites: wv.sites },
      resources: { alive: ws?.alive ?? 0, spawned: ws?.spawned ?? 0, released: ws?.released ?? 0 },
      bagStacks: stacks.length,
      hunger: hungerC === void 0 ? null : { value: hungerC.value, max: hungerC.max },
      backends: { gfx: st.backends.gfx, audio: st.backends.audio, input: st.backends.input, script: st.backends.script },
      script: sc === void 0 ? null : { calls: sc.calls, errors: sc.errors, timeouts: sc.timeouts },
      droppedSteps: st.droppedSteps
    };
    lastHudText = hudLine(facts);
    if (hudUi !== null) {
      hudUi.setHud(hudRows(facts), hungerC === void 0 || hungerC.max <= 0 ? null : hungerC.value / hungerC.max);
      syncBagUi(stacks);
    } else {
      hud.textContent = lastHudText;
    }
  });
  if (hudUi !== null) {
    const ui = hudUi;
    app.platform.input.subscribe((e) => {
      if (e.kind !== "pointer") return;
      if (e.x === void 0 || e.y === void 0) return;
      ui.pointer(e.x, e.y, e.down === true);
    });
  }
  const RESERVED = /* @__PURE__ */ new Set(["F5", "F9", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Space", "Tab"]);
  window.addEventListener("keydown", (ev) => {
    if (RESERVED.has(ev.code)) ev.preventDefault();
    if (ev.code === "ShiftLeft" || ev.code === "ShiftRight") shiftDown = true;
    if (bagOpen && /^Digit[1-8]$/.test(ev.code)) selectBagRow(Number(ev.code.slice(5)) - 1);
  });
  window.addEventListener("keyup", (ev) => {
    if (ev.code === "ShiftLeft" || ev.code === "ShiftRight") shiftDown = false;
  });
  window.addEventListener("blur", () => {
    shiftDown = false;
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
    const helpEl = document.getElementById("help");
    if (helpEl !== null) helpEl.textContent = helpText();
    toast(helpText());
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
    /** 打一下最近的敌人（自检页用：它要走**玩家这条真实路径**，见 `attackNearest`）。 */
    attack: () => attackNearest(),
    /**
     * 顿帧状态（批73）。自检页用它证两件只有浏览器里才可能坏的事：
     * ① 命中真的让世界停下来（`frozen` / `freezeTicks` / `triggers`）；
     * ② 停的时候画面还在走 —— 这条要配 `renderFrames()` 与 `snapshot().tick` 读。
     */
    hitstop: () => ({ ...hitstopMod.stats }),
    /** 图集真实来源：`assets*7`（6 PNG + 1 JPEG）表示走完了导入链；`procedural` 表示降级了。 */
    atlasSource: atlasLabel,
    /** 世界链的产物：生成计划 / 装配结果 / 可见化报告 / 再生任务句柄。 */
    world: {
      plan: worldState.plan,
      player: worldState.player,
      visual: worldState.visual,
      tasks: worldState.tasks,
      assembled: worldState.assembled,
      /** 半径拾取（自检页用；**会进背包**）。 */
      pickupNearest,
      /**
       * 按格子采一次（自检页用）。目标是确定的格子 —— 判据不该依赖"玩家恰好站在哪"。
       * ★ 注意它**不进背包**（走 `harvestAt`）：它验的是"世界这一侧"，背包那一侧用
       *   `pickup` / `bag` 验。两条判据分开，才不会一条红了两边都要查。
       */
      harvest: (cell) => {
        const t = worldState.tasks;
        if (t === null) return err(engineError("HARVEST.NO_TASKS", "\u4E16\u754C\u4EFB\u52A1\u6A21\u5757\u6CA1\u8D77\u6765"));
        return harvestAt(scene, cell, { onRelease: (c) => t.releaseCell(c) });
      },
      /** 世界里还剩多少可见的东西（地形 / 投放点 / 资源）。 */
      counts: () => ({
        terrain: scene.countOf(TERRAIN_TYPE),
        sites: scene.countOf(SITE_TYPE),
        resources: scene.countOf(RESOURCE_TYPE),
        sprites: scene.countOf(SPRITE_TYPE)
      })
    },
    /**
     * 生物群（批66）。自检页要用它证三件**只有浏览器里才可能坏**的事：
     * ① 世界里真有生物（不是只有配表）；② 它们会动；③ 玩家打得到并拿到战利品。
     * 位置直接给出来（而不是只给统计）："会动"必须能被逐次采样比对。
     */
    mobs: () => {
      const m = worldState.mobs;
      if (m === null) return null;
      return {
        ...m.stats,
        list: m.nodeIds.map((id) => {
          const n = scene.find(id);
          return {
            id,
            kind: m.templateOf(id),
            x: n === void 0 ? -1 : n.worldPosition.x,
            z: n === void 0 ? -1 : n.worldPosition.y
          };
        })
      };
    },
    snapshot: () => app.snapshot(),
    lastFrame: () => renderMod.lastFrame,
    /**
     * 饱食度（批67）。自检页要用它证两件**只有浏览器里才可能坏**的事：
     * ① 玩家的 `game.hunger` 真的挂上了（组件没注册/没 attach ⇒ 读回来 undefined）；
     * ② 它会掉（模块被 `onStep` 驱动了 ⇒ 停在那里不动就是没接上）。
     * ★ 顺带把"能吃的东西"和"当前能不能吃"给出去：判据不必自己抄一份食物表。
     */
    hunger: () => {
      const h = heroId < 0 ? void 0 : scene.find(heroId)?.get(HUNGER_TYPE);
      return {
        value: h?.value ?? -1,
        max: h?.max ?? -1,
        text: hungerText(),
        food: Object.keys(FOOD_TABLE).sort(),
        edible: heroId < 0 ? [] : stacksOf(scene, heroId).filter((s) => FOOD_TABLE[s.kind] !== void 0 && s.count > 0).map((s) => ({ kind: s.kind, count: s.count })),
        stats: survivalMod.stats
      };
    },
    /** 吃一口（自检页驱动；等价于按 E）。返回提示文本，与 toast 同一句。 */
    eat: () => eatSomething(),
    /**
     * 制作（批68）。自检页要证三件**只有浏览器里才可能坏**的事：
     * ① 配方表在建 app 之前就归一化通过了（表写错会在加载期抛）；
     * ② 缺料时制作**不动背包**；
     * ③ 材料齐了能做出东西，且**产物真的进了背包**。
     * 返回提示文本（与 toast 同一句）+ 当前配方清单。
     */
    craft: () => craftSomething(),
    recipes: () => RECIPES.map((r) => ({ id: r.id, name: r.name, inputs: r.inputs, output: r.output })),
    /**
     * **调试/自检专用**：把玩家的饱食度设成某个值。
     * ★ 为什么允许这个后门（与 `give` 同一个理由）：验"饿了能吃、满了不能吃"
     *   要么等 200 秒让它自然掉到 30，要么直接设。后门只改一个数字，不碰世界，
     *   所以它证的仍然是"进食这一侧"。
     */
    setHunger: (v) => {
      const h = heroId < 0 ? void 0 : scene.find(heroId)?.get(HUNGER_TYPE);
      if (h === void 0) return -1;
      h.value = Math.max(0, Math.min(h.max, Math.floor(v)));
      return h.value;
    },
    /** 背包内容（自检页与截图工具读它：`[{kind,count}]`，空数组 = 真空）。 */
    bag: () => heroId < 0 ? [] : stacksOf(scene, heroId).map((s) => ({ kind: s.kind, count: s.count })),
    /** 背包文本（HUD 里那一行，判据直接比对它就不用抄一份格式化逻辑）。 */
    bagText: () => bagText(),
    /** 背包的两层上限（自检页验"上限真的接上了"，不是只写在文档里）。 */
    bagLimits: () => {
      const inv = heroId < 0 ? void 0 : scene.find(heroId)?.get("game.inventory");
      return { maxStacks: inv?.maxStacks ?? 0, maxStack: inv?.maxStack ?? 0 };
    },
    /**
     * **调试/自检专用**：直接往包里放 n 个（绕过世界采集）。
     * ★ 为什么允许这个后门：堆叠上限的判据需要"采 45 次芦苇"才能撞到 40，
     *   而一次采集要等资源再生（30 tick）—— 判据会慢到没法每轮跑。
     *   后门只加物品、不碰世界，所以它证的仍是"背包这一侧"。
     */
    give: (kind, n) => heroId < 0 ? err(engineError("BAG.NO_OWNER", "\u6CA1\u6709\u73A9\u5BB6")) : addItem(scene, heroId, kind, n),
    /**
     * **调试/自检专用**：清空背包，**但不往世界里丢**。
     *
     * ★ 为什么不能直接用"整堆丢弃"来清空：`dropIntoWorld` 会把东西丢在玩家脚下，
     *   而后面还有"拾取进包"的判据 —— 清空产生的 5 堆垃圾会被它们捡走，
     *   于是"背包 53→52→54"（多捡了一份）。判据之间的**共享可变世界**就是靠
     *   "别留下副作用"来隔离的；需要副作用的地方，就该给一个没有副作用的入口。
     * ★ 只删物品节点，不碰世界、不碰玩家。
     */
    clearBag: () => {
      if (heroId < 0) return 0;
      const stacks = stacksOf(scene, heroId);
      let n = 0;
      for (const s of stacks) {
        const node = s.node;
        if (node === null || node === void 0) continue;
        scene.destroy(node.id);
        n++;
      }
      scene.flush();
      return n;
    },
    /**
     * 表现层（批69，自检页用）。
     *
     * ★ 这里返回的是**屏幕上的事实**（DOM 里几个数字、精灵现在什么颜色），
     *   不是"我调过 flash 所以应该闪了"。前者能抓住"调了但没接到渲染"，
     *   后者只能证明函数被调用过（批66 的 `firstIndex` 就是这么假绿的）。
     */
    feedback: {
      /** 屏幕上还活着的伤害数字（`[{text, dead, opacity, by}]`，空数组 = 都消失了）。 */
      numbers: () => damageNumbers.map((d) => ({ text: d.text, dead: d.dead, opacity: d.el.style.opacity, by: d.by })),
      /**
       * DOM 里真的有这么多 `.dmg` 元素（与上面的数组**分开**：一个对、一个错就是漏删）。
       * ★ `by` 可选（批74）：只数某个攻击者冒的数字。生物打斗也在冒数字，
       *   不区分来源的话"数字会消失"在打斗窗口里永远等不到 0。
       */
      domCount: (by) => by === void 0 ? fxLayer.querySelectorAll(".dmg").length : fxLayer.querySelectorAll(`.dmg[data-dmg-by="${String(by)}"]`).length,
      /** 某个节点现在是不是在闪（读组件字段，不是读"我记得调过"）。 */
      flashing: (id) => {
        const fb = scene.find(id)?.get(FEEDBACK_TYPE);
        return fb === void 0 ? -1 : fb.flashTicks;
      },
      /** 累计：表现层自己吞掉的错误码（正常时为空数组）。 */
      errors: () => [...feedbackErrors],
      /** 闪一下（自检页需要在**不打架**的情况下验"闪完会还原"）。 */
      flash: (id, ticks) => {
        const r = flash(scene, id, ticks);
        return r.ok ? r.value.remaining : `${r.error.code}\uFF1A${r.error.message}`;
      },
      /** 精灵现在乘的是什么色（验"闪的是红、还原回原色"）。 */
      tint: (id) => {
        const sp2 = scene.find(id)?.get(SPRITE_TYPE);
        return sp2 === void 0 ? null : { r: sp2.r, g: sp2.g, b: sp2.b, a: sp2.a };
      },
      /** 模块统计（闪几个/挤几个/还原几次/覆盖几次）。 */
      stats: () => feedbackMod.stats,
      /**
       * **调试/自检专用**：在玩家旁边放一个 2 血的靶子（有血量、有精灵、无 AI）。
       *
       * ★ 为什么需要它：验"屏幕上的数字是不是**实际扣血**"必须让
       *   `applied ≠ attacker.damage`（玩家伤害 3、靶子 2 血 ⇒ 应该显示 -2）。
       *   而世界里的生物血量都是满的，那两条数永远相等 —— 那种语料下
       *   "用 damage 还是 applied"是分不出来的。
       * ★ 它不改玩家状态、不碰背包，所以它证的仍然是"命中这一侧"。
       */
      dummy: (hp = 2) => {
        if (heroId < 0) return -1;
        const hero = scene.find(heroId);
        if (hero === void 0) return -1;
        const p = hero.worldPosition;
        const n = scene.spawnAt(`\u9776\u5B50\xD7${String(hp)}\u8840`, p.x + 1, p.y);
        if (!n.ok) return -1;
        const id = n.value.id;
        const h = new Health();
        h.maxHp = hp;
        h.hp = hp;
        scene.attach(id, () => h);
        scene.attach(id, () => makeSprite("rabbit", 1, 1));
        scene.flush();
        return id;
      }
    },
    /**
     * 导航网格（批60，自检页用）。
     * ★ 自检只验两件**浏览器里才可能坏**的事：网格真的建起来了、两次寻路逐格相同。
     *   寻路算法本身对不对由 Node 判据 + 变异管，这里不重复。
     */
    nav: {
      stats: () => {
        const g = worldState.nav;
        if (g === null) return null;
        const st = g.stats();
        return {
          width: st.width,
          height: st.height,
          walkable: st.walkable,
          blocked: st.blocked,
          components: g.componentCount
        };
      },
      isWalkable: (cell) => worldState.nav?.isWalkableIndex(cell) ?? false,
      /** 不抛：返回 `{ok:true,cells,cost}` 或 `{ok:false,code}`。 */
      path: (from, to) => {
        const g = worldState.nav;
        if (g === null) return { ok: false, code: "NAV.NO_GRID" };
        const r = g.findPath(from, to);
        if (!r.ok) return { ok: false, code: r.error.code };
        return { ok: true, cells: r.value.cells.slice(), cost: r.value.cost };
      }
    },
    /** 背包面板状态（自检页读 UI 之前先读它：开着没有、选中第几堆）。 */
    bagPanel: () => ({ open: bagOpen, selected: bagSel, stacks: stacksOf(scene, heroId).length }),
    /** 开关面板（自检页驱动；等价于按 Tab）。 */
    toggleBag: () => {
      setBagOpen(!bagOpen);
      return bagOpen;
    },
    /** 选中第 i 堆（自检页驱动；等价于按数字键）。 */
    selectStack: (i) => selectBagRow(i),
    /** 丢弃选中堆（自检页驱动；等价于按 Q，`whole` = 按住 Shift）。 */
    dropSelected: (whole = false) => {
      const r = dropSelected(whole);
      return r.ok ? { ok: true, value: r.value } : { ok: false, code: r.error.code, message: r.error.message };
    },
    /** 当前操作提示（**从映射表生成**，改键后它自己会变）。 */
    helpText: () => helpText(),
    /** 动作名 → 键位（改键界面的数据源，也是"提示与键位同源"的证据）。 */
    bindings: () => ({ ...controllerMod.map.toData().actions }),
    /** 最近一帧的 HUD 一行文本（**UI 路径下 DOM 不再更新**，诊断与降级都读这里）。 */
    hudText: () => lastHudText,
    /**
     * 图形后端的帧计数（`frameIndex` **每次 `endFrame` 加一**）。
     *
     * ★★ 自检页用它证"UI 与世界在**同一个 pass**"：一帧里若 UI 自己开了第二个
     *   `beginFrame/endFrame`，`frameIndex` 会跳 2。这是这条集成约定**唯一**
     *   能从外部观测到的证据 —— 顶点和 draw call 都看不出"在不在同一个 pass 里"。
     */
    gfxStats: () => app.platform.gfx.stats,
    /** 累计渲染帧数（引擎侧计数）。与 `gfxStats().frameIndex` 对账 ⇒ 一帧几个 pass。 */
    renderFrames: () => renderFrames,
    /**
     * UI（批71）。`null` = UI 资产不可用，HUD 已退回 DOM。
     *
     * ★ 这里给的必须是**屏幕上的事实**：这一帧真画了多少 quad/字形、
     *   有没有画不出来的字、面板的行文本是什么、点一下会发生什么。
     *   "我建了 UI 模块"不能当证据 —— 它和"UI 真的画出来了"是两件事。
     */
    ui: hudUi === null ? null : {
      lastFrame: () => hudUi.module.lastFrame,
      /** 设计坐标里的节点矩形（`null` = 不可见/没这个 id）。 */
      rect: (id) => rectOfId(hudUi, id) ?? null,
      /**
       * 节点的动画属性（批76 判据用）：过渡到底有没有真的改到节点上。
       * ★ 只暴露"节点自己存的值"，不在这里乘父链 —— 判据读到的东西
       *   必须与 `applyUiTween` 写进去的是同一个量，否则断言的是另一个数。
       */
      anim: (id) => {
        const n = hudUi.module.root.find(id);
        return n === void 0 ? null : { opacity: n.opacity, scale: n.scale, x: n.offset.x, y: n.offset.y };
      },
      /** 面板里**画出来的**行文本（不是重新算一遍的那份）。 */
      bagRows: () => hudUi.bagRowTexts.slice(),
      bagOpen: () => hudUi.bagOpen,
      hudRowIds: hudUi.hudRowIds,
      /** 设计坐标（自检页验"点击命中真实矩形"时用）。 */
      designSize: () => ({ w: hudUi.module.viewport.designWidth, h: hudUi.module.viewport.designHeight }),
      /**
       * 点一下某个节点：走**真实指针路径**（设计坐标 → CSS 像素 → 命中测试 → click）。
       * 直接改 `bagSel` 只能证明"赋值有效"，证明不了"面板上的行点得到"。
       */
      clickNode: (id) => {
        hudUi.module.relayout();
        const r = rectOfId(hudUi, id);
        if (r === void 0) return { ok: false, reason: "NO_RECT", clicks: [] };
        const s = hudUi.module.viewport.designToScreen(r.x + r.width / 2, r.y + r.height / 2);
        hudUi.pointer(s.x, s.y, true);
        const evs = hudUi.pointer(s.x, s.y, false);
        return {
          ok: true,
          reason: "",
          clicks: evs.filter((e) => e.type === "click").map((e) => e.target.id)
        };
      }
    }
  };
}
void main();
export {
  main
};
