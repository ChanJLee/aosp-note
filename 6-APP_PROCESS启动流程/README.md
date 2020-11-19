# app_process启动流程

app_process的启动命令在system/core/rootdir/init.zygote64.rc中

```shell
app_process -Xzygote /system/bin --zygote --start-system-server
```

这些参数会传递给 app_process的main函数，app_process的代码在

frameworks/base/cmds/app_process/app_main.cpp 中

```cpp
int main(int argc, char* const argv[])
{
    // ...
    // --zygote : Start in zygote mode
    // --start-system-server : Start the system server.
    // --application : Start in application (stand alone, non zygote) mode.
    // --nice-name : The nice name for this process.

    // ...
    ++i;  // Skip unused "parent dir" argument.
    while (i < argc) {
        const char* arg = argv[i++];
        if (strcmp(arg, "--zygote") == 0) {
            zygote = true;
            niceName = ZYGOTE_NICE_NAME;
        } else if (strcmp(arg, "--start-system-server") == 0) {
            startSystemServer = true;
        } else if (strcmp(arg, "--application") == 0) {
            application = true;
        } else if (strncmp(arg, "--nice-name=", 12) == 0) {
            niceName.setTo(arg + 12);
        } else if (strncmp(arg, "--", 2) != 0) {
            className.setTo(arg);
            break;
        } else {
            --i;
            break;
        }
    }

    Vector<String8> args;
    if (!className.isEmpty()) {
        // We're not in zygote mode, the only argument we need to pass
        // to RuntimeInit is the application argument.
        //
        // The Remainder of args get passed to startup class main(). Make
        // copies of them before we overwrite them with the process name.
        args.add(application ? String8("application") : String8("tool"));
        runtime.setClassNameAndArgs(className, argc - i, argv + i);

        if (!LOG_NDEBUG) {
          String8 restOfArgs;
          char* const* argv_new = argv + i;
          int argc_new = argc - i;
          for (int k = 0; k < argc_new; ++k) {
            restOfArgs.append("\"");
            restOfArgs.append(argv_new[k]);
            restOfArgs.append("\" ");
          }
          ALOGV("Class name = %s, args = %s", className.string(), restOfArgs.string());
        }
    } else {
        // We're in zygote mode.
        maybeCreateDalvikCache();

        if (startSystemServer) {
            args.add(String8("start-system-server"));
        }

        char prop[PROP_VALUE_MAX];
        if (property_get(ABI_LIST_PROPERTY, prop, NULL) == 0) {
            LOG_ALWAYS_FATAL("app_process: Unable to determine ABI list from property %s.",
                ABI_LIST_PROPERTY);
            return 11;
        }

        String8 abiFlag("--abi-list=");
        abiFlag.append(prop);
        args.add(abiFlag);

        // In zygote mode, pass all remaining arguments to the zygote
        // main() method.
        for (; i < argc; ++i) {
            args.add(String8(argv[i]));
        }
    }

    if (!niceName.isEmpty()) {
        runtime.setArgv0(niceName.string(), true /* setProcName */);
    }

    if (zygote) {
        runtime.start("com.android.internal.os.ZygoteInit", args, zygote);
    } else if (className) {
        runtime.start("com.android.internal.os.RuntimeInit", args, zygote);
    } else {
        fprintf(stderr, "Error: no class name or --zygote supplied.\n");
        app_usage();
        LOG_ALWAYS_FATAL("app_process: no class name or --zygote supplied.");
    }
}
```
android的核心服务是通过app_process启动的， app_process分两种模式：

1. zygote模式，这个会带有android的runtime
2. application模式，通过这个可以启动一个java程序即带有main函数的普通java程序，只要在启动app_process的时候制定main class就可以了


# zygote模式启动流程

我们查看AppRuntime的代码, AppRuntime的start函数在他的父类AndroidRuntime中

```cpp
class AppRuntime : public AndroidRuntime{};
```

