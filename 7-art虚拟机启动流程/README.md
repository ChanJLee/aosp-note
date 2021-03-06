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

JniInvocationInit.Init函数就分析完了，其实就是找到创建jvm的函数指针。

接下来会调用startVm来启动虚拟机。

```cpp
int AndroidRuntime::startVm(JavaVM** pJavaVM, JNIEnv** pEnv, bool zygote, bool primary_zygote)
{
    JavaVMInitArgs initArgs;
    // ...

    initArgs.version = JNI_VERSION_1_4;
    initArgs.options = mOptions.editArray();
    initArgs.nOptions = mOptions.size();
    initArgs.ignoreUnrecognized = JNI_FALSE;

    /*
     * Initialize the VM.
     *
     * The JavaVM* is essentially per-process, and the JNIEnv* is per-thread.
     * If this call succeeds, the VM is ready, and we can start issuing
     * JNI calls.
     */
    if (JNI_CreateJavaVM(pJavaVM, pEnv, &initArgs) < 0) {
        ALOGE("JNI_CreateJavaVM failed\n");
        return -1;
    }

    return 0;
}
```

这个函数解析了一大堆复杂的参数，然后调用 JNI_CreateJavaVM 函数，这个函数的定义在
art/runtime/jni/java_vm_ext.cc

```cpp
extern "C" jint JNI_CreateJavaVM(JavaVM** p_vm, JNIEnv** p_env, void* vm_args) {
  // ...
  if (!Runtime::Create(options, ignore_unrecognized)) {
    return JNI_ERR;
  }

  // Initialize native loader. This step makes sure we have
  // everything set up before we start using JNI.
  android::InitializeNativeLoader();

  Runtime* runtime = Runtime::Current();
  bool started = runtime->Start();
  if (!started) {
    delete Thread::Current()->GetJniEnv();
    delete runtime->GetJavaVM();
    LOG(WARNING) << "CreateJavaVM failed";
    return JNI_ERR;
  }

  *p_env = Thread::Current()->GetJniEnv();
  *p_vm = runtime->GetJavaVM();
  return JNI_OK;
}
```

先是创建Runtime，然后在jni调用前启动native loader。成功后获取当前的JniEnv，以及获取jvm对象。

Runtime的Create函数它的定义在
art/runtime/runtime.cc
```cpp
bool Runtime::Create(RuntimeArgumentMap&& runtime_options) {
  // TODO: acquire a static mutex on Runtime to avoid racing.
  if (Runtime::instance_ != nullptr) {
    return false;
  }
  instance_ = new Runtime;
  Locks::SetClientCallback(IsSafeToCallAbort);
  if (!instance_->Init(std::move(runtime_options))) {
    // TODO: Currently deleting the instance will abort the runtime on destruction. Now This will
    // leak memory, instead. Fix the destructor. b/19100793.
    // delete instance_;
    instance_ = nullptr;
    return false;
  }
  return true;
}

bool Runtime::Create(const RuntimeOptions& raw_options, bool ignore_unrecognized) {
  RuntimeArgumentMap runtime_options;
  return ParseOptions(raw_options, ignore_unrecognized, &runtime_options) &&
      Create(std::move(runtime_options));
}
```

