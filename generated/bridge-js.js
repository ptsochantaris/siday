// NOTICE: This is auto-generated code by BridgeJS from JavaScriptKit,
// DO NOT EDIT.
//
// To update this file, just rebuild your project or run
// `swift package bridge-js`.

export const JSCompositeOperationValues = {
    Replace: "replace",
    Add: "add",
    Accumulate: "accumulate",
};

export const JSFillModeValues = {
    None: "none",
    Forwards: "forwards",
    Backwards: "backwards",
    Both: "both",
    Auto: "auto",
};

export async function createInstantiator(options, swift) {
    let instance;
    let memory;
    let setException;
    let decodeString;
    const textDecoder = new TextDecoder("utf-8");
    const textEncoder = new TextEncoder("utf-8");
    let tmpRetString;
    let tmpRetBytes;
    let tmpRetException;
    let tmpRetOptionalBool;
    let tmpRetOptionalInt;
    let tmpRetOptionalFloat;
    let tmpRetOptionalDouble;
    let tmpRetOptionalHeapObject;
    let strStack = [];
    let i32Stack = [];
    let i64Stack = [];
    let f32Stack = [];
    let f64Stack = [];
    let ptrStack = [];
    let taStack = [];
    const enumHelpers = {};
    const structHelpers = {};

    let _exports = null;
    let bjs = null;
    const __bjs_arrayCodecCache = new WeakMap();
    function __bjs_arrayCodec(elementCodec) {
        let codec = __bjs_arrayCodecCache.get(elementCodec);
        if (codec !== undefined) {
            return codec;
        }
        codec = {
            lower(value) {
                for (let i = 0; i < value.length; i++) {
                    elementCodec.lower(value[i]);
                }
                i32Stack.push(value.length);
            },
            lift() {
                const count = i32Stack.pop();
                if (count === -1) {
                    return taStack.pop();
                }
                const result = new Array(count);
                for (let i = count - 1; i >= 0; i--) {
                    result[i] = elementCodec.lift();
                }
                return result;
            },
        };
        __bjs_arrayCodecCache.set(elementCodec, codec);
        return codec;
    }
    const __bjs_optionalCodecCache = new WeakMap();
    const __bjs_optionalCodecUndefinedOrCache = new WeakMap();
    function __bjs_optionalCodec(elementCodec, isUndefinedOr = false) {
        const cache = isUndefinedOr ? __bjs_optionalCodecUndefinedOrCache : __bjs_optionalCodecCache;
        let codec = cache.get(elementCodec);
        if (codec !== undefined) {
            return codec;
        }
        codec = {
            lower(value) {
                const isSome = isUndefinedOr ? value !== undefined : value != null;
                if (isSome) {
                    elementCodec.lower(value);
                    i32Stack.push(1);
                } else {
                    i32Stack.push(0);
                }
            },
            lift() {
                if (i32Stack.pop() === 0) {
                    return isUndefinedOr ? undefined : null;
                }
                return elementCodec.lift();
            },
        };
        cache.set(elementCodec, codec);
        return codec;
    }
    const __bjs_dictCodecCache = new WeakMap();
    function __bjs_dictCodec(valueCodec) {
        let codec = __bjs_dictCodecCache.get(valueCodec);
        if (codec !== undefined) {
            return codec;
        }
        codec = {
            lower(value) {
                const keys = Object.keys(value);
                for (let i = 0; i < keys.length; i++) {
                    __bjs_stringCodec.lower(keys[i]);
                    valueCodec.lower(value[keys[i]]);
                }
                i32Stack.push(keys.length);
            },
            lift() {
                const count = i32Stack.pop();
                const result = {};
                for (let i = 0; i < count; i++) {
                    const value = valueCodec.lift();
                    const key = __bjs_stringCodec.lift();
                    result[key] = value;
                }
                return result;
            },
        };
        __bjs_dictCodecCache.set(valueCodec, codec);
        return codec;
    }

    const __bjs_stringCodec = {
        lower: (v) => {
            const bytes = textEncoder.encode(v);
            const id = swift.memory.retain(bytes);
            i32Stack.push(bytes.length);
            i32Stack.push(id);
        },
        lift: () => {
            const string = strStack.pop();
            return string;
        },
    };
    const __bjs_primitiveCodecs = {
        Bool: {
            lower: (v) => {
                i32Stack.push(v ? 1 : 0);
            },
            lift: () => {
                const bool = i32Stack.pop() !== 0;
                return bool;
            },
        },
        Int: {
            lower: (v) => {
                i32Stack.push((v | 0));
            },
            lift: () => {
                const int = i32Stack.pop();
                return int;
            },
        },
        Int8: {
            lower: (v) => {
                i32Stack.push((v | 0));
            },
            lift: () => {
                const int = i32Stack.pop();
                return int;
            },
        },
        UInt8: {
            lower: (v) => {
                i32Stack.push((v | 0));
            },
            lift: () => {
                const int = i32Stack.pop() >>> 0;
                return int;
            },
        },
        Int16: {
            lower: (v) => {
                i32Stack.push((v | 0));
            },
            lift: () => {
                const int = i32Stack.pop();
                return int;
            },
        },
        UInt16: {
            lower: (v) => {
                i32Stack.push((v | 0));
            },
            lift: () => {
                const int = i32Stack.pop() >>> 0;
                return int;
            },
        },
        Int32: {
            lower: (v) => {
                i32Stack.push((v | 0));
            },
            lift: () => {
                const int = i32Stack.pop();
                return int;
            },
        },
        UInt32: {
            lower: (v) => {
                i32Stack.push((v | 0));
            },
            lift: () => {
                const int = i32Stack.pop() >>> 0;
                return int;
            },
        },
        UInt: {
            lower: (v) => {
                i32Stack.push((v | 0));
            },
            lift: () => {
                const int = i32Stack.pop() >>> 0;
                return int;
            },
        },
        Int64: {
            lower: (v) => {
                i64Stack.push(v);
            },
            lift: () => {
                const int = i64Stack.pop();
                return int;
            },
        },
        UInt64: {
            lower: (v) => {
                i64Stack.push(v);
            },
            lift: () => {
                const int = i64Stack.pop();
                return int;
            },
        },
        Float: {
            lower: (v) => {
                f32Stack.push(Math.fround(v));
            },
            lift: () => {
                const f32 = f32Stack.pop();
                return f32;
            },
        },
        Double: {
            lower: (v) => {
                f64Stack.push(v);
            },
            lift: () => {
                const f64 = f64Stack.pop();
                return f64;
            },
        },
        String: __bjs_stringCodec,
        JSValue: {
            lower: (v) => {
                const [vKind, vPayload1, vPayload2] = __bjs_jsValueLower(v);
                i32Stack.push(vKind);
                i32Stack.push(vPayload1);
                f64Stack.push(vPayload2);
            },
            lift: () => {
                const jsValuePayload2 = f64Stack.pop();
                const jsValuePayload1 = i32Stack.pop();
                const jsValueKind = i32Stack.pop();
                const jsValue = __bjs_jsValueLift(jsValueKind, jsValuePayload1, jsValuePayload2);
                return jsValue;
            },
        },
    };

    function __bjs_jsValueLower(value) {
        let kind;
        let payload1;
        let payload2;
        if (value === null) {
            kind = 4;
            payload1 = 0;
            payload2 = 0;
        } else {
            switch (typeof value) {
                case "boolean":
                    kind = 0;
                    payload1 = value ? 1 : 0;
                    payload2 = 0;
                    break;
                case "number":
                    kind = 2;
                    payload1 = 0;
                    payload2 = value;
                    break;
                case "string":
                    kind = 1;
                    payload1 = swift.memory.retain(value);
                    payload2 = 0;
                    break;
                case "undefined":
                    kind = 5;
                    payload1 = 0;
                    payload2 = 0;
                    break;
                case "object":
                    kind = 3;
                    payload1 = swift.memory.retain(value);
                    payload2 = 0;
                    break;
                case "function":
                    kind = 3;
                    payload1 = swift.memory.retain(value);
                    payload2 = 0;
                    break;
                case "symbol":
                    kind = 7;
                    payload1 = swift.memory.retain(value);
                    payload2 = 0;
                    break;
                case "bigint":
                    kind = 8;
                    payload1 = swift.memory.retain(value);
                    payload2 = 0;
                    break;
                default:
                    throw new TypeError("Unsupported JSValue type");
            }
        }
        return [kind, payload1, payload2];
    }
    function __bjs_jsValueLift(kind, payload1, payload2) {
        let jsValue;
        switch (kind) {
            case 0:
                jsValue = payload1 !== 0;
                break;
            case 1:
                jsValue = swift.memory.getObject(payload1);
                break;
            case 2:
                jsValue = payload2;
                break;
            case 3:
                jsValue = swift.memory.getObject(payload1);
                break;
            case 4:
                jsValue = null;
                break;
            case 5:
                jsValue = undefined;
                break;
            case 7:
                jsValue = swift.memory.getObject(payload1);
                break;
            case 8:
                jsValue = swift.memory.getObject(payload1);
                break;
            default:
                throw new TypeError("Unsupported JSValue kind " + kind);
        }
        return jsValue;
    }

    const swiftClosureRegistry = (typeof FinalizationRegistry === "undefined") ? { register: () => {}, unregister: () => {} } : new FinalizationRegistry((state) => {
        if (state.unregistered) { return; }
        instance?.exports?.bjs_release_swift_closure(state.pointer);
    });
    const makeClosure = (pointer, file, line, func) => {
        const state = { pointer, file, line, unregistered: false };
        const real = (...args) => {
            if (state.unregistered) {
                const bytes = new Uint8Array(memory.buffer, state.file >>> 0);
                let length = 0;
                while (bytes[length] !== 0) { length += 1; }
                const fileID = decodeString(state.file, length);
                throw new Error(`Attempted to call a released JSTypedClosure created at ${fileID}:${state.line}`);
            }
            return func(...args);
        };
        real.__unregister = () => {
            if (state.unregistered) { return; }
            state.unregistered = true;
            swiftClosureRegistry.unregister(state);
        };
        swiftClosureRegistry.register(real, state, state);
        return swift.memory.retain(real);
    };

    const __bjs_codec_Array_Double = __bjs_arrayCodec(__bjs_primitiveCodecs.Double);

    const __bjs_createStructHelpers_M14BrowserInteropT23JSKeyframeEffectOptions = () => ({
        lower: (value) => {
            i32Stack.push((value.duration | 0));
            const bytes = textEncoder.encode(value.fill);
            const id = swift.memory.retain(bytes);
            i32Stack.push(bytes.length);
            i32Stack.push(id);
            const bytes1 = textEncoder.encode(value.composite);
            const id1 = swift.memory.retain(bytes1);
            i32Stack.push(bytes1.length);
            i32Stack.push(id1);
        },
        lift: () => {
            const rawValue = strStack.pop();
            const rawValue1 = strStack.pop();
            const int = i32Stack.pop();
            return { duration: int, fill: rawValue1, composite: rawValue };
        }
    });
    const __bjs_createStructHelpers_M14BrowserInteropT17JSAnimationTiming = () => ({
        lower: (value) => {
            i32Stack.push((value.duration | 0));
        },
        lift: () => {
            const int = i32Stack.pop();
            return { duration: int };
        }
    });

    return {
        /**
         * @param {WebAssembly.Imports} importObject
         */
        addImports: (importObject, importsContext) => {
            bjs = {};
            importObject["bjs"] = bjs;
            bjs["swift_js_return_string"] = function(ptr, len) {
                tmpRetString = decodeString(ptr, len);
            }
            bjs["swift_js_init_memory"] = function(sourceId, bytesPtr) {
                const source = swift.memory.getObject(sourceId);
                swift.memory.release(sourceId);
                const bytes = new Uint8Array(memory.buffer, bytesPtr >>> 0);
                bytes.set(source);
            }
            bjs["swift_js_make_js_string"] = function(ptr, len) {
                return swift.memory.retain(decodeString(ptr, len));
            }
            bjs["swift_js_init_memory_with_result"] = function(ptr, len) {
                const target = new Uint8Array(memory.buffer, ptr >>> 0, len >>> 0);
                target.set(tmpRetBytes);
                tmpRetBytes = undefined;
            }
            bjs["swift_js_throw"] = function(id) {
                tmpRetException = swift.memory.retainByRef(id);
            }
            bjs["swift_js_retain"] = function(id) {
                return swift.memory.retainByRef(id);
            }
            bjs["swift_js_release"] = function(id) {
                swift.memory.release(id);
            }
            bjs["swift_js_push_i32"] = function(v) {
                i32Stack.push(v | 0);
            }
            bjs["swift_js_push_f32"] = function(v) {
                f32Stack.push(Math.fround(v));
            }
            bjs["swift_js_push_f64"] = function(v) {
                f64Stack.push(v);
            }
            bjs["swift_js_push_string"] = function(ptr, len) {
                const value = decodeString(ptr, len);
                strStack.push(value);
            }
            bjs["swift_js_pop_i32"] = function() {
                return i32Stack.pop();
            }
            bjs["swift_js_pop_f32"] = function() {
                return f32Stack.pop();
            }
            bjs["swift_js_pop_f64"] = function() {
                return f64Stack.pop();
            }
            bjs["swift_js_push_pointer"] = function(pointer) {
                ptrStack.push(pointer);
            }
            bjs["swift_js_pop_pointer"] = function() {
                return ptrStack.pop();
            }
            bjs["swift_js_push_i64"] = function(v) {
                i64Stack.push(v);
            }
            bjs["swift_js_pop_i64"] = function() {
                return i64Stack.pop();
            }
            const taCtors = [Int8Array, Uint8Array, Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array];
            bjs["swift_js_push_typed_array"] = function(kind, ptr, count) {
                const Ctor = taCtors[kind];
                const byteLen = count * Ctor.BYTES_PER_ELEMENT;
                const copy = memory.buffer.slice(ptr, ptr + byteLen);
                taStack.push(Array.from(new Ctor(copy)));
            }
            bjs["swift_js_struct_lower_JSKeyframeEffectOptions"] = function(objectId) {
                structHelpers.M14BrowserInteropT23JSKeyframeEffectOptions.lower(swift.memory.getObject(objectId));
            }
            bjs["swift_js_struct_lift_JSKeyframeEffectOptions"] = function() {
                const value = structHelpers.M14BrowserInteropT23JSKeyframeEffectOptions.lift();
                return swift.memory.retain(value);
            }
            bjs["swift_js_struct_lower_JSAnimationTiming"] = function(objectId) {
                structHelpers.M14BrowserInteropT17JSAnimationTiming.lower(swift.memory.getObject(objectId));
            }
            bjs["swift_js_struct_lift_JSAnimationTiming"] = function() {
                const value = structHelpers.M14BrowserInteropT17JSAnimationTiming.lift();
                return swift.memory.retain(value);
            }
            bjs["bjs_core_register_type_handles"] = function() {};
            bjs["bjs_BrowserInterop_register_type_handles"] = function() {};
            const __bjs_promiseSettlers = Symbol("JavaScriptKit.promiseSettlers");
            bjs["swift_js_make_promise"] = function() {
                let resolve, reject;
                const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
                promise[__bjs_promiseSettlers] = { resolve, reject };
                return swift.memory.retain(promise);
            }
            bjs["swift_js_return_optional_bool"] = function(isSome, value) {
                if (isSome === 0) {
                    tmpRetOptionalBool = null;
                } else {
                    tmpRetOptionalBool = value !== 0;
                }
            }
            bjs["swift_js_return_optional_int"] = function(isSome, value) {
                if (isSome === 0) {
                    tmpRetOptionalInt = null;
                } else {
                    tmpRetOptionalInt = value | 0;
                }
            }
            bjs["swift_js_return_optional_float"] = function(isSome, value) {
                if (isSome === 0) {
                    tmpRetOptionalFloat = null;
                } else {
                    tmpRetOptionalFloat = Math.fround(value);
                }
            }
            bjs["swift_js_return_optional_double"] = function(isSome, value) {
                if (isSome === 0) {
                    tmpRetOptionalDouble = null;
                } else {
                    tmpRetOptionalDouble = value;
                }
            }
            bjs["swift_js_return_optional_string"] = function(isSome, ptr, len) {
                if (isSome === 0) {
                    tmpRetString = null;
                } else {
                    tmpRetString = decodeString(ptr, len);
                }
            }
            bjs["swift_js_return_optional_object"] = function(isSome, objectId) {
                if (isSome === 0) {
                    tmpRetString = null;
                } else {
                    tmpRetString = swift.memory.getObject(objectId);
                }
            }
            bjs["swift_js_return_optional_heap_object"] = function(isSome, pointer) {
                if (isSome === 0) {
                    tmpRetOptionalHeapObject = null;
                } else {
                    tmpRetOptionalHeapObject = pointer;
                }
            }
            bjs["swift_js_get_optional_int_presence"] = function() {
                return tmpRetOptionalInt != null ? 1 : 0;
            }
            bjs["swift_js_get_optional_int_value"] = function() {
                const value = tmpRetOptionalInt;
                tmpRetOptionalInt = undefined;
                return value;
            }
            bjs["swift_js_get_optional_string"] = function() {
                const str = tmpRetString;
                tmpRetString = undefined;
                if (str == null) {
                    return -1;
                } else {
                    const bytes = textEncoder.encode(str);
                    tmpRetBytes = bytes;
                    return bytes.length;
                }
            }
            bjs["swift_js_get_optional_float_presence"] = function() {
                return tmpRetOptionalFloat != null ? 1 : 0;
            }
            bjs["swift_js_get_optional_float_value"] = function() {
                const value = tmpRetOptionalFloat;
                tmpRetOptionalFloat = undefined;
                return value;
            }
            bjs["swift_js_get_optional_double_presence"] = function() {
                return tmpRetOptionalDouble != null ? 1 : 0;
            }
            bjs["swift_js_get_optional_double_value"] = function() {
                const value = tmpRetOptionalDouble;
                tmpRetOptionalDouble = undefined;
                return value;
            }
            bjs["swift_js_get_optional_heap_object_pointer"] = function() {
                const pointer = tmpRetOptionalHeapObject;
                tmpRetOptionalHeapObject = undefined;
                return pointer || 0;
            }
            bjs["swift_js_closure_unregister"] = function(funcRef) {}
            bjs["swift_js_closure_unregister"] = function(funcRef) {
                const func = swift.memory.getObject(funcRef);
                func.__unregister();
            }
            bjs["invoke_js_callback_SidayWeb_8SidayWebSS_Sb"] = function(callbackId, param0Bytes, param0Count) {
                try {
                    const callback = swift.memory.getObject(callbackId);
                    const string = decodeString(param0Bytes, param0Count);
                    let ret = callback(string);
                    return ret ? 1 : 0;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            bjs["make_swift_closure_SidayWeb_8SidayWebSS_Sb"] = function(boxPtr, file, line) {
                const lower_closure_SidayWeb_8SidayWebSS_Sb = function(param0) {
                    const param0Bytes = textEncoder.encode(param0);
                    const param0Id = swift.memory.retain(param0Bytes);
                    const ret = instance.exports.invoke_swift_closure_SidayWeb_8SidayWebSS_Sb(boxPtr, param0Id, param0Bytes.length);
                    if (tmpRetException) {
                        const error = swift.memory.getObject(tmpRetException);
                        swift.memory.release(tmpRetException);
                        tmpRetException = undefined;
                        throw error;
                    }
                    return ret !== 0;
                };
                return makeClosure(boxPtr, file, line, lower_closure_SidayWeb_8SidayWebSS_Sb);
            }
            bjs["invoke_js_callback_SidayWeb_8SidayWebSS_y"] = function(callbackId, param0Bytes, param0Count) {
                try {
                    const callback = swift.memory.getObject(callbackId);
                    const string = decodeString(param0Bytes, param0Count);
                    callback(string);
                } catch (error) {
                    setException(error);
                }
            }
            bjs["make_swift_closure_SidayWeb_8SidayWebSS_y"] = function(boxPtr, file, line) {
                const lower_closure_SidayWeb_8SidayWebSS_y = function(param0) {
                    const param0Bytes = textEncoder.encode(param0);
                    const param0Id = swift.memory.retain(param0Bytes);
                    instance.exports.invoke_swift_closure_SidayWeb_8SidayWebSS_y(boxPtr, param0Id, param0Bytes.length);
                    if (tmpRetException) {
                        const error = swift.memory.getObject(tmpRetException);
                        swift.memory.release(tmpRetException);
                        tmpRetException = undefined;
                        throw error;
                    }
                };
                return makeClosure(boxPtr, file, line, lower_closure_SidayWeb_8SidayWebSS_y);
            }
            bjs["invoke_js_callback_SidayWeb_8SidayWebSbSSSiSiSd_y"] = function(callbackId, param0, param1Bytes, param1Count, param2, param3, param4) {
                try {
                    const callback = swift.memory.getObject(callbackId);
                    const string = decodeString(param1Bytes, param1Count);
                    callback(param0 !== 0, string, param2, param3, param4);
                } catch (error) {
                    setException(error);
                }
            }
            bjs["make_swift_closure_SidayWeb_8SidayWebSbSSSiSiSd_y"] = function(boxPtr, file, line) {
                const lower_closure_SidayWeb_8SidayWebSbSSSiSiSd_y = function(param0, param1, param2, param3, param4) {
                    const param1Bytes = textEncoder.encode(param1);
                    const param1Id = swift.memory.retain(param1Bytes);
                    instance.exports.invoke_swift_closure_SidayWeb_8SidayWebSbSSSiSiSd_y(boxPtr, param0, param1Id, param1Bytes.length, param2, param3, param4);
                    if (tmpRetException) {
                        const error = swift.memory.getObject(tmpRetException);
                        swift.memory.release(tmpRetException);
                        tmpRetException = undefined;
                        throw error;
                    }
                };
                return makeClosure(boxPtr, file, line, lower_closure_SidayWeb_8SidayWebSbSSSiSiSd_y);
            }
            bjs["invoke_js_callback_SidayWeb_8SidayWebSdSaSdSi_y"] = function(callbackId, param0, param2) {
                try {
                    const callback = swift.memory.getObject(callbackId);
                    const arrayResult = __bjs_codec_Array_Double.lift();
                    callback(param0, arrayResult, param2);
                } catch (error) {
                    setException(error);
                }
            }
            bjs["make_swift_closure_SidayWeb_8SidayWebSdSaSdSi_y"] = function(boxPtr, file, line) {
                const lower_closure_SidayWeb_8SidayWebSdSaSdSi_y = function(param0, param1, param2) {
                    __bjs_codec_Array_Double.lower(param1);
                    instance.exports.invoke_swift_closure_SidayWeb_8SidayWebSdSaSdSi_y(boxPtr, param0, param2);
                    if (tmpRetException) {
                        const error = swift.memory.getObject(tmpRetException);
                        swift.memory.release(tmpRetException);
                        tmpRetException = undefined;
                        throw error;
                    }
                };
                return makeClosure(boxPtr, file, line, lower_closure_SidayWeb_8SidayWebSdSaSdSi_y);
            }
            bjs["invoke_js_callback_SidayWeb_8SidayWebSdSb_y"] = function(callbackId, param0, param1) {
                try {
                    const callback = swift.memory.getObject(callbackId);
                    callback(param0, param1 !== 0);
                } catch (error) {
                    setException(error);
                }
            }
            bjs["make_swift_closure_SidayWeb_8SidayWebSdSb_y"] = function(boxPtr, file, line) {
                const lower_closure_SidayWeb_8SidayWebSdSb_y = function(param0, param1) {
                    instance.exports.invoke_swift_closure_SidayWeb_8SidayWebSdSb_y(boxPtr, param0, param1);
                    if (tmpRetException) {
                        const error = swift.memory.getObject(tmpRetException);
                        swift.memory.release(tmpRetException);
                        tmpRetException = undefined;
                        throw error;
                    }
                };
                return makeClosure(boxPtr, file, line, lower_closure_SidayWeb_8SidayWebSdSb_y);
            }
            bjs["invoke_js_callback_SidayWeb_8SidayWebSdSdSd_y"] = function(callbackId, param0, param1, param2) {
                try {
                    const callback = swift.memory.getObject(callbackId);
                    callback(param0, param1, param2);
                } catch (error) {
                    setException(error);
                }
            }
            bjs["make_swift_closure_SidayWeb_8SidayWebSdSdSd_y"] = function(boxPtr, file, line) {
                const lower_closure_SidayWeb_8SidayWebSdSdSd_y = function(param0, param1, param2) {
                    instance.exports.invoke_swift_closure_SidayWeb_8SidayWebSdSdSd_y(boxPtr, param0, param1, param2);
                    if (tmpRetException) {
                        const error = swift.memory.getObject(tmpRetException);
                        swift.memory.release(tmpRetException);
                        tmpRetException = undefined;
                        throw error;
                    }
                };
                return makeClosure(boxPtr, file, line, lower_closure_SidayWeb_8SidayWebSdSdSd_y);
            }
            bjs["invoke_js_callback_SidayWeb_8SidayWebSdSd_y"] = function(callbackId, param0, param1) {
                try {
                    const callback = swift.memory.getObject(callbackId);
                    callback(param0, param1);
                } catch (error) {
                    setException(error);
                }
            }
            bjs["make_swift_closure_SidayWeb_8SidayWebSdSd_y"] = function(boxPtr, file, line) {
                const lower_closure_SidayWeb_8SidayWebSdSd_y = function(param0, param1) {
                    instance.exports.invoke_swift_closure_SidayWeb_8SidayWebSdSd_y(boxPtr, param0, param1);
                    if (tmpRetException) {
                        const error = swift.memory.getObject(tmpRetException);
                        swift.memory.release(tmpRetException);
                        tmpRetException = undefined;
                        throw error;
                    }
                };
                return makeClosure(boxPtr, file, line, lower_closure_SidayWeb_8SidayWebSdSd_y);
            }
            bjs["invoke_js_callback_SidayWeb_8SidayWeby_y"] = function(callbackId) {
                try {
                    const callback = swift.memory.getObject(callbackId);
                    callback();
                } catch (error) {
                    setException(error);
                }
            }
            bjs["make_swift_closure_SidayWeb_8SidayWeby_y"] = function(boxPtr, file, line) {
                const lower_closure_SidayWeb_8SidayWeby_y = function() {
                    instance.exports.invoke_swift_closure_SidayWeb_8SidayWeby_y(boxPtr);
                    if (tmpRetException) {
                        const error = swift.memory.getObject(tmpRetException);
                        swift.memory.release(tmpRetException);
                        tmpRetException = undefined;
                        throw error;
                    }
                };
                return makeClosure(boxPtr, file, line, lower_closure_SidayWeb_8SidayWeby_y);
            }
            bjs["swift_js_closure_unregister"] = function(funcRef) {
                const func = swift.memory.getObject(funcRef);
                func.__unregister();
            }
            bjs["invoke_js_callback_BrowserInterop_14BrowserInterop7JSEventC_y"] = function(callbackId, param0) {
                try {
                    const callback = swift.memory.getObject(callbackId);
                    callback(swift.memory.getObject(param0));
                } catch (error) {
                    setException(error);
                }
            }
            bjs["make_swift_closure_BrowserInterop_14BrowserInterop7JSEventC_y"] = function(boxPtr, file, line) {
                const lower_closure_BrowserInterop_14BrowserInterop7JSEventC_y = function(param0) {
                    instance.exports.invoke_swift_closure_BrowserInterop_14BrowserInterop7JSEventC_y(boxPtr, swift.memory.retain(param0));
                    if (tmpRetException) {
                        const error = swift.memory.getObject(tmpRetException);
                        swift.memory.release(tmpRetException);
                        tmpRetException = undefined;
                        throw error;
                    }
                };
                return makeClosure(boxPtr, file, line, lower_closure_BrowserInterop_14BrowserInterop7JSEventC_y);
            }
            bjs["invoke_js_callback_BrowserInterop_14BrowserInteropSd_y"] = function(callbackId, param0) {
                try {
                    const callback = swift.memory.getObject(callbackId);
                    callback(param0);
                } catch (error) {
                    setException(error);
                }
            }
            bjs["make_swift_closure_BrowserInterop_14BrowserInteropSd_y"] = function(boxPtr, file, line) {
                const lower_closure_BrowserInterop_14BrowserInteropSd_y = function(param0) {
                    instance.exports.invoke_swift_closure_BrowserInterop_14BrowserInteropSd_y(boxPtr, param0);
                    if (tmpRetException) {
                        const error = swift.memory.getObject(tmpRetException);
                        swift.memory.release(tmpRetException);
                        tmpRetException = undefined;
                        throw error;
                    }
                };
                return makeClosure(boxPtr, file, line, lower_closure_BrowserInterop_14BrowserInteropSd_y);
            }
            bjs["invoke_js_callback_BrowserInterop_14BrowserInteropy_y"] = function(callbackId) {
                try {
                    const callback = swift.memory.getObject(callbackId);
                    callback();
                } catch (error) {
                    setException(error);
                }
            }
            bjs["make_swift_closure_BrowserInterop_14BrowserInteropy_y"] = function(boxPtr, file, line) {
                const lower_closure_BrowserInterop_14BrowserInteropy_y = function() {
                    instance.exports.invoke_swift_closure_BrowserInterop_14BrowserInteropy_y(boxPtr);
                    if (tmpRetException) {
                        const error = swift.memory.getObject(tmpRetException);
                        swift.memory.release(tmpRetException);
                        tmpRetException = undefined;
                        throw error;
                    }
                };
                return makeClosure(boxPtr, file, line, lower_closure_BrowserInterop_14BrowserInteropy_y);
            }
            const SidayWeb = importObject["SidayWeb"] = importObject["SidayWeb"] || {};
            SidayWeb["bjs_sidayListen"] = function bjs_sidayListen(accepts, added, loaded, progress, rendered, ended, held, pointed, scrolled, frame) {
                try {
                    globalThis.sidayListen(swift.memory.getObject(accepts), swift.memory.getObject(added), swift.memory.getObject(loaded), swift.memory.getObject(progress), swift.memory.getObject(rendered), swift.memory.getObject(ended), swift.memory.getObject(held), swift.memory.getObject(pointed), swift.memory.getObject(scrolled), swift.memory.getObject(frame));
                } catch (error) {
                    setException(error);
                }
            }
            SidayWeb["bjs_sidayPaint"] = function bjs_sidayPaint(address, width, height) {
                try {
                    globalThis.sidayPaint(address, width, height);
                } catch (error) {
                    setException(error);
                }
            }
            SidayWeb["bjs_sidayFillScreen"] = function bjs_sidayFillScreen() {
                try {
                    globalThis.sidayFillScreen();
                } catch (error) {
                    setException(error);
                }
            }
            SidayWeb["bjs_sidayPicture"] = function bjs_sidayPicture(nameBytes, nameCount) {
                try {
                    const string = decodeString(nameBytes, nameCount);
                    globalThis.sidayPicture(string);
                } catch (error) {
                    setException(error);
                }
            }
            SidayWeb["bjs_sidayRememberedPicture"] = function bjs_sidayRememberedPicture() {
                try {
                    let ret = globalThis.sidayRememberedPicture();
                    tmpRetBytes = textEncoder.encode(ret);
                    return tmpRetBytes.length;
                } catch (error) {
                    setException(error);
                }
            }
            SidayWeb["bjs_sidayChoose"] = function bjs_sidayChoose(folder) {
                try {
                    globalThis.sidayChoose(folder !== 0);
                } catch (error) {
                    setException(error);
                }
            }
            SidayWeb["bjs_sidayPlay"] = function bjs_sidayPlay(index, subsong) {
                try {
                    globalThis.sidayPlay(index, subsong);
                } catch (error) {
                    setException(error);
                }
            }
            SidayWeb["bjs_sidayPause"] = function bjs_sidayPause(paused) {
                try {
                    globalThis.sidayPause(paused !== 0);
                } catch (error) {
                    setException(error);
                }
            }
            SidayWeb["bjs_sidayRemove"] = function bjs_sidayRemove(index) {
                try {
                    globalThis.sidayRemove(index);
                } catch (error) {
                    setException(error);
                }
            }
            SidayWeb["bjs_sidayRemoveAll"] = function bjs_sidayRemoveAll() {
                try {
                    globalThis.sidayRemoveAll();
                } catch (error) {
                    setException(error);
                }
            }
            SidayWeb["bjs_sidayStop"] = function bjs_sidayStop() {
                try {
                    globalThis.sidayStop();
                } catch (error) {
                    setException(error);
                }
            }
            SidayWeb["bjs_sidaySeek"] = function bjs_sidaySeek(seconds) {
                try {
                    globalThis.sidaySeek(seconds);
                } catch (error) {
                    setException(error);
                }
            }
            SidayWeb["bjs_sidayVolume"] = function bjs_sidayVolume(volume) {
                try {
                    globalThis.sidayVolume(volume);
                } catch (error) {
                    setException(error);
                }
            }
            SidayWeb["bjs_sidayRememberedVolume"] = function bjs_sidayRememberedVolume() {
                try {
                    let ret = globalThis.sidayRememberedVolume();
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            SidayWeb["bjs_sidayListHeight"] = function bjs_sidayListHeight() {
                try {
                    let ret = globalThis.sidayListHeight();
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            SidayWeb["bjs_sidayScrollList"] = function bjs_sidayScrollList(top) {
                try {
                    globalThis.sidayScrollList(top);
                } catch (error) {
                    setException(error);
                }
            }
            SidayWeb["bjs_sidayOutput"] = function bjs_sidayOutput(nameBytes, nameCount, place) {
                try {
                    const string = decodeString(nameBytes, nameCount);
                    globalThis.sidayOutput(string, place);
                } catch (error) {
                    setException(error);
                }
            }
            SidayWeb["bjs_sidayHidden"] = function bjs_sidayHidden(namesBytes, namesCount) {
                try {
                    const string = decodeString(namesBytes, namesCount);
                    globalThis.sidayHidden(string);
                } catch (error) {
                    setException(error);
                }
            }
            SidayWeb["bjs_sidayRememberedHidden"] = function bjs_sidayRememberedHidden() {
                try {
                    let ret = globalThis.sidayRememberedHidden();
                    tmpRetBytes = textEncoder.encode(ret);
                    return tmpRetBytes.length;
                } catch (error) {
                    setException(error);
                }
            }
            SidayWeb["bjs_sidaySettings"] = function bjs_sidaySettings(valuesBytes, valuesCount, rememberedBytes, rememberedCount) {
                try {
                    const string = decodeString(valuesBytes, valuesCount);
                    const string1 = decodeString(rememberedBytes, rememberedCount);
                    globalThis.sidaySettings(string, string1);
                } catch (error) {
                    setException(error);
                }
            }
            SidayWeb["bjs_sidayRememberedSettings"] = function bjs_sidayRememberedSettings() {
                try {
                    let ret = globalThis.sidayRememberedSettings();
                    tmpRetBytes = textEncoder.encode(ret);
                    return tmpRetBytes.length;
                } catch (error) {
                    setException(error);
                }
            }
            SidayWeb["bjs_sidayRememberedOutput"] = function bjs_sidayRememberedOutput() {
                try {
                    let ret = globalThis.sidayRememberedOutput();
                    tmpRetBytes = textEncoder.encode(ret);
                    return tmpRetBytes.length;
                } catch (error) {
                    setException(error);
                }
            }
            const BrowserInterop = importObject["BrowserInterop"] = importObject["BrowserInterop"] || {};
            BrowserInterop["bjs_JSDocument_body_get"] = function bjs_JSDocument_body_get(self) {
                try {
                    let ret = swift.memory.getObject(self).body;
                    return swift.memory.retain(ret);
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSDocument_createElement"] = function bjs_JSDocument_createElement(self, tagNameBytes, tagNameCount) {
                try {
                    const string = decodeString(tagNameBytes, tagNameCount);
                    let ret = swift.memory.getObject(self).createElement(string);
                    return swift.memory.retain(ret);
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSDocument_createElementNS"] = function bjs_JSDocument_createElementNS(self, namespaceURIBytes, namespaceURICount, qualifiedNameBytes, qualifiedNameCount) {
                try {
                    const string = decodeString(namespaceURIBytes, namespaceURICount);
                    const string1 = decodeString(qualifiedNameBytes, qualifiedNameCount);
                    let ret = swift.memory.getObject(self).createElementNS(string, string1);
                    return swift.memory.retain(ret);
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSDocument_createTextNode"] = function bjs_JSDocument_createTextNode(self, textBytes, textCount) {
                try {
                    const string = decodeString(textBytes, textCount);
                    let ret = swift.memory.getObject(self).createTextNode(string);
                    return swift.memory.retain(ret);
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSDocument_querySelector"] = function bjs_JSDocument_querySelector(self, selectorBytes, selectorCount) {
                try {
                    const string = decodeString(selectorBytes, selectorCount);
                    let ret = swift.memory.getObject(self).querySelector(string);
                    return swift.memory.retain(ret);
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSDocument_addEventListener"] = function bjs_JSDocument_addEventListener(self, typeBytes, typeCount, listener) {
                try {
                    const string = decodeString(typeBytes, typeCount);
                    swift.memory.getObject(self).addEventListener(string, swift.memory.getObject(listener));
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSDocument_removeEventListener"] = function bjs_JSDocument_removeEventListener(self, typeBytes, typeCount, listener) {
                try {
                    const string = decodeString(typeBytes, typeCount);
                    swift.memory.getObject(self).removeEventListener(string, swift.memory.getObject(listener));
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSWindow_scrollX_get"] = function bjs_JSWindow_scrollX_get(self) {
                try {
                    let ret = swift.memory.getObject(self).scrollX;
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSWindow_scrollY_get"] = function bjs_JSWindow_scrollY_get(self) {
                try {
                    let ret = swift.memory.getObject(self).scrollY;
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSWindow_getComputedStyle"] = function bjs_JSWindow_getComputedStyle(self, element) {
                try {
                    let ret = swift.memory.getObject(self).getComputedStyle(swift.memory.getObject(element));
                    return swift.memory.retain(ret);
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSPerformance_now"] = function bjs_JSPerformance_now(self) {
                try {
                    let ret = swift.memory.getObject(self).now();
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSNode_textContent_set"] = function bjs_JSNode_textContent_set(self, newValueBytes, newValueCount) {
                try {
                    const string = decodeString(newValueBytes, newValueCount);
                    swift.memory.getObject(self).textContent = string;
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSElement_style_get"] = function bjs_JSElement_style_get(self) {
                try {
                    let ret = swift.memory.getObject(self).style;
                    return swift.memory.retain(ret);
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSElement_offsetParent_get"] = function bjs_JSElement_offsetParent_get(self) {
                try {
                    let ret = swift.memory.getObject(self).offsetParent;
                    return swift.memory.retain(ret);
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSElement_setAttribute"] = function bjs_JSElement_setAttribute(self, nameBytes, nameCount, valueBytes, valueCount) {
                try {
                    const string = decodeString(nameBytes, nameCount);
                    const string1 = decodeString(valueBytes, valueCount);
                    swift.memory.getObject(self).setAttribute(string, string1);
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSElement_removeAttribute"] = function bjs_JSElement_removeAttribute(self, nameBytes, nameCount) {
                try {
                    const string = decodeString(nameBytes, nameCount);
                    swift.memory.getObject(self).removeAttribute(string);
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSElement_appendChild"] = function bjs_JSElement_appendChild(self, child) {
                try {
                    swift.memory.getObject(self).appendChild(swift.memory.getObject(child));
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSElement_removeChild"] = function bjs_JSElement_removeChild(self, child) {
                try {
                    swift.memory.getObject(self).removeChild(swift.memory.getObject(child));
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSElement_insertBefore"] = function bjs_JSElement_insertBefore(self, newChild, refChild) {
                try {
                    swift.memory.getObject(self).insertBefore(swift.memory.getObject(newChild), swift.memory.getObject(refChild));
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSElement_replaceChildren"] = function bjs_JSElement_replaceChildren(self) {
                try {
                    swift.memory.getObject(self).replaceChildren();
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSElement_getBoundingClientRect"] = function bjs_JSElement_getBoundingClientRect(self) {
                try {
                    let ret = swift.memory.getObject(self).getBoundingClientRect();
                    return swift.memory.retain(ret);
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSElement_addEventListener"] = function bjs_JSElement_addEventListener(self, typeBytes, typeCount, listener) {
                try {
                    const string = decodeString(typeBytes, typeCount);
                    swift.memory.getObject(self).addEventListener(string, swift.memory.getObject(listener));
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSElement_removeEventListener"] = function bjs_JSElement_removeEventListener(self, typeBytes, typeCount, listener) {
                try {
                    const string = decodeString(typeBytes, typeCount);
                    swift.memory.getObject(self).removeEventListener(string, swift.memory.getObject(listener));
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSElement_focus"] = function bjs_JSElement_focus(self) {
                try {
                    swift.memory.getObject(self).focus();
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSElement_blur"] = function bjs_JSElement_blur(self) {
                try {
                    swift.memory.getObject(self).blur();
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSElement_animate"] = function bjs_JSElement_animate(self, keyframes) {
                try {
                    const structValue = structHelpers.M14BrowserInteropT23JSKeyframeEffectOptions.lift();
                    let ret = swift.memory.getObject(self).animate(swift.memory.getObject(keyframes), structValue);
                    return swift.memory.retain(ret);
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSCSSStyleDeclaration_getPropertyValue"] = function bjs_JSCSSStyleDeclaration_getPropertyValue(self, nameBytes, nameCount) {
                try {
                    const string = decodeString(nameBytes, nameCount);
                    let ret = swift.memory.getObject(self).getPropertyValue(string);
                    tmpRetBytes = textEncoder.encode(ret);
                    return tmpRetBytes.length;
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSCSSStyleDeclaration_setProperty"] = function bjs_JSCSSStyleDeclaration_setProperty(self, nameBytes, nameCount, valueBytes, valueCount) {
                try {
                    const string = decodeString(nameBytes, nameCount);
                    const string1 = decodeString(valueBytes, valueCount);
                    swift.memory.getObject(self).setProperty(string, string1);
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSCSSStyleDeclaration_removeProperty"] = function bjs_JSCSSStyleDeclaration_removeProperty(self, nameBytes, nameCount) {
                try {
                    const string = decodeString(nameBytes, nameCount);
                    swift.memory.getObject(self).removeProperty(string);
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSDOMRect_x_get"] = function bjs_JSDOMRect_x_get(self) {
                try {
                    let ret = swift.memory.getObject(self).x;
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSDOMRect_y_get"] = function bjs_JSDOMRect_y_get(self) {
                try {
                    let ret = swift.memory.getObject(self).y;
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSDOMRect_width_get"] = function bjs_JSDOMRect_width_get(self) {
                try {
                    let ret = swift.memory.getObject(self).width;
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSDOMRect_height_get"] = function bjs_JSDOMRect_height_get(self) {
                try {
                    let ret = swift.memory.getObject(self).height;
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSAnimation_effect_get"] = function bjs_JSAnimation_effect_get(self) {
                try {
                    let ret = swift.memory.getObject(self).effect;
                    return swift.memory.retain(ret);
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSAnimation_currentTime_set"] = function bjs_JSAnimation_currentTime_set(self, newValue) {
                try {
                    swift.memory.getObject(self).currentTime = newValue;
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSAnimation_onfinish_set"] = function bjs_JSAnimation_onfinish_set(self, newValue) {
                try {
                    swift.memory.getObject(self).onfinish = swift.memory.getObject(newValue);
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSAnimation_persist"] = function bjs_JSAnimation_persist(self) {
                try {
                    swift.memory.getObject(self).persist();
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSAnimation_pause"] = function bjs_JSAnimation_pause(self) {
                try {
                    swift.memory.getObject(self).pause();
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSAnimation_play"] = function bjs_JSAnimation_play(self) {
                try {
                    swift.memory.getObject(self).play();
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSAnimation_cancel"] = function bjs_JSAnimation_cancel(self) {
                try {
                    swift.memory.getObject(self).cancel();
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSAnimationEffect_setKeyframes"] = function bjs_JSAnimationEffect_setKeyframes(self, keyframes) {
                try {
                    swift.memory.getObject(self).setKeyframes(swift.memory.getObject(keyframes));
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSAnimationEffect_updateTiming"] = function bjs_JSAnimationEffect_updateTiming(self) {
                try {
                    const structValue = structHelpers.M14BrowserInteropT17JSAnimationTiming.lift();
                    swift.memory.getObject(self).updateTiming(structValue);
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSEvent_type_get"] = function bjs_JSEvent_type_get(self) {
                try {
                    let ret = swift.memory.getObject(self).type;
                    tmpRetBytes = textEncoder.encode(ret);
                    return tmpRetBytes.length;
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSEvent_target_get"] = function bjs_JSEvent_target_get(self) {
                try {
                    let ret = swift.memory.getObject(self).target;
                    return swift.memory.retain(ret);
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSKeyboardEvent_key_get"] = function bjs_JSKeyboardEvent_key_get(self) {
                try {
                    let ret = swift.memory.getObject(self).key;
                    tmpRetBytes = textEncoder.encode(ret);
                    return tmpRetBytes.length;
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSMouseEvent_altKey_get"] = function bjs_JSMouseEvent_altKey_get(self) {
                try {
                    let ret = swift.memory.getObject(self).altKey;
                    return ret ? 1 : 0;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSMouseEvent_button_get"] = function bjs_JSMouseEvent_button_get(self) {
                try {
                    let ret = swift.memory.getObject(self).button;
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSMouseEvent_buttons_get"] = function bjs_JSMouseEvent_buttons_get(self) {
                try {
                    let ret = swift.memory.getObject(self).buttons;
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSMouseEvent_clientX_get"] = function bjs_JSMouseEvent_clientX_get(self) {
                try {
                    let ret = swift.memory.getObject(self).clientX;
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSMouseEvent_clientY_get"] = function bjs_JSMouseEvent_clientY_get(self) {
                try {
                    let ret = swift.memory.getObject(self).clientY;
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSMouseEvent_ctrlKey_get"] = function bjs_JSMouseEvent_ctrlKey_get(self) {
                try {
                    let ret = swift.memory.getObject(self).ctrlKey;
                    return ret ? 1 : 0;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSMouseEvent_metaKey_get"] = function bjs_JSMouseEvent_metaKey_get(self) {
                try {
                    let ret = swift.memory.getObject(self).metaKey;
                    return ret ? 1 : 0;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSMouseEvent_movementX_get"] = function bjs_JSMouseEvent_movementX_get(self) {
                try {
                    let ret = swift.memory.getObject(self).movementX;
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSMouseEvent_movementY_get"] = function bjs_JSMouseEvent_movementY_get(self) {
                try {
                    let ret = swift.memory.getObject(self).movementY;
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSMouseEvent_offsetX_get"] = function bjs_JSMouseEvent_offsetX_get(self) {
                try {
                    let ret = swift.memory.getObject(self).offsetX;
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSMouseEvent_offsetY_get"] = function bjs_JSMouseEvent_offsetY_get(self) {
                try {
                    let ret = swift.memory.getObject(self).offsetY;
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSMouseEvent_pageX_get"] = function bjs_JSMouseEvent_pageX_get(self) {
                try {
                    let ret = swift.memory.getObject(self).pageX;
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSMouseEvent_pageY_get"] = function bjs_JSMouseEvent_pageY_get(self) {
                try {
                    let ret = swift.memory.getObject(self).pageY;
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSMouseEvent_screenX_get"] = function bjs_JSMouseEvent_screenX_get(self) {
                try {
                    let ret = swift.memory.getObject(self).screenX;
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSMouseEvent_screenY_get"] = function bjs_JSMouseEvent_screenY_get(self) {
                try {
                    let ret = swift.memory.getObject(self).screenY;
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSMouseEvent_shiftKey_get"] = function bjs_JSMouseEvent_shiftKey_get(self) {
                try {
                    let ret = swift.memory.getObject(self).shiftKey;
                    return ret ? 1 : 0;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSInputEvent_data_get"] = function bjs_JSInputEvent_data_get(self) {
                try {
                    let ret = swift.memory.getObject(self).data;
                    const isSome = ret != null;
                    tmpRetString = isSome ? ret : null;
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSInputEvent_target_get"] = function bjs_JSInputEvent_target_get(self) {
                try {
                    let ret = swift.memory.getObject(self).target;
                    return swift.memory.retain(ret);
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_window_get"] = function bjs_window_get() {
                try {
                    let ret = globalThis.window;
                    return swift.memory.retain(ret);
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_document_get"] = function bjs_document_get() {
                try {
                    let ret = globalThis.document;
                    return swift.memory.retain(ret);
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_performance_get"] = function bjs_performance_get() {
                try {
                    let ret = globalThis.performance;
                    return swift.memory.retain(ret);
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_requestAnimationFrame"] = function bjs_requestAnimationFrame(callback) {
                try {
                    let ret = globalThis.requestAnimationFrame(swift.memory.getObject(callback));
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_cancelAnimationFrame"] = function bjs_cancelAnimationFrame(handle) {
                try {
                    globalThis.cancelAnimationFrame(handle);
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_queueMicrotask"] = function bjs_queueMicrotask(callback) {
                try {
                    globalThis.queueMicrotask(swift.memory.getObject(callback));
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_setTimeout"] = function bjs_setTimeout(callback, timeout) {
                try {
                    globalThis.setTimeout(swift.memory.getObject(callback), timeout);
                } catch (error) {
                    setException(error);
                }
            }
            BrowserInterop["bjs_JSMath_cos_static"] = function bjs_JSMath_cos_static(value) {
                try {
                    let ret = globalThis.Math.cos(value);
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSMath_sin_static"] = function bjs_JSMath_sin_static(value) {
                try {
                    let ret = globalThis.Math.sin(value);
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSMath_pow_static"] = function bjs_JSMath_pow_static(base, exponent) {
                try {
                    let ret = globalThis.Math.pow(base, exponent);
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSMath_exp_static"] = function bjs_JSMath_exp_static(value) {
                try {
                    let ret = globalThis.Math.exp(value);
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
            BrowserInterop["bjs_JSMath_log_static"] = function bjs_JSMath_log_static(value) {
                try {
                    let ret = globalThis.Math.log(value);
                    return ret;
                } catch (error) {
                    setException(error);
                    return 0
                }
            }
        },
        setInstance: (i) => {
            instance = i;
            memory = instance.exports.memory;

            decodeString = (ptr, len) => { const bytes = new Uint8Array(memory.buffer, ptr >>> 0, len >>> 0); return textDecoder.decode(bytes); }

            setException = (error) => {
                instance.exports._swift_js_exception.value = swift.memory.retain(error)
            }
        },
        /** @param {WebAssembly.Instance} instance */
        createExports: (instance) => {
            const js = swift.memory.heap;
            const __bjs_helpers_M14BrowserInteropT23JSKeyframeEffectOptions = __bjs_createStructHelpers_M14BrowserInteropT23JSKeyframeEffectOptions();
            structHelpers.M14BrowserInteropT23JSKeyframeEffectOptions = __bjs_helpers_M14BrowserInteropT23JSKeyframeEffectOptions;

            const __bjs_helpers_M14BrowserInteropT17JSAnimationTiming = __bjs_createStructHelpers_M14BrowserInteropT17JSAnimationTiming();
            structHelpers.M14BrowserInteropT17JSAnimationTiming = __bjs_helpers_M14BrowserInteropT17JSAnimationTiming;

            const exports = {
                JSCompositeOperation: JSCompositeOperationValues,
                JSFillMode: JSFillModeValues,
            };
            _exports = exports;
            return exports;
        },
    }
}