frameworks/base/core/jni/AndroidRuntime.cpp
```cpp
void AndroidRuntime::start(const char* className, const Vector<String8>& options, bool zygote)
{
    // ... 设置一些环境变量

    /* start the virtual machine */
    JniInvocation jni_invocation;
    jni_invocation.Init(NULL);
    JNIEnv* env;
    if (startVm(&mJavaVM, &env, zygote, primary_zygote) != 0) {
        return;
    }
    onVmCreated(env);

    /*
     * Register android functions.
     */
    if (startReg(env) < 0) {
        ALOGE("Unable to register all android natives\n");
        return;
    }

    // ...

    /*
     * Start VM.  This thread becomes the main thread of the VM, and will
     * not return until the VM exits.
     */
    char* slashClassName = toSlashClassName(className != NULL ? className : "");
    jclass startClass = env->FindClass(slashClassName);
    if (startClass == NULL) {
        ALOGE("JavaVM unable to locate class '%s'\n", slashClassName);
        /* keep going */
    } else {
        jmethodID startMeth = env->GetStaticMethodID(startClass, "main",
            "([Ljava/lang/String;)V");
        if (startMeth == NULL) {
            ALOGE("JavaVM unable to find main() in '%s'\n", className);
            /* keep going */
        } else {
            env->CallStaticVoidMethod(startClass, startMeth, strArray);

#if 0
            if (env->ExceptionCheck())
                threadExitUncaughtException(env);
#endif
        }
    }
    free(slashClassName);

    ALOGD("Shutting down VM\n");
    if (mJavaVM->DetachCurrentThread() != JNI_OK)
        ALOGW("Warning: unable to detach main thread\n");
    if (mJavaVM->DestroyJavaVM() != 0)
        ALOGW("Warning: VM did not shut down cleanly\n");
}
```

这个函数主要做了以下几件事：

1. 设置一些环境变量
2. 启动ART虚拟机
3. 注册一些内置的jni函数
4. 将之前启动app_process的参数转成jstring数组类型，准备转入到java类的main函数中
5. 调用java类的main函数
6. 结束执行，做一些清理工作

因此，如果我们在zygote模式，剩下的工作会转交给ZygoteInit这个java类去执行，我们去查看它的main函数

frameworks/base/core/java/com/android/internal/os/ZygoteInit.java

```java
   public static void main(String argv[]) {
        ZygoteServer zygoteServer = null;

        // Mark zygote start. This ensures that thread creation will throw
        // an error.
        ZygoteHooks.startZygoteNoThreadCreation();

        // Zygote goes into its own process group.
        try {
            Os.setpgid(0, 0);
        } catch (ErrnoException ex) {
            throw new RuntimeException("Failed to setpgid(0,0)", ex);
        }

        Runnable caller;
        try {
            // ...
        
            // Do an initial gc to clean up after startup
            bootTimingsTraceLog.traceBegin("PostZygoteInitGC");
            gcAndFinalize();
            bootTimingsTraceLog.traceEnd(); // PostZygoteInitGC

            bootTimingsTraceLog.traceEnd(); // ZygoteInit

            Zygote.initNativeState(isPrimaryZygote);

            ZygoteHooks.stopZygoteNoThreadCreation();

            zygoteServer = new ZygoteServer(isPrimaryZygote);

            if (startSystemServer) {
                Runnable r = forkSystemServer(abiList, zygoteSocketName, zygoteServer);

                // {@code r == null} in the parent (zygote) process, and {@code r != null} in the
                // child (system_server) process.
                if (r != null) {
                    r.run();
                    return;
                }
            }

            Log.i(TAG, "Accepting command socket connections");

            // The select loop returns early in the child process after a fork and
            // loops forever in the zygote.
            caller = zygoteServer.runSelectLoop(abiList);
        } catch (Throwable ex) {
            Log.e(TAG, "System zygote died with exception", ex);
            throw ex;
        } finally {
            if (zygoteServer != null) {
                zygoteServer.closeServerSocket();
            }
        }

        // We're in the child process and have exited the select loop. Proceed to execute the
        // command.
        if (caller != null) {
            caller.run();
        }
    }
```

