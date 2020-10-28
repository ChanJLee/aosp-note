## 构建命令

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
$ m -j12
```

## m构建流程

```shell
function m()
(
    _trigger_build "all-modules" "$@"
)
```

m 调用 _trigger_build 并且对应传参


```shell
function _trigger_build()
(
    local -r bc="$1"; shift
    if T="$(gettop)"; then
      _wrap_build "$T/build/soong/soong_ui.bash" --build-mode --${bc} --dir="$(pwd)" "$@"
    else
      echo "Couldn't locate the top of the tree. Try setting TOP."
    fi
)
```

这里有一个特别的语法 shift, 它用来将参数左移，比如我们传参 a b c， 这时候我们能够得到$@为 a b c, 如果这时候调用了 shift, 那么这时候 $@ 就变成了 b c

因此 我们在将参数转发给 _wrap_build函数的时候 $@就是 _trigger_build "all-modules" "$@" 去除 all-modules剩下的参数。

```shell
function _wrap_build()
{
    if [[ "${ANDROID_QUIET_BUILD:-}" == true ]]; then
      "$@"
      return $?
    fi
    # ...
}
```

实际上代码就是调用  "$T/build/soong/soong_ui.bash" --build-mode --${bc} --dir="$(pwd)" "$@"

在我们的场景下，实际的命令会被解析成

```shell
build/soong/soong_ui.bash --build-mode --all-modules --dir=<aosp项目地址> -j12
```

我们查看soong_ui.bash 是怎么执行的

```shell
# Save the current PWD for use in soong_ui
export ORIGINAL_PWD=${PWD}
export TOP=$(gettop)
source ${TOP}/build/soong/scripts/microfactory.bash

soong_build_go soong_ui android/soong/cmd/soong_ui