首先它防止了重复创建，然后new一个Runtime设置到instance_里。再调用Init函数进行初始化。
```cpp
bool Runtime::Init(RuntimeArgumentMap&& runtime_options_in) {
  //...

  MemMap::Init();

  // ...

  heap_ = new gc::Heap(runtime_options.GetOrDefault(Opt::MemoryInitialSize),
                       runtime_options.GetOrDefault(Opt::HeapGrowthLimit),
                       runtime_options.GetOrDefault(Opt::HeapMinFree),
                       runtime_options.GetOrDefault(Opt::HeapMaxFree),
                       runtime_options.GetOrDefault(Opt::HeapTargetUtilization),
                       foreground_heap_growth_multiplier,
                       runtime_options.GetOrDefault(Opt::StopForNativeAllocs),
                       runtime_options.GetOrDefault(Opt::MemoryMaximumSize),
                       runtime_options.GetOrDefault(Opt::NonMovingSpaceCapacity),
                       GetBootClassPath(),
                       GetBootClassPathLocations(),
                       image_location_,
                       instruction_set_,
                       // Override the collector type to CC if the read barrier config.
                       kUseReadBarrier ? gc::kCollectorTypeCC : xgc_option.collector_type_,
                       kUseReadBarrier ? BackgroundGcOption(gc::kCollectorTypeCCBackground)
                                       : runtime_options.GetOrDefault(Opt::BackgroundGc),
                       runtime_options.GetOrDefault(Opt::LargeObjectSpace),
                       runtime_options.GetOrDefault(Opt::LargeObjectThreshold),
                       runtime_options.GetOrDefault(Opt::ParallelGCThreads),
                       runtime_options.GetOrDefault(Opt::ConcGCThreads),
                       runtime_options.Exists(Opt::LowMemoryMode),
                       runtime_options.GetOrDefault(Opt::LongPauseLogThreshold),
                       runtime_options.GetOrDefault(Opt::LongGCLogThreshold),
                       runtime_options.Exists(Opt::IgnoreMaxFootprint),
                       runtime_options.GetOrDefault(Opt::AlwaysLogExplicitGcs),
                       runtime_options.GetOrDefault(Opt::UseTLAB),
                       xgc_option.verify_pre_gc_heap_,
                       xgc_option.verify_pre_sweeping_heap_,
                       xgc_option.verify_post_gc_heap_,
                       xgc_option.verify_pre_gc_rosalloc_,
                       xgc_option.verify_pre_sweeping_rosalloc_,
                       xgc_option.verify_post_gc_rosalloc_,
                       xgc_option.gcstress_,
                       xgc_option.measure_,
                       runtime_options.GetOrDefault(Opt::EnableHSpaceCompactForOOM),
                       use_generational_cc,
                       runtime_options.GetOrDefault(Opt::HSpaceCompactForOOMMinIntervalsMs),
                       runtime_options.Exists(Opt::DumpRegionInfoBeforeGC),
                       runtime_options.Exists(Opt::DumpRegionInfoAfterGC));

 
  // ...

  std::string error_msg;
  java_vm_ = JavaVMExt::Create(this, runtime_options, &error_msg);
  if (java_vm_.get() == nullptr) {
    LOG(ERROR) << "Could not initialize JavaVMExt: " << error_msg;
    return false;
  }

  //...

  Thread::Startup();

  // ClassLinker needs an attached thread, but we can't fully attach a thread without creating
  // objects. We can't supply a thread group yet; it will be fixed later. Since we are the main
  // thread, we do not get a java peer.
  Thread* self = Thread::Attach("main", false, nullptr, false);
  CHECK_EQ(self->GetThreadId(), ThreadList::kMainThreadId);
  CHECK(self != nullptr);

  self->SetIsRuntimeThread(IsAotCompiler());

  // Set us to runnable so tools using a runtime can allocate and GC by default
  self->TransitionFromSuspendedToRunnable();

  // ...

  if (UNLIKELY(IsAotCompiler())) {
    class_linker_ = new AotClassLinker(intern_table_);
  } else {
    class_linker_ = new ClassLinker(
        intern_table_,
        runtime_options.GetOrDefault(Opt::FastClassNotFoundException));
  }
  if (GetHeap()->HasBootImageSpace()) {
    // ...
  } else {
    std::vector<std::unique_ptr<const DexFile>> boot_class_path;
    if (runtime_options.Exists(Opt::BootClassPathDexList)) {
      boot_class_path.swap(*runtime_options.GetOrDefault(Opt::BootClassPathDexList));
    } else {
      OpenBootDexFiles(ArrayRef<const std::string>(GetBootClassPath()),
                       ArrayRef<const std::string>(GetBootClassPathLocations()),
                       &boot_class_path);
    }
    if (!class_linker_->InitWithoutImage(std::move(boot_class_path), &error_msg)) {
      LOG(ERROR) << "Could not initialize without image: " << error_msg;
      return false;
    }

    // TODO: Should we move the following to InitWithoutImage?
    SetInstructionSet(instruction_set_);
    for (uint32_t i = 0; i < kCalleeSaveSize; i++) {
      CalleeSaveType type = CalleeSaveType(i);
      if (!HasCalleeSaveMethod(type)) {
        SetCalleeSaveMethod(CreateCalleeSaveMethod(), type);
      }
    }
  }

  CHECK(class_linker_ != nullptr);

  verifier::ClassVerifier::Init(class_linker_);
  // ...

  if (GetHeap()->HasBootImageSpace()) {
    const ImageHeader& image_header = GetHeap()->GetBootImageSpaces()[0]->GetImageHeader();
    ObjPtr<mirror::ObjectArray<mirror::Object>> boot_image_live_objects =
        ObjPtr<mirror::ObjectArray<mirror::Object>>::DownCast(
            image_header.GetImageRoot(ImageHeader::kBootImageLiveObjects));
    pre_allocated_OutOfMemoryError_when_throwing_exception_ = GcRoot<mirror::Throwable>(
        boot_image_live_objects->Get(ImageHeader::kOomeWhenThrowingException)->AsThrowable());
    DCHECK(pre_allocated_OutOfMemoryError_when_throwing_exception_.Read()->GetClass()
               ->DescriptorEquals("Ljava/lang/OutOfMemoryError;"));
    pre_allocated_OutOfMemoryError_when_throwing_oome_ = GcRoot<mirror::Throwable>(
        boot_image_live_objects->Get(ImageHeader::kOomeWhenThrowingOome)->AsThrowable());
    DCHECK(pre_allocated_OutOfMemoryError_when_throwing_oome_.Read()->GetClass()
               ->DescriptorEquals("Ljava/lang/OutOfMemoryError;"));
    pre_allocated_OutOfMemoryError_when_handling_stack_overflow_ = GcRoot<mirror::Throwable>(
        boot_image_live_objects->Get(ImageHeader::kOomeWhenHandlingStackOverflow)->AsThrowable());
    DCHECK(pre_allocated_OutOfMemoryError_when_handling_stack_overflow_.Read()->GetClass()
               ->DescriptorEquals("Ljava/lang/OutOfMemoryError;"));
    pre_allocated_NoClassDefFoundError_ = GcRoot<mirror::Throwable>(
        boot_image_live_objects->Get(ImageHeader::kNoClassDefFoundError)->AsThrowable());
    DCHECK(pre_allocated_NoClassDefFoundError_.Read()->GetClass()
               ->DescriptorEquals("Ljava/lang/NoClassDefFoundError;"));
  } else {
    // ...
  }

  // Class-roots are setup, we can now finish initializing the JniIdManager.
  GetJniIdManager()->Init(self);

  // ...
  return true;
}
```