ZygoteInit主要做了这几件事：

1. 检查环境
2. gc，清理下当前的内存
2. 如果是启动时制定了 start-system-server 参数，那么直接启动系统服务就可以了。否则就是app运行时fork新的进程。

## ZygoteInit启动系统服务

启动system server在forkSystemServer函数中进行

```java
   private static Runnable forkSystemServer(String abiList, String socketName,
            ZygoteServer zygoteServer) {
        // ...
        String args[] = {
                "--setuid=1000",
                "--setgid=1000",
                "--setgroups=1001,1002,1003,1004,1005,1006,1007,1008,1009,1010,1018,1021,1023,"
                        + "1024,1032,1065,3001,3002,3003,3006,3007,3009,3010,3011",
                "--capabilities=" + capabilities + "," + capabilities,
                "--nice-name=system_server",
                "--runtime-args",
                "--target-sdk-version=" + VMRuntime.SDK_VERSION_CUR_DEVELOPMENT,
                "com.android.server.SystemServer",
        };
        // ...
        int pid;

        try {
            // ...
            /* Request to fork the system server process */
            pid = Zygote.forkSystemServer(
                    parsedArgs.mUid, parsedArgs.mGid,
                    parsedArgs.mGids,
                    parsedArgs.mRuntimeFlags,
                    null,
                    parsedArgs.mPermittedCapabilities,
                    parsedArgs.mEffectiveCapabilities);
        } catch (IllegalArgumentException ex) {
            throw new RuntimeException(ex);
        }

        /* For child process */
        if (pid == 0) {
            if (hasSecondZygote(abiList)) {
                waitForSecondaryZygote(socketName);
            }

            zygoteServer.closeServerSocket();
            return handleSystemServerProcess(parsedArgs);
        }

        return null;
    }
```

forkSystemServer主要还是调用native的方法

```java
static int forkSystemServer(int uid, int gid, int[] gids, int runtimeFlags,
            int[][] rlimits, long permittedCapabilities, long effectiveCapabilities) {
        ZygoteHooks.preFork();

        int pid = nativeForkSystemServer(
                uid, gid, gids, runtimeFlags, rlimits,
                permittedCapabilities, effectiveCapabilities);

        // Set the Java Language thread priority to the default value for new apps.
        Thread.currentThread().setPriority(Thread.NORM_PRIORITY);

        ZygoteHooks.postForkCommon();
        return pid;
    }
```

然后handleSystemServerProcess返回一个Runnable对象

```java
 private static Runnable handleSystemServerProcess(ZygoteArguments parsedArgs) {
        // ...

        if (parsedArgs.mInvokeWith != null) {
            // ...
        } else {
            ClassLoader cl = null;
            if (systemServerClasspath != null) {
                cl = createPathClassLoader(systemServerClasspath, parsedArgs.mTargetSdkVersion);

                Thread.currentThread().setContextClassLoader(cl);
            }

            /*
             * Pass the remaining arguments to SystemServer.
             */
            return ZygoteInit.zygoteInit(parsedArgs.mTargetSdkVersion,
                    parsedArgs.mDisabledCompatChanges,
                    parsedArgs.mRemainingArgs, cl);
        }

        /* should never reach here */
    }
```

实际调用转发到zygoteInit函数中

```java
 public static final Runnable zygoteInit(int targetSdkVersion, long[] disabledCompatChanges,
            String[] argv, ClassLoader classLoader) {
        // ...
        RuntimeInit.commonInit();
        ZygoteInit.nativeZygoteInit();
        return RuntimeInit.applicationInit(targetSdkVersion, disabledCompatChanges, argv,
                classLoader);
    }
```

