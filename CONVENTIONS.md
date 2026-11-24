# Conventions

## Layout

```
back/            the engine
  tabl.zig       public API: the only entry point for the front
  core/          domain and ports, depends on nothing
  app/           use cases, depends on core
  infra/         adapters (csv, cache, files…), depends on core
front/
  cli/           the command line
```

- `core` depends on neither `app` nor `infra`. `app` does not depend on `infra`.
- Adapters are wired together in a single place, the composition root.
- The front only knows the engine's public API.

## Vocabulary

- **Port**: an interface declared in `core`, implemented in `infra`.
- **Adapter**: an implementation of a port, tied to a technology (mmap, CSV, JSON…).
- **Service**: logic in `core` or `app`, free of any technology.

## Ports

- Every port documents its role and its contract: what the caller can rely on.
- A port never mentions an infrastructure detail. A method that cannot be described without talking about infrastructure does not belong in the port.
- Use an interface only when there are several implementations or a test double is needed. Otherwise, use a concrete type.

## Construction

- Constructing an object performs no I/O.
- An object backed by a file reads it on demand, in its methods, which may fail. No initialization step that could be forgotten.

## Errors

- Each layer has its own errors.
- A layer never lets another layer's error through: it translates it into its own, keeping the cause.
- User-facing messages live in the front.
