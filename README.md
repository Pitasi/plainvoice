# plainvoice

Turn a text file like:

```txt
invoice INV-2025-001
  date   2025-04-23
  from   @default
  to     @acme_inc

  + Consultancy April 2025    10000.00


invoice INV-2025-002
  date   2025-04-23
  from   @default
  to     @acme_inc

  + Consultancy January 2025    10000.00
```

into two invoice PDF files, see [./example/out/INV-2025-001.pdf](./example/out/INV-2025-001.pdf).

The `from` and `to` directives can load external files using `@`, this helps
maintaining the main file clean and readable.

## Run

```sh
zig build run
```