接着调用applicationInit函数
```java
protected static Runnable applicationInit(int targetSdkVersion, long[] disabledCompatChanges,
            String[] argv, ClassLoader classLoader) {
        // If the application calls System.exit(), terminate the process
        // immediately without running any shutdown hooks.  It is not possible to
        // shutdown an Android application gracefully.  Among other things, the
        // Android runtime shutdown hooks close the Binder driver, which can cause
        // leftover running threads to crash before the process actually exits.
        nativeSetExitWithoutCleanup(true);

        VMRuntime.getRuntime().setTargetSdkVersion(targetSdkVersion);
        VMRuntime.getRuntime().setDisabledCompatChanges(disabledCompatChanges);

        final Arguments args = new Arguments(argv);

        // The end of of the RuntimeInit event (see #zygoteInit).
        Trace.traceEnd(Trace.TRACE_TAG_ACTIVITY_MANAGER);

        // Remaining arguments are passed to the start class's static main
        return findStaticMain(args.startClass, args.startArgs, classLoader);
    }
```

最后调用会转发到findStaticMain函数中，注意这里传入了一个startClass, 这个值在forkSystemServer的时候就制定了即com.android.server.SystemServer

```java
   protected static Runnable findStaticMain(String className, String[] argv,
            ClassLoader classLoader) {
        Class<?> cl;

        try {
            cl = Class.forName(className, true, classLoader);
        } catch (ClassNotFoundException ex) {
            throw new RuntimeException(
                    "Missing class when invoking static main " + className,
                    ex);
        }

        Method m;
        try {
            m = cl.getMethod("main", new Class[] { String[].class });
        } catch (NoSuchMethodException ex) {
            throw new RuntimeException(
                    "Missing static main on " + className, ex);
        } catch (SecurityException ex) {
            throw new RuntimeException(
                    "Problem getting static main on " + className, ex);
        }

        int modifiers = m.getModifiers();
        if (! (Modifier.isStatic(modifiers) && Modifier.isPublic(modifiers))) {
            throw new RuntimeException(
                    "Main method is not public and static on " + className);
        }

        /*
         * This throw gets caught in ZygoteInit.main(), which responds
         * by invoking the exception's run() method. This arrangement
         * clears up all the stack frames that were required in setting
         * up the process.
         */
        return new MethodAndArgsCaller(m, argv);
    }
```

MathodAndArgsCaller的定义如下

```java
   static class MethodAndArgsCaller implements Runnable {
        /** method to call */
        private final Method mMethod;

        /** argument array */
        private final String[] mArgs;

        public MethodAndArgsCaller(Method method, String[] args) {
            mMethod = method;
            mArgs = args;
        }

        public void run() {
            try {
                mMethod.invoke(null, new Object[] { mArgs });
            } catch (IllegalAccessException ex) {
                throw new RuntimeException(ex);
            } catch (InvocationTargetException ex) {
                Throwable cause = ex.getCause();
                if (cause instanceof RuntimeException) {
                    throw (RuntimeException) cause;
                } else if (cause instanceof Error) {
                    throw (Error) cause;
                }
                throw new RuntimeException(ex);
            }
        }
    }
```

其实就是反射调用main函数

SystemServer在/home/chan/Documents/aosp/frameworks/base/services/java/com/android/server/SystemServer.java中定义

```java
    public static void main(String[] args) {
        new SystemServer().run();
    }
```

先new了一个SystemServer实例，然后调用它的run方法

