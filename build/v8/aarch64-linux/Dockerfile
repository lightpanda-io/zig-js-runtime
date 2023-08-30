# syntax=docker/dockerfile:1-labs
FROM arm64v8/ubuntu:22.04

RUN apt-get update

# variables
ARG ZIG_VERSION=0.10.1
ARG ZIG_256SUM=db0761664f5f22aa5bbd7442a1617dd696c076d5717ddefcc9d8b95278f71f5d
ARG ARCH=aarch64
ARG V8_REVISION=11.1.134

# user args
ARG GITHUB_TOKEN
ARG AWS_ACCESS_KEY_ID
ARG AWS_SECRET_ACCESS_KEY

# setting time zone to avoid awscli select geographic area
ARG TZ=Europe/Paris
RUN ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime && echo ${TZ} > /etc/timezone

# dependencies
RUN apt-get install -y awscli
RUN apt-get install -y xz-utils # zig
RUN apt-get install -y lsb-release wget software-properties-common gnupg # clang 16
RUN apt-get install -y python3 ca-certificates git # zig-v8 get-tools, get-v8
RUN apt-get install -y pkg-config libglib2.0-dev  # zig-v8 build

# zig download
ARG ZIG_PATH=/zig-linux-${ARCH}-${ZIG_VERSION}
ADD --checksum=sha256:${ZIG_256SUM} https://ziglang.org/download/${ZIG_VERSION}${ZIG_PATH}.tar.xz ${ZIG_PATH}.tar.xz

# zig install
RUN tar -xf ${ZIG_PATH}.tar.xz
ENV PATH="$PATH:${ZIG_PATH}"
RUN zig version

# clang 16
ADD https://apt.llvm.org/llvm.sh .
RUN chmod +x llvm.sh
RUN ./llvm.sh 16 all

# zig-v8 fetch
ADD --keep-git-dir=true https://francisbouvier:${GITHUB_TOKEN}@github.com/francisbouvier/zig-v8-fork.git#fork /zig-v8
WORKDIR zig-v8

# zig-v8 build
RUN zig build get-tools
RUN zig build get-v8
RUN zig build
RUN zig build -Drelease-safe

# aws upload
ARG V8_PATH=ninja/obj/zig/libc_v8.a
RUN AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} aws s3 cp v8-build/${ARCH}-linux/debug/${V8_PATH} s3://browsercore/v8/${V8_REVISION}/${ARCH}-linux/debug/
RUN AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} aws s3 cp v8-build/${ARCH}-linux/release/${V8_PATH} s3://browsercore/v8/${V8_REVISION}/${ARCH}-linux/release/