Init非常复杂，我能看到的有这几步

1. 初始化MemMap

2. 初始化GC的堆

3. 调用JavaVMExt的Create函数

4. 创建主线程

5. 创建class linker

6. 加载boot class

7. 初始化主线程的jni

第一步和第二步跟GC有关，我们这次不考虑分析。


```cpp
std::unique_ptr<JavaVMExt> JavaVMExt::Create(Runtime* runtime,
                                             const RuntimeArgumentMap& runtime_options,
                                             std::string* error_msg) NO_THREAD_SAFETY_ANALYSIS {
  std::unique_ptr<JavaVMExt> java_vm(new JavaVMExt(runtime, runtime_options, error_msg));
  if (java_vm && java_vm->globals_.IsValid() && java_vm->weak_globals_.IsValid()) {
    return java_vm;
  }
  return nullptr;
}
```

create函数很简单，就是新建一个JavaVMExt对象。
art/runtime/thread.cc

```cpp
Thread* Thread::Attach(const char* thread_name,
                       bool as_daemon,
                       jobject thread_group,
                       bool create_peer) {
  auto create_peer_action = [&](Thread* self) {
    if (create_peer) {
      // ...
    } else {
      // These aren't necessary, but they improve diagnostics for unit tests & command-line tools.
      if (thread_name != nullptr) {
        self->tlsPtr_.name->assign(thread_name);
        ::art::SetThreadName(thread_name);
      }
      // ...
    }
    return true;
  };
  return Attach(thread_name, as_daemon, create_peer_action);
}
```

线程的创建会转发给另外一个函数

```cpp
template <typename PeerAction>
Thread* Thread::Attach(const char* thread_name, bool as_daemon, PeerAction peer_action) {
  Runtime* runtime = Runtime::Current();
  // ...
  Thread* self;
  {
    ScopedTrace trace2("Thread birth");
    MutexLock mu(nullptr, *Locks::runtime_shutdown_lock_);
    if (runtime->IsShuttingDownLocked()) {
      LOG(WARNING) << "Thread attaching while runtime is shutting down: " <<
          ((thread_name != nullptr) ? thread_name : "(Unnamed)");
      return nullptr;
    } else {
      Runtime::Current()->StartThreadBirth();
      self = new Thread(as_daemon);
      bool init_success = self->Init(runtime->GetThreadList(), runtime->GetJavaVM());
      Runtime::Current()->EndThreadBirth();
      if (!init_success) {
        delete self;
        return nullptr;
      }
    }
  }

  self->InitStringEntryPoints();

  CHECK_NE(self->GetState(), kRunnable);
  self->SetState(kNative);

  // Run the action that is acting on the peer.
  if (!peer_action(self)) {
    runtime->GetThreadList()->Unregister(self);
    // Unregister deletes self, no need to do this here.
    return nullptr;
  }

  if (VLOG_IS_ON(threads)) {
    if (thread_name != nullptr) {
      VLOG(threads) << "Attaching thread " << thread_name;
    } else {
      VLOG(threads) << "Attaching unnamed thread.";
    }
    ScopedObjectAccess soa(self);
    self->Dump(LOG_STREAM(INFO));
  }

  {
    ScopedObjectAccess soa(self);
    runtime->GetRuntimeCallbacks()->ThreadStart(self);
  }

  return self;
}
```

Thread先是创建一个对象，这个方法比较简单，就是设置各种属性。然后调用Init函数

```cpp

bool Thread::Init(ThreadList* thread_list, JavaVMExt* java_vm, JNIEnvExt* jni_env_ext) {
  // This function does all the initialization that must be run by the native thread it applies to.
  // (When we create a new thread from managed code, we allocate the Thread* in Thread::Create so
  // we can handshake with the corresponding native thread when it's ready.) Check this native
  // thread hasn't been through here already...
  CHECK(Thread::Current() == nullptr);

  // Set pthread_self_ ahead of pthread_setspecific, that makes Thread::Current function, this
  // avoids pthread_self_ ever being invalid when discovered from Thread::Current().
  tlsPtr_.pthread_self = pthread_self();
  CHECK(is_started_);

  ScopedTrace trace("Thread::Init");

  SetUpAlternateSignalStack();
  if (!InitStackHwm()) {
    return false;
  }
  InitCpu();
  InitTlsEntryPoints();
  RemoveSuspendTrigger();
  InitCardTable();
  InitTid();
  {
    ScopedTrace trace2("InitInterpreterTls");
    interpreter::InitInterpreterTls(this);
  }

#ifdef __BIONIC__
  __get_tls()[TLS_SLOT_ART_THREAD_SELF] = this;
#else
  CHECK_PTHREAD_CALL(pthread_setspecific, (Thread::pthread_key_self_, this), "attach self");
  Thread::self_tls_ = this;
#endif
  DCHECK_EQ(Thread::Current(), this);

  tls32_.thin_lock_thread_id = thread_list->AllocThreadId(this);

  if (jni_env_ext != nullptr) {
    DCHECK_EQ(jni_env_ext->GetVm(), java_vm);
    DCHECK_EQ(jni_env_ext->GetSelf(), this);
    tlsPtr_.jni_env = jni_env_ext;
  } else {
    std::string error_msg;
    tlsPtr_.jni_env = JNIEnvExt::Create(this, java_vm, &error_msg);
    if (tlsPtr_.jni_env == nullptr) {
      LOG(ERROR) << "Failed to create JNIEnvExt: " << error_msg;
      return false;
    }
  }

  ScopedTrace trace3("ThreadList::Register");
  thread_list->Register(this);
  return true;
}
```

