// Copyright 2023-2024 Lightpanda (Selecy SAS)
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");

const build_opts = @import("jsruntime_build_options");

// retrieve JS engine
pub const Engine = switch (build_opts.engine) {
    .v8 => @import("engines/v8/v8.zig"),
};

pub const API = Engine.API;

// loadFn is a function which generates
// the loading and binding of the native API into the JS engine
pub const loadFn = Engine.loadFn;

pub const Object = Engine.Object;
