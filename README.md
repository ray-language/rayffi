# rayffi

La zlib del sistema usada desde [raylang](https://github.com/ray-language/raylang) a través de la
FFI (`extern`), y comparada con la compresión de la stdlib (`std/deflate`, `std/inflate`). Comprime
y descomprime gzip en streaming con la API `gz*`, calcula CRC-32 y Adler-32, y mide qué aporta
`extern … blocking` a las demás fibras.

```
$ rayffi gzip big.txt
big.txt → big.txt.gz: 64503480 → 17583755 octets in 1614 ms

$ RAYLANG_THREADS=2 rayffi stall
8 fibers each compress 8 MiB of random octets; a ticker fiber wants every 1 ms:
extern          8 fibers on 2 workers: 492 ms in all, longest tick gap 493 ms
extern blocking  8 fibers on 2 workers: 160 ms in all, longest tick gap 2 ms
```

```
rayffi version                       la zlib que cargó el programa
rayffi gzip FILE [-o OUT] [-1..-9]   FILE → FILE.gz
rayffi gunzip FILE.gz [-o OUT]       al revés (un archivo sin comprimir pasa tal cual)
rayffi crc FILE...                   CRC-32 y Adler-32, por trozos
rayffi compare [FILE] [-l LEVEL]     zlib contra std/deflate y std/inflate: cada uno lee lo del otro
rayffi stall [-f FIBERS] [-m MIB]    la pausa más larga de un ticker, extern normal contra blocking
```

## Cómo

```
src/zlib.ray      versión, crc32, adler32, compressBound; compress2 y uncompress (blocking)
src/gz.ray        gzopen/gzread/gzwrite/gzclose (blocking) sobre un ptr opaco, en un struct GzFile
src/compare.ray   las parejas zlib ↔ stdlib, con tiempos
src/stall.ray     el experimento de las fibras
src/main.ray      la línea de órdenes
```

Así es la FFI de raylang vista desde zlib:

- **Tipos.** `u64` para los `uLong` de zlib (tamaños, CRC, Adler), convertidos con `as` en el
  borde; `int` para los `int` de C.
- **Parámetros de salida.** C escribe en el `bytes` que se le pasa: `dest` es un `ffi.buffer(n)`, y el
  `uLongf *destLen`, una celda de 8 octetos en little-endian (vale también donde `uLong` es de 32
  bits). raylang no puede escribir octeto a octeto en un `bytes` (#228): la celda sale de
  `bytes_of`.
- **Punteros opacos.** `gzopen` devuelve `Option<ptr>` (NULL es `None`). El `ptr` va en un struct con
  una marca `open`, que evita llamar a zlib con un handle ya liberado: un `close` doble o un `write`
  tras cerrar dan `Err`. La marca vive en el valor, así que una copia del struct no la ve.
- **Fibras.** Las llamadas largas (`compress2`, `uncompress` y todo `gz*` que toca disco) son
  `blocking`. Cada fibra abre su propio `gzFile`: un handle no se comparte.
- **errno.** El motivo de un `gzopen` fallido es `ffi.errno()`, leído justo después de la llamada, con
  el texto de `strerror` de la libc (otro `extern`, `"c"`).
- **Un `extern` es de su módulo.** `stall` declara `compress2` normal, y `zlib`, `blocking`: el
  experimento compara la misma función de las dos formas.

## Rendimiento

MacBook (Apple Silicon, 10 núcleos), binario nativo `--release`, zlib 1.2.12 del sistema.

`rayffi gzip` contra `gzip -6` sobre 64,5 MB de texto: los dos tardan 1,6 s y dan el mismo tamaño
(17,58 MB; difieren en los 8 octetos de la cabecera). Es la misma zlib, y llamarla desde raylang
cuesta lo mismo que desde C. `gunzip` tarda 90 ms y `crc` 20 ms.

`rayffi compare` sobre 8 MiB de texto generado:

| | zlib (FFI) | stdlib |
|---|---:|---:|
| comprimir, nivel 6 | 139 ms · 1 344 803 octetos | 170 ms · 1 344 084 octetos (`std/deflate`, miniz_oxide) |
| descomprimir | 5 ms | 10 ms (`std/inflate`) |
| crc32 | < 1 ms | 19 ms |
| gzip a archivo y leerlo con el otro | 142 ms · leído por la stdlib en 28 ms | 186 ms · leído por zlib en 10 ms |

`rayffi stall`: 8 fibras comprimen 8 MiB aleatorios cada una mientras otra fibra intenta despertar
cada milisegundo.

| workers | extern normal | extern blocking |
|---:|---|---|
| 1 (4 fibras) | 483 ms en total, pausa máxima 483 ms | 128 ms, pausa máxima 2 ms |
| 2 | 492 ms, pausa máxima 493 ms | 160 ms, pausa máxima 2 ms |
| 11 | 161 ms, pausa máxima 2 ms | 176 ms, pausa máxima 2 ms |

Con pocos workers, la llamada normal retiene el suyo y todo lo que vive en él espera. `blocking` la
manda al pool: el ticker no se entera y, además, las compresiones corren en paralelo. Con un worker
por núcleo, el ticker suele caer en un worker libre y no se nota la diferencia.

## Uso

```bash
make build         # ./rayffi, binario nativo (enlaza la zlib del sistema)
make test          # 16 tests en la VM
make test-native   # los mismos, compilados
make compare       # zlib contra la stdlib
make stall         # el experimento con 1, 2 y todos los workers
```

## Estado

| Qué | Estado |
|---|---|
| zlib, gzip, comparación, fibras | **16 tests** en VM y nativo (raylang 1.27.73, macOS) |
| macOS en CI | tests en VM y nativo, y el binario con `--release` (con raylang 1.27.65 no compilaba en el runner `macos-14`, #216) |
| Linux | en CI (el binario nativo necesita `zlib1g-dev` al compilar, #215) |
| Windows | solo `ray check`: el runner no trae zlib. raylang ya deja nombrarla por sistema (`extern "z" windows "zlib1"`) |

Pendiente: `deflate`/`inflate` en streaming con un `z_stream`. Pide un struct de C que raylang no
puede construir (§13 deja fuera los structs por valor; `deflateInit2_` tiene 8 argumentos y el
límite es 6), así que quedaría como `bytes` con offsets a mano.

## Hallazgos de dogfood

En `findings/` del directorio de las apps (`open/rayffi-1.27.65.md`, y la re-medición en
`open/rayffi-1.27.73.md`). Con raylang 1.27.73 quedaron arreglados los siete primeros, y rayffi
dejó los rodeos:

1. **#209 [B]** ✅ `u64` en un `extern` funcionaba en la VM, pero el nativo no compilaba («not
   marshalable: UInt(64)»). rayffi enmascaraba un `int` a 32 bits.
2. **#210 [B]** ✅ `ffi.errno()` era un stub que entraba en pánico en nativo, y con `--release` no se
   compilaba. rayffi preguntaba a `std/fs`.
3. **#211 [D]** ✅ La doc no decía si C puede escribir en un `bytes`, y en la VM eso cambiaba los
   literales `b"…"`. rayffi duplicaba `bytes_of([0])` hasta el tamaño; ahora usa `ffi.buffer(n)`.
4. **#212 [B]** ✅ Los `extern fn` eran globales: el mismo símbolo en dos módulos chocaba. `stall`
   comparaba `compress` con `compress2`.
5. **#213 [B]** ✅ `.and_then(parse_int)` funcionaba en la VM y en nativo salía como stub.
6. **#214 [B]** ✅ Un struct con un `ptr` enviado por canal (incluso con `spawn_local`) entraba en
   pánico en el runtime nativo.
7. **#215 [D]** ✅ §13 decía «dlopen at runtime», pero el nativo enlaza con `-l<nombre>`; no había
   nombre por sistema ni forma de saber si una biblioteca está.
8. **#216 [B]** `ray build --native --release` compilaba para la CPU de la máquina y en el runner
   `macos-14` rompía el crate `ring`. 1.27.73 ya no anuncia `+native`; el CI vuelve a usar
   `--release` para comprobarlo.
9. **#228 [B]** (con 1.27.73) `ray check` acepta `b[i] = v` sobre un `bytes`, y luego la VM se cae con
   un error interno y el nativo no compila.

Lo que salió bien:

- `extern "z" blocking`: el pool funciona como dice la doc, sin que la fibra note nada.
- `Option<string>` y `Option<ptr>` de retorno, para `zlibVersion` y `gzopen`.
- Escribir en `bytes` desde C, igual en VM y nativo.
- Rendimiento: llamar a zlib cuesta lo mismo que desde C.
- Interoperabilidad: zlib y la stdlib leen lo que escribe la otra, en los dos formatos.