Init函数很复杂，显示通过pthread函数创建一个线程， 然后通过pthrea提供的接口获取栈信息，最终要的是创建当前线程的jni env，然后调用
thread_list->Register(this); 将自己添加到线程列表里。线程列表在Runtime里。

创建完主线程，剩下的就是创建class linker，class linker是用来给class loader加载类用的。

art/runtime/class_linker.cc
```cpp
ClassLinker::ClassLinker(InternTable* intern_table, bool fast_class_not_found_exceptions)
    : boot_class_table_(new ClassTable()),
      failed_dex_cache_class_lookups_(0),
      class_roots_(nullptr),
      find_array_class_cache_next_victim_(0),
      init_done_(false),
      log_new_roots_(false),
      intern_table_(intern_table),
      fast_class_not_found_exceptions_(fast_class_not_found_exceptions),
      jni_dlsym_lookup_trampoline_(nullptr),
      jni_dlsym_lookup_critical_trampoline_(nullptr),
      quick_resolution_trampoline_(nullptr),
      quick_imt_conflict_trampoline_(nullptr),
      quick_generic_jni_trampoline_(nullptr),
      quick_to_interpreter_bridge_trampoline_(nullptr),
      image_pointer_size_(kRuntimePointerSize),
      visibly_initialized_callback_lock_("visibly initialized callback lock"),
      visibly_initialized_callback_(nullptr),
      critical_native_code_with_clinit_check_lock_("critical native code with clinit check lock"),
      critical_native_code_with_clinit_check_(),
      cha_(Runtime::Current()->IsAotCompiler() ? nullptr : new ClassHierarchyAnalysis()) {
  // For CHA disabled during Aot, see b/34193647.

  CHECK(intern_table_ != nullptr);
  static_assert(kFindArrayCacheSize == arraysize(find_array_class_cache_),
                "Array cache size wrong.");
  std::fill_n(find_array_class_cache_, kFindArrayCacheSize, GcRoot<mirror::Class>(nullptr));
}
```

加载boot class是通过class linker完成的 InitWithoutImage

