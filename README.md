# JS Runtime lib

A fast and easy library to integrate a Javascript engine into your Zig project.

With this library you can:

- add Javascript as a scripting language for your native project (eg. plugin system, game scripting)
- build a basic web browser (this library as been developed to build Browsercore headless)
- build a Javascript runtime (ie. a Node/Deno/Bun competitor)

Features:

- [x] Setup and configure the Javascript engine (v8)
- [x] Generate Zig structs into Javascript functions and objects (at compile time)
- [x] Bi-directional "link" between Zig structs and Javascript objects
- [x] Support for inheritance (on Zig structs) and prototype chain (on Javascript objects)
- [x] Support for Javascript asynchronous code (IO event loop)

Currently only _v8_ is supported as a Javascript engine, but other engines might be added in the future.

This library is fully single-threaded to matches the nature of Javascript and avoid any cost of context switching for the Javascript engine.

## Rationale

The _v8_ Javascript engine is quite easy to embed for a basic usage, but it's more difficult to integrate closely in a native project. You need to handle:

- the creation of your native structs in Javascript (_ObjectTemplate_ and _FunctionTemplate_ in _v8_)
- the callbacks of Javascript actions into your native functions (constructors, getters, setters, methods)
- the memory management between the Javascript Garbage Collector and your native code
- the IO event loop to support asynchronous Javascript code

This library takes care of all this, with no overhead thanks to Zig awesome compile time capabilities.

## Getting started

In your Zig project, let's say you have this basic struct.

```zig
const Person = struct {
    first_name: []u8,
    last_name: []u8,
    age: u32,

	// Constructor
	// if there is no 'constructor' method defined
	// 'new Person()' will be prohibited from JS
    pub fn constructor(first_name: []u8, last_name: []u8, age: u32) Person {
        return .{
            .first_name = first_name,
            .last_name = last_name,
            .age = age,
        };
    }

    // Getter
	// must be 'get_<field_name>'
    pub fn get_age(self: Person) u32 {
        return self.age;
    }

	// Setter
	// must be 'set_<field_name>'
    pub fn set_age(self: *Person, age: u32) void {
        self.age = age;
    }

	// Method
	// must be with '_<method_name>'
    pub fn _name(self: Person) []u8 {
        return self.last_name;
    }
};
```

You can use it in a Javascript script.

```javascript
// Creating a new instance of the object
let p = new Person('John', 'Doe', 40);

// Getter
console.log(p.age); // => 40

// Setter
p.age = 41;
console.log(p.age); // => 41

// Method
console.log(p.name()); // 'Doe'
```

## Build

### Prerequisites

jsruntime-lib is written with [Zig](https://ziglang.org/) `0.12`. You have to
install it with the right version in order to build the project.

To be able to build the v8 engine, you have to install some libs:

For Debian/Ubuntu based Linux:
```
sudo apt install xz-utils \
    python3 ca-certificates git \
    pkg-config libglib2.0-dev clang
```

For MacOS, you only need Python 3.

### Install and build dependencies

The project uses git submodule for dependencies.
The `make install-submodule` will init and update the submodules in the `vendor/`
directory.

```
make install-submodule
```

### Build v8

The command `make install-v8-dev` uses `zig-v8` dependency to build v8 engine lib.
Be aware the build task is very long and cpu consuming.

Build v8 engine for debug/dev version, it creates
`vendor/v8/$ARCH/debug/libc_v8.a` file.

```
make install-v8-dev
```

You should also build a release vesion of v8 with:

```
make install-v8
```

### All in one build

You can run `make intall` and `make install-dev` to install deps all in one.

## Test

You can test the jsruntime-lib by running `make test`.

## Credits

- [zig-v8](https://github.com/fubark/zig-v8/) for v8 bindings and build
- [Tigerbeetle](https://github.com/tigerbeetledb/tigerbeetle/tree/main/src/io) for the IO loop based on _io\_uring_
- The v8 team for the [v8 Javascript engine](https://v8.dev/)
- The Zig team for [Zig](https://ziglang.org/)
