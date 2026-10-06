import { readFile } from 'node:fs/promises';
import { WASI } from 'node:wasi';
const [dir, ...args] = process.argv.slice(2);
const wasi = new WASI({ version: 'preview1', args: ['siday.wasm', ...args], preopens: { '/t': dir } });
const module = await WebAssembly.compile(await readFile(new URL('./build/siday.wasm', import.meta.url)));
const instance = await WebAssembly.instantiate(module, wasi.getImportObject());
process.exitCode = wasi.start(instance);
