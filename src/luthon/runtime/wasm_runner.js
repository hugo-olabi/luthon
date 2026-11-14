/**
 * Luthon WebAssembly & WASI Host Runtime Runner (Phase 41)
 *
 * Provides headless execution of Luthon .wasm bundles using Node.js WASI Preview 1
 * and browser-compatible WebAssembly linear memory bridge utilities.
 */

const fs = require('fs');
const { WASI } = require('node:wasi');

/**
 * Executes a Luthon WASI .wasm binary bundle headlessly.
 *
 * @param {string|Buffer} wasmSource - Path to .wasm file or Buffer containing wasm bytecode.
 * @param {Object} options - Execution options (args, env, preopens).
 * @returns {Promise<{stdout: string, stderr: string, exitCode: number}>}
 */
async function runWasi(wasmSource, options = {}) {
    const wasmBytes = typeof wasmSource === 'string'
        ? fs.readFileSync(wasmSource)
        : wasmSource;

    const stdoutChunks = [];
    const stderrChunks = [];

    const wasi = new WASI({
        version: 'preview1',
        args: options.args || ['luthon_app'],
        env: options.env || {},
        preopens: options.preopens || {},
        stdout: options.stdoutFd !== undefined ? options.stdoutFd : 1,
        stderr: options.stderrFd !== undefined ? options.stderrFd : 2,
    });

    const wasmModule = await WebAssembly.compile(wasmBytes);
    const importObject = {
        wasi_snapshot_preview1: wasi.wasiImport,
        env: options.envImports || {}
    };

    const instance = await WebAssembly.instantiate(wasmModule, importObject);

    let exitCode = 0;
    try {
        exitCode = wasi.start(instance) || 0;
    } catch (e) {
        if (e.code === 'ERR_WASI_ALREADY_STARTED') {
            exitCode = 0;
        } else if (typeof e.exitCode === 'number') {
            exitCode = e.exitCode;
        } else {
            throw e;
        }
    }

    return {
        exitCode,
        instance
    };
}

/**
 * Creates an interactive WebAssembly bridge for browser / JS-Python interop.
 *
 * @param {string|Buffer} wasmSource - Path to .wasm file or Buffer.
 * @param {Object} customImports - Host functions provided to WASM.
 * @returns {Promise<Object>} Bridge interface with memory helpers.
 */
async function createWasmBridge(wasmSource, customImports = {}) {
    const wasmBytes = typeof wasmSource === 'string'
        ? fs.readFileSync(wasmSource)
        : wasmSource;

    let outputLog = [];

    const wasiMock = {
        fd_write: (fd, iovs, iovs_len, nwritten_ptr) => {
            // Minimal fd_write implementation for headless testing
            const memory = bridge.memory;
            const view = new DataView(memory.buffer);
            let total = 0;
            for (let i = 0; i < iovs_len; i++) {
                const bufPtr = view.getUint32(iovs + i * 8, true);
                const bufLen = view.getUint32(iovs + i * 8 + 4, true);
                const bytes = new Uint8Array(memory.buffer, bufPtr, bufLen);
                const str = new TextDecoder('utf-8').decode(bytes);
                outputLog.push(str);
                total += bufLen;
            }
            if (nwritten_ptr) {
                view.setUint32(nwritten_ptr, total, true);
            }
            return 0;
        },
        clock_time_get: (id, precision, time_ptr) => {
            const memory = bridge.memory;
            const view = new DataView(memory.buffer);
            const nowNs = BigInt(Date.now()) * 1000000n;
            view.setBigUint64(time_ptr, nowNs, true);
            return 0;
        },
        random_get: (buf_ptr, buf_len) => {
            const memory = bridge.memory;
            const bytes = new Uint8Array(memory.buffer, buf_ptr, buf_len);
            for (let i = 0; i < buf_len; i++) {
                bytes[i] = Math.floor(Math.random() * 256);
            }
            return 0;
        },
        proc_exit: (code) => {
            bridge.exitCode = code;
        }
    };

    const importObject = {
        wasi_snapshot_preview1: { ...wasiMock, ...customImports.wasi_snapshot_preview1 },
        env: customImports.env || {}
    };

    const wasmModule = await WebAssembly.compile(wasmBytes);
    const instance = await WebAssembly.instantiate(wasmModule, importObject);

    const bridge = {
        instance,
        exports: instance.exports,
        memory: instance.exports.memory,
        outputLog,
        exitCode: 0,

        /**
         * Allocate a null-terminated UTF-8 string in WASM linear memory.
         */
        allocString(str) {
            const encoder = new TextEncoder();
            const bytes = encoder.encode(str + '\0');
            const ptr = instance.exports.luthon_malloc
                ? instance.exports.luthon_malloc(bytes.length)
                : 1024;
            const memBytes = new Uint8Array(this.memory.buffer, ptr, bytes.length);
            memBytes.set(bytes);
            return ptr;
        },

        /**
         * Read a null-terminated UTF-8 string from WASM linear memory.
         */
        readString(ptr) {
            const bytes = new Uint8Array(this.memory.buffer);
            let end = ptr;
            while (bytes[end] !== 0 && end < bytes.length) end++;
            return new TextDecoder('utf-8').decode(bytes.subarray(ptr, end));
        },

        /**
         * Create a typed zero-copy view directly into WASM linear memory.
         */
        createTypedArrayView(pointer, length, type = 'f32') {
            const constructors = {
                u8: Uint8Array,
                i8: Int8Array,
                u16: Uint16Array,
                i16: Int16Array,
                u32: Uint32Array,
                i32: Int32Array,
                f32: Float32Array,
                f64: Float64Array
            };
            const Ctor = constructors[type] || Float32Array;
            return new Ctor(this.memory.buffer, pointer, length);
        }
    };

    return bridge;
}

module.exports = {
    runWasi,
    createWasmBridge
};
