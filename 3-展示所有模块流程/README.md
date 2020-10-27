## 展示所有模块命令

```shell
$ cd <aosp dir>
$ source build/envsetup.sh
$ lunch aosp_x86-eng
============================================
PLATFORM_VERSION_CODENAME=S
PLATFORM_VERSION=S
TARGET_PRODUCT=aosp_x86
TARGET_BUILD_VARIANT=eng
TARGET_BUILD_TYPE=release
TARGET_ARCH=x86
TARGET_ARCH_VARIANT=x86
HOST_ARCH=x86_64
HOST_2ND_ARCH=x86
HOST_OS=linux
HOST_OS_EXTRA=Linux-4.4.0-148-generic-x86_64-Ubuntu-14.04.6-LTS
HOST_CROSS_OS=windows
HOST_CROSS_ARCH=x86
HOST_CROSS_2ND_ARCH=x86_64
HOST_BUILD_TYPE=release
BUILD_ID=AOSP.MASTER
OUT_DIR=out
PRODUCT_SOONG_NAMESPACES=device/generic/goldfish device/generic/goldfish-opengl hardware/google/camera hardware/google/camera/devices/EmulatedCamera device/generic/goldfish device/generic/goldfish-opengl
============================================
$ allmod
...
zstd_dict_round_trip_fuzzer
zstd_dict_stream_round_trip_fuzzer
zstd_frame_info_fuzzer
zstd_raw_dict_round_trip_fuzzer
zstd_simple_compress_fuzzer
zstd_simple_decompress_fuzzer
zstd_simple_round_trip_fuzzer
zstd_stream_decompress_fuzzer
zstd_stream_round_trip_fuzzer
zxing-core-1.7
...
```

## allmod流程

allmod 的定义在 build/envsetup.sh里

```shell
# List all modules for the current device, as cached in module-info.json. If any build change is
# made and it should be reflected in the output, you should run 'refreshmod' first.
function allmod() {
    if [ ! "$ANDROID_PRODUCT_OUT" ]; then
        echo "No ANDROID_PRODUCT_OUT. Try running 'lunch' first." >&2
        return 1
    fi

    if [ ! -f "$ANDROID_PRODUCT_OUT/module-info.json" ]; then
        echo "Could not find module-info.json. It will only be built once, and it can be updated with 'refreshmod'" >&2
        refreshmod || return 1
    fi

    python -c "import json; print('\n'.join(sorted(json.load(open('$ANDROID_PRODUCT_OUT/module-info.json')).keys())))"
}
```

内容很简单，就是打印module-info.json的内容，那么module-info.json到底是什么时候产生的呢？ 其实是构建的时候产生的，我们的构建命令是

```shell
m -j12
```

所以我们只需要分析m的构建过程就可以了