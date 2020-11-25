# ART虚拟机启动流程

在app_process中，android会创建一个AppRuntime对象来启动zygote进程。AppRuntime在启动zygote之前会启动art虚拟机以此来执行java代码

```cpp
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
```

JniInvocation的代码在libnativehelper/include_platform/nativehelper/JniInvocation.h中

```cpp
  // Initialize JNI invocation API. library should specify a valid
  // shared library for opening via dlopen providing a JNI invocation
  // implementation, or null to allow defaulting via
  // persist.sys.dalvik.vm.lib.
  bool Init(const char* library) {
    return JniInvocationInit(impl_, library) != 0;
  }

```

init函数其实就是调用JniInvocationInit转发下

libnativehelper/JniInvocation.c

```cpp
bool JniInvocationInit(struct JniInvocationImpl* instance, const char* library_name) {
#ifdef __ANDROID__
  char buffer[PROP_VALUE_MAX];
#else
  char* buffer = NULL;
#endif
  library_name = JniInvocationGetLibrary(library_name, buffer);
  DlLibrary library = DlOpenLibrary(library_name);
  if (library == NULL) {
    if (strcmp(library_name, kDefaultJniInvocationLibrary) == 0) {
      // Nothing else to try.
      ALOGE("Failed to dlopen %s: %s", library_name, DlGetError());
      return false;
    }
    // Note that this is enough to get something like the zygote
    // running, we can't property_set here to fix this for the future
    // because we are root and not the system user. See
    // RuntimeInit.commonInit for where we fix up the property to
    // avoid future fallbacks. http://b/11463182
    ALOGW("Falling back from %s to %s after dlopen error: %s",
          library_name, kDefaultJniInvocationLibrary, DlGetError());
    library_name = kDefaultJniInvocationLibrary;
    library = DlOpenLibrary(library_name);
    if (library == NULL) {
      ALOGE("Failed to dlopen %s: %s", library_name, DlGetError());
      return false;
    }
  }

  DlSymbol JNI_GetDefaultJavaVMInitArgs_ = FindSymbol(library, "JNI_GetDefaultJavaVMInitArgs");
  if (JNI_GetDefaultJavaVMInitArgs_ == NULL) {
    return false;
  }

  DlSymbol JNI_CreateJavaVM_ = FindSymbol(library, "JNI_CreateJavaVM");
  if (JNI_CreateJavaVM_ == NULL) {
    return false;
  }

  DlSymbol JNI_GetCreatedJavaVMs_ = FindSymbol(library, "JNI_GetCreatedJavaVMs");
  if (JNI_GetCreatedJavaVMs_ == NULL) {
    return false;
  }

  instance->jni_provider_library_name = library_name;
  instance->jni_provider_library = library;
  instance->JNI_GetDefaultJavaVMInitArgs = (jint (*)(void *)) JNI_GetDefaultJavaVMInitArgs_;
  instance->JNI_CreateJavaVM = (jint (*)(JavaVM**, JNIEnv**, void*)) JNI_CreateJavaVM_;
  instance->JNI_GetCreatedJavaVMs = (jint (*)(JavaVM**, jsize, jsize*)) JNI_GetCreatedJavaVMs_;

  return true;
}
```

这里的instance其实是一个全局的对象， DLopen打开一个so后会把找到的函数都赋值给他。

```cpp
struct JniInvocationImpl {
  // Name of library providing JNI_ method implementations.
  const char* jni_provider_library_name;

  // Opaque pointer to shared library from dlopen / LoadLibrary.
  void* jni_provider_library;

  // Function pointers to methods in JNI provider.
  jint (*JNI_GetDefaultJavaVMInitArgs)(void*);
  jint (*JNI_CreateJavaVM)(JavaVM**, JNIEnv**, void*);
  jint (*JNI_GetCreatedJavaVMs)(JavaVM**, jsize, jsize*);
};

static struct JniInvocationImpl g_impl;
```

现在我们要看下dlopen的到底是什么so

```cpp
const char* JniInvocationGetLibrary(const char* library, char* buffer) {
  bool debuggable = IsDebuggable();
  const char* system_preferred_library = NULL;
  if (buffer != NULL && (GetLibrarySystemProperty(buffer) > 0)) {
    system_preferred_library = buffer;
  }
  return JniInvocationGetLibraryWith(library, debuggable, system_preferred_library);
}
```

GetLibrarySystemProperty 函数读取了一个系统属性，然后传给了JniInvocationGetLibraryWith
```cpp
static int GetLibrarySystemProperty(char* buffer) {
#ifdef __ANDROID__
  return __system_property_get("persist.sys.dalvik.vm.lib.2", buffer);
#else
  // Host does not use properties.
  UNUSED(buffer);
  return 0;
#endif
}
```

这个函数目前我搜了下，返回的应该是libart.so，这个占坑下，后面在具体分析 system/libbase/properties.cpp

```cpp

const char* JniInvocationGetLibraryWith(const char* library,
                                        bool is_debuggable,
                                        const char* system_preferred_library) {
  if (is_debuggable) {
    // Debuggable property is set. Allow library providing JNI Invocation API to be overridden.

    // Choose the library parameter (if provided).
    if (library != NULL) {
      return library;
    }
    // Choose the system_preferred_library (if provided).
    if (system_preferred_library != NULL) {
      return system_preferred_library;
    }
  }
  return kDefaultJniInvocationLibrary;
}
```

好坑，kDefaultJniInvocationLibrary值居然就是libart.so，刚刚一堆分析代码只有在debug模式下才工作

```cpp
// Name the default library providing the JNI Invocation API.
static const char* kDefaultJniInvocationLibrary = "libart.so";
```