```cpp
bool ClassLinker::InitWithoutImage(std::vector<std::unique_ptr<const DexFile>> boot_class_path,
                                   std::string* error_msg) {
  VLOG(startup) << "ClassLinker::Init";

  Thread* const self = Thread::Current();
  Runtime* const runtime = Runtime::Current();
  gc::Heap* const heap = runtime->GetHeap();

  CHECK(!heap->HasBootImageSpace()) << "Runtime has image. We should use it.";
  CHECK(!init_done_);

  // Use the pointer size from the runtime since we are probably creating the image.
  image_pointer_size_ = InstructionSetPointerSize(runtime->GetInstructionSet());

  // java_lang_Class comes first, it's needed for AllocClass
  // The GC can't handle an object with a null class since we can't get the size of this object.
  heap->IncrementDisableMovingGC(self);
  StackHandleScope<64> hs(self);  // 64 is picked arbitrarily.
  auto class_class_size = mirror::Class::ClassClassSize(image_pointer_size_);
  // Allocate the object as non-movable so that there are no cases where Object::IsClass returns
  // the incorrect result when comparing to-space vs from-space.
  Handle<mirror::Class> java_lang_Class(hs.NewHandle(ObjPtr<mirror::Class>::DownCast(
      heap->AllocNonMovableObject(self, nullptr, class_class_size, VoidFunctor()))));
  CHECK(java_lang_Class != nullptr);
  java_lang_Class->SetClassFlags(mirror::kClassFlagClass);
  java_lang_Class->SetClass(java_lang_Class.Get());
  if (kUseBakerReadBarrier) {
    java_lang_Class->AssertReadBarrierState();
  }
  java_lang_Class->SetClassSize(class_class_size);
  java_lang_Class->SetPrimitiveType(Primitive::kPrimNot);
  heap->DecrementDisableMovingGC(self);
  // AllocClass(ObjPtr<mirror::Class>) can now be used

  // Class[] is used for reflection support.
  auto class_array_class_size = mirror::ObjectArray<mirror::Class>::ClassSize(image_pointer_size_);
  Handle<mirror::Class> class_array_class(hs.NewHandle(
      AllocClass(self, java_lang_Class.Get(), class_array_class_size)));
  class_array_class->SetComponentType(java_lang_Class.Get());

  // java_lang_Object comes next so that object_array_class can be created.
  Handle<mirror::Class> java_lang_Object(hs.NewHandle(
      AllocClass(self, java_lang_Class.Get(), mirror::Object::ClassSize(image_pointer_size_))));
  CHECK(java_lang_Object != nullptr);
  // backfill Object as the super class of Class.
  java_lang_Class->SetSuperClass(java_lang_Object.Get());
  mirror::Class::SetStatus(java_lang_Object, ClassStatus::kLoaded, self);

  java_lang_Object->SetObjectSize(sizeof(mirror::Object));
  // Allocate in non-movable so that it's possible to check if a JNI weak global ref has been
  // cleared without triggering the read barrier and unintentionally mark the sentinel alive.
  runtime->SetSentinel(heap->AllocNonMovableObject(self,
                                                   java_lang_Object.Get(),
                                                   java_lang_Object->GetObjectSize(),
                                                   VoidFunctor()));

  // Initialize the SubtypeCheck bitstring for java.lang.Object and java.lang.Class.
  if (kBitstringSubtypeCheckEnabled) {
    // It might seem the lock here is unnecessary, however all the SubtypeCheck
    // functions are annotated to require locks all the way down.
    //
    // We take the lock here to avoid using NO_THREAD_SAFETY_ANALYSIS.
    MutexLock subtype_check_lock(Thread::Current(), *Locks::subtype_check_lock_);
    SubtypeCheck<ObjPtr<mirror::Class>>::EnsureInitialized(java_lang_Object.Get());
    SubtypeCheck<ObjPtr<mirror::Class>>::EnsureInitialized(java_lang_Class.Get());
  }

  // Object[] next to hold class roots.
  Handle<mirror::Class> object_array_class(hs.NewHandle(
      AllocClass(self, java_lang_Class.Get(),
                 mirror::ObjectArray<mirror::Object>::ClassSize(image_pointer_size_))));
  object_array_class->SetComponentType(java_lang_Object.Get());

  // Setup java.lang.String.
  //
  // We make this class non-movable for the unlikely case where it were to be
  // moved by a sticky-bit (minor) collection when using the Generational
  // Concurrent Copying (CC) collector, potentially creating a stale reference
  // in the `klass_` field of one of its instances allocated in the Large-Object
  // Space (LOS) -- see the comment about the dirty card scanning logic in
  // art::gc::collector::ConcurrentCopying::MarkingPhase.
  Handle<mirror::Class> java_lang_String(hs.NewHandle(
      AllocClass</* kMovable= */ false>(
          self, java_lang_Class.Get(), mirror::String::ClassSize(image_pointer_size_))));
  java_lang_String->SetStringClass();
  mirror::Class::SetStatus(java_lang_String, ClassStatus::kResolved, self);

  // Setup java.lang.ref.Reference.
  Handle<mirror::Class> java_lang_ref_Reference(hs.NewHandle(
      AllocClass(self, java_lang_Class.Get(), mirror::Reference::ClassSize(image_pointer_size_))));
  java_lang_ref_Reference->SetObjectSize(mirror::Reference::InstanceSize());
  mirror::Class::SetStatus(java_lang_ref_Reference, ClassStatus::kResolved, self);

  // Create storage for root classes, save away our work so far (requires descriptors).
  class_roots_ = GcRoot<mirror::ObjectArray<mirror::Class>>(
      mirror::ObjectArray<mirror::Class>::Alloc(self,
                                                object_array_class.Get(),
                                                static_cast<int32_t>(ClassRoot::kMax)));
  CHECK(!class_roots_.IsNull());
  SetClassRoot(ClassRoot::kJavaLangClass, java_lang_Class.Get());
  SetClassRoot(ClassRoot::kJavaLangObject, java_lang_Object.Get());
  SetClassRoot(ClassRoot::kClassArrayClass, class_array_class.Get());
  SetClassRoot(ClassRoot::kObjectArrayClass, object_array_class.Get());
  SetClassRoot(ClassRoot::kJavaLangString, java_lang_String.Get());
  SetClassRoot(ClassRoot::kJavaLangRefReference, java_lang_ref_Reference.Get());

  // Fill in the empty iftable. Needs to be done after the kObjectArrayClass root is set.
  java_lang_Object->SetIfTable(AllocIfTable(self, 0));

  // Create array interface entries to populate once we can load system classes.
  object_array_class->SetIfTable(AllocIfTable(self, 2));
  DCHECK_EQ(GetArrayIfTable(), object_array_class->GetIfTable());

  // Setup the primitive type classes.
  CreatePrimitiveClass(self, Primitive::kPrimBoolean, ClassRoot::kPrimitiveBoolean);
  CreatePrimitiveClass(self, Primitive::kPrimByte, ClassRoot::kPrimitiveByte);
  CreatePrimitiveClass(self, Primitive::kPrimChar, ClassRoot::kPrimitiveChar);
  CreatePrimitiveClass(self, Primitive::kPrimShort, ClassRoot::kPrimitiveShort);
  CreatePrimitiveClass(self, Primitive::kPrimInt, ClassRoot::kPrimitiveInt);
  CreatePrimitiveClass(self, Primitive::kPrimLong, ClassRoot::kPrimitiveLong);
  CreatePrimitiveClass(self, Primitive::kPrimFloat, ClassRoot::kPrimitiveFloat);
  CreatePrimitiveClass(self, Primitive::kPrimDouble, ClassRoot::kPrimitiveDouble);
  CreatePrimitiveClass(self, Primitive::kPrimVoid, ClassRoot::kPrimitiveVoid);

  // Allocate the primitive array classes. We need only the native pointer
  // array at this point (int[] or long[], depending on architecture) but
  // we shall perform the same setup steps for all primitive array classes.
  AllocPrimitiveArrayClass(self, ClassRoot::kPrimitiveBoolean, ClassRoot::kBooleanArrayClass);
  AllocPrimitiveArrayClass(self, ClassRoot::kPrimitiveByte, ClassRoot::kByteArrayClass);
  AllocPrimitiveArrayClass(self, ClassRoot::kPrimitiveChar, ClassRoot::kCharArrayClass);
  AllocPrimitiveArrayClass(self, ClassRoot::kPrimitiveShort, ClassRoot::kShortArrayClass);
  AllocPrimitiveArrayClass(self, ClassRoot::kPrimitiveInt, ClassRoot::kIntArrayClass);
  AllocPrimitiveArrayClass(self, ClassRoot::kPrimitiveLong, ClassRoot::kLongArrayClass);
  AllocPrimitiveArrayClass(self, ClassRoot::kPrimitiveFloat, ClassRoot::kFloatArrayClass);
  AllocPrimitiveArrayClass(self, ClassRoot::kPrimitiveDouble, ClassRoot::kDoubleArrayClass);

  // now that these are registered, we can use AllocClass() and AllocObjectArray

  // Set up DexCache. This cannot be done later since AppendToBootClassPath calls AllocDexCache.
  Handle<mirror::Class> java_lang_DexCache(hs.NewHandle(
      AllocClass(self, java_lang_Class.Get(), mirror::DexCache::ClassSize(image_pointer_size_))));
  SetClassRoot(ClassRoot::kJavaLangDexCache, java_lang_DexCache.Get());
  java_lang_DexCache->SetDexCacheClass();
  java_lang_DexCache->SetObjectSize(mirror::DexCache::InstanceSize());
  mirror::Class::SetStatus(java_lang_DexCache, ClassStatus::kResolved, self);


  // Setup dalvik.system.ClassExt
  Handle<mirror::Class> dalvik_system_ClassExt(hs.NewHandle(
      AllocClass(self, java_lang_Class.Get(), mirror::ClassExt::ClassSize(image_pointer_size_))));
  SetClassRoot(ClassRoot::kDalvikSystemClassExt, dalvik_system_ClassExt.Get());
  mirror::Class::SetStatus(dalvik_system_ClassExt, ClassStatus::kResolved, self);

  // Set up array classes for string, field, method
  Handle<mirror::Class> object_array_string(hs.NewHandle(
      AllocClass(self, java_lang_Class.Get(),
                 mirror::ObjectArray<mirror::String>::ClassSize(image_pointer_size_))));
  object_array_string->SetComponentType(java_lang_String.Get());
  SetClassRoot(ClassRoot::kJavaLangStringArrayClass, object_array_string.Get());

  LinearAlloc* linear_alloc = runtime->GetLinearAlloc();
  // Create runtime resolution and imt conflict methods.
  runtime->SetResolutionMethod(runtime->CreateResolutionMethod());
  runtime->SetImtConflictMethod(runtime->CreateImtConflictMethod(linear_alloc));
  runtime->SetImtUnimplementedMethod(runtime->CreateImtConflictMethod(linear_alloc));

  // Setup boot_class_path_ and register class_path now that we can use AllocObjectArray to create
  // DexCache instances. Needs to be after String, Field, Method arrays since AllocDexCache uses
  // these roots.
  if (boot_class_path.empty()) {
    *error_msg = "Boot classpath is empty.";
    return false;
  }
  for (auto& dex_file : boot_class_path) {
    if (dex_file == nullptr) {
      *error_msg = "Null dex file.";
      return false;
    }
    AppendToBootClassPath(self, dex_file.get());
    boot_dex_files_.push_back(std::move(dex_file));
  }

  // now we can use FindSystemClass

  // Set up GenericJNI entrypoint. That is mainly a hack for common_compiler_test.h so that
  // we do not need friend classes or a publicly exposed setter.
  quick_generic_jni_trampoline_ = GetQuickGenericJniStub();
  if (!runtime->IsAotCompiler()) {
    // We need to set up the generic trampolines since we don't have an image.
    jni_dlsym_lookup_trampoline_ = GetJniDlsymLookupStub();
    jni_dlsym_lookup_critical_trampoline_ = GetJniDlsymLookupCriticalStub();
    quick_resolution_trampoline_ = GetQuickResolutionStub();
    quick_imt_conflict_trampoline_ = GetQuickImtConflictStub();
    quick_generic_jni_trampoline_ = GetQuickGenericJniStub();
    quick_to_interpreter_bridge_trampoline_ = GetQuickToInterpreterBridge();
  }

  // Object, String, ClassExt and DexCache need to be rerun through FindSystemClass to finish init
  mirror::Class::SetStatus(java_lang_Object, ClassStatus::kNotReady, self);
  CheckSystemClass(self, java_lang_Object, "Ljava/lang/Object;");
  CHECK_EQ(java_lang_Object->GetObjectSize(), mirror::Object::InstanceSize());
  mirror::Class::SetStatus(java_lang_String, ClassStatus::kNotReady, self);
  CheckSystemClass(self, java_lang_String, "Ljava/lang/String;");
  mirror::Class::SetStatus(java_lang_DexCache, ClassStatus::kNotReady, self);
  CheckSystemClass(self, java_lang_DexCache, "Ljava/lang/DexCache;");
  CHECK_EQ(java_lang_DexCache->GetObjectSize(), mirror::DexCache::InstanceSize());
  mirror::Class::SetStatus(dalvik_system_ClassExt, ClassStatus::kNotReady, self);
  CheckSystemClass(self, dalvik_system_ClassExt, "Ldalvik/system/ClassExt;");
  CHECK_EQ(dalvik_system_ClassExt->GetObjectSize(), mirror::ClassExt::InstanceSize());

  // Run Class through FindSystemClass. This initializes the dex_cache_ fields and register it
  // in class_table_.
  CheckSystemClass(self, java_lang_Class, "Ljava/lang/Class;");

  // Setup core array classes, i.e. Object[], String[] and Class[] and primitive
  // arrays - can't be done until Object has a vtable and component classes are loaded.
  FinishCoreArrayClassSetup(ClassRoot::kObjectArrayClass);
  FinishCoreArrayClassSetup(ClassRoot::kClassArrayClass);
  FinishCoreArrayClassSetup(ClassRoot::kJavaLangStringArrayClass);
  FinishCoreArrayClassSetup(ClassRoot::kBooleanArrayClass);
  FinishCoreArrayClassSetup(ClassRoot::kByteArrayClass);
  FinishCoreArrayClassSetup(ClassRoot::kCharArrayClass);
  FinishCoreArrayClassSetup(ClassRoot::kShortArrayClass);
  FinishCoreArrayClassSetup(ClassRoot::kIntArrayClass);
  FinishCoreArrayClassSetup(ClassRoot::kLongArrayClass);
  FinishCoreArrayClassSetup(ClassRoot::kFloatArrayClass);
  FinishCoreArrayClassSetup(ClassRoot::kDoubleArrayClass);

  // Setup the single, global copy of "iftable".
  auto java_lang_Cloneable = hs.NewHandle(FindSystemClass(self, "Ljava/lang/Cloneable;"));
  CHECK(java_lang_Cloneable != nullptr);
  auto java_io_Serializable = hs.NewHandle(FindSystemClass(self, "Ljava/io/Serializable;"));
  CHECK(java_io_Serializable != nullptr);
  // We assume that Cloneable/Serializable don't have superinterfaces -- normally we'd have to
  // crawl up and explicitly list all of the supers as well.
  object_array_class->GetIfTable()->SetInterface(0, java_lang_Cloneable.Get());
  object_array_class->GetIfTable()->SetInterface(1, java_io_Serializable.Get());

  // Check Class[] and Object[]'s interfaces. GetDirectInterface may cause thread suspension.
  CHECK_EQ(java_lang_Cloneable.Get(),
           mirror::Class::GetDirectInterface(self, class_array_class.Get(), 0));
  CHECK_EQ(java_io_Serializable.Get(),
           mirror::Class::GetDirectInterface(self, class_array_class.Get(), 1));
  CHECK_EQ(java_lang_Cloneable.Get(),
           mirror::Class::GetDirectInterface(self, object_array_class.Get(), 0));
  CHECK_EQ(java_io_Serializable.Get(),
           mirror::Class::GetDirectInterface(self, object_array_class.Get(), 1));

  CHECK_EQ(object_array_string.Get(),
           FindSystemClass(self, GetClassRootDescriptor(ClassRoot::kJavaLangStringArrayClass)));

  // End of special init trickery, all subsequent classes may be loaded via FindSystemClass.

  // Create java.lang.reflect.Proxy root.
  SetClassRoot(ClassRoot::kJavaLangReflectProxy,
               FindSystemClass(self, "Ljava/lang/reflect/Proxy;"));

  // Create java.lang.reflect.Field.class root.
  ObjPtr<mirror::Class> class_root = FindSystemClass(self, "Ljava/lang/reflect/Field;");
  CHECK(class_root != nullptr);
  SetClassRoot(ClassRoot::kJavaLangReflectField, class_root);

  // Create java.lang.reflect.Field array root.
  class_root = FindSystemClass(self, "[Ljava/lang/reflect/Field;");
  CHECK(class_root != nullptr);
  SetClassRoot(ClassRoot::kJavaLangReflectFieldArrayClass, class_root);

  // Create java.lang.reflect.Constructor.class root and array root.
  class_root = FindSystemClass(self, "Ljava/lang/reflect/Constructor;");
  CHECK(class_root != nullptr);
  SetClassRoot(ClassRoot::kJavaLangReflectConstructor, class_root);
  class_root = FindSystemClass(self, "[Ljava/lang/reflect/Constructor;");
  CHECK(class_root != nullptr);
  SetClassRoot(ClassRoot::kJavaLangReflectConstructorArrayClass, class_root);

  // Create java.lang.reflect.Method.class root and array root.
  class_root = FindSystemClass(self, "Ljava/lang/reflect/Method;");
  CHECK(class_root != nullptr);
  SetClassRoot(ClassRoot::kJavaLangReflectMethod, class_root);
  class_root = FindSystemClass(self, "[Ljava/lang/reflect/Method;");
  CHECK(class_root != nullptr);
  SetClassRoot(ClassRoot::kJavaLangReflectMethodArrayClass, class_root);

  // Create java.lang.invoke.CallSite.class root
  class_root = FindSystemClass(self, "Ljava/lang/invoke/CallSite;");
  CHECK(class_root != nullptr);
  SetClassRoot(ClassRoot::kJavaLangInvokeCallSite, class_root);

  // Create java.lang.invoke.MethodType.class root
  class_root = FindSystemClass(self, "Ljava/lang/invoke/MethodType;");
  CHECK(class_root != nullptr);
  SetClassRoot(ClassRoot::kJavaLangInvokeMethodType, class_root);

  // Create java.lang.invoke.MethodHandleImpl.class root
  class_root = FindSystemClass(self, "Ljava/lang/invoke/MethodHandleImpl;");
  CHECK(class_root != nullptr);
  SetClassRoot(ClassRoot::kJavaLangInvokeMethodHandleImpl, class_root);
  SetClassRoot(ClassRoot::kJavaLangInvokeMethodHandle, class_root->GetSuperClass());

  // Create java.lang.invoke.MethodHandles.Lookup.class root
  class_root = FindSystemClass(self, "Ljava/lang/invoke/MethodHandles$Lookup;");
  CHECK(class_root != nullptr);
  SetClassRoot(ClassRoot::kJavaLangInvokeMethodHandlesLookup, class_root);

  // Create java.lang.invoke.VarHandle.class root
  class_root = FindSystemClass(self, "Ljava/lang/invoke/VarHandle;");
  CHECK(class_root != nullptr);
  SetClassRoot(ClassRoot::kJavaLangInvokeVarHandle, class_root);

  // Create java.lang.invoke.FieldVarHandle.class root
  class_root = FindSystemClass(self, "Ljava/lang/invoke/FieldVarHandle;");
  CHECK(class_root != nullptr);
  SetClassRoot(ClassRoot::kJavaLangInvokeFieldVarHandle, class_root);

  // Create java.lang.invoke.ArrayElementVarHandle.class root
  class_root = FindSystemClass(self, "Ljava/lang/invoke/ArrayElementVarHandle;");
  CHECK(class_root != nullptr);
  SetClassRoot(ClassRoot::kJavaLangInvokeArrayElementVarHandle, class_root);

  // Create java.lang.invoke.ByteArrayViewVarHandle.class root
  class_root = FindSystemClass(self, "Ljava/lang/invoke/ByteArrayViewVarHandle;");
  CHECK(class_root != nullptr);
  SetClassRoot(ClassRoot::kJavaLangInvokeByteArrayViewVarHandle, class_root);

  // Create java.lang.invoke.ByteBufferViewVarHandle.class root
  class_root = FindSystemClass(self, "Ljava/lang/invoke/ByteBufferViewVarHandle;");
  CHECK(class_root != nullptr);
  SetClassRoot(ClassRoot::kJavaLangInvokeByteBufferViewVarHandle, class_root);

  class_root = FindSystemClass(self, "Ldalvik/system/EmulatedStackFrame;");
  CHECK(class_root != nullptr);
  SetClassRoot(ClassRoot::kDalvikSystemEmulatedStackFrame, class_root);

  // java.lang.ref classes need to be specially flagged, but otherwise are normal classes
  // finish initializing Reference class
  mirror::Class::SetStatus(java_lang_ref_Reference, ClassStatus::kNotReady, self);
  CheckSystemClass(self, java_lang_ref_Reference, "Ljava/lang/ref/Reference;");
  CHECK_EQ(java_lang_ref_Reference->GetObjectSize(), mirror::Reference::InstanceSize());
  CHECK_EQ(java_lang_ref_Reference->GetClassSize(),
           mirror::Reference::ClassSize(image_pointer_size_));
  class_root = FindSystemClass(self, "Ljava/lang/ref/FinalizerReference;");
  CHECK_EQ(class_root->GetClassFlags(), mirror::kClassFlagNormal);
  class_root->SetClassFlags(class_root->GetClassFlags() | mirror::kClassFlagFinalizerReference);
  class_root = FindSystemClass(self, "Ljava/lang/ref/PhantomReference;");
  CHECK_EQ(class_root->GetClassFlags(), mirror::kClassFlagNormal);
  class_root->SetClassFlags(class_root->GetClassFlags() | mirror::kClassFlagPhantomReference);
  class_root = FindSystemClass(self, "Ljava/lang/ref/SoftReference;");
  CHECK_EQ(class_root->GetClassFlags(), mirror::kClassFlagNormal);
  class_root->SetClassFlags(class_root->GetClassFlags() | mirror::kClassFlagSoftReference);
  class_root = FindSystemClass(self, "Ljava/lang/ref/WeakReference;");
  CHECK_EQ(class_root->GetClassFlags(), mirror::kClassFlagNormal);
  class_root->SetClassFlags(class_root->GetClassFlags() | mirror::kClassFlagWeakReference);

  // Setup the ClassLoader, verifying the object_size_.
  class_root = FindSystemClass(self, "Ljava/lang/ClassLoader;");
  class_root->SetClassLoaderClass();
  CHECK_EQ(class_root->GetObjectSize(), mirror::ClassLoader::InstanceSize());
  SetClassRoot(ClassRoot::kJavaLangClassLoader, class_root);

  // Set up java.lang.Throwable, java.lang.ClassNotFoundException, and
  // java.lang.StackTraceElement as a convenience.
  SetClassRoot(ClassRoot::kJavaLangThrowable, FindSystemClass(self, "Ljava/lang/Throwable;"));
  SetClassRoot(ClassRoot::kJavaLangClassNotFoundException,
               FindSystemClass(self, "Ljava/lang/ClassNotFoundException;"));
  SetClassRoot(ClassRoot::kJavaLangStackTraceElement,
               FindSystemClass(self, "Ljava/lang/StackTraceElement;"));
  SetClassRoot(ClassRoot::kJavaLangStackTraceElementArrayClass,
               FindSystemClass(self, "[Ljava/lang/StackTraceElement;"));
  SetClassRoot(ClassRoot::kJavaLangClassLoaderArrayClass,
               FindSystemClass(self, "[Ljava/lang/ClassLoader;"));

  // Create conflict tables that depend on the class linker.
  runtime->FixupConflictTables();

  FinishInit(self);

  VLOG(startup) << "ClassLinker::InitFromCompiler exiting";

  return true;
}
```

可以看到这个方法里面有很多java最基础的类。