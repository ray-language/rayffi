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
extern          8 fibers on 2 workers: 477 ms in all, longest tick gap 476 ms
extern blocking  8 fibers on 2 workers: 171 ms in all, longest tick gap 3 ms
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

- **Tipos.** `int` para los tamaños y `uLong`: llena el registro al pasar, pero al volver es un
  `int` de C, así que rayffi enmascara a 32 bits. `u64` sería lo correcto, y la referencia lo
  admite, pero el nativo no lo compila (#209).
- **Parámetros de salida.** C escribe en el `bytes` que se le pasa: `dest` y el `uLongf *destLen` son
  búferes de raylang (8 octetos en little-endian valen también donde `uLong` es de 32 bits). La doc
  no dice que se pueda, y en la VM escribir en un literal `b"…"` cambia el literal (#211). Por eso
  cada búfer de salida es nuevo (`zlib.zeros`).
- **Punteros opacos.** `gzopen` devuelve `Option<ptr>` (NULL es `None`). El `ptr` va en un struct con
  una marca `open`, que evita llamar a zlib con un handle ya liberado: un `close` doble o un `write`
  tras cerrar dan `Err`. La marca vive en el valor, así que una copia del struct no la ve.
- **Fibras.** Las llamadas largas (`compress2`, `uncompress` y todo `gz*` que toca disco) son
  `blocking`. En nativo, un `ptr` no puede salir de su fibra (#214), así que cada fibra abre su
  propio `gzFile`.
- **errno.** `ffi.errno()` no existe en nativo (#210). El motivo de un `gzopen` fallido se pregunta
  a `std/fs`.

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
| 1 (4 fibras) | 453 ms en total, pausa máxima 453 ms | 132 ms, pausa máxima 2 ms |
| 2 | 477 ms, pausa máxima 476 ms | 171 ms, pausa máxima 3 ms |
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
| zlib, gzip, comparación, fibras | **16 tests** en VM y nativo (raylang 1.27.65, macOS) |
| macOS en CI | tests en VM y nativo; el binario sin `--release`, que en el runner `macos-14` no compila (#216) |
| Linux | en CI (el binario nativo necesita `zlib1g-dev` al compilar, #215) |
| Windows | solo `ray check`: no trae zlib, y un `extern` no puede llamarla `zlib1.dll` solo allí (#212, #215) |

Pendiente: `deflate`/`inflate` en streaming con un `z_stream`. Pide un struct de C que raylang no
puede construir (§13 deja fuera los structs por valor; `deflateInit2_` tiene 8 argumentos y el
límite es 6), así que quedaría como `bytes` con offsets a mano.

## Hallazgos de dogfood

En `findings/open/rayffi-1.27.65.md` del directorio de las apps:

1. **#209 [B]** `u64` en un `extern` funciona en la VM, pero el nativo no compila («not marshalable:
   UInt(64)»), aunque §13 lo da por bueno. En nativo no hay forma de recibir un `size_t` entero.
2. **#210 [B]** `ffi.errno()` es un stub que entra en pánico en nativo, y con `--release` no se
   compila.
3. **#211 [D]** La doc no dice si C puede escribir en un `bytes`. Puede, y en la VM eso cambia los
   literales `b"…"` para las siguientes evaluaciones.
4. **#212 [B]** Los `extern fn` son globales: el mismo símbolo en dos módulos choca, y el error
   señala un `import` de otro archivo. Una función no puede ser normal en un sitio y `blocking` en
   otro.
5. **#213 [B]** `.and_then(parse_int)` funciona en la VM y en nativo sale como stub.
6. **#214 [B]** Un struct con un `ptr` enviado por canal (incluso con `spawn_local`) compila en
   nativo y entra en pánico en el runtime, con un mensaje sobre «funciones». `try_join` no lo
   contiene.
7. **#215 [D]** §13 dice «dlopen at runtime». Así es en la VM, pero el nativo enlaza con
   `-l<nombre>` al compilar: necesita la biblioteca de desarrollo y solo vale el nombre corto. No
   hay nombre por plataforma, y en la VM una biblioteca que falta se descubre en la primera llamada,
   con un pánico que habla del símbolo.
8. **#216 [B]** `ray build --native --release` compila para la CPU de la máquina. En el runner
   `macos-14` de GitHub eso rompe el crate `ring` del runtime, y el binario no se construye.

Además, `llms.txt` no tiene sección de FFI: la superficie entera es §13 de la referencia y una
función en `std/ffi`.

Lo que salió bien:

- `extern "z" blocking`: el pool funciona como dice la doc, sin que la fibra note nada.
- `Option<string>` y `Option<ptr>` de retorno, para `zlibVersion` y `gzopen`.
- Escribir en `bytes` desde C, igual en VM y nativo.
- Rendimiento: llamar a zlib cuesta lo mismo que desde C.
- Interoperabilidad: zlib y la stdlib leen lo que escribe la otra, en los dos formatos.
