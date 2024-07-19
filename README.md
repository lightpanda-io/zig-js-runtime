# zig-js-runtime

A fast and easy library to add a Javascript runtime into your Zig project.

With this library you can:

- add Javascript as a scripting language for your Zig project (eg. plugin system, game scripting)
- build a web browser (this library as been developed for the [Ligthpanda headless browser](https://lightpanda.io))
- build a Javascript runtime (ie. a Node/Bun like)

Features:

- [x] Setup and configure the Javascript engine
- [x] Expose Zig structs as Javascript functions and objects (at compile time)
- [x] Bi-directional "link" between Zig structs and Javascript objects
- [x] Support for inheritance (on Zig structs) and prototype chain (on Javascript objects)
- [x] Support for Javascript asynchronous code (I/O event loop)

Currently only v8 is supported as a Javascript engine, but other engines might be added in the future.

This library is fully single-threaded to matches the nature of Javascript and avoid any cost of context switching for the Javascript engine.

## Rationale

Integrate a Javascript engine into a Zig project is not just embeding an external library and making language bindings.
You need to handle other stuffs:

- the generation of your Zig structs as Javascript functions and objects (_ObjectTemplate_ and _FunctionTemplate_ in v8)
- the callbacks of Javascript actions into your Zig functions (constructors, getters, setters, methods)
- the memory management between the Javascript engine and your Zig code
- the I/O event loop to support asynchronous Javascript code

This library takes care of all this, with no overhead thanks to Zig awesome compile time capabilities.

## Getting started

In your Zig project, let's say you have this basic struct that you want to expose in Javascript:

```zig
const Person = struct {
    first_name: []u8,
    last_name: []u8,
    age: u32,

    // Constructor
    // if there is no 'constructor' defined 'new Person()' will raise a TypeError in JS
    pub fn constructor(first_name: []u8, last_name: []u8, age: u32) Person {
        return .{
            .first_name = first_name,
            .last_name = last_name,
            .age = age,
        };
    }

    // Getter, 'get_<field_name>'
    pub fn get_age(self: Person) u32 {
        return self.age;
    }

    // Setter, 'set_<field_name>'
    pub fn set_age(self: *Person, age: u32) void {
        self.age = age;
    }

    // Method, '_<method_name>'
    pub fn _lastName(self: Person) []u8 {
        return self.last_name;
    }
};
```

You can generate the corresponding Javascript functions at comptime with:

```zig
const jsruntime = @import("jsruntime");
pub const Types = jsruntime.reflect(.{Person});
```

And then use it in a Javascript script:

```javascript
// Creating a new instance of Person
let p = new Person('John', 'Doe', 40);

// Getter
p.age; // => 40

// Setter
p.age = 41;
p.age; // => 41

// Method
p.lastName(); // => 'Doe'
```

Let's add some inheritance (ie. prototype chain):

```zig
const User = struct {
    proto: Person,
    role: u8,

    pub const prototype = *Person;

    pub fn constructor(first_name: []u8, last_name: []u8, age: u32, role: u8) User {
        const proto = Person.constructor(first_name, last_name, age);
        return .{ .proto = proto, .role = role };
    }

    pub fn get_role(self: User) u8 {
        return self.role;
    }
};

pub const Types = jsruntime.reflect(.{Person, User});
```

And use it in a Javascript script:

```javascript
// Creating a new instance of User
let u = new User('Jane', 'Smith', 35, 1); // eg. 1 for admin

// we can use the User getters/setters/methods
u.role; // => 1

// but also the Person getters/setters/methods
u.age; // => 35
u.age = 36;
u.age; // => 36
u.lastName(); // => 'Smith'

// checking the prototype chain
u instanceof User == true;
u instanceof Person == true;
User.prototype.__proto__ === Person.prototype;
```

### Javascript shell

A Javascript shell is provided as an example in `src/main_shell.zig`.

```sh
$ make shell

zig-js-runtime - Javascript Shell
exit with Ctrl+D or "exit"

>
```

## Build

### Prerequisites

zig-js-runtime is written with [Zig](https://ziglang.org/) `0.13.0`. You have to
install it with the right version in order to build the project.

To be able to build the v8 engine, you have to install some libs:

For Debian/Ubuntu based Linux:
```sh
sudo apt install xz-utils \
    python3 ca-certificates git \
    pkg-config libglib2.0-dev clang
```

For MacOS, you only need Python 3.

### Install and build dependencies

The project uses git submodule for dependencies.
The `make install-submodule` will init and update the submodules in the `vendor/`
directory.

```sh
make install-submodule
```

### Build v8

The command `make install-v8-dev` uses `zig-v8` dependency to build v8 engine lib.
Be aware the build task is very long and cpu consuming.

Build v8 engine for debug/dev version, it creates
`vendor/v8/$ARCH/debug/libc_v8.a` file.

```sh
make install-v8-dev
```

You should also build a release vesion of v8 with:

```sh
make install-v8
```

### All in one build

You can run `make install` and `make install-dev` to install deps all in one.

## Development

Some Javascript features are not supported yet:

- [ ] [Promises](https://github.com/lightpanda-io/zig-js-runtime/issues/73) and [micro-tasks](https://github.com/lightpanda-io/zig-js-runtime/issues/56)
- [ ] Some Javascript types, including [Arrays](https://github.com/lightpanda-io/zig-js-runtime/issues/52)
- [ ] [Function overloading](https://github.com/lightpanda-io/zig-js-runtime/issues/54)
- [ ] [Types static methods](https://github.com/lightpanda-io/zig-js-runtime/issues/127)
- [ ] [Non-optional nullable types](https://github.com/lightpanda-io/zig-js-runtime/issues/72)

### Test

You can test the zig-js-runtime library by running `make test`.

## Credits

- [zig-v8](https://github.com/fubark/zig-v8/) for v8 bindings and build
- [Tigerbeetle](https://github.com/tigerbeetledb/tigerbeetle/tree/main/src/io) for the IO loop based on _io\_uring_
- The v8 team for the [v8 Javascript engine](https://v8.dev/)
- The Zig team for [Zig](https://ziglang.org/)