cd ${TOP}
exec "$(getoutdir)/soong_ui" "$@"
```

soong_ui.bash执行流程我们在第二章已经描述过了，因此我们可以看到实际是转发给soong_ui进行构建，soong_ui的源码在 build/soong/cmd/soong_ui/main.go下

soong_ui具体的分析方法我们就不给出了，我们可以看到当我们传递参数 build-mode给soong_ui的时候，操作会被转发到如下的函数

```go
var commands []command = []command{
    // ...
	{
		flag:        "--build-mode",
		description: "build modules based on the specified build action",
		config:      buildActionConfig,
		stdio:       stdio,
		run:         make,
	},
}
```

即make函数

```go
func make(ctx build.Context, config build.Config, _ []string, logsDir string) {
    // ...
	if _, ok := config.Environment().Get("ONE_SHOT_MAKEFILE"); ok {
		writer := ctx.Writer
		fmt.Fprintln(writer, "! The variable `ONE_SHOT_MAKEFILE` is obsolete.")
		fmt.Fprintln(writer, "!")
		fmt.Fprintln(writer, "! If you're using `mm`, you'll need to run `source build/envsetup.sh` to update.")
		fmt.Fprintln(writer, "!")
		fmt.Fprintln(writer, "! Otherwise, either specify a module name with m, or use mma / MODULES-IN-...")
		fmt.Fprintln(writer, "")
		ctx.Fatal("done")
	}

	toBuild := build.BuildAll
	if config.Checkbuild() {
		toBuild |= build.RunBuildTests
	}
	build.Build(ctx, config, toBuild)
}
```

Build函数在 build/soong/ui/build/build.go下，其中 build.BuildALL的值为 BuildProductConfig | BuildSoong | BuildKati | BuildNinja

```go
func Build(ctx Context, config Config, what int) {
    // ...

    // 检查可能导致问题的一些脏文件是否存在
	checkProblematicFiles(ctx)

    // ...

    // 检查当前的文件系统是不是大小写敏感的，主要针对mac操作系统
	checkCaseSensitivity(ctx, config)

    // ...

	if what&BuildProductConfig != 0 {
		// Run make for product config
		runMakeProductConfig(ctx, config)
	}

    // ...

	if what&BuildSoong != 0 {
		// Run Soong
		runSoong(ctx, config)
	}

	if what&BuildKati != 0 {
		// Run ckati
		genKatiSuffix(ctx, config)
		runKatiCleanSpec(ctx, config)
		runKatiBuild(ctx, config)
		runKatiPackage(ctx, config)

		ioutil.WriteFile(config.LastKatiSuffixFile(), []byte(config.KatiSuffix()), 0777)
	} else {
		// ...
	}

	// Write combined ninja file
	createCombinedBuildNinjaFile(ctx, config)

	// ...

	if what&BuildNinja != 0 {
		if !config.SkipMake() {
			installCleanIfNecessary(ctx, config)
		}

		// Run ninja
		runNinja(ctx, config)
	}
}
```

从之前 BuildAll我们可以看到，一次构建会一次执行 

1. runMakeProductConfig
2. runSoong
3. 构建ckati
4. 合并ninja文件
5. 通过ninja构建


## runMakeProductConfig分析

runMakeProductConfig的定义在 build/soong/ui/build/dumpvars.go 文件中

```go
func runMakeProductConfig(ctx Context, config Config) {
	// Variables to export into the environment of Kati/Ninja
	exportEnvVars := []string{
		// So that we can use the correct TARGET_PRODUCT if it's been
		// modified by a buildspec.mk
		"TARGET_PRODUCT",
		"TARGET_BUILD_VARIANT",
		"TARGET_BUILD_APPS",
		"TARGET_BUILD_UNBUNDLED",

		// compiler wrappers set up by make
		"CC_WRAPPER",
		"CXX_WRAPPER",
		"RBE_WRAPPER",
		"JAVAC_WRAPPER",
		"R8_WRAPPER",
		"D8_WRAPPER",

		// ccache settings
		"CCACHE_COMPILERCHECK",
		"CCACHE_SLOPPINESS",
		"CCACHE_BASEDIR",
		"CCACHE_CPP2",
	}

	allVars := append(append([]string{
		// Used to execute Kati and Ninja
		"NINJA_GOALS",
		"KATI_GOALS",

		// To find target/product/<DEVICE>
		"TARGET_DEVICE",

		// So that later Kati runs can find BoardConfig.mk faster
		"TARGET_DEVICE_DIR",

		// Whether --werror_overriding_commands will work
		"BUILD_BROKEN_DUP_RULES",

		// Whether to enable the network during the build
		"BUILD_BROKEN_USES_NETWORK",

		// Extra environment variables to be exported to ninja
		"BUILD_BROKEN_NINJA_USES_ENV_VARS",

		// Not used, but useful to be in the soong.log
		"BOARD_VNDK_VERSION",

		"DEFAULT_WARNING_BUILD_MODULE_TYPES",
		"DEFAULT_ERROR_BUILD_MODULE_TYPES",
		"BUILD_BROKEN_PREBUILT_ELF_FILES",
		"BUILD_BROKEN_TREBLE_SYSPROP_NEVERALLOW",
		"BUILD_BROKEN_USES_BUILD_COPY_HEADERS",
		"BUILD_BROKEN_USES_BUILD_EXECUTABLE",
		"BUILD_BROKEN_USES_BUILD_FUZZ_TEST",
		"BUILD_BROKEN_USES_BUILD_HEADER_LIBRARY",
		"BUILD_BROKEN_USES_BUILD_HOST_DALVIK_JAVA_LIBRARY",
		"BUILD_BROKEN_USES_BUILD_HOST_DALVIK_STATIC_JAVA_LIBRARY",
		"BUILD_BROKEN_USES_BUILD_HOST_EXECUTABLE",
		"BUILD_BROKEN_USES_BUILD_HOST_JAVA_LIBRARY",
		"BUILD_BROKEN_USES_BUILD_HOST_PREBUILT",
		"BUILD_BROKEN_USES_BUILD_HOST_SHARED_LIBRARY",
		"BUILD_BROKEN_USES_BUILD_HOST_STATIC_LIBRARY",
		"BUILD_BROKEN_USES_BUILD_JAVA_LIBRARY",
		"BUILD_BROKEN_USES_BUILD_MULTI_PREBUILT",
		"BUILD_BROKEN_USES_BUILD_NATIVE_TEST",
		"BUILD_BROKEN_USES_BUILD_NOTICE_FILE",
		"BUILD_BROKEN_USES_BUILD_PACKAGE",
		"BUILD_BROKEN_USES_BUILD_PHONY_PACKAGE",
		"BUILD_BROKEN_USES_BUILD_PREBUILT",
		"BUILD_BROKEN_USES_BUILD_RRO_PACKAGE",
		"BUILD_BROKEN_USES_BUILD_SHARED_LIBRARY",
		"BUILD_BROKEN_USES_BUILD_STATIC_JAVA_LIBRARY",
		"BUILD_BROKEN_USES_BUILD_STATIC_LIBRARY",
	}, exportEnvVars...), BannerVars...)

	make_vars, err := dumpMakeVars(ctx, config, config.Arguments(), allVars, true, "")
	if err != nil {
		ctx.Fatalln("Error dumping make vars:", err)
	}

	env := config.Environment()
	// Print the banner like make does
	if !env.IsEnvTrue("ANDROID_QUIET_BUILD") {
		fmt.Fprintln(ctx.Writer, Banner(make_vars))
	}

	// Populate the environment
	for _, name := range exportEnvVars {
		if make_vars[name] == "" {
			env.Unset(name)
		} else {
			env.Set(name, make_vars[name])
		}
	}

	config.SetKatiArgs(strings.Fields(make_vars["KATI_GOALS"]))
	config.SetNinjaArgs(strings.Fields(make_vars["NINJA_GOALS"]))
	config.SetTargetDevice(make_vars["TARGET_DEVICE"])
	config.SetTargetDeviceDir(make_vars["TARGET_DEVICE_DIR"])

	config.SetBuildBrokenDupRules(make_vars["BUILD_BROKEN_DUP_RULES"] == "true")
	config.SetBuildBrokenUsesNetwork(make_vars["BUILD_BROKEN_USES_NETWORK"] == "true")
	config.SetBuildBrokenNinjaUsesEnvVars(strings.Fields(make_vars["BUILD_BROKEN_NINJA_USES_ENV_VARS"]))
}
```
就是准备一些环境变量

## runSoong分析

runSoong的实现在 build/soong/ui/build/goong.go 
```go
func runSoong(ctx Context, config Config) {
	// ...
	func() {
		// ...
		cmd := Command(ctx, config, "blueprint bootstrap", "build/blueprint/bootstrap.bash", "-t", "-n")
		// ...
	}()

	func() {
		// ...
		envFile := filepath.Join(config.SoongOutDir(), ".soong.environment")
		envTool := filepath.Join(config.SoongOutDir(), ".bootstrap/bin/soong_env")
		if _, err := os.Stat(envFile); err == nil {
			if _, err := os.Stat(envTool); err == nil {
				cmd := Command(ctx, config, "soong_env", envTool, envFile)
				// ...
			} else {
				// ...
			}
		} else if !os.IsNotExist(err) {
			// ...
		}
	}()

	var cfg microfactory.Config
	cfg.Map("github.com/google/blueprint", "build/blueprint")

	cfg.TrimPath = absPath(ctx, ".")

	func() {
		ctx.BeginTrace(metrics.RunSoong, "minibp")
		defer ctx.EndTrace()

		minibp := filepath.Join(config.SoongOutDir(), ".minibootstrap/minibp")
		if _, err := microfactory.Build(&cfg, minibp, "github.com/google/blueprint/bootstrap/minibp"); err != nil {
			ctx.Fatalln("Failed to build minibp:", err)
		}
	}()

	func() {
		ctx.BeginTrace(metrics.RunSoong, "bpglob")
		defer ctx.EndTrace()

		bpglob := filepath.Join(config.SoongOutDir(), ".minibootstrap/bpglob")
		if _, err := microfactory.Build(&cfg, bpglob, "github.com/google/blueprint/bootstrap/bpglob"); err != nil {
			ctx.Fatalln("Failed to build bpglob:", err)
		}
	}()

	ninja := func(name, file string) {
		ctx.BeginTrace(metrics.RunSoong, name)
		defer ctx.EndTrace()

		fifo := filepath.Join(config.OutDir(), ".ninja_fifo")
		nr := status.NewNinjaReader(ctx, ctx.Status.StartTool(), fifo)
		defer nr.Close()

		cmd := Command(ctx, config, "soong "+name,
			config.PrebuiltBuildTool("ninja"),
			"-d", "keepdepfile",
			"-d", "stats",
			"-o", "usesphonyoutputs=yes",
			"-o", "preremoveoutputs=yes",
			"-w", "dupbuild=err",
			"-w", "outputdir=err",
			"-w", "missingoutfile=err",
			"-j", strconv.Itoa(config.Parallel()),
			"--frontend_file", fifo,
			"-f", filepath.Join(config.SoongOutDir(), file))
		cmd.Environment.Set("SOONG_SANDBOX_SOONG_BUILD", "true")
		cmd.Sandbox = soongSandbox
		cmd.RunAndStreamOrFatal()
	}

	ninja("minibootstrap", ".minibootstrap/build.ninja")
	ninja("bootstrap", ".bootstrap/build.ninja")

	soongBuildMetrics := loadSoongBuildMetrics(ctx, config)
	logSoongBuildMetrics(ctx, soongBuildMetrics)

	distGzipFile(ctx, config, config.SoongNinjaFile(), "soong")

	if !config.SkipMake() {
		distGzipFile(ctx, config, config.SoongAndroidMk(), "soong")
		distGzipFile(ctx, config, config.SoongMakeVarsMk(), "soong")
	}

	if ctx.Metrics != nil {
		ctx.Metrics.SetSoongBuildMetrics(soongBuildMetrics)
	}
}                                                                                                                                                                                                                
```

## 构建ckati

## 合并ninja文件

## 通过ninja构建