```java
 private void run() {
        // ...
        try {
            t.traceBegin("InitBeforeStartServices");

            // Record the process start information in sys props.
            SystemProperties.set(SYSPROP_START_COUNT, String.valueOf(mStartCount));
            SystemProperties.set(SYSPROP_START_ELAPSED, String.valueOf(mRuntimeStartElapsedTime));
            SystemProperties.set(SYSPROP_START_UPTIME, String.valueOf(mRuntimeStartUptime));

            EventLog.writeEvent(EventLogTags.SYSTEM_SERVER_START,
                    mStartCount, mRuntimeStartUptime, mRuntimeStartElapsedTime);

            //
            // Default the timezone property to GMT if not set.
            //
            String timezoneProperty = SystemProperties.get("persist.sys.timezone");
            if (!isValidTimeZoneId(timezoneProperty)) {
                Slog.w(TAG, "persist.sys.timezone is not valid (" + timezoneProperty
                        + "); setting to GMT.");
                SystemProperties.set("persist.sys.timezone", "GMT");
            }

            // If the system has "persist.sys.language" and friends set, replace them with
            // "persist.sys.locale". Note that the default locale at this point is calculated
            // using the "-Duser.locale" command line flag. That flag is usually populated by
            // AndroidRuntime using the same set of system properties, but only the system_server
            // and system apps are allowed to set them.
            //
            // NOTE: Most changes made here will need an equivalent change to
            // core/jni/AndroidRuntime.cpp
            if (!SystemProperties.get("persist.sys.language").isEmpty()) {
                final String languageTag = Locale.getDefault().toLanguageTag();

                SystemProperties.set("persist.sys.locale", languageTag);
                SystemProperties.set("persist.sys.language", "");
                SystemProperties.set("persist.sys.country", "");
                SystemProperties.set("persist.sys.localevar", "");
            }

            // The system server should never make non-oneway calls
            Binder.setWarnOnBlocking(true);
            // The system server should always load safe labels
            PackageItemInfo.forceSafeLabels();

            // Default to FULL within the system server.
            SQLiteGlobal.sDefaultSyncMode = SQLiteGlobal.SYNC_MODE_FULL;

            // Deactivate SQLiteCompatibilityWalFlags until settings provider is initialized
            SQLiteCompatibilityWalFlags.init(null);

            // Here we go!
            Slog.i(TAG, "Entered the Android system server!");
            final long uptimeMillis = SystemClock.elapsedRealtime();
            EventLog.writeEvent(EventLogTags.BOOT_PROGRESS_SYSTEM_RUN, uptimeMillis);
            if (!mRuntimeRestart) {
                FrameworkStatsLog.write(FrameworkStatsLog.BOOT_TIME_EVENT_ELAPSED_TIME_REPORTED,
                        FrameworkStatsLog
                                .BOOT_TIME_EVENT_ELAPSED_TIME__EVENT__SYSTEM_SERVER_INIT_START,
                        uptimeMillis);
            }

            // In case the runtime switched since last boot (such as when
            // the old runtime was removed in an OTA), set the system
            // property so that it is in sync. We can't do this in
            // libnativehelper's JniInvocation::Init code where we already
            // had to fallback to a different runtime because it is
            // running as root and we need to be the system user to set
            // the property. http://b/11463182
            SystemProperties.set("persist.sys.dalvik.vm.lib.2", VMRuntime.getRuntime().vmLibrary());

            // Mmmmmm... more memory!
            VMRuntime.getRuntime().clearGrowthLimit();

            // Some devices rely on runtime fingerprint generation, so make sure
            // we've defined it before booting further.
            Build.ensureFingerprintProperty();

            // Within the system server, it is an error to access Environment paths without
            // explicitly specifying a user.
            Environment.setUserRequired(true);

            // Within the system server, any incoming Bundles should be defused
            // to avoid throwing BadParcelableException.
            BaseBundle.setShouldDefuse(true);

            // Within the system server, when parceling exceptions, include the stack trace
            Parcel.setStackTraceParceling(true);

            // Ensure binder calls into the system always run at foreground priority.
            BinderInternal.disableBackgroundScheduling(true);

            // Increase the number of binder threads in system_server
            BinderInternal.setMaxThreads(sMaxBinderThreads);

            // Prepare the main looper thread (this thread).
            android.os.Process.setThreadPriority(
                    android.os.Process.THREAD_PRIORITY_FOREGROUND);
            android.os.Process.setCanSelfBackground(false);
            Looper.prepareMainLooper();
            Looper.getMainLooper().setSlowLogThresholdMs(
                    SLOW_DISPATCH_THRESHOLD_MS, SLOW_DELIVERY_THRESHOLD_MS);

            SystemServiceRegistry.sEnableServiceNotFoundWtf = true;

            // Initialize native services.
            System.loadLibrary("android_servers");

            // Allow heap / perf profiling.
            initZygoteChildHeapProfiling();

            // Debug builds - spawn a thread to monitor for fd leaks.
            if (Build.IS_DEBUGGABLE) {
                spawnFdLeakCheckThread();
            }

            // Check whether we failed to shut down last time we tried.
            // This call may not return.
            performPendingShutdown();

            // Initialize the system context.
            createSystemContext();

            // Call per-process mainline module initialization.
            ActivityThread.initializeMainlineModules();

            // Create the system service manager.
            mSystemServiceManager = new SystemServiceManager(mSystemContext);
            mSystemServiceManager.setStartInfo(mRuntimeRestart,
                    mRuntimeStartElapsedTime, mRuntimeStartUptime);
            LocalServices.addService(SystemServiceManager.class, mSystemServiceManager);
            // Prepare the thread pool for init tasks that can be parallelized
            SystemServerInitThreadPool.start();
            // Attach JVMTI agent if this is a debuggable build and the system property is set.
            if (Build.IS_DEBUGGABLE) {
                // Property is of the form "library_path=parameters".
                String jvmtiAgent = SystemProperties.get("persist.sys.dalvik.jvmtiagent");
                if (!jvmtiAgent.isEmpty()) {
                    int equalIndex = jvmtiAgent.indexOf('=');
                    String libraryPath = jvmtiAgent.substring(0, equalIndex);
                    String parameterList =
                            jvmtiAgent.substring(equalIndex + 1, jvmtiAgent.length());
                    // Attach the agent.
                    try {
                        Debug.attachJvmtiAgent(libraryPath, parameterList, null);
                    } catch (Exception e) {
                        Slog.e("System", "*************************************************");
                        Slog.e("System", "********** Failed to load jvmti plugin: " + jvmtiAgent);
                    }
                }
            }
        } finally {
            t.traceEnd();  // InitBeforeStartServices
        }

        // Setup the default WTF handler
        RuntimeInit.setDefaultApplicationWtfHandler(SystemServer::handleEarlySystemWtf);

        // Start services.
        try {
            t.traceBegin("StartServices");
            startBootstrapServices(t);
            startCoreServices(t);
            startOtherServices(t);
        } catch (Throwable ex) {
            Slog.e("System", "******************************************");
            Slog.e("System", "************ Failure starting system services", ex);
            throw ex;
        } finally {
            t.traceEnd(); // StartServices
        }

        StrictMode.initVmDefaults(null);

        if (!mRuntimeRestart && !isFirstBootOrUpgrade()) {
            final long uptimeMillis = SystemClock.elapsedRealtime();
            FrameworkStatsLog.write(FrameworkStatsLog.BOOT_TIME_EVENT_ELAPSED_TIME_REPORTED,
                    FrameworkStatsLog.BOOT_TIME_EVENT_ELAPSED_TIME__EVENT__SYSTEM_SERVER_READY,
                    uptimeMillis);
            final long maxUptimeMillis = 60 * 1000;
            if (uptimeMillis > maxUptimeMillis) {
                Slog.wtf(SYSTEM_SERVER_TIMING_TAG,
                        "SystemServer init took too long. uptimeMillis=" + uptimeMillis);
            }
        }

        // Loop forever.
        Looper.loop();
        throw new RuntimeException("Main thread loop unexpectedly exited");
    }
```

## ZygoteInit从应用进程fork

# application模式启动流程application