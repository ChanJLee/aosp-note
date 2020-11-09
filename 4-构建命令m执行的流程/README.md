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

	// ...

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
	// ...
}                                                                                                                                                                                                                
```

1. 首先调用 build/blueprint/bootstrap.bash 这个文件的作用是检查ninja的运行参数

2. 然后调用soong_env， soong_env的源码在 build/soong/cmd/soong_env下，这个主要检查 out/.soong.environment 下的环境变量

3. 构建 minibp 

4. 构建 bpglob

5. 调用ninja生成 out/.minibootstrap/build.ninja out/.bootstrap/build.ninja 

6. 读取soong metrics文件

## 构建ckati

```go
genKatiSuffix(ctx, config)
runKatiCleanSpec(ctx, config)
runKatiBuild(ctx, config)
runKatiPackage(ctx, config)
```

构建ckati分为四步，第一步获取kati的后缀，主要是通过TargetProduct来进行构造字符串。第二runKatiCleanSpec

```go

func runKatiCleanSpec(ctx Context, config Config) {
	ctx.BeginTrace(metrics.RunKati, "kati cleanspec")
	defer ctx.EndTrace()

	runKati(ctx, config, katiCleanspecSuffix, []string{
		"--werror_implicit_rules",
		"--werror_overriding_commands",
		"-f", "build/make/core/cleanbuild.mk",
		"SOONG_MAKEVARS_MK=" + config.SoongMakeVarsMk(),
		"TARGET_DEVICE_DIR=" + config.TargetDeviceDir(),
	}, func(env *Environment) {})
}
```

调用ckati进行清理工作，然后再构建。

## 合并ninja文件

```go
func createCombinedBuildNinjaFile(ctx Context, config Config) {
	// If we're in SkipMake mode, skip creating this file if it already exists
	if config.SkipMake() {
		if _, err := os.Stat(config.CombinedNinjaFile()); err == nil || !os.IsNotExist(err) {
			return
		}
	}

	file, err := os.Create(config.CombinedNinjaFile())
	if err != nil {
		ctx.Fatalln("Failed to create combined ninja file:", err)
	}
	defer file.Close()

	if err := combinedBuildNinjaTemplate.Execute(file, config); err != nil {
		ctx.Fatalln("Failed to write combined ninja file:", err)
	}
}
```

创建一个临时ninja文件，并且合并它

## 通过ninja构建

```go
func runNinja(ctx Context, config Config) {
	ctx.BeginTrace(metrics.PrimaryNinja, "ninja")
	defer ctx.EndTrace()

	fifo := filepath.Join(config.OutDir(), ".ninja_fifo")
	nr := status.NewNinjaReader(ctx, ctx.Status.StartTool(), fifo)
	defer nr.Close()

	executable := config.PrebuiltBuildTool("ninja")
	args := []string{
		"-d", "keepdepfile",
		"-d", "keeprsp",
		"-d", "stats",
		"--frontend_file", fifo,
	}

	args = append(args, config.NinjaArgs()...)

	var parallel int
	if config.UseRemoteBuild() {
		parallel = config.RemoteParallel()
	} else {
		parallel = config.Parallel()
	}
	args = append(args, "-j", strconv.Itoa(parallel))
	if config.keepGoing != 1 {
		args = append(args, "-k", strconv.Itoa(config.keepGoing))
	}

	args = append(args, "-f", config.CombinedNinjaFile())

	args = append(args,
		"-o", "usesphonyoutputs=yes",
		"-w", "dupbuild=err",
		"-w", "missingdepfile=err")

	cmd := Command(ctx, config, "ninja", executable, args...)
	cmd.Sandbox = ninjaSandbox
	if config.HasKatiSuffix() {
		cmd.Environment.AppendFromKati(config.KatiEnvFile())
	}

	// Allow both NINJA_ARGS and NINJA_EXTRA_ARGS, since both have been
	// used in the past to specify extra ninja arguments.
	if extra, ok := cmd.Environment.Get("NINJA_ARGS"); ok {
		cmd.Args = append(cmd.Args, strings.Fields(extra)...)
	}
	if extra, ok := cmd.Environment.Get("NINJA_EXTRA_ARGS"); ok {
		cmd.Args = append(cmd.Args, strings.Fields(extra)...)
	}

	logPath := filepath.Join(config.OutDir(), ".ninja_log")
	ninjaHeartbeatDuration := time.Minute * 5
	if overrideText, ok := cmd.Environment.Get("NINJA_HEARTBEAT_INTERVAL"); ok {
		// For example, "1m"
		overrideDuration, err := time.ParseDuration(overrideText)
		if err == nil && overrideDuration.Seconds() > 0 {
			ninjaHeartbeatDuration = overrideDuration
		}
	}

	// Filter the environment, as ninja does not rebuild files when environment variables change.
	//
	// Anything listed here must not change the output of rules/actions when the value changes,
	// otherwise incremental builds may be unsafe. Vars explicitly set to stable values
	// elsewhere in soong_ui are fine.
	//
	// For the majority of cases, either Soong or the makefiles should be replicating any
	// necessary environment variables in the command line of each action that needs it.
	if cmd.Environment.IsEnvTrue("ALLOW_NINJA_ENV") {
		ctx.Println("Allowing all environment variables during ninja; incremental builds may be unsafe.")
	} else {
		cmd.Environment.Allow(append([]string{
			"ASAN_SYMBOLIZER_PATH",
			"HOME",
			"JAVA_HOME",
			"LANG",
			"LC_MESSAGES",
			"OUT_DIR",
			"PATH",
			"PWD",
			"PYTHONDONTWRITEBYTECODE",
			"TMPDIR",
			"USER",

			// TODO: remove these carefully
			"ASAN_OPTIONS",
			"TARGET_BUILD_APPS",
			"TARGET_BUILD_VARIANT",
			"TARGET_PRODUCT",
			// b/147197813 - used by art-check-debug-apex-gen
			"EMMA_INSTRUMENT_FRAMEWORK",

			// Goma -- gomacc may not need all of these
			"GOMA_DIR",
			"GOMA_DISABLED",
			"GOMA_FAIL_FAST",
			"GOMA_FALLBACK",
			"GOMA_GCE_SERVICE_ACCOUNT",
			"GOMA_TMP_DIR",
			"GOMA_USE_LOCAL",

			// RBE client
			"RBE_compare",
			"RBE_exec_root",
			"RBE_exec_strategy",
			"RBE_invocation_id",
			"RBE_log_dir",
			"RBE_platform",
			"RBE_remote_accept_cache",
			"RBE_remote_update_cache",
			"RBE_server_address",
			// TODO: remove old FLAG_ variables.
			"FLAG_compare",
			"FLAG_exec_root",
			"FLAG_exec_strategy",
			"FLAG_invocation_id",
			"FLAG_log_dir",
			"FLAG_platform",
			"FLAG_remote_accept_cache",
			"FLAG_remote_update_cache",
			"FLAG_server_address",

			// ccache settings
			"CCACHE_COMPILERCHECK",
			"CCACHE_SLOPPINESS",
			"CCACHE_BASEDIR",
			"CCACHE_CPP2",
			"CCACHE_DIR",
		}, config.BuildBrokenNinjaUsesEnvVars()...)...)
	}

	cmd.Environment.Set("DIST_DIR", config.DistDir())
	cmd.Environment.Set("SHELL", "/bin/bash")

	ctx.Verboseln("Ninja environment: ")
	envVars := cmd.Environment.Environ()
	sort.Strings(envVars)
	for _, envVar := range envVars {
		ctx.Verbosef("  %s", envVar)
	}

	// Poll the ninja log for updates; if it isn't updated enough, then we want to show some diagnostics
	done := make(chan struct{})
	defer close(done)
	ticker := time.NewTicker(ninjaHeartbeatDuration)
	defer ticker.Stop()
	checker := &statusChecker{}
	go func() {
		for {
			select {
			case <-ticker.C:
				checker.check(ctx, config, logPath)
			case <-done:
				return
			}
		}
	}()

	ctx.Status.Status("Starting ninja...")
	cmd.RunAndStreamOrFatal()
}
```

在运行ninja之前，设置一堆环境变量，然后进行构建。